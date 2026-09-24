#!/usr/bin/env bash
# ====================================================================
#  Sing-box 管理面板
#  版本: v3.3.0  |  快捷指令: SB / sb
# --------------------------------------------------------------------
#  特性:
#    • VLESS-Reality 节点管理（二维码 / 分享链接）
#    • TCP/UDP 端口转发
#    • Cloudflare WARP 出口（AI / 流媒体 / 自定义分流）
#    • 实用小工具（流媒体解锁检测 / DNS / 防火墙）
#    • 配置校验 + 自动回滚 + 并发锁
#  备份策略: 仅当“校验通过”才刷新唯一备份(.bak)，失败备份不动
# ====================================================================

set -o pipefail

SCRIPT_VERSION="v3.3.0"

# ---------- 颜色 ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[36m"; CYAN="\033[35m"; PLAIN="\033[0m"

# ---------- 路径 ----------
CONFIG_FILE="/etc/sing-box/config.json"
BIN_FILE="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
META_DIR="/etc/sing-box/.meta"
REALITY_META="$META_DIR/reality.txt"
WARP_META="$META_DIR/warp.json"
LOCK_FILE="/var/run/sing-box-manager.lock"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 若通过管道/进程替换（如 bash <(curl ...)）运行，stdin 不是终端，
# read 会立即读到 EOF 导致菜单空转或直接退出（表现为“执行完就断连”）。
# 强制把 stdin 重定向到终端，保证交互菜单始终从 TTY 读取。
if [ ! -t 0 ] && [ -e /dev/tty ]; then exec < /dev/tty; fi

# ---------- 通用交互 ----------
pause() { echo ""; read -rp "按回车键继续..." _; }

# ==================== 并发锁 ====================
acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo -e "${RED}错误：另一个管理实例正在运行，请稍后重试。${PLAIN}"
        exit 1
    fi
}
acquire_lock

# ==================== 依赖安装 ====================
install_dependencies() {
    local missing=0
    for cmd in curl jq wget qrencode flock; do
        command -v "$cmd" &>/dev/null || missing=1
    done
    [ $missing -eq 0 ] && return

    echo -e "${BLUE}正在安装必要依赖 (curl jq wget qrencode flock)...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y -qq curl jq wget ufw qrencode util-linux
    elif [ -f /etc/redhat-release ]; then
        yum install -y -q curl jq wget firewalld qrencode util-linux
    fi
}

# ==================== 安全读取与配置管理 ====================
ensure_config() {
    mkdir -p /etc/sing-box "$META_DIR"
    if [ ! -f "$CONFIG_FILE" ] || ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        cat > "$CONFIG_FILE" <<'EOF'
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"rules": []}
}
EOF
    fi
    chmod 600 "$CONFIG_FILE"
}

