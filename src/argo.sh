# ==================== Argo：域名 + Tunnel Token，不索要 API 权限 ====================
valid_domain() {
    local domain="$1" label
    [ "${#domain}" -le 253 ] && [[ "$domain" == *.* && "$domain" != *[!a-zA-Z0-9.-]* ]] || return 1
    local parts=()
    IFS=. read -r -a parts <<< "$domain"
    [[ "$domain" != *. ]] || return 1
    for label in "${parts[@]}"; do
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
    done
}
valid_ws_path() {
    # 只接受无需歧义解释的 URL path；查询参数、空白、百分号和片段不混入路径。
    [[ "$1" =~ ^/[a-zA-Z0-9/_~.-]*$ ]] && [ "${#1}" -le 256 ]
}
valid_tunnel_id() { [[ "$1" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; }
token_tunnel_id() {
    local decoded
    # Token 仅通过 stdin 解码，不放进任何子进程的命令行。
    [[ "$1" =~ ^[a-zA-Z0-9+/=]+$ ]] || return 1
    decoded=$(printf '%s' "$1" | base64 -d 2>/dev/null) || return 1
    jq -er 'select((.a | type) == "string" and (.s | type) == "string") | .t | select(type == "string")' <<< "$decoded"
}
argo_unit_path() {
    valid_tunnel_id "$1" || return 1
    case "$INIT_SYS" in
        systemd) printf '/etc/systemd/system/sb-argo-%s.service' "$1" ;;
        openrc) printf '/etc/init.d/sb-argo-%s' "$1" ;;
        *) return 1 ;;
    esac
}
argo_owned() {
    local id="$1" path
    valid_tunnel_id "$id" || return 1
    path=$(argo_unit_path "$id") || return 1
    jq -e --arg id "$id" '.managed_by == "sb-v4" and .id == $id' "$ARGO_DIR/$id/tunnel.json" >/dev/null 2>&1 &&
        grep -Fxq '# sb-v4-managed' "$path" 2>/dev/null
}
argo_active() {
    valid_tunnel_id "$1" || return 1
    argo_owned "$1" || return 1
    svc_active_name "sb-argo-$1"
}
argo_ctl() {
    local id="$1" action="$2"
    argo_owned "$id" || { error '拒绝操作未由 v4 管理的隧道。'; return 1; }
    case "$INIT_SYS" in
        systemd) (exec 200>&-; systemctl "$action" "sb-argo-$id") ;;
        openrc) (exec 200>&-; rc-service "sb-argo-$id" "$action") ;;
        *) return 1 ;;
    esac
}
argo_enable() {
    case "$INIT_SYS" in systemd) systemctl enable "sb-argo-$1" ;; openrc) rc-update add "sb-argo-$1" default ;; *) return 1 ;; esac
}
argo_disable() {
    case "$INIT_SYS" in systemd) systemctl disable "sb-argo-$1" ;; openrc) rc-update del "sb-argo-$1" default ;; *) return 1 ;; esac
}
install_cloudflared() {
    if [ -x "$CF_BIN" ]; then
        "$CF_BIN" tunnel run --help 2>/dev/null | grep -F -- '--token-file' >/dev/null || {
            error '现有 cloudflared 不支持 token-file，请先升级；不会把 Token 放到进程参数。'; return 1;
        }
        return 0
    fi
    local directory arch url
    arch=$(release_arch) || return 1
    directory=$(mktemp -d) || return 1
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
    if curl -fsSL --proto '=https' --max-time 300 "$url" -o "$directory/cloudflared" && chmod 755 "$directory/cloudflared" && "$directory/cloudflared" version &&
        "$directory/cloudflared" tunnel run --help | grep -F -- '--token-file' >/dev/null; then
        install_binary "$directory/cloudflared" "$CF_BIN"
        local rc=$?; rm -rf "$directory"; return "$rc"
    fi
    rm -rf "$directory"; error 'cloudflared 安装失败。'
}
argo_create() {
    local id="$1" token="$2" path directory="$ARGO_DIR/$1"
    valid_tunnel_id "$id" && [ "$INIT_SYS" != none ] || return 1
    path=$(argo_unit_path "$id") || return 1
    if argo_owned "$id"; then
        # 不自动替换已有凭据；同一固定隧道只托管一个进程，多个节点可复用。
        [ "$(cat "$directory/token" 2>/dev/null)" = "$token" ] || { error '该隧道的 Token 与已保存值不同；请先核对，不自动覆盖。'; return 1; }
        return 0
    fi
    [ ! -e "$directory" ] && [ ! -e "$path" ] || { error '隧道目录或服务已存在但不归本面板管理。'; return 1; }
    if [ "$INIT_SYS" = systemd ] && systemctl cat "sb-argo-$id" >/dev/null 2>&1; then
        error '发现其他位置的同名隧道服务，拒绝覆盖。'; return 1
    fi
    mkdir -p "$ARGO_DIR" && chmod 700 "$ARGO_DIR" && mkdir -m 700 "$directory" || return 1
    if ! printf '%s' "$token" > "$directory/token" || ! chmod 600 "$directory/token" ||
        ! write_json "$directory/tunnel.json" "{\"managed_by\":\"sb-v4\",\"id\":\"$id\"}"; then
        rm -f "$directory/token" "$directory/tunnel.json"; rmdir "$directory"; return 1
    fi
    case "$INIT_SYS" in
        systemd)
            cat > "$path" <<EOF
