#!/bin/bash

# ==============================================================================
# Smart Traffic Limiter Manager - (智能检测Realm TOML配置并创建易用命令)
# Author: Gemini AI
# Version: 2.3 - Added auto symlink creation for easy command access
# ==============================================================================

# --- 全局变量和颜色定义 ---
CONFIG_FILE="/etc/traffic_limits.conf"
REALM_CONFIG_TOML="/root/.realm/config.toml"
# 主脚本的最终安装路径
MAIN_SCRIPT_PATH="/usr/local/bin/smart-limiter-toml-manager" # 将脚本主体安装到这个特定名称
# 用户调用的简洁命令
EASY_COMMAND_NAME="slm"
EASY_COMMAND_PATH="/usr/local/bin/${EASY_COMMAND_NAME}"

LIMITER_SCRIPT="/usr/local/bin/traffic_limiter.sh" # 后台监控脚本
SETUP_SCRIPT="/usr/local/bin/setup_traffic_limits.sh"   # iptables设置脚本
STATUS_SCRIPT="/usr/local/bin/check_traffic_status.sh" # 状态检查脚本 (可被主脚本内部调用)

LOG_FILE="/var/log/traffic_limiter.log"
CRON_JOB_CMD="${LIMITER_SCRIPT}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 检查是否为 root 用户 ---
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}错误：此脚本必须以 root 用户权限运行。请使用 'sudo'。${NC}"
        exit 1
    fi
}

# --- 功能函数定义 ---

install_dependencies() {
    echo -e "${GREEN}--> 1. 正在检查并安装依赖 (iptables-persistent, bc)...${NC}"
    apt-get update >/dev/null 2>&1
    if ! dpkg -s iptables-persistent &> /dev/null || ! dpkg -s bc &> /dev/null; then
        apt-get install -y iptables-persistent bc >/dev/null 2>&1
    fi
    for cmd in grep awk sed curl; do # curl 也是一键安装的依赖
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}错误: 命令 '$cmd' 未找到，请先安装它。${NC}"
            exit 1
        fi
    done
    echo "依赖安装完成。"
}