inbound_count() {
    local c
    c=$(jq '.inbounds | length' "$CONFIG_FILE" 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo "0"
}

inbound_field() {
    jq -r ".inbounds[$1].$2 // \"\"" "$CONFIG_FILE" 2>/dev/null
}

count_by_type() {
    local c
    c=$(jq --arg t "$1" '[.inbounds[] | select(.type == $t)] | length' "$CONFIG_FILE" 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo "0"
}

save_and_check_config() {
    local new_json="$1"
    local test_file="/tmp/sing-box-test.json"

    printf '%s\n' "$new_json" > "$test_file"
    chmod 600 "$test_file"

    echo -e "${BLUE}⏳ 正在校验配置...${PLAIN}"
    if ! "$BIN_FILE" check -c "$test_file" &>/dev/null; then
        echo -e "${RED}❌ 配置校验失败，以下为错误详情：${PLAIN}"
        "$BIN_FILE" check -c "$test_file"
        rm -f "$test_file"
        echo -e "${YELLOW}💡 已放弃更改：原配置与备份均保持不变。${PLAIN}"
        return 1
    fi

    if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" 2>/dev/null; then
        install -m 600 "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    fi

    install -m 600 "$test_file" "$CONFIG_FILE"
    rm -f "$test_file"

    echo -e "${GREEN}✨ 配置校验通过，已应用；备份已刷新为上一版有效配置。${PLAIN}"
    return 0
}

rollback_config() {
    if [ ! -f "${CONFIG_FILE}.bak" ]; then
        echo -e "${RED}未找到备份文件，无法回滚。${PLAIN}"
        return 1
    fi
    if ! jq empty "${CONFIG_FILE}.bak" 2>/dev/null; then
        echo -e "${RED}备份文件语法异常，拒绝回滚。${PLAIN}"
        return 1
    fi
    install -m 600 "${CONFIG_FILE}.bak" "$CONFIG_FILE"
    systemctl restart sing-box
    echo -e "${GREEN}✅ 已回滚到上一次有效配置并重启服务。${PLAIN}"
}

# ==================== 辅助工具函数 ====================
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

port_in_use() {
    [ -f "$CONFIG_FILE" ] || return 1
    local n
    n=$(jq --argjson p "$1" '[.inbounds[] | select(.listen_port == $p)] | length' "$CONFIG_FILE" 2>/dev/null)
    [ "${n:-0}" -gt 0 ]
}

get_public_ip() {
    local ip
    ip=$(curl -s -4 --max-time 5 https://api.ipify.org \
      || curl -s -4 --max-time 5 https://ipv4.icanhazip.com \
      || curl -s -6 --max-time 5 https://api64.ipify.org)
    echo "${ip:-127.0.0.1}"
}

open_firewall_port() {
    local port="$1"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$port"/tcp &>/dev/null; ufw allow "$port"/udp &>/dev/null
    elif command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --zone=public --add-port="$port"/tcp --permanent &>/dev/null
        firewall-cmd --zone=public --add-port="$port"/udp --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
    fi
}

get_singbox_status() {
    if [ ! -f "$BIN_FILE" ]; then echo -e "${RED}🔴 未安装${PLAIN}"; return; fi
    local ver
    ver=$($BIN_FILE version 2>/dev/null | head -n1 | awk '{print $3}')
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "${GREEN}🟢 运行中 [v${ver}]${PLAIN}"
    else
        echo -e "${YELLOW}🟡 已停止 [v${ver}]${PLAIN}"
    fi
}

restart_service() {
    if [ ! -f "$BIN_FILE" ]; then echo -e "${RED}尚未安装 Sing-box！${PLAIN}"; return 1; fi
    echo -e "${BLUE}⏳ 正在重启 sing-box...${PLAIN}"
    systemctl restart sing-box
    sleep 1
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✅ 重启成功！当前状态: $(get_singbox_status)${PLAIN}"
    else
        echo -e "${RED}❌ 重启失败！请查看日志排查：${PLAIN}"
        journalctl -u sing-box -n 20 --no-pager
    fi
}

read_valid_port() {
    local prompt="$1" default="$2" check_dup="${3:-1}" p
    while true; do
        read -rp "$prompt" p
        p=${p:-$default}
        if ! validate_port "$p"; then echo -e "${RED}端口无效！${PLAIN}"; continue; fi
        if [ "$check_dup" == "1" ] && port_in_use "$p"; then
            echo -e "${RED}端口 $p 已被占用！${PLAIN}"; continue
        fi
        echo "$p"; return
    done
}

save_reality_meta()   { mkdir -p "$META_DIR"; echo "$1|$2" >> "$REALITY_META"; }
get_reality_pubkey()  { [ -f "$REALITY_META" ] && grep -F "$1|" "$REALITY_META" | tail -1 | cut -d'|' -f2; }
remove_reality_meta() {
    [ -f "$REALITY_META" ] || return 0
    grep -vF "$1|" "$REALITY_META" > "${REALITY_META}.tmp" 2>/dev/null
    mv "${REALITY_META}.tmp" "$REALITY_META"
}

# ==================== 删除项选择 ====================
prompt_delete_index() {
    local title="$1" filter_type="$2"
    local total idxs=() i=0 n=0

    total=$(inbound_count)
    while [ $i -lt "$total" ]; do
        local t
        t=$(inbound_field "$i" "type")
        [ "$t" == "$filter_type" ] && idxs+=("$i")
        i=$((i+1))
    done

    if [ ${#idxs[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可操作的${title}。${PLAIN}" >&2
        echo ""
        return
    fi

    echo -e "${CYAN}=== 请选择${title} ===${PLAIN}" >&2
    for real in "${idxs[@]}"; do
        n=$((n+1))
        local tag port
        tag=$(inbound_field "$real" "tag")
        port=$(inbound_field "$real" "listen_port")
        echo -e "  [${GREEN}$n${PLAIN}] $tag  (端口: $port)" >&2
    done
    echo -e "--------------------------------------------------" >&2

    local choice
    read -rp "请输入序号 (0 取消): " choice
    [[ "$choice" == "0" ]] && { echo ""; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
        echo -e "${RED}无效序号！${PLAIN}" >&2
        echo ""
        return
    fi
    echo "${idxs[$((choice-1))]}"
}

# ==================== 系统管理 ====================
install_singbox() {
    echo -e "${BLUE}正在获取最新版 Sing-box...${PLAIN}"
    local tag
    tag=$(curl -s --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    [[ -z "$tag" ]] && tag="v1.8.8"

    local arch="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${tag#v}-linux-${arch}.tar.gz"
    echo -e "${BLUE}下载: ${url}${PLAIN}"

    curl -L --max-time 300 -o /tmp/sing-box.tar.gz "$url" || { echo -e "${RED}❌ 下载失败${PLAIN}"; return 1; }
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || { echo -e "${RED}解压失败${PLAIN}"; return 1; }

    mkdir -p /etc/sing-box
    mv "/tmp/sing-box-${tag#v}-linux-${arch}/sing-box" "$BIN_FILE"
    chmod +x "$BIN_FILE"
    rm -rf /tmp/sing-box*

    if [ ! -f "$SERVICE_FILE" ]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=$BIN_FILE run -C /etc/sing-box
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box &>/dev/null
    fi
    ensure_config
    systemctl restart sing-box
    echo -e "${GREEN}✅ 安装/更新成功！版本: ${tag}${PLAIN}"
}

uninstall_singbox() {
    read -rp "⚠️ 确定完全卸载 Sing-box 及其配置吗？[y/N]: " c
    [[ ! "$c" =~ ^[Yy]$ ]] && return
    systemctl stop sing-box &>/dev/null
    systemctl disable sing-box &>/dev/null
    rm -f "$SERVICE_FILE" "$BIN_FILE"
    rm -rf /etc/sing-box /tmp/sing-box* /tmp/sing-box-test.json
    systemctl daemon-reload
    echo -e "${GREEN}✅ 已完全卸载。${PLAIN}"
}

show_service_status() {
    [ ! -f "$BIN_FILE" ] && echo -e "${RED}尚未安装 Sing-box！${PLAIN}" && return
    echo -e "${CYAN}=== Sing-box 服务状态 ===${PLAIN}"
    systemctl status sing-box --no-pager
}

show_full_config() {
    echo -e "${CYAN}=== 完整配置文件 (${CONFIG_FILE}) ===${PLAIN}"
    [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || echo -e "${RED}配置文件不存在！${PLAIN}"
}

view_logs() {
    echo -e "${CYAN}=== Sing-box 日志 (最近 100 行) ===${PLAIN}"
    journalctl -u sing-box -n 100 --no-pager
    echo -e "--------------------------------------------------"
    read -rp "是否进入实时日志? (Ctrl+C 退出) [y/N]: " f
    [[ "$f" =~ ^[Yy]$ ]] && journalctl -u sing-box -f
}

# ==================== 节点操作 ====================
add_reality_node() {
    [ ! -f "$BIN_FILE" ] && echo -e "${RED}请先安装 Sing-box！${PLAIN}" && return
    ensure_config

    echo -e "${CYAN}=== 添加 VLESS-Reality 节点 ===${PLAIN}"
    local port
    port=$(read_valid_port "监听端口 [默认 443]: " 443 1)

    read -rp "伪装域名 SNI [默认 yahoo.com]: " sni
    sni=${sni:-yahoo.com}

    echo -e "${BLUE}⏳ 生成密钥对...${PLAIN}"
    local key_output private_key public_key uuid short_id
    key_output=$("$BIN_FILE" generate reality-keypair)
    private_key=$(echo "$key_output" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
    public_key=$(echo  "$key_output" | grep "PublicKey"  | awk '{print $2}' | tr -d '"')
    uuid=$("$BIN_FILE" generate uuid)
    short_id=$("$BIN_FILE" generate rand 8 --hex)

    local tag="vless-reality-$port"
    local temp_json
    temp_json=$(jq --argjson port "$port" --arg uuid "$uuid" --arg pk "$private_key" \
                   --arg sni "$sni" --arg sid "$short_id" --arg tag "$tag" \
                   '.inbounds += [{
                       "type": "vless", "tag": $tag, "listen": "::", "listen_port": $port,
                       "users": [{"uuid": $uuid, "flow": "xtls-rprx-vision"}],
                       "tls": {
                           "enabled": true, "server_name": $sni,
                           "reality": {
                               "enabled": true, "private_key": $pk, "short_id": [$sid],
                               "handshake": {"server": $sni, "server_port": 443}
                           }
                       }
                   }]' "$CONFIG_FILE")

    if save_and_check_config "$temp_json"; then
        save_reality_meta "$tag" "$public_key"
        open_firewall_port "$port"
        systemctl restart sing-box
        local ip=$(get_public_ip)
        local link="vless://$uuid@$ip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp#Reality-$port"
        echo -e "${GREEN}====================================================${PLAIN}"
        echo -e "${GREEN}🎉 节点添加成功！（已放行防火墙）${PLAIN}"
        echo -e "${GREEN}====================================================${PLAIN}"
        echo -e "服务器 IP  : ${BLUE}$ip${PLAIN}"
        echo -e "端口       : ${BLUE}$port${PLAIN}"
        echo -e "UUID       : ${BLUE}$uuid${PLAIN}"
        echo -e "公钥 (PK)  : ${BLUE}$public_key${PLAIN}"
        echo -e "ShortId    : ${BLUE}$short_id${PLAIN}"
        echo -e "SNI        : ${BLUE}$sni${PLAIN}"
        echo -e "分享链接   : ${YELLOW}$link${PLAIN}"
        echo -e "${GREEN}====================================================${PLAIN}"

        if command -v qrencode &>/dev/null; then
            read -rp "是否显示二维码？[y/N]: " show_qr
            if [[ "$show_qr" =~ ^[Yy]$ ]]; then
                echo -e "${BLUE}二维码:${PLAIN}"
                qrencode -t ANSIUTF8 "$link"
            fi
        fi
    fi
}

view_node_links() {
    ensure_config
    local ip=$(get_public_ip)
    echo -e "${CYAN}=== 节点分享链接 ===${PLAIN}"
    echo -e "${BLUE}服务器 IP: $ip${PLAIN}"
    echo -e "--------------------------------------------------"

    local total
    total=$(count_by_type "vless")
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}当前没有配置任何 VLESS-Reality 节点。${PLAIN}"
        return
    fi

    local links=() tags=() i=0 idx=0 total_all
    total_all=$(inbound_count)
    while [ $i -lt "$total_all" ]; do
        local type
        type=$(inbound_field "$i" "type")
        if [ "$type" == "vless" ]; then
            idx=$((idx+1))
            local uuid sni sid tag port pbk link
            uuid=$(inbound_field "$i" "users[0].uuid")
            sni=$(inbound_field  "$i" "tls.server_name")
            sid=$(inbound_field  "$i" "tls.reality.short_id[0]")
            tag=$(inbound_field  "$i" "tag")
            port=$(inbound_field "$i" "listen_port")
            pbk=$(get_reality_pubkey "$tag")
            link="vless://$uuid@$ip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$pbk&sid=$sid&type=tcp#$tag"

            links+=("$link")
            tags+=("$tag")

            echo -e "  [${GREEN}$idx${PLAIN}] ${GREEN}VLESS-Reality${PLAIN} | ${BLUE}$tag${PLAIN} | 端口: $port"
            echo -e "      SNI : $sni  |  ShortId: $sid"
            echo -e "      公钥: ${pbk:-未记录}"
            echo -e "      链接: ${YELLOW}$link${PLAIN}"
            echo -e "--------------------------------------------------"
        fi
        i=$((i+1))
    done

    if command -v qrencode &>/dev/null; then
        read -rp "输入要显示二维码的序号 (0 跳过): " qr_idx
        if [[ "$qr_idx" =~ ^[0-9]+$ ]] && [ "$qr_idx" -ge 1 ] && [ "$qr_idx" -le "${#links[@]}" ]; then
            local ridx=$((qr_idx - 1))
            echo -e "${BLUE}二维码 [${tags[$ridx]}]:${PLAIN}"
            qrencode -t ANSIUTF8 "${links[$ridx]}"
        fi
    fi
}

delete_node() {
    ensure_config
    local total
    total=$(count_by_type "vless")
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}当前没有 VLESS-Reality 节点。${PLAIN}"; return
    fi

    echo -e "${CYAN}=== 删除 VLESS-Reality 节点 ===${PLAIN}"
    local real_idx
    real_idx=$(prompt_delete_index "节点" "vless")
    [ -z "$real_idx" ] && return

    local del_tag
    del_tag=$(inbound_field "$real_idx" "tag")

    local temp_json
    temp_json=$(jq --argjson i "$real_idx" '.inbounds |= (.[:$i] + .[$i+1:])' "$CONFIG_FILE")

    if save_and_check_config "$temp_json"; then
        remove_reality_meta "$del_tag"
        systemctl restart sing-box
        echo -e "${GREEN}✅ 节点 [${del_tag}] 已删除。${PLAIN}"
    fi
}

# ==================== 端口转发 ====================
add_port_forward() {
    [ ! -f "$BIN_FILE" ] && echo -e "${RED}请先安装 Sing-box！${PLAIN}" && return
    ensure_config

    echo -e "${CYAN}=== 添加 TCP/UDP 端口转发 ===${PLAIN}"
    local local_port remote_ip remote_port
    local_port=$(read_valid_port "本机监听端口: " "" 1)
    read -rp "目标远程 IP: " remote_ip
    [[ -z "$remote_ip" ]] && echo -e "${RED}IP 不能为空！${PLAIN}" && return
    remote_port=$(read_valid_port "目标远程端口: " "" 0)

    local tag="forward-$local_port-to-$remote_port"

    local temp_json
    temp_json=$(jq --argjson lport "$local_port" --arg rip "$remote_ip" \
                   --argjson rport "$remote_port" --arg tag "$tag" \
                   '.inbounds += [{
                       "type": "direct", "tag": $tag, "listen": "::",
                       "listen_port": $lport,
                       "override_address": $rip, "override_port": $rport
                   }] |
                    .route.rules += [{"inbound": [$tag], "outbound": "direct"}]' \
                   "$CONFIG_FILE")

    if save_and_check_config "$temp_json"; then
        open_firewall_port "$local_port"
        systemctl restart sing-box
        echo -e "${GREEN}✅ 转发成功：本机 [${local_port}] → ${remote_ip}:${remote_port}${PLAIN}"
    fi
}

view_port_forwards() {
    ensure_config
    echo -e "${CYAN}=== 端口转发列表 ===${PLAIN}"
    echo -e "--------------------------------------------------"

    local total
    total=$(count_by_type "direct")
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}当前没有端口转发。${PLAIN}"
        return
    fi

    local i=0 idx=0 total_all
    total_all=$(inbound_count)
    while [ $i -lt "$total_all" ]; do
        local t
        t=$(inbound_field "$i" "type")
        if [ "$t" == "direct" ]; then
            idx=$((idx+1))
            local lp rip rp tag
            tag=$(inbound_field "$i" "tag")
            lp=$(inbound_field  "$i" "listen_port")
            rip=$(inbound_field "$i" "override_address")
            rp=$(inbound_field  "$i" "override_port")
            echo -e "  [${GREEN}$idx${PLAIN}] 监听 [${BLUE}$lp${PLAIN}] → ${rip}:${rp}   ${CYAN}($tag)${PLAIN}"
        fi
        i=$((i+1))
    done
    echo -e "--------------------------------------------------"
}

delete_port_forward() {
    ensure_config
    local total
    total=$(count_by_type "direct")
    if [ "$total" -eq 0 ]; then
        echo -e "${YELLOW}当前没有端口转发。${PLAIN}"; return
    fi

    echo -e "${CYAN}=== 删除端口转发 ===${PLAIN}"
    local real_idx
    real_idx=$(prompt_delete_index "端口转发" "direct")
    [ -z "$real_idx" ] && return

    local del_tag
    del_tag=$(inbound_field "$real_idx" "tag")

    local temp_json
    temp_json=$(jq --argjson i "$real_idx" --arg tag "$del_tag" \
                   '.inbounds |= (.[:$i] + .[$i+1:]) |
                    .route.rules |= [.[] | select((.inbound? // []) | index($tag) | not)]' \
                   "$CONFIG_FILE")

    if save_and_check_config "$temp_json"; then
        systemctl restart sing-box
        echo -e "${GREEN}✅ 转发 [${del_tag}] 已删除。${PLAIN}"
    fi
}

# ==================== 配置诊断与回滚 ====================
diagnose_config() {
    while true; do
        clear
        echo -e "=================================================="
        echo -e "        配置诊断与回滚"
        echo -e "=================================================="
        echo -e " 配置文件: ${BLUE}$CONFIG_FILE${PLAIN}"
        if [ -f "$CONFIG_FILE" ]; then
            local size
            size=$(wc -c < "$CONFIG_FILE" 2>/dev/null)
            echo -e " 文件大小: ${BLUE}${size}${PLAIN} bytes"
            if jq empty "$CONFIG_FILE" 2>/dev/null; then
                echo -e " JSON状态: ${GREEN}✅ 语法正确${PLAIN}"
                echo -e " 入站总数: ${BLUE}$(inbound_count)${PLAIN}  (VLESS: $(count_by_type vless), 转发: $(count_by_type direct))"
            else
                echo -e " JSON状态: ${RED}❌ 语法错误${PLAIN}"
            fi
        else
            echo -e " 状态: ${RED}配置文件不存在${PLAIN}"
        fi
        echo -e " 备份文件: $([ -f "${CONFIG_FILE}.bak" ] && echo -e "${GREEN}✅ 存在（上一版有效配置）${PLAIN}" || echo -e "${YELLOW}⚠️ 不存在${PLAIN}")"
        echo -e "--------------------------------------------------"
        echo -e " 1. 查看原始 JSON"
        echo -e " 2. 查看 Reality 元数据"
        echo -e " 3. 手动编辑配置"
        echo -e " 4. 重置为空配置 (备份旧文件)"
        echo -e " 5. 回滚到上次有效备份  ${RED}⚠️${PLAIN}"
        echo -e "--------------------------------------------------"
        echo -e " 0. 返回主菜单"
        echo -e "=================================================="
        read -rp "请输入选项 [0-5]: " c
        case "$c" in
            1) echo -e "${CYAN}--- 原始 JSON ---${PLAIN}"; cat "$CONFIG_FILE" 2>/dev/null ;;
            2) echo -e "${CYAN}--- Reality 元数据 ---${PLAIN}"; [ -f "$REALITY_META" ] && cat "$REALITY_META" || echo -e "${YELLOW}无${PLAIN}" ;;
            3) local editor="vi"; command -v nano &>/dev/null && editor="nano"; $editor "$CONFIG_FILE"
               if jq empty "$CONFIG_FILE" 2>/dev/null; then
                   systemctl restart sing-box
                   echo -e "${GREEN}✅ 配置有效，已重启服务${PLAIN}"
               else
                   echo -e "${RED}❌ 配置仍无效！${PLAIN}"
               fi ;;
            4) read -rp "是否备份并重置为空配置？[y/N]: " cc
               if [[ "$cc" =~ ^[Yy]$ ]]; then
                   cp "$CONFIG_FILE" "${CONFIG_FILE}.broken.$(date +%s)" 2>/dev/null
                   rm -f "$CONFIG_FILE"
                   ensure_config
                   echo -e "${GREEN}✅ 已重置（旧文件已备份）${PLAIN}"
               fi ;;
            5) read -rp "确定要回滚到上次有效备份吗？[y/N]: " cc
               [[ "$cc" =~ ^[Yy]$ ]] && rollback_config ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

# ==================== 子菜单 ====================
menu_system() {
    while true; do
        clear
        echo -e "=================================================="
        echo -e "        系统管理"
        echo -e "=================================================="
        echo -e " 当前状态 : $(get_singbox_status)"
        echo -e "--------------------------------------------------"
        echo -e " ${CYAN}【核心】${PLAIN}"
        echo -e " 1. 安装 / 更新核心"
        echo -e " 2. 启动服务"
        echo -e " 3. 停止服务"
        echo -e " 4. 重启服务"
        echo -e " 5. 完全卸载"
        echo -e " ${CYAN}【监控】${PLAIN}"
        echo -e " 6. 查看服务运行状态"
        echo -e " 7. 查看完整配置文件"
        echo -e " 8. 查看运行日志"
        echo -e "--------------------------------------------------"
        echo -e " 0. 返回主菜单"
        echo -e "=================================================="
        read -rp "请输入选项 [0-8]: " c
        case "$c" in
            1) install_singbox ;;
            2) systemctl start sing-box && echo -e "${GREEN}✅ 已启动${PLAIN}" ;;
            3) systemctl stop sing-box  && echo -e "${YELLOW}🛑 已停止${PLAIN}" ;;
            4) restart_service ;;
            5) uninstall_singbox ;;
            6) show_service_status ;;
            7) show_full_config ;;
            8) view_logs ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

