#!/usr/bin/env bash
# ====================================================================
#  Sing-box 管理面板
#  版本: v3.4.4  |  快捷指令: SB / sb
# --------------------------------------------------------------------
#  特性:
#    • VLESS-Reality 节点管理（二维码 / 分享链接）
#    • TCP/UDP 端口转发
#    • Cloudflare WARP 出口（AI / 流媒体 / 自定义分流）
#    • 实用小工具（流媒体解锁检测 / DNS / 防火墙）
#    • 网络加速（BBR / BBRv3 拥塞控制切换 + BBRv3 内核安装）
#    • 客户端订阅一键导入（sing-box 订阅 URL / import scheme）
#    • 配置校验 + 自动回滚 + 并发锁
#  备份策略: 仅当“校验通过”才刷新唯一备份(.bak)，失败备份不动
# ====================================================================

set -o pipefail

SCRIPT_VERSION="v3.4.4"

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

# ---------- 客户端订阅（一键导入）----------
# 订阅文件目录：每个子目录 = 一个订阅，目录名就是链接里的随机路径（口令，勿外传）。
# SUB_BASE_URL 是这些文件对外的访问前缀，需与反代/静态目录配置一致；两者都可用环境变量覆盖。
SUB_DIR="${SUB_DIR:-/root/.nanobot/workspace/subs}"
SUB_BASE_URL="${SUB_BASE_URL:-https://usage.ecio.cn/sub}"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 若通过管道/进程替换（如 bash <(curl ...)）运行，stdin 不是终端，
# read 会立即读到 EOF 导致菜单空转或直接退出（表现为“执行完就断连”）。
# 强制把 stdin 重定向到终端，保证交互菜单始终从 TTY 读取。
if [ ! -t 0 ] && [ -e /dev/tty ]; then exec < /dev/tty; fi

# ---------- 通用交互 ----------
pause() { echo ""; read -rp "按回车键继续..." _; }

# 统一菜单样式：所有菜单使用同一套标题、分组和提示，避免重复绘制导致维护混乱。
menu_header() {
    local title="$1" subtitle="${2:-}" status="${3:-}"
    clear
    # 不使用固定宽度右边框：printf 的 %-Ns 按字符而非终端显示宽度计算，
    # 中文、ANSI 颜色码和手机 SSH 客户端会导致边框错位。
    printf '\n%b┌─ %s ─┐%b\n' "$CYAN" "$title" "$PLAIN"
    [ -n "$subtitle" ] && printf '%b│%b %s\n' "$CYAN" "$PLAIN" "$subtitle"
    [ -n "$status" ] && printf '%b│%b 状态：%b\n' "$CYAN" "$PLAIN" "$status"
    printf '%b└────────────────────────────────────────%b\n' "$CYAN" "$PLAIN"
}
menu_section() { printf '\n%b【%s】%b\n' "$BLUE" "$1" "$PLAIN"; }
menu_option() { printf '  %b%-2s%b %s\n' "$GREEN" "$1." "$PLAIN" "$2"; }
menu_back() { printf '\n  %b0.%b 返回上一级\n' "$YELLOW" "$PLAIN"; }
read_menu_choice() { local prompt="${1:-请选择}"; read -rp "$prompt：" REPLY; }

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

# URL 百分号编码（用于把订阅 URL 拼进 sing-box:// scheme 的 query 参数）
urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

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