detect_and_populate_config_toml() {
    echo -e "${GREEN}--> 2. 正在尝试自动检测 Realm TOML 配置...${NC}"
    if [ -f "$REALM_CONFIG_TOML" ]; then
        echo -e "${GREEN}成功！发现 Realm TOML 配置文件: ${REALM_CONFIG_TOML}${NC}"
        
        if [ -f "$CONFIG_FILE" ]; then
            echo -e "${YELLOW}检测到您已有一个流量限制配置文件 (${CONFIG_FILE})。${NC}"
            read -p "请选择操作: [1]合并 [2]覆盖 [3]跳过 (默认1): " choice
            case "$choice" in
                2) rm -f "$CONFIG_FILE";;
                3) echo "已跳过自动配置。"; return 0;;
                *) ;;
            esac
        fi

        echo "正在解析 Realm TOML 规则，请为每条规则设置流量限制:"
        local in_endpoints_block=0
        local current_listen_port=""

        while IFS= read -r line; do
            line_trimmed=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//' | sed 's/#.*//')
            if [[ "$line_trimmed" == "[[endpoints]]" ]]; then
                in_endpoints_block=1
                current_listen_port=""
                continue
            fi
            if [[ $in_endpoints_block -eq 1 && "$line_trimmed" == listen* ]]; then
                PORT=$(echo "$line_trimmed" | grep -oP 'listen\s*=\s*"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\K([0-9]+)(?=")')
                if [ -z "$PORT" ]; then PORT=$(echo "$line_trimmed" | grep -oP 'listen\s*=\s*":\K([0-9]+)(?=")'); fi
                if [ -z "$PORT" ]; then PORT=$(echo "$line_trimmed" | grep -oP 'listen\s*=\s*"\K([0-9]+)(?=")'); fi
                if [ -n "$PORT" ]; then
                    current_listen_port=$PORT
                    if [ -f "$CONFIG_FILE" ] && grep -q "^${current_listen_port} " "$CONFIG_FILE"; then
                        echo -e "${YELLOW}端口 ${current_listen_port} 已存在于配置中，跳过。${NC}"
                        continue
                    fi
                    echo "-----------------------------------------------------"
                    echo -e "检测到转发规则，监听端口: ${YELLOW}${current_listen_port}${NC}"
                    read -p "  - 请为此规则设置每月双向流量限制 (GB, 默认 500): " limit_gb
                    limit_gb=${limit_gb:-500}
                    read -p "  - 请为此规则设置一个名称 (默认 Realm-${current_listen_port}): " rule_name
                    rule_name=${rule_name:-"Realm-${current_listen_port}"}
                    echo "${current_listen_port} ${limit_gb} ${rule_name}" >> "$CONFIG_FILE"
                    echo -e "${GREEN}规则已添加: ${current_listen_port} -> ${limit_gb}GB -> ${rule_name}${NC}"
                fi
            elif [[ $in_endpoints_block -eq 1 && ! "$line_trimmed" =~ ^\s*$ && ! "$line_trimmed" =~ ^remote\s*= && ! "$line_trimmed" =~ ^\[ ]]; then
                if [[ "$line_trimmed" == "[[endpoints]]" ]]; then
                     in_endpoints_block=1
                     current_listen_port=""
                else
                    in_endpoints_block=0
                fi
            fi
        done < "$REALM_CONFIG_TOML"

        if [ ! -s "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
             echo -e "${RED}无法从Realm TOML配置中解析出任何规则，或您选择不添加。请检查 ${REALM_CONFIG_TOML} 文件格式是否正确。${NC}"
             return 1
        elif [ ! -s "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
            echo -e "${YELLOW}未从Realm TOML配置中添加任何新规则 (可能已存在或未解析到)。${NC}"
        fi
        echo "-----------------------------------------------------"
        echo -e "${GREEN}Realm TOML 规则自动配置完成！${NC}"
        if [ -f "$CONFIG_FILE" ]; then
            echo "最终配置文件内容如下:"
            echo -e "${YELLOW}"
            cat "$CONFIG_FILE"
            echo -e "${NC}"
        fi
        read -p "确认无误后，请按 [Enter] 键继续..."
        return 0
    else
        echo -e "${YELLOW}未找到 Realm TOML 配置文件 (${REALM_CONFIG_TOML})。${NC}"
        return 1
    fi
}

create_manual_config() {
    echo -e "${GREEN}--> 将为您创建通用配置文件...${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件 ${CONFIG_FILE} 已存在，跳过创建。${NC}"
        return
    fi
    cat << 'EOF' > "$CONFIG_FILE"
# 格式: <端口号> <流量限制GB> <一个易于识别的名称>
8001 500 Realm-US-Node
8002 100 Game-Server-Minecraft
EOF
    echo "通用配置文件已创建于 ${CONFIG_FILE}"
    echo -e "\n${YELLOW}重要：请立即编辑此文件，根据您的需求修改端口和流量限制。${NC}"
    read -p "编辑完成后，请按 [Enter] 键继续安装..."
}

create_helper_scripts() {
    # 1. 规则设置脚本 (setup_traffic_limits.sh)
    cat << 'EOF' > "$SETUP_SCRIPT"
#!/bin/bash
CONFIG_FILE="/etc/traffic_limits.conf"
echo "正在根据 ${CONFIG_FILE} 设置流量限制规则..."
for rule_num in $(iptables -L FORWARD --line-numbers 2>/dev/null | grep "TRAFFIC_LIMIT_" | awk '{print $1}' | sort -r); do
    iptables -D FORWARD ${rule_num}
done
for chain in $(iptables -L 2>/dev/null | grep "Chain TRAFFIC_LIMIT_" | awk '{print $2}'); do
    iptables -F ${chain}; iptables -X ${chain}
done
echo "旧规则已清理。"
if [ ! -f "$CONFIG_FILE" ]; then echo "错误：配置文件 ${CONFIG_FILE} 未找到！"; exit 1; fi
grep -v "^#" ${CONFIG_FILE} | while read -r PORT LIMIT NAME; do
    if [ -n "$PORT" ]; then
        CHAIN_NAME="TRAFFIC_LIMIT_${PORT}"
        echo "为端口 ${PORT} (${NAME}) 创建规则..."
        iptables -N ${CHAIN_NAME}
        iptables -A FORWARD -p tcp --dport ${PORT} -j ${CHAIN_NAME}
        iptables -A FORWARD -p tcp --sport ${PORT} -j ${CHAIN_NAME}
        iptables -A FORWARD -p udp --dport ${PORT} -j ${CHAIN_NAME}
        iptables -A FORWARD -p udp --sport ${PORT} -j ${CHAIN_NAME}
        iptables -A ${CHAIN_NAME} -j ACCEPT
    fi
done
if sudo netfilter-persistent save >/dev/null 2>&1; then
    echo "新规则已创建并保存。"
else
    echo -e "\033[0;31m错误：保存 iptables 规则失败。请确保 iptables-persistent 已正确安装和配置。\033[0m"
fi
EOF

    # 2. 后台监控限制脚本 (traffic_limiter.sh)
    cat << 'EOF' > "$LIMITER_SCRIPT"
#!/bin/bash
CONFIG_FILE="/etc/traffic_limits.conf"
LOG_FILE="/var/log/traffic_limiter.log"
if [ ! -f "$CONFIG_FILE" ]; then exit 0; fi
grep -v "^#" ${CONFIG_FILE} | while read -r PORT LIMIT_GB NAME; do
    if [ -n "$PORT" ]; then
        LIMIT_BYTES=$((LIMIT_GB * 1024 * 1024 * 1024))
        CHAIN_NAME="TRAFFIC_LIMIT_${PORT}"
        TRAFFIC_BYTES=$(iptables -L FORWARD -v -n -x 2>/dev/null | grep "${CHAIN_NAME}" | awk '{print $2}' | paste -sd+ | bc)
        if [ -z "$TRAFFIC_BYTES" ]; then TRAFFIC_BYTES=0; fi
        if [ "$LIMIT_BYTES" -gt 0 ] && [ "$TRAFFIC_BYTES" -gt "$LIMIT_BYTES" ]; then
            if ! iptables -C FORWARD -p tcp --dport ${PORT} -j DROP &> /dev/null; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): 端口 ${PORT} (${NAME}) 流量超限! 已用: ${TRAFFIC_BYTES} B. 正在禁用..." >> "$LOG_FILE"
                iptables -I FORWARD 1 -p tcp --dport ${PORT} -j DROP
                iptables -I FORWARD 1 -p udp --dport ${PORT} -j DROP
                iptables -I FORWARD 1 -p tcp --sport ${PORT} -j DROP
                iptables -I FORWARD 1 -p udp --sport ${PORT} -j DROP
                sudo netfilter-persistent save >/dev/null 2>&1
            fi
        fi
    fi
done
exit 0
EOF
    
    # 3. 可视化状态检查脚本 (由主脚本内部调用)
    # 这个脚本不再需要用户直接执行，所以可以不创建，或者创建一个内部使用的版本
    # 为简单起见，我们让主脚本直接包含状态显示逻辑

    chmod +x "$SETUP_SCRIPT" "$LIMITER_SCRIPT"
}

setup_cron_job() {
    (crontab -l 2>/dev/null | grep -v "$CRON_JOB_CMD") | { cat; echo "*/5 * * * * $CRON_JOB_CMD"; } | crontab -
}

# 主管理脚本自身的内容 (将被复制到 MAIN_SCRIPT_PATH)
# 注意：这里的 $0 在一键安装时是 curl 的输出，不是脚本文件名
# 所以我们需要在安装时将脚本内容写入目标文件
create_main_manager_script_content() {
cat << EOFMGR
#!/bin/bash
# 这是安装到 ${MAIN_SCRIPT_PATH} 的主管理脚本
# 它会被符号链接到 ${EASY_COMMAND_PATH} (${EASY_COMMAND_NAME})

CONFIG_FILE="/etc/traffic_limits.conf"
SETUP_SCRIPT="/usr/local/bin/setup_traffic_limits.sh" # 确保这里的路径正确
LOG_FILE="/var/log/traffic_limiter.log"
EASY_COMMAND_NAME="${EASY_COMMAND_NAME}"
MAIN_SCRIPT_PATH_INTERNAL="${MAIN_SCRIPT_PATH}" # 内部使用
EASY_COMMAND_PATH_INTERNAL="${EASY_COMMAND_PATH}"
LIMITER_SCRIPT_INTERNAL="${LIMITER_SCRIPT}" # 卸载时需要

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_root_internal() {
    if [[ "\$EUID" -ne 0 ]]; then
        echo -e "\${RED}错误：此命令必须以 root 用户权限运行。请使用 'sudo \${EASY_COMMAND_NAME} <action>'。 \${NC}"
        exit 1
    fi
}

show_status_internal() {
    check_root_internal
    echo -e "\n--- iptables 流量使用状态报告 ---\n"
    if [ ! -f "\$CONFIG_FILE" ]; then echo "错误：配置文件 \$CONFIG_FILE 未找到！"; exit 1; fi
    grep -v "^#" "\$CONFIG_FILE" | while read -r PORT LIMIT_GB NAME; do
        if [ -n "\$PORT" ]; then
            LIMIT_BYTES=\$((LIMIT_GB * 1024 * 1024 * 1024))
            CHAIN_NAME="TRAFFIC_LIMIT_\${PORT}"
            TRAFFIC_BYTES=\$(iptables -L FORWARD -v -n -x 2>/dev/null | grep "\${CHAIN_NAME}" | awk '{print \$2}' | paste -sd+ | bc)
            if [ -z "\$TRAFFIC_BYTES" ]; then TRAFFIC_BYTES=0; fi
            TRAFFIC_GB=\$(echo "scale=2; \${TRAFFIC_BYTES} / 1024 / 1024 / 1024" | bc)
            PERCENTAGE=\$(echo "scale=2; if(\${LIMIT_BYTES} > 0) \${TRAFFIC_BYTES} * 100 / \${LIMIT_BYTES} else 0" | bc | awk '{printf "%.0f", \$1}')
            BAR=\$(for ((i=0; i<40; i++)); do if [ \$(echo "\${PERCENTAGE} * 40 / 100" | bc) -gt \$i ]; then echo -n "#"; else echo -n "-"; fi; done)
            echo -e "规则: \${YELLOW}\${NAME} (端口: \${PORT})\${NC}"
            echo -e "  配额: \${GREEN}\${LIMIT_GB} GB\${NC}, 已用: \${GREEN}\${TRAFFIC_GB} GB\${NC}"
            echo -e "  进度: [\${BAR}] \${PERCENTAGE}%"
            if iptables -C FORWARD -p tcp --dport \${PORT} -j DROP &> /dev/null; then
                echo -e "  状态: \${RED}已禁用 (流量超限)\${NC}"
            else
                echo -e "  状态: \${GREEN}正常\${NC}"
            fi
            echo ""
        fi
    done
}

reset_rules_internal() {
    check_root_internal
    echo "正在重置 iptables 规则..."
    bash "\$SETUP_SCRIPT" # 调用独立的设置脚本
    echo "重置完成。"
}

uninstall_internal() {
    check_root_internal
    echo -e "\${RED}您确定要卸载流量限制器 (\${EASY_COMMAND_NAME}) 吗？ (y/n)\${NC}"
    read -r confirmation
    if [[ "\$confirmation" != "y" && "\$confirmation" != "Y" ]]; then echo "卸载已取消。"; exit 0; fi
    
    echo "--> 1. 正在移除定时任务..."
    (crontab -l 2>/dev/null | grep -v "${CRON_JOB_CMD}") | crontab -
    
    echo "--> 2. 正在清理 iptables 规则..."
    tmpext=\$(date +%s); mv \$CONFIG_FILE \${CONFIG_FILE}.\$tmpext 2>/dev/null; touch \$CONFIG_FILE
    bash "\$SETUP_SCRIPT" >/dev/null 2>&1; rm \$CONFIG_FILE; mv \${CONFIG_FILE}.\$tmpext \$CONFIG_FILE 2>/dev/null
    
    echo "--> 3. 正在删除核心脚本文件..."
    rm -f "\${LIMITER_SCRIPT_INTERNAL}" "\${SETUP_SCRIPT}" "\${MAIN_SCRIPT_PATH_INTERNAL}"
    
    echo "--> 4. 正在删除易用命令符号链接..."
    rm -f "\${EASY_COMMAND_PATH_INTERNAL}"
    
    read -p "是否删除配置文件 \${CONFIG_FILE}？ (y/n)" del_conf
    if [[ "\$del_conf" == "y" ]]; then rm -f "\$CONFIG_FILE"; fi
    
    read -p "是否删除日志文件 \${LOG_FILE}？ (y/n)" del_log
    if [[ "\$del_log" == "y" ]]; then rm -f "\$LOG_FILE"; fi
    
    echo -e "\${GREEN}卸载完成。${NC}"
}


case "\$1" in
    status|s) show_status_internal;;
    reset|r) reset_rules_internal;;
    uninstall|u) uninstall_internal;;
    # 'install' 命令由外部一键脚本处理，这里不需要
    *)
        echo "智能流量限制器管理命令 (\${EASY_COMMAND_NAME})"
        echo "用法: sudo \${EASY_COMMAND_NAME} {status|reset|uninstall}"
        echo "  status     - (或 s) 显示当前所有规则的流量使用状态"
        echo "  reset      - (或 r) 根据配置文件重新应用iptables规则"
        echo "  uninstall  - (或 u) 卸载所有组件"
        exit 1
        ;;
