#!/usr/bin/env bash
# ====================================================================
# Sing-box 管理面板 v3.0.2 (生产级纯净版)
# 特性: 无备注 / 官方文档配置格式 / 端口转发修复 / 配置回滚 / 并发锁
# 备份策略: 每次"配置校验通过"才刷新唯一备份(.bak)，校验失败备份不动
# ====================================================================

set -o pipefail

# ---------- 颜色 ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[36m"; CYAN="\033[35m"; PLAIN="\033[0m"

# ---------- 路径 ----------
CONFIG_FILE="/etc/sing-box/config.json"
BIN_FILE="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
META_DIR="/etc/sing-box/.meta"
REALITY_META="$META_DIR/reality.txt"
LOCK_FILE="/var/run/sing-box-manager.lock"

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

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
        echo ""; read -rp "按回车键继续..."
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
        echo ""; read -rp "按回车键继续..."
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
        echo ""; read -rp "按回车键继续..."
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
        echo ""; read -rp "按回车键继续..."
    done
}

# ==================== 主菜单 ====================
show_menu() {
    clear
    echo -e "=================================================="
    echo -e "        Sing-box 管理面板 v3.0.2 (生产级纯净版)"
    echo -e "=================================================="
    echo -e " 当前状态 : $(get_singbox_status)"
    echo -e "--------------------------------------------------"
    echo -e " 1. 系统管理   (核心 / 状态 / 日志 / 卸载)"
    echo -e " 2. 节点管理   (VLESS-Reality / 二维码)"
    echo -e " 3. 端口转发   (TCP/UDP)"
    echo -e " 4. 配置诊断   (查看 / 修复 / 回滚)"
    echo -e " 5. 重启服务   🚀 一键重启"
    echo -e "--------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo -e "=================================================="
    read -rp "请输入选项 [0-5]: " choice
    case "$choice" in
        1) menu_system ;;
        2) menu_nodes ;;
        3) menu_forward ;;
        4) diagnose_config ;;
        5) restart_service; echo ""; read -rp "按回车键继续..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项！${PLAIN}"; sleep 1 ;;
    esac
}

# ==================== 入口 ====================
install_dependencies
ensure_config
while true; do
    show_menu
done
