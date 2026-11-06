# ==================== WARP 出口与分流 ====================
WARP_REG_AMD64='https://github.com/badafans/warp-reg/releases/download/v1.0/main-linux-amd64'
WARP_REG_ARM64='https://github.com/badafans/warp-reg/releases/download/v1.0/main-linux-arm64'
WARP_PEER_PUBKEY='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo='
GEOSITE_BASE='https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set'
has_warp_endpoint() { jq '[.endpoints[]? | select(.tag == "warp")] | length' "$CONFIG_FILE"; }
register_warp_account() {
    local directory url="$WARP_REG_AMD64" output pk v6 reserved
    [ "$(release_arch)" != arm64 ] || url="$WARP_REG_ARM64"
    directory=$(mktemp -d) || return 1
    if ! curl -fsSL --proto '=https' --max-time 90 "$url" -o "$directory/warp-reg" || ! chmod 755 "$directory/warp-reg"; then rm -rf "$directory"; return 1; fi
    output=$( (exec 200>&-; "$directory/warp-reg") 2>/dev/null)
    local rc=$?
    rm -rf "$directory"
    [ "$rc" = 0 ] || return 1
    pk=$(sed -n 's/^private_key:[[:space:]]*//p' <<< "$output")
    v6=$(sed -n 's/^v6:[[:space:]]*//p' <<< "$output")
    reserved=$(sed -n 's/^reserved:[[:space:]]*//p' <<< "$output" | tr -d ' ')
    [ -n "$pk" ] && [ -n "$v6" ] || return 1
    jq -cen --arg pk "$pk" --arg v6 "$v6" --argjson r "$reserved" 'select(($r | type)=="array" and ($r | length)==3) | {private_key:$pk,ipv6:$v6,reserved:$r}'
}
add_warp() {
    prepare_core || return 1
    confirm '下载并执行 warp-reg 注册 WARP 账号；已有 WARP 出口将被重置，原分流规则保留' && acquire_lock || return 1
    local meta config
    meta=$(register_warp_account) || { error 'WARP 注册失败，原配置未变。'; return 1; }
    config=$(jq --argjson m "$meta" --arg pub "$WARP_PEER_PUBKEY" '
        .endpoints = ((.endpoints // []) | map(select(.tag != "warp"))) + [{
          type:"wireguard",tag:"warp",mtu:1280,address:["172.16.0.2/32",($m.ipv6+"/128")],private_key:$m.private_key,
          peers:[{address:"162.159.192.1",port:2408,public_key:$pub,allowed_ips:["0.0.0.0/0","::/0"],reserved:$m.reserved}]}]' "$CONFIG_FILE") || return 1
    save_and_check_config "$config"
}
view_warp() {
    require_owned || return 1
    jq '.endpoints[]? | select(.tag == "warp") | {type,tag,address,mtu,peers:[.peers[] | {address,port}]}' "$CONFIG_FILE"
}
delete_warp() {
    require_owned || return 1
    local config
    config=$(jq '.endpoints = ((.endpoints // []) | map(select(.tag != "warp"))) | .route.rules |= map(select(.outbound? != "warp"))' "$CONFIG_FILE") || return 1
    apply_config "$config" "$(cat "$STATE_FILE")" '移除 WARP 出口和全部指向 WARP 的分流规则（保留其他规则和规则集）'
}
require_warp() {
    require_owned && [ "$(has_warp_endpoint)" -gt 0 ] || { error '请先添加 WARP 出口。'; return 1; }
}
add_warp_node_route() {
    require_warp || return 1
    local tag config
    tag=$(select_node) || return 1
    config=$(jq --arg t "$tag" '
        if any(.route.rules[]?; .outbound?=="warp" and .inbound?==[$t]) then error("该节点已配置 WARP")
        else .route.rules = ([{inbound:[$t],outbound:"warp"}] + .route.rules) end' "$CONFIG_FILE") || return 1
    save_and_check_config "$config"
}
add_warp_route() {
    require_warp || return 1
    local input domains config domain
    read -rp '填写域名后缀，多个用空格分隔: ' input || return 1
    [ -n "$input" ] || return 1
    for domain in $input; do valid_domain "$domain" || { error '包含无效域名。'; return 1; }; done
    domains=$(printf '%s' "$input" | jq -Rc 'split(" ") | map(select(length>0)) | unique')
    config=$(jq --argjson d "$domains" 'if any(.route.rules[]?; .outbound?=="warp" and .domain_suffix?==$d) then error("该分流已存在") else .route.rules = ([{domain_suffix:$d,outbound:"warp"}] + .route.rules) end' "$CONFIG_FILE") || return 1
    save_and_check_config "$config"
}
add_warp_sites() {
    require_warp || return 1
    local sites="$1" config site entry definitions='[]' rule_tags='[]' tag
    for site in $sites; do
        tag="geosite-$site"
        entry=$(jq -n --arg t "$tag" --arg u "$GEOSITE_BASE/$site.srs" '{type:"remote",tag:$t,format:"binary",url:$u,download_detour:"direct"}')
        definitions=$(jq --argjson e "$entry" '.+[$e]' <<< "$definitions")
        rule_tags=$(jq --arg t "$tag" '.+[$t]' <<< "$rule_tags")
    done
    config=$(jq --argjson defs "$definitions" --argjson tags "$rule_tags" '
        if any(.route.rules[]?; .outbound?=="warp" and .rule_set?==$tags) then error("该分流已存在") else
        .route.rule_set = ((.route.rule_set // []) as $existing | $existing + [$defs[] | select(.tag as $t | all($existing[]; .tag != $t))]) |
        .route.rules = ([{rule_set:$tags,outbound:"warp"}] + .route.rules) end' "$CONFIG_FILE") || return 1
    save_and_check_config "$config"
}
add_warp_ai() { add_warp_sites 'category-ai-!cn openai anthropic'; }
add_warp_media() { add_warp_sites 'netflix disney hbo youtube primevideo tiktok spotify hulu'; }
view_warp_rules() {
    require_owned || return 1
    jq -r '.route.rules | to_entries[] | select(.value.outbound? == "warp") | "[\(.key)] \(.value | tojson)"' "$CONFIG_FILE"
}
delete_warp_rule() {
    require_warp || return 1
    view_warp_rules
    local index config
    read -rp '填写方括号内的规则编号 [留空取消]: ' index || return 1
    [[ "$index" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    jq -e --argjson i "$index" '.route.rules[$i].outbound == "warp"' "$CONFIG_FILE" >/dev/null || return 1
    config=$(jq --argjson i "$index" 'del(.route.rules[$i])' "$CONFIG_FILE") || return 1
    save_and_check_config "$config"
}
menu_warp() {
    local choice
    while true; do
        menu_header 'WARP 出口与分流' '出口与入站独立；Reality 和 Argo 节点均可分流'
        menu_option 1 '添加 / 重置 WARP'; menu_option 2 '查看出口信息'; menu_option 3 '移除出口及相关规则'
        menu_option 4 'AI 服务走 WARP'; menu_option 5 '流媒体走 WARP'; menu_option 6 '自定义域名走 WARP'
        menu_option 7 '指定节点全部走 WARP'; menu_option 8 '查看分流规则'; menu_option 9 '删除指定规则'; menu_back
        read_menu_choice; choice="$REPLY"
        case "$choice" in
            1) add_warp ;; 2) view_warp ;; 3) delete_warp ;; 4) add_warp_ai ;; 5) add_warp_media ;;
            6) add_warp_route ;; 7) add_warp_node_route ;; 8) view_warp_rules ;; 9) delete_warp_rule ;; 0) return ;;
        esac
        pause
    done
}