esac
exit 0
EOFMGR
}


do_install() {
    check_root
    echo "--- 开始安装智能流量限制器 (TOML兼容版, v2.3) ---"
    install_dependencies
    
    detect_and_populate_config_toml
    local detection_result=$?
    if [ $detection_result -ne 0 ]; then
        create_manual_config
    fi
    
    echo -e "${GREEN}--> 3. 正在创建辅助脚本...${NC}"
    create_helper_scripts # 创建 setup_traffic_limits.sh 和 traffic_limiter.sh
    
    echo -e "${GREEN}--> 4. 正在创建主管理脚本...${NC}"
    create_main_manager_script_content > "$MAIN_SCRIPT_PATH" # 将管理脚本内容写入文件
    chmod +x "$MAIN_SCRIPT_PATH"

    echo -e "${GREEN}--> 5. 正在创建易用命令符号链接 (${EASY_COMMAND_NAME})...${NC}"
    if [ -f "$EASY_COMMAND_PATH" ]; then
        echo -e "${YELLOW}符号链接 ${EASY_COMMAND_PATH} 已存在，将尝试覆盖。${NC}"
        rm -f "$EASY_COMMAND_PATH"
    fi
    ln -s "$MAIN_SCRIPT_PATH" "$EASY_COMMAND_PATH"
    if [ -L "$EASY_COMMAND_PATH" ]; then
        echo -e "${GREEN}易用命令 '${EASY_COMMAND_NAME}' 创建成功！${NC}"
    else
        echo -e "${RED}错误：创建符号链接失败。请检查权限或路径。${NC}"
    fi

    echo -e "${GREEN}--> 6. 正在应用 iptables 规则...${NC}"
    bash "$SETUP_SCRIPT" # 使用独立的设置脚本

    echo -e "${GREEN}--> 7. 正在设置定时任务...${NC}"
    setup_cron_job
    
    echo -e "\n${YELLOW}是否需要现在安装 Netdata 以获得最佳的 Web 可视化监控？(y/n)${NC}"
    read -r install_netdata
    if [[ "$install_netdata" == "y" || "$install_netdata" == "Y" ]]; then
        echo -e "${GREEN}--> 正在安装 Netdata...${NC}"
        bash <(curl -Ss https://my-netdata.io/kickstart.sh) --dont-wait
        echo -e "${GREEN}Netdata 安装请求已发送，它将在后台继续安装。${NC}"
    fi

    echo -e "\n${GREEN}恭喜！流量限制器已安装并激活成功！${NC}"
    echo -e "您现在可以使用 'sudo ${EASY_COMMAND_NAME} status' 命令检查流量使用情况。"
    echo -e "要管理您的规则，请编辑 ${CONFIG_FILE} 然后运行 'sudo ${EASY_COMMAND_NAME} reset'。"
}

# 注意：uninstall, status, reset 的主逻辑现在在 MAIN_SCRIPT_PATH 指向的脚本中
# 这个外部脚本主要负责 install 和作为调用其他命令的入口（如果用户直接运行此文件）

# --- 主程序入口 ---
# 这个外部脚本现在主要负责 'install'
# 其他命令 (status, reset, uninstall) 将通过符号链接调用 MAIN_SCRIPT_PATH
if [ "$(basename "$0")" == "smart-limiter-toml.sh" ] || [[ "$0" == "bash" && ( "$1" == "-c" || "$1" == "-s" ) ]]; then
    # 当作为独立脚本执行时 (例如通过 curl ... | bash -s install)
    # 或者通过 bash some_script.sh install
    # 注意: bash -c "..." install 时，$1 是 "install"
    # curl | bash -s install 时，$1 也是 "install"
    
    # 如果是 bash -c "curl..." install, 那么 $1 是 "install"
    # 如果是 bash smart-limiter-toml.sh install, 那么 $1 是 "install"

    # 获取真正的动作参数
    # 如果 $0 是 bash, 且 $1 是 -c 或 -s, 那么真正的参数从 $2 开始
    if [[ "$0" == "bash" && ( "$1" == "-c" || "$1" == "-s" ) ]]; then
        ACTION_PARAM="$2"
    else
        ACTION_PARAM="$1"
    fi

    case "$ACTION_PARAM" in
        install|i) do_install;;
        uninstall|u|status|s|reset|r)
            echo -e "${YELLOW}提示: 脚本已安装。请使用 'sudo ${EASY_COMMAND_NAME} ${ACTION_PARAM}' 进行操作。${NC}"
            echo -e "如果 '${EASY_COMMAND_NAME}' 命令无效，请确保 ${EASY_COMMAND_PATH} 在您的 PATH 中，或重新运行安装程序。"
            if [ -x "${EASY_COMMAND_PATH}" ]; then
                 sudo "${EASY_COMMAND_PATH}" "${ACTION_PARAM}"
            fi
            ;;
        *)
            echo "智能流量限制器一键安装脚本 (v2.3)"
            echo "用法 (首次安装): sudo bash -c \"\$(curl -sL URL_TO_SCRIPT)\" install"
            echo "或下载后: sudo bash your_script_name.sh install"
            echo "安装后，请使用 'sudo ${EASY_COMMAND_NAME} <command>' 进行管理。"
            exit 1
            ;;
    esac
else
    # 当通过符号链接 (如 slm) 调用时，MAIN_SCRIPT_PATH 内部的 case 语句会处理
    # 此时 $0 会是 EASY_COMMAND_PATH (例如 /usr/local/bin/slm)
    # MAIN_SCRIPT_PATH 脚本会正确处理这种情况
    :
fi

exit 0