menu_nodes() {
    while true; do
        clear
        echo -e "=================================================="
        echo -e "        节点管理"
        echo -e "=================================================="
        echo -e " 1. 添加 VLESS-Reality 节点"
        echo -e " 2. 查看节点分享链接 (支持二维码)"
        echo -e " 3. 删除 VLESS-Reality 节点"
        echo -e " 0. 返回主菜单"
        echo -e "=================================================="
        read -rp "请输入选项 [0-3]: " c
        case "$c" in
            1) add_reality_node ;;
            2) view_node_links ;;
            3) delete_node ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

menu_forward() {
    while true; do
        clear
        echo -e "=================================================="
        echo -e "        端口转发管理"
        echo -e "=================================================="
        echo -e " 1. 添加 TCP/UDP 端口转发"
        echo -e " 2. 查看所有转发规则"
        echo -e " 3. 删除转发规则"
        echo -e " 0. 返回主菜单"
        echo -e "=================================================="
        read -rp "请输入选项 [0-3]: " c
        case "$c" in
            1) add_port_forward ;;
            2) view_port_forwards ;;
            3) delete_port_forward ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

# ==================== 实用小工具 ====================
# 参考 VPSBox (github.com/vmenzo/VPSBox) 的工具集思路：流媒体检测 / DNS / 防火墙

