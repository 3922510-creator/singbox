# ==================== 交互层 ====================
menu_add() {
    local choice
    while true; do
        menu_header '搭建 / 添加节点' '端口可自定义；Argo 还需填写路径、域名、Tunnel Token'
        menu_option 1 'VLESS Reality（推荐，无需域名）'
        menu_option 2 'AnyTLS Reality'
        menu_option 3 'Argo 隧道节点（VLESS + WS + TLS）'; menu_back
        read_menu_choice; choice="$REPLY"
        case "$choice" in 1) add_reality_node ;; 2) add_anytls_node ;; 3) add_argo_node ;; 0) return ;; esac
        pause
    done
}
menu_nodes() {
    require_owned || return 1
    local choice tag
    while true; do
        menu_header '我的节点' '查看、重命名、检查和删除'
        menu_option 1 '选择一个节点'; menu_option 2 '查看全部链接 / 二维码'; menu_back
        read_menu_choice; choice="$REPLY"
        case "$choice" in
            1) tag=$(select_node) || continue; menu_node "$tag" ;;
            2) view_node_links; pause ;;
            0) return ;;
        esac
    done
}
menu_node() {
    local tag="$1" choice
    while jq -e --arg t "$tag" '.nodes | has($t)' "$STATE_FILE" >/dev/null; do
        menu_header "节点：$(node_display_name "$tag")"
        menu_option 1 '查看参数 / 链接 / 二维码'; menu_option 2 '修改备注（无需重启）'
        menu_option 3 '检查完整代理链路'; menu_option 4 '删除节点'; menu_back
        read_menu_choice; choice="$REPLY"
        case "$choice" in 1) show_node "$tag" ;; 2) rename_node "$tag" ;; 3) probe_node "$tag" ;; 4) delete_node "$tag" ;; 0) return ;; esac
        pause
    done
}
menu_forward() {
    local choice
    while true; do
        menu_header 'TCP / UDP 端口转发'
        menu_option 1 '添加转发'; menu_option 2 '查看转发'; menu_option 3 '删除转发'; menu_back
        read_menu_choice; choice="$REPLY"
        case "$choice" in 1) add_port_forward ;; 2) view_port_forwards ;; 3) delete_port_forward ;; 0) return ;; esac
        pause
    done
}
menu_network() {
    while true; do
        menu_header '转发与分流'
        menu_option 1 'TCP / UDP 端口转发'; menu_option 2 'WARP 出口与分流'; menu_back
        read_menu_choice
        case "$REPLY" in 1) menu_forward ;; 2) menu_warp ;; 0) return ;; esac
    done
}
diagnose_config() {
    local choice
    while true; do
        menu_header '配置维护' '配置和元数据一起备份；不会因语法错误自动清空'
        menu_option 1 '查看原始配置（含私密信息）'; menu_option 2 '查看节点元数据（不含 Tunnel Token）'
        menu_option 3 '编辑副本并校验应用'; menu_option 4 '重置为空配置'; menu_option 5 '从备份回滚'
        menu_option 6 '只校验当前配置'; menu_back
        read_menu_choice; choice="$REPLY"
        case "$choice" in
            1) show_full_config ;; 2) cat "$STATE_FILE" ;; 3) edit_config ;; 4) reset_config ;; 5) rollback_config ;;
            6) require_owned && "$BIN_FILE" check -c "$CONFIG_FILE" ;; 0) return ;;
        esac
        pause
    done
}
menu_argo() {
    require_owned || return 1
    local id action refs
    while true; do
        menu_header '本机固定隧道管理' '云端 Tunnel 和 DNS 由用户管理'
        local directory
        for directory in "$ARGO_DIR"/*; do
            [ -d "$directory" ] || continue
            id=${directory##*/}
            valid_tunnel_id "$id" || continue
            if argo_active "$id"; then printf '%s：运行中\n' "$id"; else printf '%s：已停止或资源异常\n' "$id"; fi
        done
        read -rp '填写隧道 ID（留空返回）: ' id || return
        [ -n "$id" ] || return
        argo_owned "$id" || { error '未找到本面板管理的隧道。'; pause; continue; }
        menu_option 1 '查看日志'; menu_option 2 '启动'; menu_option 3 '停止'; menu_option 4 '重启'
        menu_option 5 '移除无节点引用的本机隧道'; menu_back
        read_menu_choice; action="$REPLY"
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
menu_diagnostics() {
    local choice
    while true; do
        menu_header '检查与维护' '检查默认只读；不自动重置、不静默修复'
        menu_option 1 '一键检查'; menu_option 2 'sing-box 状态与日志'; menu_option 3 'Argo 状态 / 日志 / 服务'
        menu_option 4 '配置查看 / 编辑 / 校验 / 回滚'; menu_option 5 '流媒体解锁（快速）'
        menu_option 6 '流媒体解锁（完整社区脚本）'; menu_option 7 '回程路由测试'; menu_back
        read_menu_choice; choice="$REPLY"
        case "$choice" in
            1) check_all ;; 2) svc_status; svc_logs ;; 3) menu_argo ;; 4) diagnose_config ;;
            5) media_check_quick ;; 6) media_check_full ;; 7) besttrace_check ;; 0) return ;;
        esac
        pause
    done
}
menu_system() {
    local choice
    while true; do
        menu_header '核心与服务' '新版不迁移旧版、不接管未知服务'
        menu_option 1 '安装 / 更新核心'; menu_option 2 '启动 sing-box'; menu_option 3 '停止 sing-box'
        menu_option 4 '重启 sing-box'; menu_option 5 '查看核心版本'; menu_option 6 'Argo 隧道服务'
        menu_option 7 '卸载核心与服务（保留配置和备份）'; menu_option 8 '安装必要依赖'
        menu_option 9 '安装二维码工具（可选）'; menu_back
        read_menu_choice; choice="$REPLY"
        case "$choice" in
            1) install_singbox ;; 2) service_action start ;; 3) service_action stop ;; 4) service_action restart ;;
            5) [ ! -x "$BIN_FILE" ] || "$BIN_FILE" version ;; 6) menu_argo ;; 7) uninstall_singbox ;;
            8) install_dependencies ;; 9) install_qrencode ;; 0) return ;;
        esac
        pause
    done
}
install_qrencode() {
    command -v qrencode >/dev/null && return 0
    confirm '安装可选二维码工具 qrencode' && acquire_lock || return 1
    case "$OS_FAMILY" in
        debian) apt-get install -y qrencode ;; redhat) yum install -y qrencode ;;
        alpine) apk add --no-cache libqrencode-tools ;; *) error '请手动安装 qrencode。' ;;
    esac
}
menu_advanced() {
    while true; do
        menu_header '系统与高级设置' '系统改动按项确认，不参与节点搭建的默认操作'
        menu_option 1 '核心与服务'; menu_option 2 'DNS 设置'; menu_option 3 '防火墙'
        menu_option 4 '网络加速 / BBR / TCP 缓冲区'; menu_option 5 'Swap 管理'; menu_back
        read_menu_choice
        case "$REPLY" in 1) menu_system ;; 2) menu_dns ;; 3) menu_firewall ;; 4) menu_bbr ;; 5) menu_swap ;; 0) return ;; esac
    done
}
show_menu() {
    menu_header 'Sing-box 管理面板' "$SCRIPT_VERSION · 首次使用请选择搭建节点" "$(get_singbox_status)"
    if command -v jq >/dev/null && jq -e '.format==4' "$STATE_FILE" >/dev/null 2>&1; then
        jq -r '"直连节点：\([.nodes[] | select(.kind != "argo")] | length)  Argo 节点：\([.nodes[] | select(.kind == "argo")] | length)"' "$STATE_FILE"
        printf '转发规则：%s  WARP 出口：%s\n' "$(count_by_type direct)" "$(has_warp_endpoint)"
    fi
    menu_option 1 '搭建 / 添加节点'; menu_option 2 '我的节点'; menu_option 3 '转发与分流'
    menu_option 4 '检查与维护'; menu_option 5 '系统与高级设置'; menu_option 0 '退出'
    read_menu_choice
    case "$REPLY" in 1) menu_add ;; 2) menu_nodes ;; 3) menu_network ;; 4) menu_diagnostics ;; 5) menu_advanced ;; 0) return 10 ;; esac
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
