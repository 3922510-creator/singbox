# ==================== 节点：统一列表和元数据 ====================
node_display_name() { jq -jr --arg t "$1" '.nodes[$t].name // $t' "$STATE_FILE"; }
read_node_name() {
    local name
    read -rp '节点备注（留空自动命名）: ' name || return 1
    [ "${#name}" -le 80 ] && [[ ! "$name" =~ [[:cntrl:]] ]] || { error '备注最多 80 字且不能含控制字符。'; return 1; }
    printf '%s' "$name"
}
node_link_fragment() { node_display_name "$1" | jq -sRr '@uri'; }
node_state() { jq -ec --arg t "$1" '.nodes[$t]' "$STATE_FILE"; }
node_tags() { jq -r '.inbounds[] | select(.type == "vless" or .type == "anytls") | .tag' "$CONFIG_FILE"; }
select_node() {
    require_owned || return 1
    local tags=() t n=0 selected
    while IFS= read -r t; do
        tags+=("$t"); n=$((n+1)); printf '  %s. %s [%s]\n' "$n" "$(node_display_name "$t")" "$t" >&2
    done < <(node_tags)
    [ "$n" -gt 0 ] || { error '还没有节点，请先添加。'; return 1; }
    read -rp '选择节点 [0 返回]: ' selected || return 1
    [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "$n" ] || return 1
    printf '%s' "${tags[$((selected-1))]}"
}
node_link() {
    local t="$1" node meta type port server uuid sni sid pub path
    node=$(jq -ec --arg t "$t" '.inbounds[] | select(.tag == $t)' "$CONFIG_FILE") || return 1
    meta=$(node_state "$t") || { error "节点 $t 没有关联元数据，不能生成链接。"; return 1; }
    type=$(jq -r '.kind' <<< "$meta")
    port=$(jq -r '.listen_port' <<< "$node")
    if [ "$type" = argo ]; then
        server=$(jq -r '.domain' <<< "$meta")
        uuid=$(jq -r '.users[0].uuid' <<< "$node")
        path=$(jq -r '.transport.path | @uri' <<< "$node")
        printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' "$uuid" "$server" "$server" "$server" "$path" "$(node_link_fragment "$t")"
        return
    fi
    server=$(get_public_ip) || { error '无法获取公网 IP。'; return 1; }
    [[ "$server" != *:* ]] || server="[$server]"
    sni=$(jq -r '.tls.server_name | @uri' <<< "$node")
    sid=$(jq -r '.tls.reality.short_id[0]' <<< "$node")
    pub=$(jq -r '.public_key' <<< "$meta")
    if [ "$type" = vless ]; then
        uuid=$(jq -r '.users[0].uuid' <<< "$node")
        printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' "$uuid" "$server" "$port" "$sni" "$pub" "$sid" "$(node_link_fragment "$t")"
    elif [ "$type" = anytls ]; then
        uuid=$(jq -r '.users[0].password' <<< "$node")
        printf 'anytls://%s@%s:%s/?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s#%s' "$uuid" "$server" "$port" "$sni" "$pub" "$sid" "$(node_link_fragment "$t")"
    else error '未知节点类型。'; fi
}
show_node() {
    local t="$1" link
    printf '\n节点：%s\n' "$(node_display_name "$t")"
    jq --arg t "$t" '.inbounds[] | select(.tag == $t) | {type,listen,listen_port,transport}' "$CONFIG_FILE"
    if [ "$(node_state "$t" | jq -r '.kind')" = argo ]; then
        local id
        id=$(node_state "$t" | jq -r '.tunnel_id')
        printf '域名：%s\n' "$(node_state "$t" | jq -r '.domain')"
        if argo_active "$id"; then printf '隧道进程：运行中（端到端连接请运行节点检查）\n'; else printf '隧道进程：已停止\n'; fi
    fi
    link=$(node_link "$t") || return 1
    printf '分享链接：\n%s\n' "$link"
    if command -v qrencode >/dev/null; then qrencode -t ANSIUTF8 "$link"; else printf '未安装 qrencode，已提供链接。\n'; fi
}
view_node_links() {
    require_owned || return 1
    local t found=0
    while IFS= read -r t; do found=1; show_node "$t"; done < <(node_tags)
    [ "$found" = 1 ] || printf '还没有节点。\n'
}
rename_node() {
    local t="${1:-}" name state
    [ -n "$t" ] || t=$(select_node) || return 1
    name=$(read_node_name) || return 1
    name=${name:-$t}
    confirm "将节点备注改为：$name（无需重启）" && acquire_lock || return 1
    state=$(jq --arg t "$t" --arg n "$name" '.nodes[$t].name=$n' "$STATE_FILE") || return 1
    snapshot && write_json "$STATE_FILE" "$state"
}