_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"

# ---------- 流媒体解锁检测（本机出口）----------
media_check_quick() {
    echo -e "${CYAN}=== 流媒体解锁检测（基于本机直连出口）===${PLAIN}"
    echo -e "${BLUE}⏳ 检测中，请稍候...${PLAIN}"

    # 出口 IP / 地区
    local geo ip country org
    geo=$(curl -s --max-time 10 https://ipinfo.io/json 2>/dev/null)
    ip=$(jq -r '.ip // "?"' <<<"$geo" 2>/dev/null)
    country=$(jq -r '.country // "?"' <<<"$geo" 2>/dev/null)
    org=$(jq -r '.org // "?"' <<<"$geo" 2>/dev/null)
    echo -e "--------------------------------------------------"
    echo -e " 出口 IP : ${BLUE}${ip}${PLAIN}   地区: ${BLUE}${country}${PLAIN}"
    echo -e " ISP    : ${org}"
    echo -e "--------------------------------------------------"

    # ChatGPT / OpenAI
    local loc comp gpt
    loc=$(curl -s --max-time 10 "https://chat.openai.com/cdn-cgi/trace" 2>/dev/null | grep -oP 'loc=\K\w+')
    comp=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "https://api.openai.com/compliance/cookie_requirements" -H "authorization: Bearer x" 2>/dev/null)
    if [[ -n "$loc" && "$comp" == "200" ]]; then
        gpt="${GREEN}✅ 可用${PLAIN} (地区: $loc)"
    elif [[ -n "$loc" ]]; then
        gpt="${YELLOW}⚠ 网页可访问但 App/API 受限${PLAIN} (地区: $loc)"
    else
        gpt="${RED}❌ 不可用/超时${PLAIN}"
    fi
    printf ' %-12s: %b\n' "ChatGPT" "$gpt"

    # YouTube Premium 地区
    local yt ytc
    ytc=$(curl -s --max-time 12 -A "$_UA" -H "Accept-Language: en-US" "https://www.youtube.com/premium" 2>/dev/null | grep -oP '"GL":"\K[A-Z]{2}' | head -1)
    if [[ -n "$ytc" ]]; then yt="${GREEN}✅ 可用${PLAIN} (地区: $ytc)"; else yt="${RED}❌ 不可用/超时${PLAIN}"; fi
    printf ' %-12s: %b\n' "YouTube" "$yt"

    # Netflix：非自制剧 81280792  200=完整解锁 / 404=仅自制剧 / 其它=不可用
    local nf nfc
    nfc=$(curl -sL --max-time 12 -A "$_UA" -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/81280792" 2>/dev/null)
    case "$nfc" in
        200) nf="${GREEN}✅ 完整解锁${PLAIN}" ;;
        404) nf="${YELLOW}⚠ 仅自制剧${PLAIN}" ;;
        *)   nf="${RED}❌ 不可用 (http=$nfc)${PLAIN}" ;;
    esac
    printf ' %-12s: %b\n' "Netflix" "$nf"

    # Disney+
    local dp dpc
    dpc=$(curl -s --max-time 12 -A "$_UA" -o /dev/null -w "%{http_code}" "https://www.disneyplus.com/" 2>/dev/null)
    if [[ "$dpc" == "200" ]]; then dp="${GREEN}✅ 可访问${PLAIN}"; else dp="${RED}❌ 不可用 (http=$dpc)${PLAIN}"; fi
    printf ' %-12s: %b\n' "Disney+" "$dp"

    # TikTok 地区
    local tt ttc
    ttc=$(curl -s --max-time 12 -A "$_UA" "https://www.tiktok.com/" 2>/dev/null | grep -oP '"region":"\K[A-Z]{2}' | head -1)
    if [[ -n "$ttc" ]]; then tt="${GREEN}✅ 可用${PLAIN} (地区: $ttc)"; else tt="${YELLOW}⚠ 未获取到地区${PLAIN}"; fi
    printf ' %-12s: %b\n' "TikTok" "$tt"
    echo -e "--------------------------------------------------"
    echo -e "${YELLOW}提示：此结果为服务器本机直连出口。若想让某服务走 WARP，可在「WARP 出口」菜单添加分流。${PLAIN}"
}

