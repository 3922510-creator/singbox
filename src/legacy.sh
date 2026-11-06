# shellcheck shell=bash
# ==================== 显式清理 v3；绝不在启动时自动执行 ====================
LEGACY_PANEL="/usr/local/bin/sb"
LEGACY_ALIAS="/usr/local/bin/SB"
LEGACY_COPY="/root/singbox.sh"

legacy_script_owned() {
    [ -f "$1" ] && [ ! -L "$1" ] &&
        grep -Fq 'Sing-box 管理面板' "$1" &&
        grep -Eq '^SCRIPT_VERSION="v3\.[0-9]+\.[0-9]+"$' "$1"
}
legacy_service_known() {
    local path="$1"
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    ! grep -Fq '# sb-v4-managed' "$path" || return 1
    if [ "$path" = "$SERVICE_FILE" ]; then
        grep -Fxq 'Description=Sing-box Service' "$path" &&
            grep -Fxq "ExecStart=$BIN_FILE run -C $CONFIG_DIR" "$path" &&
            [ "$(grep -c '^Exec' "$path")" = 1 ]
    else
        grep -Eq '^# sb-service-rev=[0-9]+$' "$path" &&
            grep -Fxq '# 由 sb 管理面板生成；手动改完请 rc-service sing-box restart' "$path" &&
            grep -Fxq "command=\"$BIN_FILE\"" "$path" &&
            grep -Fxq "command_args=\"run -C $CONFIG_DIR\"" "$path"
    fi
}
legacy_preflight() {
    local path found=0 fragment dropins load_state
    case "$INIT_SYS" in systemd|openrc) ;; *) error '需要 systemd / OpenRC，不能安全清理无服务托管的旧进程。'; return 1 ;; esac
    # 不以 jq 解析失败作为“旧版”证据；v4 的整个状态文件存在就拒绝。
    [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || { error '存在 v4 状态或未知元数据，拒绝按旧版清理。'; return 1; }
    for path in "$CONFIG_DIR" "$BIN_FILE" "$SINGBOX_LOG"; do
        [ ! -L "$path" ] || { error "拒绝清理符号链接：$path"; return 1; }
    done
    [ ! -e "$CONFIG_DIR" ] || [ -d "$CONFIG_DIR" ] || return 1
    # BusyBox rm 没有 --one-file-system；清理前拒绝目录内任何挂载点。
    if awk -v p="$CONFIG_DIR" '$5 == p || index($5, p "/") == 1 { found=1 } END { exit !found }' /proc/self/mountinfo; then
        error '配置目录含挂载点，拒绝递归删除。'; return 1
    fi
    for path in "$SERVICE_FILE" "$OPENRC_FILE"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            legacy_service_known "$path" || { error "无法确认旧版服务归属，保留：$path"; return 1; }
            found=1
        fi
    done
    [ ! -d "$ARGO_DIR" ] || { error '发现隧道元数据，请先核实归属；本入口不清理共享 cloudflared。'; return 1; }
    if [ "$found" = 0 ]; then
        # 卸载后仅剩目录 / 核心时，不应要求已被删除的旧 unit 作为证据。
        # 仍拒绝发行版其他路径的服务，以及任何残留运行进程。
        if [ "$INIT_SYS" = systemd ]; then
            load_state=$(systemctl show sing-box -p LoadState --value) || return 1
            fragment=$(systemctl show sing-box -p FragmentPath --value) || return 1
            dropins=$(systemctl show sing-box -p DropInPaths --value) || return 1
            [ "$load_state" = not-found ] && [ -z "$fragment$dropins" ] || {
                error '其他位置仍有 sing-box 服务或缓存的服务定义，拒绝按残留目录清理。'; return 1;
            }
        fi
        if legacy_still_running; then error '无服务文件但仍有 sing-box 进程，请先核实托管方式。'; return 1; fi
        printf '未发现服务文件；将按残留安装清理，确认前不会删除任何文件。\n'
        return 0
    fi
    if [ "$INIT_SYS" = systemd ]; then
        [ -f "$SERVICE_FILE" ] || return 1
        fragment=$(systemctl show sing-box -p FragmentPath --value) || return 1
        dropins=$(systemctl show sing-box -p DropInPaths --value) || return 1
        [ "$fragment" = "$SERVICE_FILE" ] && [ -z "$dropins" ] || {
            error '服务来源不匹配或含额外 drop-in，拒绝自动清理。'; return 1;
        }
    else
        [ -f "$OPENRC_FILE" ] || return 1
    fi
}
legacy_stop() {
    # 普通 svc_stop 只接受 v4；旧版在独立归属检查通过后才走此入口。
    case "$INIT_SYS" in
        systemd) (exec 200>&-; systemctl stop sing-box) ;;
        openrc) (exec 200>&-; rc-service sing-box stop) ;;
        *) return 1 ;;
    esac
}
legacy_still_running() {
    local proc
    local -a argv=()
    case "$INIT_SYS" in
        systemd) systemctl is-active --quiet sing-box && return 0 ;;
        openrc) rc-service sing-box status >/dev/null 2>&1 && return 0 ;;
    esac
    # 同时查旧版 -C 参数的孤儿进程；不按名字盲目 pkill。
    for proc in /proc/[0-9]*; do
        mapfile -d '' -t argv < "$proc/cmdline" 2>/dev/null || continue
        [ "${#argv[@]}" -ge 4 ] || continue
        if [ "${argv[-3]}" = run ]; then
            [ "${argv[-4]}" != "$BIN_FILE" ] || return 0
            if { [ "${argv[-2]}" = -C ] && [ "${argv[-1]}" = "$CONFIG_DIR" ]; } ||
                { [ "${argv[-2]}" = -c ] && [ "${argv[-1]}" = "$CONFIG_FILE" ]; }; then return 0; fi
        fi
    done
    return 1
}
legacy_cleanup() {
    local path directory name
    local -a scripts=()
    legacy_preflight || return 1
    for path in "$LEGACY_PANEL" "$LEGACY_COPY"; do
        if legacy_script_owned "$path"; then scripts+=("$path"); fi
    done
    if [ -L "$LEGACY_ALIAS" ] && [ "$(readlink -f "$LEGACY_ALIAS")" = "$LEGACY_PANEL" ] && legacy_script_owned "$LEGACY_PANEL"; then
        scripts+=("$LEGACY_ALIAS")
    elif legacy_script_owned "$LEGACY_ALIAS"; then scripts+=("$LEGACY_ALIAS"); fi
    printf '\n将停止旧 sing-box，全部旧节点将失效。清理范围：\n'
    for path in "$CONFIG_DIR" "$BIN_FILE" "$SERVICE_FILE" "$OPENRC_FILE" "$SINGBOX_LOG" "${scripts[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then printf '  %s\n' "$path"; fi
    done
    printf '保留：当前 v4 脚本、全部备份、共享依赖 / cloudflared、云端 Tunnel / DNS、系统 DNS / 防火墙 / BBR / Swap。\n'
    confirm '清理旧版脚本、核心、服务、自启与全部旧配置；先保存私密恢复备份' && acquire_lock || return 1
    legacy_preflight || return 1
    # 清理前备份不可重建内容；旧目录整体复制，包含 .meta 与旧 .bak。
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || return 1
    directory=$(mktemp -d "$BACKUP_DIR/legacy-XXXXXXXX") || return 1
    chmod 700 "$directory" || return 1
    for name in config systemd openrc log; do
        case "$name" in
            config) path="$CONFIG_DIR" ;; systemd) path="$SERVICE_FILE" ;;
            openrc) path="$OPENRC_FILE" ;; log) path="$SINGBOX_LOG" ;;
        esac
        if [ -e "$path" ]; then cp -a "$path" "$directory/$name" || return 1; fi
    done
    mkdir "$directory/scripts" || return 1
    local index=0
    for path in "${scripts[@]}"; do
        cp -a "$path" "$directory/scripts/$index" || return 1
        printf '%s\t%s\n' "$index" "$path" >> "$directory/scripts/paths"
        index=$((index + 1))
    done
    printf '私密恢复备份：%s（包含旧配置和密钥，请勿公开）\n' "$directory"
    if [ -f "$SERVICE_FILE" ] || [ -f "$OPENRC_FILE" ]; then
        legacy_stop || { error '停止失败，未删除配置。'; return 1; }
        if legacy_still_running; then error '旧核心仍在运行，停止清理。'; return 1; fi
        svc_disable || { error '移除自启失败，停止清理。'; return 1; }
    elif legacy_still_running; then
        error '发现运行中的残留进程，停止清理。'; return 1
    fi
    rm -f -- "$BIN_FILE" "$SERVICE_FILE" "$OPENRC_FILE" "$SINGBOX_LOG" "${scripts[@]}" || return 1
    rm -rf -- "$CONFIG_DIR" || return 1
    [ "$INIT_SYS" != systemd ] || systemctl daemon-reload || return 1
    printf '旧版已清理。备份保留在 %s；当前 v4 脚本继续可用。\n' "$directory"
}
legacy_reinstall() {
    legacy_cleanup || return 1
    printf '\n接下来可安装全新 v4；安装仍需单独确认，取消不会恢复旧节点。\n'
    install_singbox
}