add_direct_node() {
    local type="$1" port sni name keys pk pub secret sid tag config state
    prepare_core || return 1
    if [ "$type" = anytls ] && ! singbox_version_ge 1.12.0; then error 'AnyTLS 需要核心 >= 1.12.0。'; return 1; fi
    port=$(read_valid_port '公网监听端口 [默认 443]: ' 443) || return 1
    read -rp '伪装域名 SNI [默认 yahoo.com]: ' sni || return 1
    sni=${sni:-yahoo.com}
    valid_domain "$sni" || { error 'SNI 必须是有效域名。'; return 1; }
    name=$(read_node_name) || return 1
    keys=$("$BIN_FILE" generate reality-keypair) || return 1
    pk=$(awk '/PrivateKey:/ {gsub(/"/,"",$2);print $2}' <<< "$keys")
    pub=$(awk '/PublicKey:/ {gsub(/"/,"",$2);print $2}' <<< "$keys")
    [ -n "$pk" ] && [ -n "$pub" ] || { error '生成 Reality 密钥失败。'; return 1; }
    sid=$("$BIN_FILE" generate rand 8 --hex) || return 1
    if [ "$type" = vless ]; then secret=$("$BIN_FILE" generate uuid); else secret=$("$BIN_FILE" generate rand 16 --hex); fi
    [ -n "$secret" ] || return 1
    tag="$type-reality-$port"
    config=$(jq --arg type "$type" --arg t "$tag" --argjson p "$port" --arg secret "$secret" --arg pk "$pk" --arg sni "$sni" --arg sid "$sid" '
        .inbounds += [{type:$type,tag:$t,listen:"::",listen_port:$p,
          users:[(if $type == "vless" then {uuid:$secret,flow:"xtls-rprx-vision"} else {password:$secret} end)],
          tls:{enabled:true,server_name:$sni,reality:{enabled:true,private_key:$pk,short_id:[$sid],handshake:{server:$sni,server_port:443}}}}]' "$CONFIG_FILE") || return 1
    state=$(jq --arg t "$tag" --arg k "$type" --arg name "${name:-$tag}" --arg pub "$pub" '.nodes[$t]={kind:$k,name:$name,public_key:$pub}' "$STATE_FILE") || return 1
    apply_config "$config" "$state" "添加 $type Reality 节点，公网端口 $port" || return 1
    printf '节点配置已应用；请确保云安全组与本机防火墙允许 TCP %s。\n' "$port"
    offer_firewall_port "$port"
    [ "$type" != anytls ] || printf 'AnyTLS + Reality 需要支持此组合的客户端；mihomo 不支持该组合。\n'
    show_node "$tag"
}
add_reality_node() { add_direct_node vless; }
add_anytls_node() { add_direct_node anytls; }

# 删除节点时只从规则的 inbound 数组中移除该 tag，不误删共享规则。
config_without_inbound() {
    jq --arg t "$1" '
      .inbounds |= map(select(.tag != $t)) |
      .route.rules |= map(if (.inbound? | type) == "array" then .inbound -= [$t] else . end) |
      .route.rules |= map(select((has("inbound") | not) or .inbound != []))' "$CONFIG_FILE"
}
delete_node() {
    require_owned || return 1
    local t="${1:-}" config state kind id refs
    [ -n "$t" ] || t=$(select_node) || return 1
    jq -e --arg t "$t" '.nodes | has($t)' "$STATE_FILE" >/dev/null || return 1
    kind=$(node_state "$t" | jq -r '.kind')
    id=$(node_state "$t" | jq -r '.tunnel_id // empty')
    config=$(config_without_inbound "$t") || return 1
    state=$(jq --arg t "$t" 'del(.nodes[$t])' "$STATE_FILE") || return 1
    if [ "$kind" = argo ]; then
        refs=$(jq --arg id "$id" '[.nodes[] | select(.tunnel_id == $id)] | length' <<< "$state")
        if [ "$refs" = 0 ]; then
            printf '这是该隧道最后一个节点；将同时停止并移除本机隧道服务和 Token。云端 Tunnel / DNS 不会删除。\n'
        fi
    fi
    apply_config "$config" "$state" "删除节点 $(node_display_name "$t") 及其专属分流关联" || return 1
    if [ "$kind" = argo ] && [ "$refs" = 0 ]; then
        if ! argo_remove "$id"; then
            restore_snapshot "$LAST_TX" && svc_restart
            error '隧道移除失败，节点配置已尝试恢复；请检查服务状态。'; return 1
        fi
    fi
    printf '节点已删除。\n'
}

add_port_forward() {
    prepare_core || return 1
    local lp host rp tag config
    lp=$(read_valid_port '本机监听端口: ' '') || return 1
    read -rp '目标 IP / 域名: ' host || return 1
    [[ "$host" =~ ^[a-zA-Z0-9.:_-]+$ ]] || { error '目标地址格式无效。'; return 1; }
    rp=$(read_valid_port '目标端口: ' '' 0) || return 1
    tag="forward-$lp"
    config=$(jq --arg t "$tag" --argjson lp "$lp" --arg h "$host" --argjson rp "$rp" '
        .inbounds += [{type:"direct",tag:$t,listen:"::",listen_port:$lp,override_address:$h,override_port:$rp}] |
        .route.rules = ([{inbound:[$t],outbound:"direct"}] + .route.rules)' "$CONFIG_FILE") || return 1
    apply_config "$config" "$(cat "$STATE_FILE")" "添加 TCP/UDP 转发 $lp → $host:$rp" || return 1
    offer_firewall_port "$lp" both
}
view_port_forwards() {
    require_owned || return 1
    jq -r '.inbounds[] | select(.type == "direct") | "\(.tag)  :\(.listen_port) → \(.override_address):\(.override_port)"' "$CONFIG_FILE"
}
delete_port_forward() {
    require_owned || return 1
    view_port_forwards
    local tag config
    read -rp '填写要删除的转发标识 [留空取消]: ' tag || return 1
    jq -e --arg t "$tag" '.inbounds[] | select(.tag == $t and .type == "direct")' "$CONFIG_FILE" >/dev/null || return 1
    config=$(config_without_inbound "$tag") || return 1
    apply_config "$config" "$(cat "$STATE_FILE")" "删除转发 $tag"
}