# sb-v4-managed
[Unit]
Description=Cloudflare Tunnel managed by sb v4
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$CF_BIN tunnel --no-autoupdate --metrics 127.0.0.1:0 run --token-file $directory/token
Restart=on-failure
RestartSec=10
UMask=0077
NoNewPrivileges=true
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload || return 1 ;;
        openrc)
            cat > "$path" <<EOF
#!/sbin/openrc-run
# sb-v4-managed
command="$CF_BIN"
command_args="tunnel --no-autoupdate --metrics 127.0.0.1:0 run --token-file $directory/token"
supervisor="supervise-daemon"
respawn_delay=10
respawn_max=0
pidfile="/run/sb-argo-$id.pid"
output_log="/var/log/sb-argo-$id.log"
error_log="/var/log/sb-argo-$id.log"
depend() { need net; }
EOF
            chmod 755 "$path" || return 1 ;;
    esac
}
argo_remove() {
    local id="$1" path directory="$ARGO_DIR/$1"
    argo_owned "$id" || return 1
    path=$(argo_unit_path "$id") || return 1
    local entry active=0
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case "${entry##*/}" in token|tunnel.json) ;; *) error '隧道目录有其他文件，拒绝移除任何资源。'; return 1 ;; esac
    done
    argo_active "$id" && active=1
    # 留存不可重建的 Token 和服务定义，避免删除后无法恢复。
    [ -n "${LAST_TX:-}" ] || return 1
    cp -a "$directory" "$LAST_TX/tunnel-$id" && cp -p "$path" "$LAST_TX/unit-$id" || return 1
    argo_ctl "$id" stop || return 1
    if ! argo_disable "$id"; then
        [ "$active" = 0 ] || argo_ctl "$id" start
        return 1
    fi
    if rm -f "$path" "$directory/token" "$directory/tunnel.json" && rmdir "$directory"; then
        [ "$INIT_SYS" != systemd ] || systemctl daemon-reload
        return "$?"
    fi
    # 文件移除失败时恢复自己的文件，绝不递归删除目录中的未知内容。
    mkdir -p "$directory" && chmod 700 "$directory" &&
        install -m 600 "$LAST_TX/tunnel-$id/token" "$directory/token" &&
        install -m 600 "$LAST_TX/tunnel-$id/tunnel.json" "$directory/tunnel.json" &&
        cp -p "$LAST_TX/unit-$id" "$path" || { error '隧道文件恢复失败，请核对备份。'; return 1; }
    [ "$INIT_SYS" != systemd ] || systemctl daemon-reload
    argo_enable "$id" || true
    [ "$active" = 0 ] || argo_ctl "$id" start
    error '隧道移除失败，已尝试恢复原资源。'
}
argo_logs() {
    local id="$1"
    argo_owned "$id" || return 1
    case "$INIT_SYS" in systemd) journalctl -u "sb-argo-$id" -n 60 --no-pager ;; *) tail -n 60 "/var/log/sb-argo-$id.log" ;; esac
}