media_check_full() {
    echo -e "${CYAN}=== 完整流媒体解锁检测（社区脚本 RegionRestrictionCheck）===${PLAIN}"
    echo -e "${YELLOW}将下载并运行外部脚本，需能访问 GitHub。${PLAIN}"
    read -rp "继续？[y/N]: " c
    [[ ! "$c" =~ ^[Yy]$ ]] && return
    bash <(curl -L -s https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh)
}

# ---------- DNS 设置 ----------
DNS_BACKUP="$META_DIR/resolv.conf.bak"

show_dns() {
    echo -e "${CYAN}=== 当前 DNS (/etc/resolv.conf) ===${PLAIN}"
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || echo -e "${YELLOW}未配置 nameserver${PLAIN}"
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo -e "${YELLOW}⚠ 检测到 systemd-resolved 正在运行，直改 resolv.conf 可能被覆盖。${PLAIN}"
    fi
}

set_dns() {
    local servers="$1" label="$2"
    mkdir -p "$META_DIR"
    [ -f /etc/resolv.conf ] && cp /etc/resolv.conf "$DNS_BACKUP" 2>/dev/null
    {
        echo "# generated by sb $(date '+%F %T')"
        for s in $servers; do echo "nameserver $s"; done
    } > /etc/resolv.conf
    echo -e "${GREEN}✅ 已切换 DNS 为：$label${PLAIN}"
    show_dns
}

