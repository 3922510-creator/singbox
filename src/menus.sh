# ==================== 交互层（最多二级菜单，小白优先） ====================
node_summary_lines() {
    command -v jq >/dev/null && jq -e '.format==4' "$STATE_FILE" >/dev/null 2>&1 || return 1
    local t count=0 meta kind port extra
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        count=$((count + 1))
        meta=$(node_state "$t" 2>/dev/null) || continue
        kind=$(jq -r '.kind' <<< "$meta")
        port=$(jq -r --arg t "$t" '.inbounds[] | select(.tag == $t) | .listen_port' "$CONFIG_FILE" 2>/dev/null)
        case "$kind" in
            argo) extra="Argo  $(jq -r '.domain' <<< "$meta"):443 -> 127.0.0.1:$port" ;;
            anytls) extra="AnyTLS-Reality  端口 $port" ;;
            *) extra="VLESS-Reality   端口 $port" ;;
        esac
        printf '    %b%d.%b %s  %b(%s)%b\n' "$GREEN" "$count" "$PLAIN" "$(node_display_name "$t")" "$DIM" "$extra" "$PLAIN"
    done < <(node_tags 2>/dev/null)
    [ "$count" -gt 0 ]
}
menu_add() {
    local choice
    while true; do
        menu_header '添加节点' '自动准备核心与服务；直连节点无需域名' "$(get_singbox_status)"
        menu_section '选择节点类型'
        menu_option 1 'VLESS Reality（推荐 · 免域名直连）'
        menu_option 2 'AnyTLS Reality（免域名直连）'
        menu_option 3 'Argo 固定隧道（VLESS + WS + TLS · 需域名与 Token）'
        menu_back
        read_menu_choice '请选择 [0-3]'; choice="$REPLY"
        case "$choice" in
            1) add_reality_node ;; 2) add_anytls_node ;; 3) add_argo_node ;;
            0) return ;; *) error '请输入 0-3 之间的数字。' ;;
        esac
        pause
    done
}
menu_nodes() {
    require_owned || return 1
    local choice tag
    while true; do
        menu_header '我的节点' '查看分享链接、二维码、测活、改备注与删除' "$(get_singbox_status)"
        menu_section '当前节点'
        node_summary_lines || printf '    %b还没有节点，请返回首页选 1 添加。%b\n' "$YELLOW" "$PLAIN"
        menu_section '节点操作'
        menu_option 1 '查看全部节点链接 / 二维码'
        menu_option 2 '查看单个节点详情 / 二维码'
        menu_option 3 '测试节点连通性（真实验证）'
        menu_option 4 '修改节点备注（无需重启）'
        menu_option 5 '删除节点'
        menu_option 6 '安装二维码显示工具（可选）'
        menu_back
        read_menu_choice '请选择 [0-6]'; choice="$REPLY"
        case "$choice" in
            1) view_node_links ;;
            2) tag=$(select_node) && show_node "$tag" ;;
            3) tag=$(select_node) && probe_node "$tag" ;;
            4) rename_node ;;
            5) delete_node ;;
            6) install_qrencode ;;
            0) return ;;
            *) error '请输入 0-6 之间的数字。' ;;
        esac
        pause
    done
}
menu_node() {
    local tag="$1" choice
    while jq -e --arg t "$tag" '.nodes | has($t)' "$STATE_FILE" >/dev/null; do
        menu_header "节点：$(node_display_name "$tag")"
        menu_option 1 '查看参数 / 链接 / 二维码'; menu_option 2 '修改备注（无需重启）'
        menu_option 3 '检查完整代理链路'; menu_option 4 '删除节点'; menu_back
        read_menu_choice '请选择 [0-4]'; choice="$REPLY"
        case "$choice" in 1) show_node "$tag" ;; 2) rename_node "$tag" ;; 3) probe_node "$tag" ;; 4) delete_node "$tag" ;; 0) return ;; esac
        pause
    done
}
menu_forward() {
    local choice
    while true; do
        menu_header 'TCP / UDP 端口转发' '监听本机端口并转发到目标地址'
        menu_section '当前转发规则'
        if command -v jq >/dev/null && [ -f "$CONFIG_FILE" ] && [ "$(count_by_type direct)" -gt 0 ]; then
            view_port_forwards | sed 's/^/    /'
        else
            printf '    %b暂无端口转发规则%b\n' "$DIM" "$PLAIN"
        fi
        menu_section '转发操作'
        menu_option 1 '添加端口转发'; menu_option 2 '查看转发规则'; menu_option 3 '删除转发规则'; menu_back
        read_menu_choice '请选择 [0-3]'; choice="$REPLY"
        case "$choice" in 1) add_port_forward ;; 2) view_port_forwards ;; 3) delete_port_forward ;; 0) return ;; *) error '请输入 0-3 之间的数字。' ;; esac
        pause
    done
}
menu_network() {
    while true; do
        menu_header '转发与分流' '端口转发与 Cloudflare WARP 分流'
        menu_option 1 'TCP / UDP 端口转发'; menu_option 2 'WARP 出口与分流'; menu_back
        read_menu_choice '请选择 [0-2]'
        case "$REPLY" in 1) menu_forward ;; 2) menu_warp ;; 0) return ;; esac
    done
}
diagnose_config() {
    local choice
    while true; do
        menu_header '配置维护与备份回滚' '每次变更自动备份；语法错误不会自动清空配置'
        menu_section '查看与校验'
        menu_option 1 '查看原始配置 JSON（含私密信息）'
        menu_option 2 '查看节点元数据（不含 Tunnel Token）'
        menu_option 6 '校验当前配置文件'
        menu_section '修改与恢复'
        menu_option 3 '手动编辑配置并校验应用'
        menu_option 5 '从历史备份回滚配置'
        menu_option 4 '清空全部节点与规则（保留备份）'
        menu_back
        read_menu_choice '请选择 [0-6]'; choice="$REPLY"
        case "$choice" in
            1) show_full_config ;; 2) cat "$STATE_FILE" ;; 3) edit_config ;; 4) reset_config ;; 5) rollback_config ;;
            6) require_owned && "$BIN_FILE" check -c "$CONFIG_FILE" && printf '配置校验通过。\n' ;; 0) return ;;
            *) error '请输入 0-6 之间的数字。' ;;
        esac
        pause
    done
}
menu_argo() {
    require_owned || return 1
    local id action refs found
    while true; do
        menu_header 'Argo 固定隧道管理' '云端 Tunnel 和 DNS 由用户管理'
        menu_section '本机隧道实例'
        found=0
        local directory
        for directory in "$ARGO_DIR"/*; do
            [ -d "$directory" ] || continue
            id=${directory##*/}
            valid_tunnel_id "$id" || continue
            found=1
            if argo_active "$id"; then printf '    %s  %b[运行中]%b\n' "$id" "$GREEN" "$PLAIN"
            else printf '    %s  %b[已停止]%b\n' "$id" "$RED" "$PLAIN"; fi
        done
        [ "$found" = 1 ] || printf '    %b暂无本机隧道实例%b\n' "$DIM" "$PLAIN"
        printf '\n'
        read -rp '  填写隧道 ID 管理（直接回车返回）: ' id || return
        [ -n "$id" ] || return
        argo_owned "$id" || { error '未找到本面板管理的隧道。'; pause; continue; }
        menu_section "操作隧道 $id"
        menu_option 1 '查看隧道日志'; menu_option 2 '启动隧道'; menu_option 3 '停止隧道'; menu_option 4 '重启隧道'
        menu_option 5 '移除无节点引用的本机隧道'; menu_back
        read_menu_choice '请选择 [0-5]'; action="$REPLY"
        case "$action" in
            1) argo_logs "$id" ;;
            2|3|4)
                case "$action" in 2) action=start ;; 3) action=stop ;; 4) action=restart ;; esac
                confirm "对隧道 $id 执行 $action；会影响使用该隧道的节点" && acquire_lock && argo_ctl "$id" "$action" ;;
            5)
                refs=$(jq --arg id "$id" '[.nodes[] | select(.tunnel_id == $id)] | length' "$STATE_FILE")
                if [ "$refs" != 0 ]; then error '仍有关联节点，请先从“我的节点”删除。'
                else confirm "移除本机隧道 $id 的服务与 Token，保留云端资源" && acquire_lock && snapshot && argo_remove "$id"; fi ;;
        esac
        pause
    done
}
menu_system() {
    local choice
    while true; do
        menu_header '运行状态与核心维护' '查看状态、日志、启停服务、回滚配置与卸载' "$(get_singbox_status)"
        menu_section '体检与日志（只读，不改配置）'
        menu_option 1 '一键全面检查（核心 + 配置 + 监听端口 + 隧道）'
        menu_option 2 '查看 sing-box 状态与最近日志'
        menu_option 3 'Argo 隧道状态与日志'
        menu_section '服务控制'
        menu_option 4 '重启 sing-box 服务'
        menu_option 5 '启动 sing-box 服务'
        menu_option 6 '停止 sing-box 服务'
        menu_option 7 '安装 / 更新 sing-box 核心'
        menu_section '配置与清理'
        menu_option 8 '从历史备份回滚配置'
        menu_option 9 '高级配置维护（查看 / 编辑 / 清空）'
        menu_option 10 '卸载 v4 核心与服务（保留配置和备份）'
        menu_option 11 '彻底清理旧版 v3 并重新搭建（旧节点失效）'
        menu_back
        read_menu_choice '请选择 [0-11]'; choice="$REPLY"
        case "$choice" in
            1) check_all ;; 2) svc_status; svc_logs ;; 3) menu_argo ;;
            4) service_action restart ;; 5) service_action start ;; 6) service_action stop ;;
            7) install_singbox ;; 8) rollback_config ;; 9) diagnose_config ;;
            10) uninstall_singbox ;; 11) legacy_reinstall ;; 0) return ;;
            *) error '请输入 0-11 之间的数字。' ;;
        esac
        pause
    done
}
menu_diagnostics() { menu_system; }
menu_advanced() { menu_tools; }
install_qrencode() {
    command -v qrencode >/dev/null && { printf '二维码工具 qrencode 已安装。\n'; return 0; }
    confirm '安装可选二维码工具 qrencode' && acquire_lock || return 1
    case "$OS_FAMILY" in
        debian) apt-get install -y qrencode ;; redhat) yum install -y qrencode ;;
        alpine) apk add --no-cache libqrencode-tools ;; *) error '请手动安装 qrencode。' ;;
    esac
}
show_dashboard() {
    if command -v jq >/dev/null && jq -e '.format==4' "$STATE_FILE" >/dev/null 2>&1; then
        local direct argo fwd warp warp_text
        direct=$(jq '[.nodes[] | select(.kind != "argo")] | length' "$STATE_FILE")
        argo=$(jq '[.nodes[] | select(.kind == "argo")] | length' "$STATE_FILE")
        fwd=$(count_by_type direct)
        warp=$(has_warp_endpoint)
        if [ "$warp" -gt 0 ]; then warp_text="${GREEN}已开启${PLAIN}"; else warp_text="${DIM}未开启${PLAIN}"; fi
        printf '  %b概览%b  直连 %b%s%b 个 · Argo %b%s%b 个 · 转发 %b%s%b 条 · WARP %b\n' \
            "$DIM" "$PLAIN" "$BOLD" "$direct" "$PLAIN" "$BOLD" "$argo" "$PLAIN" "$BOLD" "$fwd" "$PLAIN" "$warp_text"
        ui_rule
    elif [ -e "$CONFIG_DIR" ] && [ ! -f "$STATE_FILE" ]; then
        printf '  %b提示%b  %b检测到旧版或残留配置；首次使用 v4 请选 9 清理旧版并重新搭建%b\n' "$YELLOW" "$PLAIN" "$YELLOW" "$PLAIN"
        ui_rule
    else
        printf '  %b新手提示%b  直接选 %b1%b 添加节点，脚本会自动安装核心并生成分享链接\n' "$BLUE" "$PLAIN" "$GREEN" "$PLAIN"
        ui_rule
    fi
}
show_menu() {
    menu_header 'Sing-box 管理面板' "极简搭建 · Reality / Argo 固定隧道 / WARP 分流 · ${SCRIPT_VERSION}" "$(get_singbox_status)"
    show_dashboard
    menu_section '常用操作（新手从这里开始）'
    menu_option 1 '快速搭建 / 添加节点（自动装核心）'
    menu_option 2 '我的节点（链接 / 二维码 / 测活 / 改名 / 删除）'
    menu_option 3 '查看全部节点链接与二维码'
    menu_section '进阶功能'
    menu_option 4 'WARP 出口与分流（解锁 AI / 流媒体 / 换出口 IP）'
    menu_option 5 'TCP / UDP 端口转发'
    menu_option 6 'BBR 网络加速 / 流媒体检测 / DNS / Swap / 防火墙'
    menu_section '状态与维护'
    menu_option 7 '运行状态 / 日志 / 重启 / 配置回滚 / 更新核心'
    menu_option 8 '安装 / 更新 sing-box 核心'
    menu_option 9 '清理旧版 v3 并重新搭建（旧节点失效）'
    menu_exit
    read_menu_choice '请选择 [0-9]'
    case "$REPLY" in
        1) menu_add ;;
        2) menu_nodes ;;
        3) view_node_links; pause ;;
        4) menu_warp ;;
        5) menu_forward ;;
        6) menu_tools ;;
        7) menu_system ;;
        8) install_singbox; pause ;;
        9) legacy_reinstall; pause ;;
        0) return 10 ;;
        *) error '请输入 0-9 之间的数字。'; sleep 1 ;;
    esac
    return 0
}
main() {
    set +x
    umask 077
    [ "$EUID" = 0 ] || { error '请使用 root 运行。'; return 1; }
    platform_detect
    if [ ! -t 0 ] && [ -r /dev/tty ]; then exec < /dev/tty; fi
    while true; do
        show_menu
        [ "$?" != 10 ] || break
    done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