# ==================== 客户端订阅（一键导入） ====================
# 订阅文件不由本脚本生成（默认在 $SUB_DIR/<随机名>/，由外部工具/面板投放）；
# 这里只做展示与自检：订阅 URL、sing-box 一键导入 scheme、文件清单、线上可达性 + 配置校验。
sub_links() {
    echo -e "${CYAN}=== 客户端订阅（sing-box 一键导入） ===${PLAIN}"
    if [ ! -d "$SUB_DIR" ]; then
        echo -e "${YELLOW}订阅目录不存在：$SUB_DIR${PLAIN}"
        echo -e "可用环境变量覆盖：SUB_DIR=... SUB_BASE_URL=... sb"
        return
    fi

    local found=0 d name label url scheme files code
    for d in "$SUB_DIR"/*/; do
        [ -f "${d}config.json" ] || continue
        found=1
        name=$(basename "$d")
        label=$(head -1 "$d/name.txt" 2>/dev/null); [ -n "$label" ] || label="$name"
        url="$SUB_BASE_URL/$name/config.json"
        scheme="sing-box://import-remote-profile?url=$(urlenc "$url")#$(urlenc "$label")"
        files=$(ls -1 "$d" 2>/dev/null | grep -v '\.bak' | tr '\n' ' ')

        echo -e "--------------------------------------------------"
        echo -e "  订阅名    : ${BLUE}$name${PLAIN}"
        echo -e "  本地文件  : ${d}config.json  ($(stat -c%s "${d}config.json") B, 更新于 $(date -r "${d}config.json" '+%F %T'))"
        echo -e "  同目录    : ${files}"
        echo -e "  订阅 URL  : ${YELLOW}$url${PLAIN}"
        echo -e "  一键导入  : ${GREEN}$scheme${PLAIN}"

        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null)
        if [ "$code" = "200" ]; then
            echo -e "  线上自检  : ${GREEN}✅ HTTP 200${PLAIN}"
        else
            echo -e "  线上自检  : ${RED}❌ HTTP ${code:-无响应}${PLAIN}（本地文件在，检查反代/静态服务）"
        fi
        if "$BIN_FILE" check -c "${d}config.json" >/dev/null 2>&1; then
            echo -e "  配置校验  : ${GREEN}✅ sing-box check 通过${PLAIN}"
        else
            echo -e "  配置校验  : ${RED}❌ sing-box check 失败${PLAIN}"
        fi
    done

    if [ "$found" -eq 0 ]; then
        echo -e "${YELLOW}$SUB_DIR 下没找到订阅（需存在 <名>/config.json）。${PLAIN}"
        return
    fi
    echo -e "--------------------------------------------------"
    echo -e "${BLUE}怎么用：${PLAIN}"
    echo -e "  iOS「sing-box MT」→ Profile → 右上角 + → 从 URL 导入，粘贴上面的订阅 URL"
    echo -e "  「一键导入」链接要放进 Safari 地址栏或备忘录里点（微信会拦自定义 scheme）"
    echo -e "  Remote profile 客户端自带自动更新（默认 60 分钟），也可手动下拉刷新"
}

# ==================== 配置诊断与回滚 ====================
diagnose_config() {
    while true; do
        menu_header "配置诊断与回滚" "查看、编辑、校验与恢复配置"
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
        menu_section "配置操作"
        menu_option 1 "查看原始 JSON"
        menu_option 2 "查看 Reality 元数据"
        menu_option 3 "手动编辑并校验配置"
        menu_option 4 "重置为空配置（自动备份）"
        menu_option 5 "回滚到上次有效备份 ${RED}⚠️${PLAIN}"
        menu_back
        read_menu_choice "请选择 [0-5]"; c="$REPLY"
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
        menu_header "系统管理" "核心、服务与运行监控" "$(get_singbox_status)"
        menu_section "服务操作"
        menu_option 1 "安装 / 更新 Sing-box 核心"
        menu_option 2 "启动服务"
        menu_option 3 "停止服务"
        menu_option 4 "重启服务"
        menu_option 5 "卸载 Sing-box"
        menu_section "查看与诊断"
        menu_option 6 "查看服务状态"
        menu_option 7 "查看当前配置"
        menu_option 8 "查看运行日志"
        menu_back
        read_menu_choice "请选择 [0-8]"; c="$REPLY"
        case "$c" in
            1) install_singbox ;; 2) systemctl start sing-box && echo -e "${GREEN}✅ 已启动${PLAIN}" ;;
            3) systemctl stop sing-box && echo -e "${YELLOW}🛑 已停止${PLAIN}" ;; 4) restart_service ;;
            5) uninstall_singbox ;; 6) show_service_status ;; 7) show_full_config ;; 8) view_logs ;;
            0) return ;; *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

menu_nodes() {
    while true; do
        menu_header "节点管理" "VLESS-Reality 节点与分享信息"
        menu_option 1 "添加 VLESS-Reality 节点"
        menu_option 2 "查看分享链接 / 二维码"
        menu_option 3 "删除节点"
        menu_back
        read_menu_choice "请选择 [0-3]"; c="$REPLY"
        case "$c" in 1) add_reality_node ;; 2) view_node_links ;; 3) delete_node ;; 0) return ;; *) echo -e "${RED}无效选项！${PLAIN}" ;; esac
        pause
    done
}

menu_forward() {
    while true; do
        menu_header "端口转发" "TCP / UDP 转发规则管理"
        menu_option 1 "添加端口转发"
        menu_option 2 "查看转发规则"
        menu_option 3 "删除转发规则"
        menu_back
        read_menu_choice "请选择 [0-3]"; c="$REPLY"
        case "$c" in 1) add_port_forward ;; 2) view_port_forwards ;; 3) delete_port_forward ;; 0) return ;; *) echo -e "${RED}无效选项！${PLAIN}" ;; esac
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
        menu_header "DNS 设置" "解析服务器配置"
        show_dns
        menu_section "常用 DNS"
        menu_option 1 "Cloudflare（1.1.1.1 / 1.0.0.1）"
        menu_option 2 "Google（8.8.8.8 / 8.8.4.4）"
        menu_option 3 "Quad9（9.9.9.9 / 149.112.112.112）"
        menu_option 4 "AliDNS（223.5.5.5 / 223.6.6.6）"
        menu_option 5 "自定义 DNS（空格分隔多个）"
        menu_option 6 "恢复备份 resolv.conf"
        menu_back
        read_menu_choice "请选择 [0-6]"; c="$REPLY"
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
        menu_header "防火墙设置" "ufw 端口与安全策略"
        ufw status verbose 2>/dev/null | head -20
        menu_section "规则操作"
        menu_option 1 "开放端口（TCP + UDP）"
        menu_option 2 "关闭 / 删除端口规则"
        menu_option 3 "启用防火墙（自动保留 SSH 22）"
        menu_option 4 "关闭防火墙"
        menu_option 5 "重载防火墙"
        menu_back
        read_menu_choice "请选择 [0-5]"; c="$REPLY"
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

# ==================== 网络加速（BBR / BBRv3 拥塞控制） ====================
# 关键点："bbr" 只是内核里的一个算法名，跑的是 v1 还是 v3 由内核决定
#（自编译 bbr3 内核 / 打了 BBRv3 补丁的发行版内核）。
# 判定依据只有两条硬证据：内核 release 名 + tcp_bbr 模块的 version 字段（bbr3 内核 = 3）。
# 队列统一用 fq_codel：XDflight/bbr3-debs 的内核是 defconfig 构建（CONFIG_NET_SCH_FQ 未开），
# 所以「BBR + fq」只在内核实测支持时才切；要 fq 得换带 SCH_FQ 的内核源（XanMod 等）。
BBR_CONF="/etc/sysctl.d/99-zz-bbr-mode.conf"   # 字母序排在 99-vpsbox-bbr.conf 之后，最后生效
BBR3_REPO="XDflight/bbr3-debs"                 # BBRv3 内核 deb 源（与本机 6.1.187-bbr3 同源）

bbr_kernel_label() {
    local k mt maj min
    k=$(uname -r)
    case "$k" in
        *bbr3*|*bbrv3*|*xanmod*) echo "v3"; return ;;
        *bbrplus*)               echo "plus"; return ;;
    esac
    mt=$(command -v modinfo >/dev/null 2>&1 && modinfo -F version tcp_bbr 2>/dev/null)
    [ "$mt" = "3" ] && { echo "v3"; return; }
    # 主线内核自带新版 BBR 代码但不打版本戳（6.12 的 tcp_bbr.c 里就有 bbr_beta / bbr_ecn_alpha_gain
    # 这类 v3 才有的符号），所以 ≥6.12 的主线内核只能报“疑似”，不算硬判定。
    maj=${k%%.*}; min=$(printf '%s' "$k" | cut -d. -f2)
    if [ -n "$maj" ] && [ -n "$min" ] && { [ "$maj" -gt 6 ] || { [ "$maj" -eq 6 ] && [ "$min" -ge 12 ]; }; } 2>/dev/null; then
        echo "v3u"; return
    fi
    echo "v1"
}

bbr_kernel_desc() {
    case "$(bbr_kernel_label)" in
        v3)   echo -e "${YELLOW}BBRv3${PLAIN}" ;;
        v3u)  echo -e "${YELLOW}疑似 BBRv3${PLAIN}${GREEN}（≥6.12 主线自带新版 BBR，未打版本戳）${PLAIN}" ;;
        plus) echo -e "${YELLOW}BBRplus${PLAIN}" ;;
        *)    echo -e "${GREEN}非 BBRv3（内核原生 bbr v1/v2）${PLAIN}" ;;
    esac
}

# 内核有没有 fq 队列算法：先看模块树 / 内核 config，都判不出再在 lo 上试挂一次
bbr_fq_available() {
    local cfg
    modinfo -k "$(uname -r)" sch_fq >/dev/null 2>&1 && return 0
    cfg="/boot/config-$(uname -r)"
    if [ -r "$cfg" ]; then
        grep -qE '^CONFIG_NET_SCH_FQ=[ym]' "$cfg" && return 0
        return 1
    fi
    tc qdisc add dev lo root fq >/dev/null 2>&1 && { tc qdisc del dev lo root >/dev/null 2>&1; return 0; }
    return 1
}

bbr_default_iface() { ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}'; }

bbr_os_family() {
    local id like
    id=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
    like=$(. /etc/os-release 2>/dev/null; echo "${ID_LIKE:-}")
    case "$id $like" in
        *debian*|*ubuntu*) echo "debian" ;;
        *rhel*|*centos*|*fedora*) echo "rhel" ;;
        *) echo "unknown" ;;
    esac
}

bbr_status_short() {
    local iface
    iface=$(bbr_default_iface)
    echo -e "  内核      : ${YELLOW}$(uname -r)${PLAIN}    BBR 版本: $(bbr_kernel_desc)"
    echo -e "  拥塞算法  : ${YELLOW}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${PLAIN}    默认队列: ${YELLOW}$(sysctl -n net.core.default_qdisc 2>/dev/null)${PLAIN}"
    echo -e "  可用算法  : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
    if bbr_fq_available; then echo -e "  fq 队列   : ${GREEN}可用${PLAIN}"; else echo -e "  fq 队列   : ${YELLOW}不可用（本机内核只有 fq_codel）${PLAIN}"; fi
    [ -n "$iface" ] && echo -e "  ${iface} 实际队列: $(tc qdisc show dev "$iface" 2>/dev/null | head -1)"
}

bbr_show_status() {
    echo -e "${BLUE}=== 拥塞控制状态 ===${PLAIN}"
    bbr_status_short
    echo -e "\n  判定依据 : 内核 $(uname -r) / tcp_bbr 模块 version=$(command -v modinfo >/dev/null 2>&1 && modinfo -F version tcp_bbr 2>/dev/null || echo 未知)"
    echo -e "  持久化   : ${BBR_CONF}"
    if [ -f "$BBR_CONF" ]; then sed 's/^/    /' "$BBR_CONF"; else echo -e "    ${YELLOW}(本面板尚未写入该文件)${PLAIN}"; fi
    echo -e "\n  ${YELLOW}说明：换内核后算法名仍是 bbr，v1/v3 由内核决定，不需要改这里的配置。${PLAIN}"
}

# 写入持久化 + 立即生效 + 回读校验；$1=算法 $2=队列 $3=显示名
# 先拿 tc 实测内核支不支持该队列：不支持就直接拒绝、一点都不改（否则把内核没编译的 qdisc
# 写进 sysctl.d，开机会静默失败），回读不一致时还要把配置文件恢复原样。
bbr_apply() {
    local cc="$1" qdisc="$2" label="$3" avail iface cur_cc cur_qd cur_qd_live bak=""
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    if ! printf '%s\n' $avail | grep -qx "$cc"; then
        echo -e "${RED}❌ 当前内核不支持 ${cc}（可用: ${avail}）${PLAIN}"
        return 1
    fi

    iface=$(bbr_default_iface)
    if [ -n "$iface" ]; then
        cur_qd_live=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1{print $2}')
        if [ "$cur_qd_live" != "$qdisc" ]; then
            # 默认队列只影响新建的网卡队列，已在跑的网卡必须手动替换；顺便用它验证内核是否支持
            if ! tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1; then
                echo -e "${RED}❌ 当前内核没有 ${qdisc} 这个队列算法（tc 替换失败），配置未做任何改动。${PLAIN}"
                echo -e "${YELLOW}   ${iface} 现用 ${cur_qd_live}；要 ${qdisc} 只能换一个带该算法（CONFIG_NET_SCH_FQ）的内核。${PLAIN}"
                return 1
            fi
        fi
    fi

    mkdir -p /etc/sysctl.d
    [ -f "$BBR_CONF" ] && { bak=$(mktemp); cp -p "$BBR_CONF" "$bak"; }
    {
        echo "# ${label} —— 由 sb 管理面板写入 $(date '+%Y-%m-%d %H:%M')"
        echo "net.core.default_qdisc = ${qdisc}"
        echo "net.ipv4.tcp_congestion_control = ${cc}"
    } > "$BBR_CONF"
    chmod 644 "$BBR_CONF"

    modprobe tcp_bbr >/dev/null 2>&1 || true
    sysctl -q -w "net.core.default_qdisc=${qdisc}" "net.ipv4.tcp_congestion_control=${cc}" >/dev/null 2>&1

    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    cur_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ "$cur_cc" = "$cc" ] && [ "$cur_qd" = "$qdisc" ]; then
        echo -e "${GREEN}✅ 已切换到 ${label}${PLAIN}"
        echo -e "   算法=${cur_cc}  默认队列=${cur_qd}  ${iface:-?} 实际队列=$(tc qdisc show dev "${iface:-eth0}" 2>/dev/null | awk 'NR==1{print $2}')"
        echo -e "   持久化=${BBR_CONF}（重启后自动生效）"
        echo -e "${YELLOW}   注意：已建立的 TCP 连接沿用旧算法，新连接才生效。${PLAIN}"
    else
        if [ -n "$bak" ]; then cp -p "$bak" "$BBR_CONF"; else rm -f "$BBR_CONF"; fi
        rm -f "$bak"
        echo -e "${RED}❌ 回读校验不一致：算法=${cur_cc} 队列=${cur_qd}（期望 ${cc} / ${qdisc}）${PLAIN}"
        echo -e "${YELLOW}   已把 ${BBR_CONF} 恢复原样。${PLAIN}"
        return 1
    fi
}

bbr_set_bbr() {
    bbr_apply bbr fq_codel "BBR + fq_codel" || return 1
    case "$(bbr_kernel_label)" in
        v3)  echo -e "${YELLOW}   本机是 BBRv3 内核 → 实际生效的就是 BBRv3 + fq_codel。${PLAIN}" ;;
        v3u) echo -e "${YELLOW}   本机内核 ≥6.12，自带新版 BBR 代码，大概率就是 BBRv3。${PLAIN}" ;;
        *)   echo -e "${YELLOW}   提示：本机内核不是 BBRv3，想要 v3 请用菜单里的「安装 BBRv3 内核」。${PLAIN}" ;;
    esac
}

# 切「BBR + fq」：先确认内核真有 fq，没有就别切（否则只会报错/无效）
bbr_set_bbr_fq() {
    if ! bbr_fq_available; then
        echo -e "${YELLOW}本机内核 $(uname -r) 没有 fq 队列算法，切 fq 没意义。${PLAIN}"
        echo -e "   ${BBR3_REPO} 的内核是 defconfig 构建（CONFIG_NET_SCH_FQ 未开）；要 fq 得换带 fq 的内核源（XanMod / Fridream）。"
        read -rp "  改切「BBR + fq_codel」？[Y/n]: " y
        case "$y" in n|N) echo -e "${YELLOW}已取消。${PLAIN}"; return ;; esac
        bbr_set_bbr; return
    fi
    bbr_apply bbr fq "BBR + fq" || return 1
    [ "$(bbr_kernel_label)" = "v3" ] && echo -e "${YELLOW}   本机是 BBRv3 内核 → 实际生效的就是 BBRv3 + fq。${PLAIN}"
    return 0
}

# 装完内核先离线核验新内核能力（fq / BBRv3），别等重启完才发现缺东西
bbr_post_install_check() {
    local cfg krel fq ver
    cfg=$(ls -1 /boot/config-* 2>/dev/null | sort -V | tail -1)
    [ -n "$cfg" ] || { echo -e "${YELLOW}  （没找到 /boot/config-*，跳过能力自检）${PLAIN}"; return 0; }
    krel=${cfg#/boot/config-}
    fq=$(grep -E '^CONFIG_NET_SCH_FQ=' "$cfg" | head -1 | cut -d= -f2)
    ver=$(modinfo -k "$krel" -F version tcp_bbr 2>/dev/null)
    echo -e "${BLUE}--- 最新内核能力自检（${krel}）---${PLAIN}"
    if [ "$fq" = "y" ] || [ "$fq" = "m" ]; then
        echo -e "  fq 队列 : ${GREEN}支持${PLAIN}（CONFIG_NET_SCH_FQ=${fq}）"
    else
        echo -e "  fq 队列 : ${YELLOW}不支持${PLAIN}（CONFIG_NET_SCH_FQ 未开）→ 用 fq_codel"
    fi
    if [ "$ver" = "3" ]; then
        echo -e "  BBR     : ${GREEN}BBRv3${PLAIN}（tcp_bbr 模块 version=3）"
    else
        echo -e "  BBR     : ${YELLOW}非 BBRv3${PLAIN}（tcp_bbr version=${ver:-无}）"
    fi
}

bbr_list_kernels() {
    if command -v dpkg-query >/dev/null 2>&1; then
        echo -e "${BLUE}=== 已安装内核（dpkg）===${PLAIN}"
        dpkg-query -W -f='${db:Status-Abbrev}|${Package}|${Version}\n' 'linux-image*' 2>/dev/null \
            | awk -F'|' '$1 ~ /^ii/ && $2 !~ /-common$/ {printf "  %s  %s\n", $2, $3}'
    elif command -v rpm >/dev/null 2>&1; then
        echo -e "${BLUE}=== 已安装内核（rpm）===${PLAIN}"
        rpm -qa 2>/dev/null | grep -E '^kernel' | sort -V | sed 's/^/  /'
    else
        echo -e "${RED}未找到 dpkg / rpm，无法列出内核。${PLAIN}"; return
    fi
    echo -e "  当前运行 : ${GREEN}$(uname -r)${PLAIN}"
}

# 从 BBR3_REPO 安装 BBRv3 内核（deb 系；不自动重启）
# 注：这些包是 defconfig 构建，没有 CONFIG_NET_SCH_FQ → 装完用 fq_codel。
bbr_install_kernel() {
    local arch fam resp tags sel tag ver url_img url_hdr tmp i
    arch=$(uname -m)
    [ "$arch" = "x86_64" ] || { echo -e "${RED}❌ ${BBR3_REPO} 只提供 amd64 的 deb（当前 ${arch}）。ARM 请用发行版自带内核。${PLAIN}"; return 1; }
    fam=$(bbr_os_family)
    [ "$fam" = "debian" ] || { echo -e "${RED}❌ 本功能只处理 deb 系（Debian / Ubuntu），当前系统判定为 ${fam}。${PLAIN}"; return 1; }

    echo -e "${BLUE}⏳ 正在从 ${BBR3_REPO} 获取可用版本...${PLAIN}"
    resp=$(curl -sL --max-time 25 "https://api.github.com/repos/${BBR3_REPO}/releases?per_page=100" 2>/dev/null)
    tags=$(jq -r '.[].tag_name' <<<"$resp" 2>/dev/null | grep -E -- '-bbr3-amd64$' | head -6)
    if [ -z "$tags" ]; then
        echo -e "${RED}❌ 取不到版本列表（GitHub API 限流 / 无外网）。退路：VPSBox 的 BBR 菜单，或手动 dpkg 安装 deb。${PLAIN}"
        return 1
    fi

    echo -e "${BLUE}可用 BBRv3 内核（新 → 旧）：${PLAIN}"
    i=0
    while read -r tag; do
        [ -z "$tag" ] && continue
        i=$((i+1))
        echo -e "  ${GREEN}${i})${PLAIN} ${tag}"
    done <<< "$tags"
    read -rp "选择编号（回车取消）: " sel
    [ -z "$sel" ] && { echo -e "${YELLOW}已取消。${PLAIN}"; return; }
    case "$sel" in *[!0-9]*) echo -e "${RED}无效编号。${PLAIN}"; return 1 ;; esac
    tag=$(printf '%s\n' "$tags" | sed -n "${sel}p")
    [ -n "$tag" ] || { echo -e "${RED}无效编号。${PLAIN}"; return 1; }

    url_img=$(jq -r --arg t "$tag" '.[] | select(.tag_name==$t) | .assets[].browser_download_url' <<<"$resp" 2>/dev/null | grep -E '/linux-image-[^/]*amd64\.deb$' | head -1)
    url_hdr=$(jq -r --arg t "$tag" '.[] | select(.tag_name==$t) | .assets[].browser_download_url' <<<"$resp" 2>/dev/null | grep -E '/linux-headers-[^/]*amd64\.deb$' | head -1)
    [ -n "$url_img" ] || { echo -e "${RED}❌ 该版本没有 amd64 image 资产。${PLAIN}"; return 1; }

    tmp=$(mktemp -d /tmp/bbr3-XXXXXX)
    echo -e "${BLUE}⏳ 下载 $(basename "$url_img") ...${PLAIN}"
    curl -fL --max-time 600 -o "$tmp/$(basename "$url_img")" "$url_img" || { echo -e "${RED}❌ image 下载失败（文件留在 ${tmp}）。${PLAIN}"; return 1; }
    if [ -n "$url_hdr" ]; then
        echo -e "${BLUE}⏳ 下载 $(basename "$url_hdr") ...${PLAIN}"
        curl -fL --max-time 600 -o "$tmp/$(basename "$url_hdr")" "$url_hdr" || echo -e "${YELLOW}  ⚠️ headers 下载失败，只装 image。${PLAIN}"
    fi

    echo -e "\n${YELLOW}即将 dpkg 安装 ${tag} 并更新 GRUB 默认项。${PLAIN}"
    echo -e "${RED}注意：需要重启才生效；新内核起不来时用 VPS 控制台（VNC）选旧内核回退。${PLAIN}"
    echo -e "${YELLOW}  注：${BBR3_REPO} 的内核是 defconfig 构建 → 没有 fq（只有 fq_codel）。${PLAIN}"
    read -rp "确认安装？输入 yes 继续: " conf
    [ "$conf" = "yes" ] || { echo -e "${YELLOW}已取消（deb 文件留在 ${tmp}）。${PLAIN}"; return; }

    if dpkg -i "$tmp"/*.deb; then
        command -v update-grub >/dev/null 2>&1 && update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null
        echo -e "${GREEN}✅ 安装完成，重启后生效： ${YELLOW}reboot${PLAIN}"
        bbr_post_install_check
        echo -e "   重启回来后在「网络加速」里选一次「BBR + fq_codel」确认即可。"
    else
        echo -e "${RED}❌ dpkg 安装失败，尝试补齐依赖...${PLAIN}"
        apt-get -f install -y && update-grub 2>/dev/null
        echo -e "${YELLOW}若仍失败，deb 文件保留在 ${tmp} 可手动处理。${PLAIN}"
    fi
}

menu_bbr() {
    while true; do
        menu_header "网络加速" "BBR / BBRv3 拥塞控制 + 内核"
        bbr_status_short
        menu_section "切换（立即生效 + 写入持久化）"
        menu_option 1 "BBR + fq_codel（推荐；内核是 bbr3 就是 BBRv3）"
        menu_option 2 "BBR + fq（先实测内核支不支持 fq，不支持就拒绝）"
        menu_option 3 "CUBIC + fq_codel（恢复系统默认）"
        menu_section "内核"
        menu_option 4 "安装 BBRv3 内核（${BBR3_REPO}）"
        menu_option 5 "查看已安装内核"
        menu_section "查看"
        menu_option 6 "完整状态与判定依据"
        menu_back
        read_menu_choice "请选择 [0-6]"; c="$REPLY"
        case "$c" in
            1) bbr_set_bbr ;; 2) bbr_set_bbr_fq ;; 3) bbr_apply cubic fq_codel "CUBIC + fq_codel" ;;
            4) bbr_install_kernel ;; 5) bbr_list_kernels ;; 6) bbr_show_status ;;
            0) return ;; *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

menu_tools() {
    while true; do
        menu_header "实用工具" "网络检测、加速、DNS 与防火墙"
        menu_section "网络检测"
        menu_option 1 "流媒体解锁检测（快速）"
        menu_option 2 "流媒体解锁检测（完整社区脚本）"
        menu_section "系统网络"
        menu_option 3 "DNS 设置"
        menu_option 4 "防火墙设置（ufw）"
        menu_option 5 "网络加速（BBR / BBRv3 + fq）"
        menu_back
        read_menu_choice "请选择 [0-5]"; c="$REPLY"
        case "$c" in
            1) media_check_quick; pause ;; 2) media_check_full; pause ;;
            3) menu_dns ;; 4) menu_firewall ;; 5) menu_bbr ;; 0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
    done
}

# ==================== 主菜单 ====================
show_menu() {
    menu_header "Sing-box 管理面板" "Reality / 转发 / WARP 分流  ·  ${SCRIPT_VERSION}" "$(get_singbox_status)"
    menu_section "核心管理"
    menu_option 1 "系统管理（安装、服务、日志、卸载）"
    menu_option 2 "节点管理（VLESS-Reality、链接、二维码）"
    menu_option 3 "端口转发（TCP / UDP）"
    menu_option 4 "WARP 出口与分流"
    menu_section "配置与工具"
    menu_option 5 "配置诊断（查看、编辑、回滚）"
    menu_option 6 "实用工具（解锁检测、DNS、防火墙）"
    menu_option 7 "客户端订阅（sing-box 一键导入链接）"
    printf '\n  %b0.%b 退出脚本\n\n' "$YELLOW" "$PLAIN"
    read_menu_choice "请选择 [0-7]"; choice="$REPLY"
    case "$choice" in
        1) menu_system ;; 2) menu_nodes ;; 3) menu_forward ;; 4) menu_warp ;;
        5) diagnose_config ;; 6) menu_tools ;; 7) sub_links; pause ;;
        0) exit 0 ;; *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
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

add_warp_node_route() {
    ensure_config
    if [ "$(has_warp_endpoint)" -eq 0 ]; then
        echo -e "${YELLOW}请先添加 WARP 出口。${PLAIN}"; return
    fi

    local tags=() i=0 n=0 tag choice selected
    while [ $i -lt "$(inbound_count)" ]; do
        tag=$(inbound_field "$i" "tag")
        if [ "$(inbound_field "$i" "type")" == "vless" ] && [ -n "$tag" ]; then
            tags+=("$tag")
            n=$((n+1))
            echo "  $n. $tag"
        fi
        i=$((i+1))
    done
    if [ "$n" -eq 0 ]; then
        echo -e "${YELLOW}当前没有 VLESS 节点。${PLAIN}"; return
    fi

    read -rp "选择要全部走 WARP 的节点 [1-$n]: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
        echo -e "${RED}无效序号。${PLAIN}"; return
    fi
    selected="${tags[$((choice-1))]}"

    local temp_json
    temp_json=$(jq --arg tag "$selected" '
        .route = (.route // {})
        | .route.rules = ([{"inbound":[$tag],"outbound":"warp"}] +
            [(.route.rules // [])[] | select((.inbound? // []) | index($tag) | not)])
    ' "$CONFIG_FILE")
    if save_and_check_config "$temp_json"; then
        systemctl restart sing-box
        if systemctl is-active --quiet sing-box; then
            echo -e "${GREEN}✅ 节点 [$selected] 已设置为全部走 WARP。${PLAIN}"
        else
            echo -e "${RED}❌ 配置已写入，但 sing-box 重启失败，请查看日志。${PLAIN}"
        fi
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
      | .value as $r
      | ([
          (if ($r.inbound?       // null) != null then "入站: "     + (($r.inbound       | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.rule_set?      // null) != null then "规则集: "   + (($r.rule_set      | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.domain_suffix? // null) != null then "域名后缀: " + (($r.domain_suffix | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.domain?        // null) != null then "域名: "     + (($r.domain        | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.domain_keyword? // null) != null then "关键词: "   + (($r.domain_keyword | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.ip_cidr?       // null) != null then "IP: "       + (($r.ip_cidr       | if type == "array" then join(",") else tostring end)) else empty end)
        ] | map(select(. != "")) | join("  |  ")) as $detail
      | "  [\(.key + 1)] " + (if $detail == "" then "全部流量 → warp" else $detail end)
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
        local warp_status
        warp_status=$([ "$(has_warp_endpoint)" -gt 0 ] && echo -e "${GREEN}已配置${PLAIN}" || echo -e "${YELLOW}未配置${PLAIN}")
        menu_header "WARP 出口" "Cloudflare WARP · 出口与分流规则" "$warp_status"
        menu_section "出口"
        menu_option 1 "添加 / 重置 WARP（自动注册账号）"
        menu_option 2 "查看 WARP 出口信息"
        menu_option 9 "删除 WARP 出口及相关规则"
        menu_section "分流规则"
        menu_option 3 "AI 服务走 WARP"
        menu_option 4 "流媒体走 WARP"
        menu_option 5 "自定义域名走 WARP"
        menu_option 8 "指定节点全部走 WARP"
        local rule_count
        rule_count=$(jq '[.route.rules[]? | select((.outbound? // "") == "warp")] | length' "$CONFIG_FILE" 2>/dev/null)
        menu_option 6 "查看已添加的规则（${rule_count:-0} 条）"
        menu_option 7 "删除指定规则"
        menu_back
        read_menu_choice "请选择 [0-9]"; c="$REPLY"
        case "$c" in
            1) add_warp ;; 2) view_warp ;; 3) add_warp_ai ;; 4) add_warp_media ;;
            5) add_warp_route ;; 6) view_warp_rules ;; 7) delete_warp_rule ;;
            8) add_warp_node_route ;; 9) delete_warp ;; 0) return ;;
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