menu_dns() {
    while true; do
        clear
        echo -e "${CYAN}==================================================${PLAIN}"
        echo -e "        DNS 设置"
        echo -e "${CYAN}==================================================${PLAIN}"
        show_dns
        echo -e "--------------------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN} Cloudflare  (1.1.1.1 / 1.0.0.1)"
        echo -e "  ${GREEN}2.${PLAIN} Google      (8.8.8.8 / 8.8.4.4)"
        echo -e "  ${GREEN}3.${PLAIN} Quad9       (9.9.9.9 / 149.112.112.112)"
        echo -e "  ${GREEN}4.${PLAIN} AliDNS      (223.5.5.5 / 223.6.6.6)"
        echo -e "  ${GREEN}5.${PLAIN} 自定义（空格分隔多个）"
        echo -e "  ${GREEN}6.${PLAIN} 恢复备份 (resolv.conf.bak)"
        echo -e "  ${YELLOW}0.${PLAIN} 返回"
        echo -e "${CYAN}==================================================${PLAIN}"
        read -rp "请选择 [0-6]: " c
        case "$c" in
            1) set_dns "1.1.1.1 1.0.0.1 2606:4700:4700::1111" "Cloudflare" ;;
            2) set_dns "8.8.8.8 8.8.4.4 2001:4860:4860::8888" "Google" ;;
            3) set_dns "9.9.9.9 149.112.112.112" "Quad9" ;;
            4) set_dns "223.5.5.5 223.6.6.6" "AliDNS" ;;
            5) read -rp "输入 DNS（空格分隔）: " custom
               [[ -n "$custom" ]] && set_dns "$custom" "自定义" || echo -e "${RED}未输入。${PLAIN}" ;;
            6) if [ -f "$DNS_BACKUP" ]; then cp "$DNS_BACKUP" /etc/resolv.conf; echo -e "${GREEN}✅ 已恢复备份。${PLAIN}"; show_dns; else echo -e "${YELLOW}无备份。${PLAIN}"; fi ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

# ---------- 防火墙 (ufw) 设置 ----------
menu_firewall() {
    if ! command -v ufw &>/dev/null; then
        echo -e "${YELLOW}未安装 ufw，正在安装...${PLAIN}"
        if [ -f /etc/debian_version ]; then apt-get install -y -qq ufw; else yum install -y -q ufw 2>/dev/null; fi
    fi
    while true; do
        clear
        echo -e "${CYAN}==================================================${PLAIN}"
        echo -e "        防火墙设置 (ufw)"
        echo -e "${CYAN}==================================================${PLAIN}"
        ufw status verbose 2>/dev/null | head -20
        echo -e "--------------------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN} 开放端口 (tcp+udp)"
        echo -e "  ${GREEN}2.${PLAIN} 关闭/删除端口规则"
        echo -e "  ${GREEN}3.${PLAIN} 启用防火墙 (自动保留 22/SSH)"
        echo -e "  ${GREEN}4.${PLAIN} 关闭防火墙"
        echo -e "  ${GREEN}5.${PLAIN} 重载防火墙"
        echo -e "  ${YELLOW}0.${PLAIN} 返回"
        echo -e "${CYAN}==================================================${PLAIN}"
        read -rp "请选择 [0-5]: " c
        case "$c" in
            1) local p
               read -rp "要开放的端口: " p
               if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
                   ufw allow "$p"/tcp && ufw allow "$p"/udp && echo -e "${GREEN}✅ 已开放 $p (tcp+udp)${PLAIN}"
               else echo -e "${RED}端口无效！${PLAIN}"; fi ;;
            2) local p
               read -rp "要关闭的端口: " p
               if [[ "$p" == "22" ]]; then
                   read -rp "${RED}⚠ 关闭 22 可能导致 SSH 无法登录，确定？[y/N]: ${PLAIN}" yn
                   [[ ! "$yn" =~ ^[Yy]$ ]] && { echo "已取消。"; pause; continue; }
               fi
               if [[ "$p" =~ ^[0-9]+$ ]]; then
                   ufw delete allow "$p"/tcp 2>/dev/null; ufw delete allow "$p"/udp 2>/dev/null
                   echo -e "${GREEN}✅ 已删除 $p 的开放规则${PLAIN}"
               else echo -e "${RED}端口无效！${PLAIN}"; fi ;;
            3) ufw allow 22/tcp &>/dev/null
               echo -e "${YELLOW}已自动保留 22/tcp，防止锁死。${PLAIN}"
               yes | ufw enable && echo -e "${GREEN}✅ 防火墙已启用${PLAIN}" ;;
            4) ufw disable && echo -e "${YELLOW}🛡 防火墙已关闭${PLAIN}" ;;
            5) ufw reload && echo -e "${GREEN}✅ 已重载${PLAIN}" ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

menu_tools() {
    while true; do
        clear
        echo -e "${CYAN}==================================================${PLAIN}"
        echo -e "        实用小工具"
        echo -e "${CYAN}==================================================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 流媒体解锁检测（快速）"
        echo -e "  ${GREEN}2.${PLAIN} 流媒体解锁检测（完整社区脚本）"
        echo -e "  ${GREEN}3.${PLAIN} DNS 设置"
        echo -e "  ${GREEN}4.${PLAIN} 防火墙 (ufw) 设置"
        echo -e "  ${YELLOW}0.${PLAIN} 返回主菜单"
        echo -e "${CYAN}==================================================${PLAIN}"
        read -rp "请输入选项 [0-4]: " c
        case "$c" in
            1) media_check_quick; pause ;;
            2) media_check_full; pause ;;
            3) menu_dns ;;
            4) menu_firewall ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
    done
}

# ==================== 主菜单 ====================
show_banner() {
    echo -e "${CYAN}"
    echo -e "   ╔════════════════════════════════════╗"
    echo -e "   ║      Sing-box 管理面板   ${SCRIPT_VERSION}      ║"
    echo -e "   ║      Reality / 转发 / WARP 分流        ║"
    echo -e "   ╚════════════════════════════════════╝"
    echo -e "${PLAIN}"
}

show_menu() {
    clear
    show_banner
    echo -e " 当前状态 : $(get_singbox_status)"
    echo -e "${BLUE}--------------------------------------------------${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 系统管理   核心 / 状态 / 日志 / 卸载"
    echo -e "  ${GREEN}2.${PLAIN} 节点管理   VLESS-Reality / 二维码"
    echo -e "  ${GREEN}3.${PLAIN} 端口转发   TCP/UDP"
    echo -e "  ${GREEN}4.${PLAIN} WARP 出口   AI / 流媒体 / 自定义分流"
    echo -e "  ${GREEN}5.${PLAIN} 配置诊断   查看 / 修复 / 回滚"
    echo -e "  ${GREEN}6.${PLAIN} 实用工具   流媒体检测 / DNS / 防火墙"
    echo -e "  ${GREEN}7.${PLAIN} 重启服务   🚀 一键重启"
    echo -e "${BLUE}--------------------------------------------------${PLAIN}"
    echo -e "  ${YELLOW}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}==================================================${PLAIN}"
    read -rp "请输入选项 [0-7]: " choice
    case "$choice" in
        1) menu_system ;;
        2) menu_nodes ;;
        3) menu_forward ;;
        4) menu_warp ;;
        5) diagnose_config ;;
        6) menu_tools ;;
        7) restart_service; pause ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
    esac
}

# ==================== WARP 出口 ====================
# sing-box 1.11+ 将 wireguard 从 outbound 迁移为 endpoint，这里采用 endpoint 架构。
# 账号通过 warp-reg 本地注册（不依赖不稳定的第三方 API）。
WARP_REG_AMD64="https://github.com/badafans/warp-reg/releases/download/v1.0/main-linux-amd64"
WARP_REG_ARM64="https://github.com/badafans/warp-reg/releases/download/v1.0/main-linux-arm64"
WARP_PEER_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

