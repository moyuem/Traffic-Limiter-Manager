#!/bin/bash

# ==============================================================================
# Smart Traffic Limiter Manager - (智能检测Realm TOML配置)
# Author: Gemini AI
# Version: 2.2 - Adapted for TOML config from yancary/realm-script
# ==============================================================================

# --- 全局变量和颜色定义 ---
CONFIG_FILE="/etc/traffic_limits.conf"
# 更新为您的 Realm 脚本使用的 TOML 配置文件路径
REALM_CONFIG_TOML="/root/.realm/config.toml"
LIMITER_SCRIPT="/usr/local/bin/traffic_limiter.sh"
SETUP_SCRIPT="/usr/local/bin/setup_traffic_limits.sh"
STATUS_SCRIPT="/usr/local/bin/check_traffic_status.sh"
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
    # jq 不再是此特定 TOML 解析的硬性要求，但保留它可能对其他脚本有用
    apt-get update >/dev/null 2>&1
    if ! dpkg -s iptables-persistent &> /dev/null || ! dpkg -s bc &> /dev/null; then
        apt-get install -y iptables-persistent bc >/dev/null 2>&1
    fi
    # 确保 grep, awk, sed 可用 (通常系统自带)
    for cmd in grep awk sed; do
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
        # 解析 TOML 文件中的 listen 端口
        # 确保只处理 [[endpoints]] 下的 listen
        local in_endpoints_block=0
        local current_listen_port=""

        while IFS= read -r line; do
            # 移除行首尾空格和注释
            line_trimmed=$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//' | sed 's/#.*//')

            if [[ "$line_trimmed" == "[[endpoints]]" ]]; then
                in_endpoints_block=1
                current_listen_port="" # 重置，为新的 block 准备
                continue
            fi

            if [[ $in_endpoints_block -eq 1 && "$line_trimmed" == listen* ]]; then
                # 提取 listen = "0.0.0.0:PORT" 中的 PORT
                PORT=$(echo "$line_trimmed" | grep -oP 'listen\s*=\s*"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\K([0-9]+)(?=")')
                if [ -z "$PORT" ]; then # 尝试提取 listen = ":PORT"
                    PORT=$(echo "$line_trimmed" | grep -oP 'listen\s*=\s*":\K([0-9]+)(?=")')
                fi
                 if [ -z "$PORT" ]; then # 尝试提取 listen = "PORT" (如果realm支持裸端口)
                    PORT=$(echo "$line_trimmed" | grep -oP 'listen\s*=\s*"\K([0-9]+)(?=")')
                fi


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
                # 如果在 endpoints 块中遇到非空、非 remote、非新块开始的行，则可能意味着一个 endpoints 块结束了
                # 或者，如果 TOML 块之间没有空行，我们需要在遇到下一个 [[endpoints]] 时重置
                if [[ "$line_trimmed" == "[[endpoints]]" ]]; then
                     in_endpoints_block=1 # 保持在块内，因为这是新块的开始
                     current_listen_port=""
                else
                    in_endpoints_block=0
                fi
            fi
        done < "$REALM_CONFIG_TOML"


        if [ ! -s "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then # 检查文件是否为空或不存在
             echo -e "${RED}无法从Realm TOML配置中解析出任何规则，或您选择不添加。请检查 ${REALM_CONFIG_TOML} 文件格式是否正确。${NC}"
             return 1
        elif [ ! -s "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then # 文件存在但为空
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
netfilter-persistent save
echo "新规则已创建并保存。"
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
        if [ "$LIMIT_BYTES" -gt 0 ] && [ "$TRAFFIC_BYTES" -gt "$LIMIT_BYTES" ]; then # 仅当限制大于0时才比较
            if ! iptables -C FORWARD -p tcp --dport ${PORT} -j DROP &> /dev/null; then
                echo "$(date '+%Y-%m-%d %H:%M:%S'): 端口 ${PORT} (${NAME}) 流量超限! 已用: ${TRAFFIC_BYTES} B. 正在禁用..." >> "$LOG_FILE"
                iptables -I FORWARD 1 -p tcp --dport ${PORT} -j DROP
                iptables -I FORWARD 1 -p udp --dport ${PORT} -j DROP
                iptables -I FORWARD 1 -p tcp --sport ${PORT} -j DROP
                iptables -I FORWARD 1 -p udp --sport ${PORT} -j DROP
                netfilter-persistent save
            fi
        fi
    fi
done
exit 0
EOF
    
    # 3. 可视化状态检查脚本 (check_traffic_status.sh)
    cat << 'EOF' > "$STATUS_SCRIPT"
#!/bin/bash
CONFIG_FILE="/etc/traffic_limits.conf"
echo -e "\n--- iptables 流量使用状态报告 ---\n"
if [ ! -f "$CONFIG_FILE" ]; then echo "错误：配置文件 ${CONFIG_FILE} 未找到！"; exit 1; fi
grep -v "^#" ${CONFIG_FILE} | while read -r PORT LIMIT_GB NAME; do
    if [ -n "$PORT" ]; then
        LIMIT_BYTES=$((LIMIT_GB * 1024 * 1024 * 1024))
        CHAIN_NAME="TRAFFIC_LIMIT_${PORT}"
        TRAFFIC_BYTES=$(iptables -L FORWARD -v -n -x 2>/dev/null | grep "${CHAIN_NAME}" | awk '{print $2}' | paste -sd+ | bc)
        if [ -z "$TRAFFIC_BYTES" ]; then TRAFFIC_BYTES=0; fi
        TRAFFIC_GB=$(echo "scale=2; ${TRAFFIC_BYTES} / 1024 / 1024 / 1024" | bc)
        PERCENTAGE=$(echo "scale=2; if(${LIMIT_BYTES} > 0) ${TRAFFIC_BYTES} * 100 / ${LIMIT_BYTES} else 0" | bc | awk '{printf "%.0f", $1}')
        BAR=$(for ((i=0; i<40; i++)); do if [ $(echo "${PERCENTAGE} * 40 / 100" | bc) -gt $i ]; then echo -n "#"; else echo -n "-"; fi; done)
        echo -e "规则: \033[1;33m${NAME} (端口: ${PORT})\033[0m"
        echo -e "  配额: \033[0;32m${LIMIT_GB} GB\033[0m, 已用: \033[0;32m${TRAFFIC_GB} GB\033[0m"
        echo -e "  进度: [${BAR}] ${PERCENTAGE}%"
        if iptables -C FORWARD -p tcp --dport ${PORT} -j DROP &> /dev/null; then
            echo -e "  状态: \033[0;31m已禁用 (流量超限)\033[0m"
        else
            echo -e "  状态: \033[0;32m正常\033[0m"
        fi
        echo ""
    fi
done
EOF

    chmod +x "$SETUP_SCRIPT" "$LIMITER_SCRIPT" "$STATUS_SCRIPT"
}

setup_cron_job() {
    (crontab -l 2>/dev/null | grep -v "$CRON_JOB_CMD") | { cat; echo "*/5 * * * * $CRON_JOB_CMD"; } | crontab -
}

do_install() {
    check_root
    echo "--- 开始安装智能流量限制器 (TOML兼容版) ---"
    install_dependencies
    
    detect_and_populate_config_toml
    local detection_result=$?
    if [ $detection_result -ne 0 ]; then
        create_manual_config
    fi
    
    echo -e "${GREEN}--> 3. 正在创建核心脚本...${NC}"
    create_helper_scripts
    
    echo -e "${GREEN}--> 4. 正在应用 iptables 规则...${NC}"
    bash "$SETUP_SCRIPT"

    echo -e "${GREEN}--> 5. 正在设置定时任务...${NC}"
    setup_cron_job
    
    echo -e "\n${YELLOW}是否需要现在安装 Netdata 以获得最佳的 Web 可视化监控？(y/n)${NC}"
    read -r install_netdata
    if [[ "$install_netdata" == "y" || "$install_netdata" == "Y" ]]; then
        echo -e "${GREEN}--> 正在安装 Netdata...${NC}"
        bash <(curl -Ss https://my-netdata.io/kickstart.sh) --dont-wait
        echo -e "${GREEN}Netdata 安装请求已发送，它将在后台继续安装。${NC}"
    fi

    echo -e "\n${GREEN}恭喜！流量限制器已安装并激活成功！${NC}"
    echo "您可以随时使用 'sudo $0 status' 命令检查流量使用情况。"
    echo "要管理您的规则，请编辑 ${CONFIG_FILE} 然后运行 'sudo $0 reset'。"
}

do_uninstall() {
    check_root
    echo -e "${RED}您确定要卸载流量限制器吗？ (y/n)${NC}"
    read -r confirmation
    if [[ "$confirmation" != "y" && "$confirmation" != "Y" ]]; then echo "卸载已取消。"; exit 0; fi
    echo "--> 1. 正在移除定时任务..."
    (crontab -l 2>/dev/null | grep -v "$CRON_JOB_CMD") | crontab -
    echo "--> 2. 正在清理 iptables 规则..."
    tmpext=$(date +%s); mv $CONFIG_FILE ${CONFIG_FILE}.$tmpext 2>/dev/null; touch $CONFIG_FILE
    bash "$SETUP_SCRIPT" >/dev/null 2>&1; rm $CONFIG_FILE; mv ${CONFIG_FILE}.$tmpext $CONFIG_FILE 2>/dev/null
    echo "--> 3. 正在删除脚本文件..."
    rm -f "$LIMITER_SCRIPT" "$SETUP_SCRIPT" "$STATUS_SCRIPT"
    read -p "是否删除配置文件 ${CONFIG_FILE}？ (y/n)" del_conf
    if [[ "$del_conf" == "y" ]]; then rm -f "$CONFIG_FILE"; fi
    read -p "是否删除日志文件 ${LOG_FILE}？ (y/n)" del_log
    if [[ "$del_log" == "y" ]]; then rm -f "$LOG_FILE"; fi
    echo -e "${GREEN}卸载完成。${NC}"
}

show_status() {
    check_root; bash "$STATUS_SCRIPT"
}

reset_rules() {
    check_root; echo "正在重置 iptables 规则..."; bash "$SETUP_SCRIPT"; echo "重置完成。"
}

# --- 主程序入口 ---
case "$1" in
    install|i) do_install;;
    uninstall|u) do_uninstall;;
    status|s) show_status;;
    reset|r) reset_rules;;
    *)
        echo "智能流量限制器管理脚本 (v2.2 - TOML 兼容版)"
        echo "用法: sudo bash $0 {install|uninstall|status|reset}"
        echo "  install    - (或 i) 安装并配置，可自动检测Realm TOML配置"
        echo "  uninstall  - (或 u) 卸载所有组件"
        echo "  status     - (或 s) 显示当前所有规则的流量使用状态"
        echo "  reset      - (或 r) 根据配置文件重新应用iptables规则"
        exit 1
        ;;
esac

exit 0