# 通过真实 sing-box 客户端走节点请求，不能拿 cloudflared 进程存活冒充链路成功。
probe_node() (
    local tag="$1" directory port outbound pid='' rc=1 kind meta node domain
    require_owned || return 1
    meta=$(node_state "$tag") || return 1
    kind=$(jq -r '.kind' <<< "$meta")
    node=$(jq -ec --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$CONFIG_FILE") || return 1
    port=$(free_port) || return 1
    directory=$(mktemp -d) || return 1
    trap '[ -z "$pid" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }; rm -rf "$directory"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$kind" = argo ]; then
        domain=$(jq -r '.domain' <<< "$meta")
        outbound=$(jq -n --arg server "$domain" --arg uuid "$(jq -r '.users[0].uuid' <<< "$node")" --arg path "$(jq -r '.transport.path' <<< "$node")" '
            {type:"vless",tag:"probe",server:$server,server_port:443,uuid:$uuid,
             tls:{enabled:true,server_name:$server},transport:{type:"ws",path:$path,headers:{Host:$server}}}')
    else
        local ip pub
        ip=$(get_public_ip) || { rm -rf "$directory"; return 1; }
        pub=$(jq -r '.public_key' <<< "$meta")
        outbound=$(jq --arg ip "$ip" --arg pub "$pub" '
            {type:.type,tag:"probe",server:$ip,server_port:.listen_port,tls:{enabled:true,server_name:.tls.server_name,
              utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$pub,short_id:.tls.reality.short_id[0]}}} +
            (if .type=="vless" then {uuid:.users[0].uuid,flow:"xtls-rprx-vision"} else {password:.users[0].password} end)' <<< "$node")
    fi
    jq -n --argjson p "$port" --argjson out "$outbound" '{log:{level:"error"},inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:$p}],outbounds:[$out]}' > "$directory/client.json"
    chmod 600 "$directory/client.json"
    if ! "$BIN_FILE" check -c "$directory/client.json" >/dev/null 2>&1; then rm -rf "$directory"; error '检测客户端配置不受当前核心支持。'; return 1; fi
    # 只终止自己刚创建的、尚未 wait 的子进程，绝不搜索或 kill 其他监听者。
    (exec 200>&-; exec "$BIN_FILE" run -c "$directory/client.json") > "$directory/client.log" 2>&1 &
    pid=$!
    local attempt
    for ((attempt=0; attempt<3; attempt++)); do
        sleep 2
        kill -0 "$pid" 2>/dev/null || break
        if curl -fsS --noproxy '' --proxy "socks5h://127.0.0.1:$port" --connect-timeout 8 --max-time 15 https://www.cloudflare.com/cdn-cgi/trace > "$directory/result" 2>/dev/null && grep -E '^ip=.+$' "$directory/result" >/dev/null; then rc=0; break; fi
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=''
    if [ "$rc" = 0 ]; then printf '完整代理链路验证通过。\n'
    else error '链路未通过：检查域名解析、Cloudflare 回源端口、WS 路径及隧道日志。'; fi
    return "$rc"
)

add_argo_node() {
    set +x
    prepare_core || return 1
    local port default path domain token id uuid name tag config state new=1 was_active=0 previous_tx
    default=$(free_port) || return 1
    port=$(read_valid_port "本机回源端口 [默认 $default]: " "$default") || return 1
    default="/$("$BIN_FILE" generate rand 8 --hex)" || return 1
    read -rp "WS 路径 [默认 $default]: " path || return 1
    path=${path:-$default}
    valid_ws_path "$path" || { error '路径必须以 / 开头，只能含字母、数字、/、_、-、.、~，最长 256 字符。'; return 1; }
    printf '\n请在 Cloudflare 创建固定隧道，并配置公开主机名：\n服务类型：HTTP\n服务地址：127.0.0.1:%s\n此处不附加 WS 路径。\n' "$port"
    read -rp '节点域名（不含 https://）: ' domain || return 1
    domain=${domain,,}
    valid_domain "$domain" || { error '域名格式无效。'; return 1; }
    if jq -e --arg d "$domain" '.nodes[] | select(.domain == $d)' "$STATE_FILE" >/dev/null; then error '该域名已有节点；不同回源端口请使用不同公开主机名。'; return 1; fi
    read -rsp 'Tunnel Token（隐藏输入，仅粘贴 Token 本身）: ' token || return 1
    printf '\n'
    id=$(token_tunnel_id "$token") && valid_tunnel_id "$id" || { unset token; error 'Tunnel Token 格式无效；不要粘贴整条安装命令或 API Token。'; return 1; }
    name=$(read_node_name) || { unset token; return 1; }
    printf '\n域名：%s:443\n本机回源：http://127.0.0.1:%s\nWS 路径：%s\n不开放公网回源端口；不改 Cloudflare 云端配置。\n' "$domain" "$port" "$path"
    confirm '安装 cloudflared（若缺少）、创建 / 复用固定隧道服务并设置自启' && acquire_lock || { unset token; return 1; }
    install_cloudflared || { unset token; return 1; }
    if argo_owned "$id"; then new=0; argo_active "$id" && was_active=1; fi
    uuid=$("$BIN_FILE" generate uuid) || { unset token; return 1; }
    if ! argo_create "$id" "$token"; then
        unset token
        if [ "$new" = 1 ] && argo_owned "$id"; then snapshot && argo_remove "$id"; fi
        return 1
    fi
    unset token
    tag="argo-$port"
    config=$(jq --arg t "$tag" --argjson p "$port" --arg u "$uuid" --arg path "$path" '.inbounds += [{type:"vless",tag:$t,listen:"127.0.0.1",listen_port:$p,users:[{uuid:$u}],transport:{type:"ws",path:$path}}]' "$CONFIG_FILE") || return 1
    state=$(jq --arg t "$tag" --arg n "${name:-$domain}" --arg d "$domain" --arg id "$id" '.nodes[$t]={kind:"argo",name:$n,domain:$d,tunnel_id:$id}' "$STATE_FILE") || return 1
    if apply_config "$config" "$state" "添加 Argo 节点 $domain，端口 $port，路径 $path"; then
        previous_tx="$LAST_TX"
        if argo_enable "$id" && argo_ctl "$id" start && probe_node "$tag"; then show_node "$tag"; return 0; fi
        printf 'Argo 验证失败，恢复本次新增前的节点配置。\n' >&2
        restore_snapshot "$previous_tx" && svc_restart || error "恢复失败，请核对备份：$previous_tx"
    fi
    # 取消或失败不得遗留本次新建的隧道服务；已有共享隧道保持原状态。
    if [ "$new" = 1 ]; then
        [ -n "${LAST_TX:-}" ] || snapshot || return 1
        argo_remove "$id" || error '新建隧道清理失败，请到隧道管理核对。'
    elif [ "$was_active" = 0 ]; then argo_ctl "$id" stop || true; fi
    return 1
}