# geosite 规则集（SagerNet/sing-geosite rule-set 分支，.srs 二进制）
GEOSITE_BASE="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
# AI ：category-ai-!cn 已聚合 ChatGPT/Claude/Gemini 等，再显式补 openai/anthropic
WARP_AI_SITES="category-ai-!cn openai anthropic"
# 流媒体
WARP_MEDIA_SITES="netflix disney hbo youtube primevideo tiktok spotify hulu"

save_warp_meta() { mkdir -p "$META_DIR"; printf '%s' "$1" > "$WARP_META"; chmod 600 "$WARP_META"; }

has_warp_endpoint() {
    local c
    c=$(jq '[.endpoints[]? | select(.tag == "warp")] | length' "$CONFIG_FILE" 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo "0"
}

register_warp_account() {
    # 下载 warp-reg 并注册，输出 JSON {ipv6, private_key, reserved:[..]}（写到 stdout）
    local url="$WARP_REG_AMD64" tmp out pk v6 reserved
    [[ "$(uname -m)" =~ ^(aarch64|arm64)$ ]] && url="$WARP_REG_ARM64"
    tmp=$(mktemp)
    if ! curl -sL --max-time 60 -o "$tmp" "$url"; then
        rm -f "$tmp"; echo -e "${RED}❌ warp-reg 下载失败${PLAIN}" >&2; return 1
    fi
    chmod +x "$tmp"
    out=$("$tmp" 2>/dev/null)
    rm -f "$tmp"

    pk=$(grep -oP '^private_key:\s*\K.*' <<<"$out")
    v6=$(grep -oP '^v6:\s*\K.*' <<<"$out")
    reserved=$(grep -oP '^reserved:\s*\K.*' <<<"$out" | tr -d ' ')
    if [[ -z "$pk" || -z "$v6" || -z "$reserved" ]]; then
        echo -e "${RED}❌ WARP 账号注册失败或返回异常${PLAIN}" >&2; return 1
    fi
    jq -cn --arg pk "$pk" --arg v6 "$v6" --argjson reserved "$reserved" \
        '{ipv6:$v6, private_key:$pk, reserved:$reserved}'
}

add_warp() {
    [ ! -f "$BIN_FILE" ] && echo -e "${RED}请先安装 Sing-box！${PLAIN}" && return
    ensure_config

    if [ "$(has_warp_endpoint)" -gt 0 ]; then
        echo -e "${YELLOW}已存在 WARP 出口，将重新注册并覆盖。${PLAIN}"
    fi

    echo -e "${BLUE}⏳ 正在注册 WARP 账号...${PLAIN}"
    local meta
    meta=$(register_warp_account) || return 1

    local ip6 pk reserved
    ip6=$(jq -r '.ipv6' <<<"$meta")
    pk=$(jq -r '.private_key' <<<"$meta")
    reserved=$(jq -c '.reserved' <<<"$meta")

    local temp_json
    temp_json=$(jq --arg ip6 "$ip6" --arg pk "$pk" --argjson reserved "$reserved" --arg pub "$WARP_PEER_PUBKEY" '
        .endpoints = (.endpoints // [])
        | .endpoints |= (map(select(.tag != "warp")))
        | .endpoints += [{
            "type": "wireguard", "tag": "warp", "mtu": 1280,
            "address": ["172.16.0.2/32", ($ip6 + "/128")],
            "private_key": $pk,
            "peers": [{
                "address": "162.159.192.1", "port": 2408,
                "public_key": $pub,
                "allowed_ips": ["0.0.0.0/0", "::/0"],
                "reserved": $reserved
            }]
        }]' "$CONFIG_FILE")

    if save_and_check_config "$temp_json"; then
        save_warp_meta "$meta"
        systemctl restart sing-box
        echo -e "${GREEN}✅ WARP 出口添加成功！${PLAIN}"
        echo -e "  出口标签 : ${BLUE}warp${PLAIN}（wireguard endpoint）"
        echo -e "  WARP IPv6: ${BLUE}$ip6${PLAIN}"
        echo -e "  元数据   : $WARP_META"
        echo -e "${YELLOW}💡 使用方式：菜单选 3 添加分流规则，或手动把路由规则的 outbound 指向 \"warp\"。${PLAIN}"
    fi
}

add_warp_route() {
    ensure_config
    if [ "$(has_warp_endpoint)" -eq 0 ]; then
        echo -e "${YELLOW}请先添加 WARP 出口。${PLAIN}"; return
    fi
    read -rp "输入要走 WARP 的域名后缀（逗号分隔，如 openai.com,claude.ai）: " doms
    [[ -z "$doms" ]] && { echo -e "${RED}未输入域名。${PLAIN}"; return; }
    local arr
    arr=$(printf '%s' "$doms" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | jq -R . | jq -cs .)
    if [[ "$arr" == "[]" || -z "$arr" ]]; then
        echo -e "${RED}域名解析为空。${PLAIN}"; return
    fi
    local temp_json
    temp_json=$(jq --argjson doms "$arr" '
        .route = (.route // {})
        | .route.rules = (.route.rules // [])
        | .route.rules += [{"domain_suffix": $doms, "outbound": "warp"}]' "$CONFIG_FILE")
    if save_and_check_config "$temp_json"; then
        systemctl restart sing-box
        echo -e "${GREEN}✅ 已添加分流规则：$doms → warp${PLAIN}"
    fi
}

# 确保 rule_set 定义存在（按 tag 去重）并添加一条指向 warp 的规则；参数：规则组名 + geosite 列表
add_ruleset_to_warp() {
    local label="$1"; shift
    local sites=("$@")
    if [ "$(has_warp_endpoint)" -eq 0 ]; then
        echo -e "${YELLOW}请先添加 WARP 出口。${PLAIN}"; return
    fi

    local tags_json defs_json
    tags_json=$(printf '%s\n' "${sites[@]}" | sed 's/^/geosite-/' | jq -R . | jq -cs .)
    defs_json=$(printf '%s\n' "${sites[@]}" | jq -R --arg base "$GEOSITE_BASE" \
        '{tag:("geosite-"+.),type:"remote",format:"binary",url:($base+"/geosite-"+.+".srs")}' | jq -cs .)

    local temp_json
    temp_json=$(jq --argjson tags "$tags_json" --argjson defs "$defs_json" '
        # sing-box 1.14+: 以 http_clients + default_http_client 代替已弃用的 download_detour
        .http_clients = ((.http_clients // []) + [{"tag":"rs-http"}] | group_by(.tag) | map(.[0]))
        | .route = (.route // {})
        | .route.default_http_client = "rs-http"
        # 新增 rule_set 定义，并清掉旧的 download_detour 字段（按 tag 去重）
        | .route.rule_set = (((.route.rule_set // []) + $defs) | map(del(.download_detour)) | group_by(.tag) | map(.[0]))
        | .route.rules = (.route.rules // [])
        | .route.rules += [{"rule_set": $tags, "outbound": "warp"}]' "$CONFIG_FILE")

    if save_and_check_config "$temp_json"; then
        systemctl restart sing-box
        echo -e "${GREEN}✅ 已添加「$label」分流规则 → warp${PLAIN}"
        echo -e "  规则集: $(printf 'geosite-%s ' "${sites[@]}")"
        echo -e "${YELLOW}💡 首次启动会自动下载规则集，若无法下载请确认服务器能访问 GitHub。${PLAIN}"
    fi
}

add_warp_ai()    { ensure_config; add_ruleset_to_warp "AI 服务" $WARP_AI_SITES; }
add_warp_media() { ensure_config; add_ruleset_to_warp "流媒体"   $WARP_MEDIA_SITES; }

view_warp_rules() {
    ensure_config
    if [ "$(has_warp_endpoint)" -eq 0 ]; then
        echo -e "${YELLOW}当前没有 WARP 出口。${PLAIN}"; return
    fi
    local n
    n=$(jq '[.route.rules[]? | select((.outbound? // "") == "warp")] | length' "$CONFIG_FILE" 2>/dev/null)
    echo -e "${CYAN}=== 指向 WARP 的分流规则（共 ${n:-0} 条）===${PLAIN}"
    if [ "${n:-0}" -eq 0 ]; then
        echo -e "${YELLOW}暂无规则。可用菜单 3/4/5 添加。${PLAIN}"; return
    fi
    jq -r '
      [.route.rules[]? | select((.outbound? // "") == "warp")]
      | to_entries[]
      | "  [\(.key+1)] " +
        ([ (if .value.rule_set      then "规则集: "   + (.value.rule_set|join(",")) else empty end),
           (if .value.domain_suffix  then "域名后缀: " + (.value.domain_suffix|join(",")) else empty end),
           (if .value.domain         then "域名: "     + (.value.domain|join(",")) else empty end),
           (if .value.domain_keyword then "关键词: "   + (.value.domain_keyword|join(",")) else empty end),
           (if .value.ip_cidr        then "IP: "       + (.value.ip_cidr|join(",")) else empty end)
         ] | join("  |  "))
    ' "$CONFIG_FILE"
}

delete_warp_rule() {
    ensure_config
    local n
    n=$(jq '[.route.rules[]? | select((.outbound? // "") == "warp")] | length' "$CONFIG_FILE" 2>/dev/null)
    if [ "${n:-0}" -eq 0 ]; then
        echo -e "${YELLOW}暂无指向 warp 的分流规则。${PLAIN}"; return
    fi
    view_warp_rules
    echo -e "--------------------------------------------------"
    local idx
    read -rp "输入要删除的规则序号 (0 取消): " idx
    [[ "$idx" == "0" ]] && return
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$n" ]; then
        echo -e "${RED}无效序号！${PLAIN}"; return
    fi
    local abs
    abs=$(jq --argjson k "$((idx-1))" '
      [.route.rules | to_entries[] | select((.value.outbound? // "") == "warp") | .key][$k]' "$CONFIG_FILE")
    local temp_json
    temp_json=$(jq --argjson i "$abs" '.route.rules |= (.[:$i] + .[$i+1:])' "$CONFIG_FILE")
    if save_and_check_config "$temp_json"; then
        systemctl restart sing-box
        echo -e "${GREEN}✅ 已删除第 $idx 条 warp 分流规则。${PLAIN}"
    fi
}

delete_warp() {
    ensure_config
    if [ "$(has_warp_endpoint)" -eq 0 ]; then
        echo -e "${YELLOW}当前没有 WARP 出口。${PLAIN}"; return
    fi
    local temp_json
    temp_json=$(jq '
        .endpoints |= ((. // []) | map(select(.tag != "warp")))
        | if .route then .route.rules = ([(.route.rules // [])[] | select((.outbound? // "") != "warp")]) else . end' "$CONFIG_FILE")
    if save_and_check_config "$temp_json"; then
        rm -f "$WARP_META"
        systemctl restart sing-box
        echo -e "${GREEN}✅ WARP 出口已删除（含指向 warp 的路由规则）。${PLAIN}"
    fi
}

view_warp() {
    ensure_config
    if [ "$(has_warp_endpoint)" -eq 0 ]; then
        echo -e "${YELLOW}当前没有 WARP 出口。${PLAIN}"; return
    fi
    echo -e "${CYAN}=== WARP 出口 (wireguard endpoint) ===${PLAIN}"
    jq '.endpoints[] | select(.tag == "warp")' "$CONFIG_FILE"
    local rc
    rc=$(jq '[.route.rules[]? | select((.outbound? // "") == "warp")] | length' "$CONFIG_FILE" 2>/dev/null)
    echo -e "  指向 warp 的路由规则数: ${BLUE}${rc:-0}${PLAIN}"
    [ -f "$WARP_META" ] && echo -e "  账号元数据: $WARP_META"
}

menu_warp() {
    while true; do
        clear
        echo -e "=================================================="
        echo -e "        WARP 出口管理 (Cloudflare WARP)"
        echo -e "=================================================="
        echo -e " 当前状态 : $([ "$(has_warp_endpoint)" -gt 0 ] && echo -e "${GREEN}🟢 已配置${PLAIN}" || echo -e "${YELLOW}🟡 未配置${PLAIN}")"
        echo -e "--------------------------------------------------"
        echo -e " 1. 添加 / 重置 WARP 出口 (自动注册账号)"
        echo -e " 2. 查看 WARP 出口信息"
        echo -e " ${CYAN}【分流规则】${PLAIN}"
        echo -e " 3. AI 服务走 WARP   (ChatGPT/Claude/Gemini 等)"
        echo -e " 4. 流媒体走 WARP     (Netflix/Disney/YouTube 等)"
        echo -e " 5. 自定义域名走 WARP"
        echo -e " 6. 查看已添加的分流规则"
        echo -e " 7. 删除指定分流规则"
        echo -e "--------------------------------------------------"
        echo -e " 8. 删除 WARP 出口"
        echo -e " 0. 返回主菜单"
        echo -e "=================================================="
        read -rp "请输入选项 [0-8]: " c
        case "$c" in
            1) add_warp ;;
            2) view_warp ;;
            3) add_warp_ai ;;
            4) add_warp_media ;;
            5) add_warp_route ;;
            6) view_warp_rules ;;
            7) delete_warp_rule ;;
            8) delete_warp ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

# ==================== 入口 ====================
install_dependencies
ensure_config
while true; do
    show_menu
done
