# ==================== 维护：只读检查和显式变更 ====================
check_all() {
    printf '\n核心：%s\n' "$(get_singbox_status)"
    require_owned || return 1
    "$BIN_FILE" check -c "$CONFIG_FILE" || return 1
    printf '\n本机监听：\n'
    ss -lntup
    local id
    while IFS= read -r id; do
        if argo_active "$id"; then printf '隧道 %s：进程运行中\n' "$id"; else printf '隧道 %s：已停止或缺少本机服务\n' "$id"; fi
    done < <(jq -r '[.nodes[] | .tunnel_id // empty] | unique[]' "$STATE_FILE")
    printf '\n配置检查完成；端到端连通性请在“我的节点 → 检查节点”中测试。未执行修复。\n'
}
show_full_config() { [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || error '还没有配置。'; }
show_service_status() { svc_status; }
view_logs() { svc_logs 100; }
service_action() {
    local action="$1"
    require_owned && service_owned || return 1
    confirm "对 sing-box 执行 $action；可能中断现有连接" && acquire_lock || return 1
    "$BIN_FILE" check -c "$CONFIG_FILE" || return 1
    svc_ctl "$action" || return 1
    sleep 1
    if [ "$action" = stop ]; then ! svc_active; else svc_active; fi
}
edit_config() {
    require_owned || return 1
    local directory editor config
    editor='vi'; command -v nano >/dev/null && editor='nano'
    directory=$(mktemp -d) || return 1
    cp "$CONFIG_FILE" "$directory/config.json" && chmod 600 "$directory/config.json" || { rm -rf "$directory"; return 1; }
    if "$editor" "$directory/config.json"; then
        config=$(cat "$directory/config.json")
        rm -rf "$directory"
        apply_config "$config" "$(cat "$STATE_FILE")" '应用手动编辑后的配置'
    else rm -rf "$directory"; return 1; fi
}
reset_config() {
    require_owned || return 1
    if jq -e '.nodes[] | select(.kind == "argo")' "$STATE_FILE" >/dev/null; then
        error '请先从“我的节点”逐项移除 Argo 节点，以免遗留隧道服务。'; return 1
    fi
    apply_config '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' '{"format":4,"nodes":{}}' '清空所有节点、端口转发、WARP 出口与分流（保留备份）'
}
rollback_config() {
    require_owned || return 1
    printf '可用配置备份：\n'
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'change-*' 2>/dev/null | sort
    local selected config state id
    read -rp '填写备份目录名（change-...，留空取消）: ' selected || return 1
    [[ "$selected" =~ ^change-[0-9-]+-[a-zA-Z0-9]+$ ]] || return 1
    [ -d "$BACKUP_DIR/$selected" ] && [ ! -L "$BACKUP_DIR/$selected" ] || return 1
    config=$(cat "$BACKUP_DIR/$selected/config.json") && state=$(cat "$BACKUP_DIR/$selected/state.json") || return 1
    local token token_path target="$BACKUP_DIR/$selected" previous previous_state created=() started=() failed=0
    # 先验证所需凭据，不能只恢复入站却留下缺失的隧道。
    while IFS= read -r id; do
        valid_tunnel_id "$id" || return 1
        if ! argo_owned "$id"; then
            token_path="$target/tunnels/$id/token"
            [ -f "$token_path" ] || token_path="$target/tunnel-$id/token"
            [ -f "$token_path" ] && [ "$(token_tunnel_id "$(cat "$token_path")")" = "$id" ] || {
                error "备份缺少可恢复的隧道凭据：$id"; return 1;
            }
            [ -x "$CF_BIN" ] || { error '恢复隧道前请先安装 cloudflared。'; return 1; }
        fi
    done < <(jq -r '[.nodes[] | .tunnel_id // empty] | unique[]' <<< "$state")
    previous_state=$(cat "$STATE_FILE")
    apply_config "$config" "$state" "回滚到 $selected；恢复所需本机隧道并停止无节点引用的隧道（保留其凭据）；不重置系统设置" || return 1
    previous="$LAST_TX"
    while IFS= read -r id; do
        if ! argo_owned "$id"; then
            token_path="$target/tunnels/$id/token"; [ -f "$token_path" ] || token_path="$target/tunnel-$id/token"
            token=$(cat "$token_path")
            if argo_create "$id" "$token"; then created+=("$id"); else failed=1; fi
            unset token
        fi
        if ! argo_active "$id"; then started+=("$id"); argo_enable "$id" && argo_ctl "$id" start || failed=1; fi
    done < <(jq -r '[.nodes[] | .tunnel_id // empty] | unique[]' <<< "$state")
    if [ "$failed" = 1 ]; then
        for id in "${started[@]}"; do argo_ctl "$id" stop || true; done
        for id in "${created[@]}"; do argo_remove "$id" || true; done
        restore_snapshot "$previous" && svc_restart || error "恢复失败，请核对 $previous"
        error '隧道恢复失败，本次配置回滚已撤销。'; return 1
    fi
    while IFS= read -r id; do
        if ! jq -e --arg id "$id" '.nodes[] | select(.tunnel_id == $id)' <<< "$state" >/dev/null; then
            argo_ctl "$id" stop || error "未能停止无节点引用的隧道：$id"
        fi
    done < <(jq -r '[.nodes[] | .tunnel_id // empty] | unique[]' <<< "$previous_state")
    printf '配置与本机隧道资源已恢复；云端配置未改变，请运行节点检查验证连接。\n'
}
uninstall_singbox() {
    require_owned && service_owned || return 1
    if jq -e '.nodes[] | select(.kind == "argo")' "$STATE_FILE" >/dev/null; then
        error '请先移除全部 Argo 节点，再卸载核心；不会隐式删除隧道。'; return 1
    fi
    confirm '卸载 v4 核心与服务；配置、元数据和备份保留，不修改 DNS / 防火墙 / Swap / 内核' && acquire_lock && snapshot || return 1
    svc_stop && svc_disable || return 1
    rm -f "$BIN_FILE" "$SERVICE_FILE" "$OPENRC_FILE" || return 1
    [ "$INIT_SYS" != systemd ] || systemctl daemon-reload
    printf '已卸载核心与服务。配置保留在 %s，备份保留在 %s。\n' "$CONFIG_DIR" "$BACKUP_DIR"
}

# 防火墙默认不变；只有用户主动选择才修改。识别真实 SSH 入口而不是假定 22。
ssh_ports() {
    local ports
    ports=$(ss -H -lntp | awk '/"sshd"/ {n=split($4,a,":");print a[n]}' | sort -nu) || return 1
    [ -n "$ports" ] || { error '无法确认正在监听的 SSH 端口，拒绝自动启用防火墙。'; return 1; }
    printf '%s\n' "$ports"
}
open_firewall_port() {
    local p="$1" protocol="${2:-tcp}"
    validate_port "$p" || return 1
    case "$protocol" in tcp|udp) ;; both) open_firewall_port "$p" tcp && open_firewall_port "$p" udp; return ;; *) return 1 ;; esac
    if command -v ufw >/dev/null; then ufw allow "$p/$protocol"
    elif command -v firewall-cmd >/dev/null && svc_active_name firewalld; then
        firewall-cmd --permanent --add-port="$p/$protocol" && firewall-cmd --reload
    else error '没有可管理的 ufw / firewalld；请在本机防火墙和云安全组手动放行。'; fi
}
offer_firewall_port() {
    local p="$1" protocol="${2:-tcp}"
    if confirm "是否放行本机防火墙端口 $p/$protocol（不会自动启用防火墙，也不能修改云安全组）"; then open_firewall_port "$p" "$protocol"; fi
}
menu_firewall() {
    if ! command -v ufw >/dev/null; then error '此交互菜单需要 ufw，不会自动安装或启用。'; return 1; fi
    local choice port ports p protocol
    while true; do
        menu_header '防火墙设置' '只修改明确选择的规则；云安全组需另行设置'
        ufw status verbose
        menu_section '端口与开关'
        menu_option 1 '开放端口'; menu_option 2 '删除端口规则'
        menu_option 3 '启用防火墙（先放行当前 SSH 端口）'; menu_option 4 '关闭防火墙'; menu_option 5 '重载规则'; menu_back
        read_menu_choice '请选择 [0-5]'; choice="$REPLY"
        case "$choice" in
            1|2)
                port=$(read_valid_port '端口: ' '' 0) || continue
                read -rp '协议 [tcp / udp / both，默认 tcp]: ' protocol || continue
                protocol=${protocol:-tcp}; case "$protocol" in tcp|udp|both) ;; *) continue ;; esac
                confirm "防火墙操作 $choice：$port/$protocol" && acquire_lock || continue
                if [ "$choice" = 1 ]; then open_firewall_port "$port" "$protocol"
                elif [ "$protocol" = both ]; then ufw delete allow "$port/tcp"; ufw delete allow "$port/udp"
                else ufw delete allow "$port/$protocol"; fi ;;
            3)
                ports=$(ssh_ports) || { pause; continue; }
                confirm "启用 ufw；将先放行 SSH 端口：$ports。请确保云侧入口可用" && acquire_lock || continue
                local ok=1
                while IFS= read -r p; do ufw allow "$p/tcp" || ok=0; done <<< "$ports"
                [ "$ok" = 0 ] || ufw --force enable ;;
            4) confirm '关闭 ufw 防火墙' && acquire_lock && ufw disable ;;
            5) confirm '重载 ufw 防火墙' && acquire_lock && ufw reload ;;
            0) return ;;
        esac
        pause
    done
}
set_dns() {
    local servers="$1" description="$2" directory server
    # 不擅自关闭 systemd-resolved、不 chattr 解锁，也不覆盖其符号链接。
    if [ -L /etc/resolv.conf ]; then error 'resolv.conf 由其他网络管理器维护，请在该管理器中配置 DNS。'; return 1; fi
    for server in $servers; do [[ "$server" =~ ^[0-9a-fA-F.:]+$ ]] || { error 'DNS 地址格式无效。'; return 1; }; done
    [ -n "$servers" ] || return 1
    confirm "修改系统 DNS 为 $description：$servers（可能影响网络解析）" && acquire_lock || return 1
    directory=$(mktemp -d "$BACKUP_DIR/dns-XXXXXX") || {
        mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" && directory=$(mktemp -d "$BACKUP_DIR/dns-XXXXXX") || return 1;
    }
    cp -p /etc/resolv.conf "$directory/resolv.conf" || return 1
    local tmp
    tmp=$(mktemp) || return 1
    for server in $servers; do printf 'nameserver %s\n' "$server"; done > "$tmp"
    if cat "$tmp" > /etc/resolv.conf; then printf 'DNS 已写入。原文件备份：%s/resolv.conf\n' "$directory"
    else error 'DNS 写入失败，正在恢复原内容。'; cat "$directory/resolv.conf" > /etc/resolv.conf; fi
    rm -f "$tmp"
}

# 手动编辑也必须保持节点与元数据一致，不允许把 Argo 回源暴露到公网。
validate_managed_config() {
    jq -en --argjson c "$1" --argjson s "$2" '
      ([$c.inbounds[].tag] | length == (unique | length)) and
      all($s.nodes | to_entries[]; . as $entry |
        [$c.inbounds[] | select(.tag == $entry.key)] as $matches |
        ($matches | length) == 1 and
        (if $entry.value.kind == "argo" then
          $matches[0].type == "vless" and $matches[0].listen == "127.0.0.1" and
          $matches[0].transport.type == "ws" and ($matches[0].tls.enabled? != true)
         else $matches[0].type == $entry.value.kind end))' >/dev/null
}
restore_dns() {
    [ ! -L /etc/resolv.conf ] || { error 'resolv.conf 由其他管理器维护，不直接覆盖。'; return 1; }
    find "$BACKUP_DIR" -maxdepth 2 -type f -path '*/dns-*/resolv.conf' 2>/dev/null
    local selected
    read -rp '填写 DNS 备份目录名（dns-...）: ' selected || return 1
    [[ "$selected" =~ ^dns-[a-zA-Z0-9]+$ ]] && [ -f "$BACKUP_DIR/$selected/resolv.conf" ] || return 1
    confirm "从 $selected 恢复系统 DNS" && acquire_lock || return 1
    local directory
    directory=$(mktemp -d "$BACKUP_DIR/dns-XXXXXX") && cp -p /etc/resolv.conf "$directory/resolv.conf" || return 1
    cat "$BACKUP_DIR/$selected/resolv.conf" > /etc/resolv.conf
}
backup_system_file() {
    local path="$1" directory
    [ -e "$path" ] || return 0
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || return 1
    directory=$(mktemp -d "$BACKUP_DIR/system-XXXXXX") || return 1
    cp -p "$path" "$directory/$(basename "$path")" || return 1
    printf '系统配置备份：%s\n' "$directory"
}
