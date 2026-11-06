#!/usr/bin/env bash
# Sing-box 管理面板 v4。源文件在 src/，tools/build.py 生成单文件分发。
# 不迁移 v3 或接管未知服务。打开菜单不安装依赖、不写配置、不更新服务定义。
set -o pipefail
SCRIPT_VERSION="v4.0.0"
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[36m'
CYAN='\033[35m'; PLAIN='\033[0m'; BOLD='\033[1m'
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
META_DIR="$CONFIG_DIR/.meta"
STATE_FILE="$META_DIR/state.json"
BIN_FILE="/usr/local/bin/sing-box"
CF_BIN="/usr/local/bin/cloudflared"
ARGO_DIR="$META_DIR/tunnels"
BACKUP_DIR="/var/lib/sb/backups"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
OPENRC_FILE="/etc/init.d/sing-box"
SINGBOX_LOG="/var/log/sing-box.log"
LOCK_FILE="/run/sing-box-manager.lock"
OS_FAMILY=unknown; INIT_SYS=none

platform_detect() {
    local ID='' ID_LIKE=''
    [ ! -r /etc/os-release ] || . /etc/os-release
    case "$ID $ID_LIKE" in
        *alpine*) OS_FAMILY=alpine ;;
        *debian*|*ubuntu*) OS_FAMILY=debian ;;
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*amzn*) OS_FAMILY=redhat ;;
    esac
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null; then INIT_SYS=systemd
    elif command -v rc-service >/dev/null; then INIT_SYS=openrc
    else INIT_SYS=none; fi
}

pause() { printf '\n'; read -rp '按回车键继续…' _ || return 0; }
confirm() {
    local answer
    printf '\n%s\n' "$1"
    read -rp '确认执行？回复 y / n [默认 n]: ' answer || return 1
    [ "$answer" = y ]
}
ui_rule() { printf '%s\n' '────────────────────────────────'; }
menu_header() {
    [ ! -t 1 ] || clear
    printf '\n'; ui_rule
    printf '%b%s%b\n' "$BOLD" "$1" "$PLAIN"
    [ -z "${2:-}" ] || printf '%s\n' "$2"
    [ -z "${3:-}" ] || printf '状态：%s\n' "$3"
    ui_rule
}
menu_section() { printf '\n%s\n' "$1"; }
menu_option() { printf '  %s. %s\n' "$1" "$2"; }
menu_back() { menu_option 0 返回; }
read_menu_choice() {
    read -rp "${1:-请选择}: " REPLY || REPLY=0
}
error() { printf '%s\n' "$*" >&2; return 1; }

# 锁只在明确执行变更后获取；浏览与测试 source 均不创建任何文件。
acquire_lock() {
    command -v flock >/dev/null || { error '缺少 flock，请先安装 util-linux。'; return 1; }
    [ "${SB_LOCKED:-0}" = 1 ] && return 0
    exec 200>"$LOCK_FILE" || return 1
    flock -n 200 || { error '另一个面板正在执行变更。'; return 1; }
    SB_LOCKED=1
}

require_owned() {
    command -v jq >/dev/null || { error '缺少 jq，请先运行搭建或安装依赖。'; return 1; }
    jq -e '.format == 4 and (.nodes | type == "object")' "$STATE_FILE" >/dev/null 2>&1 || {
        error '没有可管理的 v4 安装。新版不迁移旧版，也不接管未知配置。'; return 1;
    }
    jq -e 'type == "object" and (.inbounds | type == "array")' "$CONFIG_FILE" >/dev/null 2>&1 || {
        error '配置损坏或丢失，请检查与恢复备份；不会自动清空。'; return 1;
    }
}
ensure_config() { require_owned; }

inbound_count() { jq '.inbounds | length' "$CONFIG_FILE" 2>/dev/null || printf '0\n'; }
inbound_field() { jq -r ".inbounds[$1].$2 // empty" "$CONFIG_FILE"; }
count_by_type() { jq --arg t "$1" '[.inbounds[] | select(.type == $t)] | length' "$CONFIG_FILE" 2>/dev/null || printf '0\n'; }
validate_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }
port_in_use() {
    local p="$1" listeners
    if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null; then
        jq -e --argjson p "$p" '.inbounds[]? | select(.listen_port == $p)' "$CONFIG_FILE" >/dev/null 2>&1 && return 0
    fi
    command -v ss >/dev/null || { error '缺少 ss，无法安全判断端口占用。'; return 0; }
    listeners=$(ss -H -lntu) || return 0
    awk -v p="$p" '$5 ~ (":" p "$") {found=1} END {exit !found}' <<< "$listeners"
}
read_valid_port() {
    local prompt="$1" default="$2" check="${3:-1}" p
    while true; do
        read -rp "$prompt" p || return 1
        p=${p:-$default}
        if ! validate_port "$p"; then printf '端口必须为 1–65535，不带前导零。\n' >&2; continue; fi
        if [ "$check" = 1 ] && port_in_use "$p"; then printf '端口 %s 已占用或无法检测，请换一个。\n' "$p" >&2; continue; fi
        printf '%s' "$p"; return 0
    done
}
free_port() {
    local p
    for ((p=21871; p<22071; p++)); do
        port_in_use "$p" || { printf '%s' "$p"; return 0; }
    done
    error '未找到空闲测试端口。'
}
get_public_ip() {
    curl -fsS --max-time 8 https://api.ipify.org || curl -fsS --max-time 8 https://api64.ipify.org
}

# 原子写入，临时文件也位于私密目录。服务使用 -c，不扫描候选配置。
write_json() {
    local target="$1" json="$2" tmp
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    if printf '%s\n' "$json" | jq -e . > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$target"; then return 0; fi
    rm -f "$tmp"; return 1
}
snapshot() {
    mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$BACKUP_DIR" || return 1
    LAST_TX=$(mktemp -d "$BACKUP_DIR/change-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
    cp -p "$CONFIG_FILE" "$LAST_TX/config.json" && cp -p "$STATE_FILE" "$LAST_TX/state.json" || return 1
    if [ -d "$ARGO_DIR" ]; then cp -a "$ARGO_DIR" "$LAST_TX/tunnels" || return 1; fi
}
restore_snapshot() {
    local directory="$1"
    [ -f "$directory/config.json" ] && [ -f "$directory/state.json" ] || return 1
    install -m 600 "$directory/config.json" "$CONFIG_FILE" && install -m 600 "$directory/state.json" "$STATE_FILE"
}

service_owned() {
    local path="$SERVICE_FILE"
    [ "$INIT_SYS" != openrc ] || path="$OPENRC_FILE"
    [ "$INIT_SYS" != none ] && grep -Fxq '# sb-v4-managed' "$path" 2>/dev/null
}
svc_active() {
    case "$INIT_SYS" in
        systemd) systemctl is-active --quiet sing-box ;;
        openrc) rc-service sing-box status >/dev/null 2>&1 && core_process_alive ;;
        *) return 1 ;;
    esac
}
core_process_alive() {
    local proc executable expected
    local -a argv=()
    expected=$(readlink -f "$BIN_FILE") || return 1
    for proc in /proc/[0-9]*; do
        executable=$(readlink "$proc/exe" 2>/dev/null) || continue
        if [ "$executable" != "$expected" ]; then
            # Alpine gcompat explicitly runs the musl loader; /proc/exe is not the core ELF.
            case "$executable" in /lib/ld-musl-*.so.1) ;; *) continue ;; esac
        fi
        mapfile -d '' -t argv < "$proc/cmdline" 2>/dev/null || continue
        [ "${#argv[@]}" -ge 4 ] || continue
        [ "${argv[-4]}" = "$BIN_FILE" ] && [ "${argv[-3]}" = run ] &&
            [ "${argv[-2]}" = -c ] && [ "${argv[-1]}" = "$CONFIG_FILE" ] && return 0
    done
    return 1
}
svc_ctl() {
    service_owned || { error 'sing-box 服务不是 v4 管理的服务，拒绝操作。'; return 1; }
    case "$INIT_SYS" in
        systemd) (exec 200>&-; systemctl "$1" sing-box) ;;
        openrc) (exec 200>&-; rc-service sing-box "$1") ;;
        *) error '需要 systemd 或 OpenRC。' ;;
    esac
}
svc_start() { svc_ctl start; }
svc_stop() { svc_ctl stop; }
svc_restart() { svc_ctl restart; }
svc_enable() {
    case "$INIT_SYS" in systemd) systemctl enable sing-box ;; openrc) rc-update add sing-box default ;; *) return 1 ;; esac
}
svc_disable() {
    case "$INIT_SYS" in systemd) systemctl disable sing-box ;; openrc) rc-update del sing-box default ;; *) return 1 ;; esac
}
svc_active_name() {
    case "$INIT_SYS" in systemd) systemctl is-active --quiet "$1" ;; openrc) rc-service "$1" status >/dev/null 2>&1 ;; *) return 1 ;; esac
}
svc_logs() {
    case "$INIT_SYS" in systemd) journalctl -u sing-box -n "${1:-60}" --no-pager ;; *) tail -n "${1:-60}" "$SINGBOX_LOG" 2>/dev/null ;; esac
}
svc_status() {
    case "$INIT_SYS" in systemd) systemctl status sing-box --no-pager ;; openrc) rc-service sing-box status ;; *) error '没有服务管理器。' ;; esac
}
get_singbox_status() {
    if [ ! -x "$BIN_FILE" ]; then printf '未安装'
    elif svc_active >/dev/null 2>&1; then printf '运行中'
    else printf '已停止'; fi
}

install_service_file() {
    local path="$SERVICE_FILE"
    [ "$INIT_SYS" != openrc ] || path="$OPENRC_FILE"
    if [ -e "$path" ] && ! grep -Fxq '# sb-v4-managed' "$path"; then error "拒绝覆盖未知服务：$path"; return 1; fi
    backup_system_file "$path" || return 1
    case "$INIT_SYS" in
        systemd)
            cat > "$SERVICE_FILE" <<EOF
# sb-v4-managed
[Unit]
Description=Sing-box managed by sb v4
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$BIN_FILE run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload ;;
        openrc)
            cat > "$OPENRC_FILE" <<EOF
#!/sbin/openrc-run
# sb-v4-managed
command="$BIN_FILE"
command_args="run -c $CONFIG_FILE"
supervisor="supervise-daemon"
respawn_delay=10
respawn_max=0
pidfile="/run/sing-box.pid"
output_log="$SINGBOX_LOG"
error_log="$SINGBOX_LOG"
depend() { need net; }
EOF
            chmod 755 "$OPENRC_FILE" ;;
        *) error 'v4 要求 systemd 或 OpenRC，不使用不可靠的后台进程托管。'; return 1 ;;
    esac
}

# 所有配置写入统一校验与回退。返回非零时不得继续展示成功或写元数据。
apply_config() {
    local config="$1" state="$2" description="$3" candidate active=0
    require_owned && service_owned || return 1
    candidate=$(mktemp) || return 1
    chmod 600 "$candidate"
    printf '%s\n' "$config" > "$candidate"
    if ! jq -e . "$candidate" >/dev/null || ! "$BIN_FILE" check -c "$candidate"; then
        rm -f "$candidate"; error '候选配置校验失败，原配置未改动。'; return 1
    fi
    rm -f "$candidate"
    jq -e '.format == 4 and (.nodes | type == "object")' <<< "$state" >/dev/null || return 1
    validate_managed_config "$config" "$state" || { error '节点关联校验失败，未应用配置。'; return 1; }
    confirm "$description；将应用配置并短暂重启 sing-box，影响其现有连接。" || return 1
    acquire_lock && snapshot || return 1
    svc_active && active=1
    if write_json "$CONFIG_FILE" "$config" && write_json "$STATE_FILE" "$state" && svc_restart && sleep 1 && svc_active; then
        printf '配置已应用。回滚备份：%s\n' "$LAST_TX"; return 0
    fi
    printf '应用失败，正在恢复本次变更前配置。\n' >&2
    if restore_snapshot "$LAST_TX"; then
        if [ "$active" = 1 ]; then svc_restart && svc_active || error '配置已恢复，但服务恢复失败，请查看日志。'
        else svc_stop || true; fi
    else error "配置恢复失败，请手动恢复：$LAST_TX"; fi
    return 1
}
save_and_check_config() { apply_config "$1" "$(cat "$STATE_FILE")" '修改出口 / 路由配置'; }

install_dependencies() {
    local missing=0 c
    for c in curl jq ss flock tar base64; do command -v "$c" >/dev/null || missing=1; done
    [ "$missing" = 1 ] || return 0
    confirm '安装必要依赖（不启用防火墙、不修改 DNS）' || return 1
    case "$OS_FAMILY" in
        debian) apt-get update -qq && apt-get install -y curl jq iproute2 util-linux ca-certificates tar ;;
        redhat) yum install -y curl jq iproute util-linux ca-certificates tar ;;
        alpine) apk add --no-cache curl jq iproute2 util-linux ca-certificates tar ;;
        *) error '请手动安装 curl jq iproute2 util-linux ca-certificates tar。'; return 1 ;;
    esac
    for c in curl jq ss flock tar base64; do command -v "$c" >/dev/null || return 1; done
}
release_arch() {
    case "$(uname -m)" in x86_64) printf amd64 ;; aarch64|arm64) printf arm64 ;; *) error '仅支持 amd64 / arm64。' ;; esac
}
install_singbox() {
    [ "$INIT_SYS" != none ] || { error '需要 systemd / OpenRC。'; return 1; }
    # 没有任何旧版迁移或隐式接管；包括已有但损坏的目录。
    if [ -e "$CONFIG_DIR" ] && [ ! -f "$STATE_FILE" ]; then error "发现已有目录 $CONFIG_DIR；v4 不覆盖旧版或未知配置。"; return 1; fi
    if [ -e "$STATE_FILE" ]; then require_owned || return 1; fi
    local path="$SERVICE_FILE"
    [ "$INIT_SYS" != openrc ] || path="$OPENRC_FILE"
    if [ -e "$path" ] && ! service_owned; then error '发现未知 sing-box 服务，拒绝覆盖。'; return 1; fi
    if [ "$INIT_SYS" = systemd ] && [ ! -e "$path" ] && systemctl cat sing-box >/dev/null 2>&1; then
        error '发现其他位置的 sing-box systemd 服务，拒绝创建覆盖单元。'; return 1
    fi
    if [ -e "$BIN_FILE" ] && [ ! -f "$STATE_FILE" ]; then error '发现已有核心，拒绝接管。'; return 1; fi
    confirm '安装 / 更新 sing-box 核心和 v4 服务；已有 v4 服务将短暂重启' || return 1
    install_dependencies && acquire_lock || return 1
    local directory arch release url binary suffix active=0 previous=0
    arch=$(release_arch) || return 1
    directory=$(mktemp -d) || return 1
    release=$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest) || { rm -rf "$directory"; return 1; }
    suffix="linux-$arch.tar.gz"
    [ "$OS_FAMILY" != alpine ] || suffix="linux-$arch-musl.tar.gz"
    url=$(jq -er --arg suffix "$suffix" '.assets[] | select(.name | endswith($suffix)) | .browser_download_url' <<< "$release") || { rm -rf "$directory"; return 1; }
    if ! curl -fsSL --proto '=https' --max-time 300 "$url" -o "$directory/core.tgz"; then rm -rf "$directory"; return 1; fi
    # 不把远端归档直接解压到系统目录。
    binary=$(tar -tzf "$directory/core.tgz" | awk '/\/sing-box$/ {print; exit}')
    if [[ ! "$binary" =~ ^sing-box-[a-zA-Z0-9._+-]+/sing-box$ ]] || ! tar -xOzf "$directory/core.tgz" "$binary" > "$directory/sing-box"; then
        rm -rf "$directory"; error '核心归档异常。'; return 1
    fi
    chmod 755 "$directory/sing-box"
    if ! "$directory/sing-box" version >/dev/null 2>&1 && [ "$OS_FAMILY" = alpine ]; then
        confirm '安装 Alpine 核心兼容层 gcompat / libc6-compat' && apk add --no-cache gcompat libc6-compat || { rm -rf "$directory"; return 1; }
    fi
    if ! "$directory/sing-box" version; then
        rm -rf "$directory"; error '核心不能在本系统运行。'; return 1
    fi
    if [ -f "$CONFIG_FILE" ] && ! "$directory/sing-box" check -c "$CONFIG_FILE"; then rm -rf "$directory"; return 1; fi
    svc_active && active=1
    if [ -f "$BIN_FILE" ]; then cp -p "$BIN_FILE" "$directory/previous" || { rm -rf "$directory"; return 1; }; previous=1; fi
    if [ ! -e "$CONFIG_DIR" ]; then
        mkdir -p "$META_DIR" && chmod 700 "$META_DIR" || { rm -rf "$directory"; return 1; }
        write_json "$CONFIG_FILE" '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' || return 1
        write_json "$STATE_FILE" '{"format":4,"nodes":{}}' || return 1
    fi
    if [ -e "$path" ]; then cp -p "$path" "$directory/previous-unit" || { rm -rf "$directory"; return 1; }; fi
    if install_binary "$directory/sing-box" "$BIN_FILE" && install_service_file && svc_enable && svc_restart && sleep 1 && svc_active; then
        rm -rf "$directory"; printf '核心与服务已就绪。\n'; return 0
    fi
    if [ "$previous" = 1 ]; then
        install_binary "$directory/previous" "$BIN_FILE" || error '旧核心恢复失败。'
        if [ -f "$directory/previous-unit" ]; then
            cp -p "$directory/previous-unit" "$path"
            [ "$INIT_SYS" != systemd ] || systemctl daemon-reload
        fi
        if [ "$active" = 1 ]; then svc_restart || true; else svc_stop || true; fi
        printf '更新失败，已恢复上一核心。\n' >&2
    else printf '首次安装未完成，请检查服务日志后重试；不会展示搭建成功。\n' >&2; fi
    rm -rf "$directory"; return 1
}
prepare_core() {
    if [ ! -f "$STATE_FILE" ] || [ ! -x "$BIN_FILE" ] || ! service_owned; then install_singbox || return 1; fi
    require_owned && [ -x "$BIN_FILE" ]
}
singbox_version_ge() {
    local cur
    cur=$("$BIN_FILE" version | awk 'NR==1 {print $3}') || return 1
    awk -v a="$cur" -v b="$1" 'BEGIN {split(a,x,".");split(b,y,".");for(i=1;i<=3;i++){if(x[i]+0>y[i]+0)exit 0;if(x[i]+0<y[i]+0)exit 1}exit 0}'
}

# 在目标文件系统先完整写入候选，再原子替换，避免覆盖正在执行的 ELF。
install_binary() {
    local source="$1" target="$2" tmp
    mkdir -p "$(dirname "$target")" || return 1
    tmp=$(mktemp "${target}.new.XXXXXX") || return 1
    if install -m 755 "$source" "$tmp" && mv -f "$tmp" "$target"; then return 0; fi
    rm -f "$tmp"; return 1
}

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
        menu_option 1 '开放端口'; menu_option 2 '删除端口规则'
        menu_option 3 '启用（先保留实际 SSH 端口）'; menu_option 4 '关闭防火墙'; menu_option 5 '重载'; menu_back
        read_menu_choice; choice="$REPLY"
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

# ==================== 实用小工具 ====================
# 参考 VPSBox (github.com/vmenzo/VPSBox) 的工具集思路：流媒体检测 / DNS / 防火墙

_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"

# ---------- 流媒体解锁检测（本机出口）----------
media_check_quick() {
    echo -e "${CYAN}=== 流媒体解锁检测（基于本机直连出口）===${PLAIN}"
    echo -e "${BLUE}检测中，请稍候...${PLAIN}"

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
    loc=$(curl -s --max-time 10 "https://chat.openai.com/cdn-cgi/trace" 2>/dev/null | sed -n 's/^loc=\([A-Za-z]*\).*/\1/p' | head -1)
    comp=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "https://api.openai.com/compliance/cookie_requirements" -H "authorization: Bearer x" 2>/dev/null)
    if [[ -n "$loc" && "$comp" == "200" ]]; then
        gpt="${GREEN} 可用${PLAIN} (地区: $loc)"
    elif [[ -n "$loc" ]]; then
        gpt="${YELLOW} 网页可访问但 App/API 受限${PLAIN} (地区: $loc)"
    else
        gpt="${RED} 不可用/超时${PLAIN}"
    fi
    printf ' %-12s: %b\n' "ChatGPT" "$gpt"

    # YouTube Premium 地区
    local yt ytc
    ytc=$(curl -s --max-time 12 -A "$_UA" -H "Accept-Language: en-US" "https://www.youtube.com/premium" 2>/dev/null | sed -n 's/.*"GL":"\([A-Z][A-Z]\)".*/\1/p' | head -1)
    if [[ -n "$ytc" ]]; then yt="${GREEN} 可用${PLAIN} (地区: $ytc)"; else yt="${RED} 不可用/超时${PLAIN}"; fi
    printf ' %-12s: %b\n' "YouTube" "$yt"

    # Netflix：非自制剧 81280792  200=完整解锁 / 404=仅自制剧 / 其它=不可用
    local nf nfc
    nfc=$(curl -sL --max-time 12 -A "$_UA" -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/81280792" 2>/dev/null)
    case "$nfc" in
        200) nf="${GREEN} 完整解锁${PLAIN}" ;;
        404) nf="${YELLOW} 仅自制剧${PLAIN}" ;;
        *)   nf="${RED} 不可用 (http=$nfc)${PLAIN}" ;;
    esac
    printf ' %-12s: %b\n' "Netflix" "$nf"

    # Disney+
    local dp dpc
    dpc=$(curl -s --max-time 12 -A "$_UA" -o /dev/null -w "%{http_code}" "https://www.disneyplus.com/" 2>/dev/null)
    if [[ "$dpc" == "200" ]]; then dp="${GREEN} 可访问${PLAIN}"; else dp="${RED} 不可用 (http=$dpc)${PLAIN}"; fi
    printf ' %-12s: %b\n' "Disney+" "$dp"

    # TikTok 地区
    local tt ttc
    ttc=$(curl -s --max-time 12 -A "$_UA" "https://www.tiktok.com/" 2>/dev/null | sed -n 's/.*"region":"\([A-Z][A-Z]\)".*/\1/p' | head -1)
    if [[ -n "$ttc" ]]; then tt="${GREEN} 可用${PLAIN} (地区: $ttc)"; else tt="${YELLOW} 未获取到地区${PLAIN}"; fi
    printf ' %-12s: %b\n' "TikTok" "$tt"
    echo -e "--------------------------------------------------"
    echo -e "${YELLOW}提示：此结果为服务器本机直连出口。若想让某服务走 WARP，可在「WARP 出口」菜单添加分流。${PLAIN}"
}

media_check_full() {
    echo -e "${CYAN}=== 完整流媒体解锁检测（社区脚本 RegionRestrictionCheck）===${PLAIN}"
    echo -e "${YELLOW}将下载并运行外部脚本，需能访问 GitHub。${PLAIN}"
    confirm '以 root 权限下载并执行 RegionRestrictionCheck 第三方脚本' || return 1
    (
        exec 200>&-
        local directory
        directory=$(mktemp -d) || exit 1
        trap 'rm -rf "$directory"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        curl -fsSL --proto '=https' --proto-redir '=https' --max-time 120 https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh -o "$directory/check.sh" &&
            [ -s "$directory/check.sh" ] && bash -n "$directory/check.sh" && bash "$directory/check.sh"
    )
}

# BestTrace 保持独立子进程，避免上游的变量、exit 和 trap 影响面板。
besttrace_check() {
    local answer rc tmp
    echo -e "${CYAN}=== 回程路由测试（BestTrace.sh）===${PLAIN}"
    echo "支持电信 / 联通 / 移动 / 教育网，线路识别结果仅供参考。"
    echo -e "${YELLOW}将以 root 权限下载并运行 https://besttrace.sh/ 的第三方脚本。${PLAIN}"
    echo "首次运行可能由上游下载并安装 NextTrace；不会主动修改 sing-box 配置。"
    read -rp "运行第三方脚本（可能安装 NextTrace）？[y/N]: " answer || return 0
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
    (
        # 不让上游安装器启动的后台进程继承面板锁。
        exec 200>&-
        tmp=$(mktemp -d) || exit 1
        trap 'rm -rf -- "$tmp"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if ! curl --proto '=https' --proto-redir '=https' -fSL \
            --connect-timeout 15 --max-time 120 --retry 2 \
            https://besttrace.sh/ -o "$tmp/besttrace.sh"; then
            echo -e "${RED}BestTrace 下载失败，未执行。${PLAIN}" >&2
            exit 1
        fi
        if [[ ! -s "$tmp/besttrace.sh" ]] || ! bash -n "$tmp/besttrace.sh"; then
            echo -e "${RED}BestTrace 内容为空或语法检查失败，未执行。${PLAIN}" >&2
            exit 1
        fi
        bash "$tmp/besttrace.sh"
    )
    rc=$?
    if (( rc != 0 )); then
        echo -e "${YELLOW}BestTrace 未正常完成（退出码 ${rc}），已返回面板。${PLAIN}"
    fi
    return "$rc"
}

# ---------- DNS 设置 ----------

show_dns() {
    echo -e "${CYAN}=== 当前 DNS (/etc/resolv.conf) ===${PLAIN}"
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || echo -e "${YELLOW}未配置 nameserver${PLAIN}"
    if [ "$INIT_SYS" = "systemd" ] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo -e "${YELLOW} 检测到 systemd-resolved 正在运行，直改 resolv.conf 可能被覆盖。${PLAIN}"
    fi
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
            6) restore_dns ;;
            0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

# ---------- 防火墙 (ufw) 设置 ----------

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
    command -v modinfo >/dev/null 2>&1 && modinfo -k "$(uname -r)" sch_fq >/dev/null 2>&1 && return 0
    cfg="/boot/config-$(uname -r)"                 # Debian/Ubuntu 有；Alpine 无此文件，直接跳到 tc 实测
    if [ -r "$cfg" ]; then
        grep -qE '^CONFIG_NET_SCH_FQ=[ym]' "$cfg" && return 0
        return 1
    fi
    # 状态查询不安装软件、不试挂 lo 队列。缺少模块/config 证据时按未知处理。
    return 1
}

bbr_default_iface() { ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}'; }

bbr_os_family() {
    case "$OS_FAMILY" in
        debian) echo "debian" ;;
        redhat) echo "rhel" ;;
        *)      echo "${OS_FAMILY:-unknown}" ;;
    esac
}

# 队列操作要 tc（iproute2）；Alpine 基础系统不自带，按需装一次
bbr_require_tc() {
    command -v tc >/dev/null 2>&1 && return 0
    if [ "$OS_FAMILY" = "alpine" ]; then
        confirm '安装 iproute2（提供 tc）' && acquire_lock || return 1
        apk add --no-cache iproute2 >/dev/null 2>&1
    fi
    command -v tc >/dev/null 2>&1
}

bbr_status_short() {
    local iface
    iface=$(bbr_default_iface)
    echo -e "  内核      : ${YELLOW}$(uname -r)${PLAIN}    BBR 版本: $(bbr_kernel_desc)"
    echo -e "  拥塞算法  : ${YELLOW}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${PLAIN}    默认队列: ${YELLOW}$(sysctl -n net.core.default_qdisc 2>/dev/null)${PLAIN}"
    echo -e "  可用算法  : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
    if bbr_fq_available; then echo -e "  fq 队列   : ${GREEN}可用${PLAIN}"; else echo -e "  fq 队列   : ${YELLOW}未确认支持（不会为状态查询修改队列）${PLAIN}"; fi
    if [ -n "$iface" ] && command -v tc >/dev/null 2>&1; then
        echo -e "  ${iface} 实际队列: $(tc qdisc show dev "$iface" 2>/dev/null | head -1)"
    fi
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
    confirm "切换拥塞控制为 $1，队列为 $2，并持久化系统设置" && acquire_lock && backup_system_file "$BBR_CONF" || return 1
    local cc="$1" qdisc="$2" label="$3" avail iface cur_cc cur_qd cur_qd_live bak="" have_tc=0
    bbr_require_tc && have_tc=1
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    if ! printf '%s\n' $avail | grep -x -- "$cc" >/dev/null; then
        echo -e "${RED} 当前内核不支持 ${cc}（可用: ${avail}）${PLAIN}"
        return 1
    fi

    iface=$(bbr_default_iface)
    if [ -n "$iface" ] && [ "$have_tc" = "1" ]; then
        cur_qd_live=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1{print $2}')
        if [ "$cur_qd_live" != "$qdisc" ]; then
            # 默认队列只影响新建的网卡队列，已在跑的网卡必须手动替换；顺便用它验证内核是否支持
            if ! tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1; then
                echo -e "${RED} 当前内核没有 ${qdisc} 这个队列算法（tc 替换失败），配置未做任何改动。${PLAIN}"
                echo -e "${YELLOW}   ${iface} 现用 ${cur_qd_live}；要 ${qdisc} 只能换一个带该算法（CONFIG_NET_SCH_FQ）的内核。${PLAIN}"
                return 1
            fi
        fi
    fi

    [ "$have_tc" = "0" ] && echo -e "${YELLOW} 没有 tc（iproute2 未装）→ 跳过队列实测/替换，只写 sysctl 持久化。${PLAIN}"

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
        local live="n/a"
        [ "$have_tc" = "1" ] && live=$(tc qdisc show dev "${iface:-eth0}" 2>/dev/null | awk 'NR==1{print $2}')
        echo -e "${GREEN} 已切换到 ${label}${PLAIN}"
        echo -e "   算法=${cur_cc}  默认队列=${cur_qd}  ${iface:-?} 实际队列=${live}"
        echo -e "   持久化=${BBR_CONF}（重启后自动生效）"
        echo -e "${YELLOW}   注意：已建立的 TCP 连接沿用旧算法，新连接才生效。${PLAIN}"
        [ -z "$bak" ] || rm -f "$bak"
    else
        if [ -n "$bak" ]; then cp -p "$bak" "$BBR_CONF"; else rm -f "$BBR_CONF"; fi
        rm -f "$bak"
        echo -e "${RED} 回读校验不一致：算法=${cur_cc} 队列=${cur_qd}（期望 ${cc} / ${qdisc}）${PLAIN}"
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
    cfg=$(ls -1t /boot/config-* 2>/dev/null | head -1)      # 最新装的内核 = 本次装的那个
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
    [ "$arch" = "x86_64" ] || { echo -e "${RED} ${BBR3_REPO} 只提供 amd64 的 deb（当前 ${arch}）。ARM 请用发行版自带内核。${PLAIN}"; return 1; }
    fam=$(bbr_os_family)
    [ "$fam" = "debian" ] || {
        echo -e "${RED} BBRv3 内核安装只处理 deb 系（Debian / Ubuntu），当前系统判定为 ${fam}。${PLAIN}"
        [ "$fam" = "alpine" ] && echo -e "${YELLOW}   Alpine 请用官方内核：apk add linux-lts（或 linux-virt / linux-edge），重启后在菜单里选一次「BBR + fq_codel」。${PLAIN}"
        return 1
    }

    echo -e "${BLUE}正在从 ${BBR3_REPO} 获取可用版本...${PLAIN}"
    resp=$(curl -sL --max-time 25 "https://api.github.com/repos/${BBR3_REPO}/releases?per_page=100" 2>/dev/null)
    tags=$(jq -r '.[].tag_name' <<<"$resp" 2>/dev/null | grep -E -- '-bbr3-amd64$' | head -6)
    if [ -z "$tags" ]; then
        echo -e "${RED} 取不到版本列表（GitHub API 限流 / 无外网）。退路：VPSBox 的 BBR 菜单，或手动 dpkg 安装 deb。${PLAIN}"
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
    [ -n "$url_img" ] || { echo -e "${RED} 该版本没有 amd64 image 资产。${PLAIN}"; return 1; }

    tmp=$(mktemp -d /tmp/bbr3-XXXXXX)
    echo -e "${BLUE}下载 $(basename "$url_img") ...${PLAIN}"
    curl -fL --max-time 600 -o "$tmp/$(basename "$url_img")" "$url_img" || { echo -e "${RED} image 下载失败（文件留在 ${tmp}）。${PLAIN}"; return 1; }
    if [ -n "$url_hdr" ]; then
        echo -e "${BLUE}下载 $(basename "$url_hdr") ...${PLAIN}"
        curl -fL --max-time 600 -o "$tmp/$(basename "$url_hdr")" "$url_hdr" || echo -e "${YELLOW}   headers 下载失败，只装 image。${PLAIN}"
    fi

    echo -e "\n${YELLOW}即将 dpkg 安装 ${tag} 并更新 GRUB 默认项。${PLAIN}"
    echo -e "${RED}注意：需要重启才生效；新内核起不来时用 VPS 控制台（VNC）选旧内核回退。${PLAIN}"
    echo -e "${YELLOW}  注：${BBR3_REPO} 的内核是 defconfig 构建 → 没有 fq（只有 fq_codel）。${PLAIN}"
    read -rp "确认安装内核？回复 y / n [默认 n]: " conf
    [ "$conf" = "y" ] || { rm -rf "$tmp"; echo -e "${YELLOW}已取消。${PLAIN}"; return; }
    acquire_lock || { rm -rf "$tmp"; return 1; }

    if dpkg -i "$tmp"/*.deb; then
        command -v update-grub >/dev/null 2>&1 && update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null
        echo -e "${GREEN} 安装完成，重启后生效： ${YELLOW}reboot${PLAIN}"
        bbr_post_install_check
        echo -e "   重启回来后在「网络加速」里选一次「BBR + fq_codel」确认即可。"
    else
        echo -e "${RED} dpkg 安装失败，尝试补齐依赖...${PLAIN}"
        apt-get -f install -y && update-grub 2>/dev/null
        echo -e "${YELLOW}若仍失败，请检查包管理器状态。${PLAIN}"
    fi
    rm -rf "$tmp"
}

# ==================== TCP 缓冲区调优 ====================
# 只调「上限」(rmem_max/wmem_max 与 tcp_rmem/tcp_wmem 的 max)，min/default 保持内核自动调优默认，
# 也不动 fq_codel 队列。推荐值按 BDP(带宽×RTT) 估算并用物理内存兜底，避开 OU-SB 那种
# 把 default 一起改小、反复 `>>` 追加、无基线无回滚的坑。
TCP_BUF_CONF="/etc/sysctl.d/99-zz-tcp-buf.conf"
TCP_BUF_BASELINE="/etc/sysctl.d/.tcp-buf-baseline"   # 隐藏文件（非 .conf，sysctl 不加载）：首次改前的内核原值

tcp_mem_total_mb() { awk '/^MemTotal:/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null || echo 1024; }
tcp_bytes_to_mb()  { awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1048576}'; }

# 推荐上限(MB)：参考链路 BDP + 物理内存兜底
tcp_buf_recommend_mb() {
    local ram rec cap
    ram=$(tcp_mem_total_mb)
    # 参考 BDP：~200Mbps × 150ms ÷ 8 ≈ 3.75MB，取 2× 余量 ≈ 8MB；大内存放宽到 16MB
    if [ "$ram" -ge 4096 ]; then rec=16; else rec=8; fi
    # 物理内存兜底：单条上限不超过内存的 1/32（即便开很多连接也安全）
    cap=$(( ram / 32 )); [ "$cap" -lt 4 ] && cap=4
    [ "$rec" -gt "$cap" ] && rec=$cap
    echo "$rec"
}

tcp_buf_status() {
    local rm wm tr tw ovr
    rm=$(sysctl -n net.core.rmem_max 2>/dev/null)
    wm=$(sysctl -n net.core.wmem_max 2>/dev/null)
    tr=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
    tw=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)
    if [ -f "$TCP_BUF_CONF" ]; then ovr="${GREEN}已写入 ${TCP_BUF_CONF}${PLAIN}"; else ovr="${YELLOW}无（用内核默认）${PLAIN}"; fi
    echo -e "  rmem_max / wmem_max  : ${YELLOW}$(tcp_bytes_to_mb "$rm") MB / $(tcp_bytes_to_mb "$wm") MB${PLAIN}"
    echo -e "  tcp_rmem(min/def/max): ${YELLOW}${tr}${PLAIN}"
    echo -e "  tcp_wmem(min/def/max): ${YELLOW}${tw}${PLAIN}"
    echo -e "  物理内存 : ${YELLOW}$(tcp_mem_total_mb) MB${PLAIN}    面板覆盖 : ${ovr}"
}

# 首次改前把当前 4 个值存成基线，供「恢复」用（已存在就不覆盖）
tcp_buf_save_baseline() {
    [ -f "$TCP_BUF_BASELINE" ] && return 0
    {
        echo "# sb 面板 TCP 缓冲区基线（首次调优前的内核原值）$(date '+%Y-%m-%d %H:%M')"
        echo "rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null)"
        echo "wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null)"
        echo "tcp_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
        echo "tcp_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
    } > "$TCP_BUF_BASELINE"
    chmod 600 "$TCP_BUF_BASELINE"
}

# $1 = 目标上限 MB；只抬 max，保留 min/default = 当前内核自动调优值
tcp_buf_apply() {
    confirm "修改 TCP 缓冲区上限为 $1 MB，并持久化" && acquire_lock && backup_system_file "$TCP_BUF_CONF" || return 1
    local mb="$1" ram max cur_rm cur_wm def_r def_w bak=""
    case "$mb" in ''|*[!0-9]*) echo -e "${RED} 请输入纯数字 MB。${PLAIN}"; return 1 ;; esac
    if [ "$mb" -lt 1 ] || [ "$mb" -gt 512 ]; then
        echo -e "${RED} 请输入 1-512 之间的 MB。${PLAIN}"; return 1
    fi
    ram=$(tcp_mem_total_mb); max=$(( mb * 1024 * 1024 ))
    # 内存护栏：单条上限 > 内存 1/8 时要人确认（连接多可能吃光内存）
    if [ "$max" -gt $(( ram * 1024 * 1024 / 8 )) ]; then
        echo -e "${YELLOW} ${mb}MB 超过物理内存(${ram}MB)的 1/8，连接多时有 OOM 风险。${PLAIN}"
        read -rp "  仍要继续？[y/N]: " y; case "$y" in y|Y) ;; *) echo -e "${YELLOW}已取消。${PLAIN}"; return 1 ;; esac
    fi
    def_r=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $1, $2}'); [ -n "$def_r" ] || def_r="4096 131072"
    def_w=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $1, $2}'); [ -n "$def_w" ] || def_w="4096 16384"

    tcp_buf_save_baseline
    mkdir -p /etc/sysctl.d
    [ -f "$TCP_BUF_CONF" ] && { bak=$(mktemp); cp -p "$TCP_BUF_CONF" "$bak"; }
    {
        echo "# TCP 缓冲区上限 ${mb}MB —— 由 sb 管理面板写入 $(date '+%Y-%m-%d %H:%M')"
        echo "net.core.rmem_max = ${max}"
        echo "net.core.wmem_max = ${max}"
        echo "net.ipv4.tcp_rmem = ${def_r} ${max}"
        echo "net.ipv4.tcp_wmem = ${def_w} ${max}"
    } > "$TCP_BUF_CONF"
    chmod 644 "$TCP_BUF_CONF"

    sysctl -q -w "net.core.rmem_max=${max}" "net.core.wmem_max=${max}" \
        "net.ipv4.tcp_rmem=${def_r} ${max}" "net.ipv4.tcp_wmem=${def_w} ${max}" >/dev/null 2>&1

    cur_rm=$(sysctl -n net.core.rmem_max 2>/dev/null)
    cur_wm=$(sysctl -n net.core.wmem_max 2>/dev/null)
    if [ "$cur_rm" = "$max" ] && [ "$cur_wm" = "$max" ]; then
        rm -f "$bak"
        echo -e "${GREEN} TCP 缓冲区上限已设为 ${mb} MB（min/default 保持内核默认，队列不变）${PLAIN}"
        echo -e "   持久化=${TCP_BUF_CONF}（重启后自动生效）"
        echo -e "${YELLOW}   注意：只影响新建连接；代理转发瓶颈通常在 CPU/队列，缓冲区够用即可。${PLAIN}"
    else
        if [ -n "$bak" ]; then cp -p "$bak" "$TCP_BUF_CONF"; else rm -f "$TCP_BUF_CONF"; fi
        rm -f "$bak"
        echo -e "${RED} 回读不一致：rmem_max=${cur_rm} wmem_max=${cur_wm}（期望 ${max}）→ 已回滚配置。${PLAIN}"
        return 1
    fi
}

# 带宽(Mbps) × RTT(ms) 估算 BDP → 推荐 MB
tcp_buf_estimate() {
    local bw rtt bdp mb
    read -rp "  估算带宽 (Mbps, 回车默认 200): " bw; bw=${bw:-200}
    read -rp "  往返延迟 RTT (ms, 回车默认 150): " rtt; rtt=${rtt:-150}
    case "${bw}${rtt}" in *[!0-9]*) echo -e "${RED} 带宽/RTT 需为纯数字。${PLAIN}"; return 1 ;; esac
    { [ "$bw" -gt 0 ] && [ "$rtt" -gt 0 ]; } || { echo -e "${RED} 带宽/RTT 需大于 0。${PLAIN}"; return 1; }
    # BDP(字节) = 带宽(bit/s) × RTT(s) ÷ 8；取 2× 余量后向上取整到整数 MB
    bdp=$(( bw * 1000000 / 8 * rtt / 1000 ))
    mb=$(( (bdp * 2 + 1048575) / 1048576 )); [ "$mb" -lt 1 ] && mb=1
    echo -e "  BDP ≈ $(tcp_bytes_to_mb "$bdp") MB → 含 2× 余量推荐 ${GREEN}${mb} MB${PLAIN}"
    read -rp "  按此值应用？[Y/n]: " y; case "$y" in n|N) echo -e "${YELLOW}已取消。${PLAIN}"; return ;; esac
    tcp_buf_apply "$mb"
}

tcp_buf_restore() {
    confirm '恢复本面板调整前的 TCP 缓冲区设置' && acquire_lock && backup_system_file "$TCP_BUF_CONF" || return 1
    local b_rm b_wm b_tr b_tw
    if [ -f "$TCP_BUF_BASELINE" ]; then
        b_rm=$(grep '^rmem_max=' "$TCP_BUF_BASELINE" | cut -d= -f2-)
        b_wm=$(grep '^wmem_max=' "$TCP_BUF_BASELINE" | cut -d= -f2-)
        b_tr=$(grep '^tcp_rmem=' "$TCP_BUF_BASELINE" | cut -d= -f2-)
        b_tw=$(grep '^tcp_wmem=' "$TCP_BUF_BASELINE" | cut -d= -f2-)
        rm -f "$TCP_BUF_CONF"
        [ -n "$b_rm" ] && sysctl -q -w "net.core.rmem_max=${b_rm}" >/dev/null 2>&1
        [ -n "$b_wm" ] && sysctl -q -w "net.core.wmem_max=${b_wm}" >/dev/null 2>&1
        [ -n "$b_tr" ] && sysctl -q -w "net.ipv4.tcp_rmem=${b_tr}" >/dev/null 2>&1
        [ -n "$b_tw" ] && sysctl -q -w "net.ipv4.tcp_wmem=${b_tw}" >/dev/null 2>&1
        rm -f "$TCP_BUF_BASELINE"
        echo -e "${GREEN} 已恢复到首次调优前的内核原值，并删除面板覆盖。${PLAIN}"
    elif [ -f "$TCP_BUF_CONF" ]; then
        rm -f "$TCP_BUF_CONF"
        echo -e "${YELLOW}已删除面板覆盖 ${TCP_BUF_CONF}（无基线记录）。${PLAIN}"
        echo -e "${YELLOW}运行时值将在重启后由内核重新自动计算；或手动 sysctl 调整。${PLAIN}"
    else
        echo -e "${YELLOW}本面板未写入任何 TCP 缓冲区覆盖，无需恢复。${PLAIN}"
    fi
}

menu_tcp_buf() {
    local rec c mb
    while true; do
        menu_header "TCP 缓冲区调优" "只抬 socket 缓冲上限，不动 fq_codel 队列"
        tcp_buf_status
        rec=$(tcp_buf_recommend_mb)
        echo -e "\n  ${BLUE}推荐依据${PLAIN}：BDP = 带宽(bit/s) × RTT(s) ÷ 8。本机参考 ~200Mbps/150ms"
        echo -e "  → BDP≈3.75MB，含 2× 余量 ≈ 8MB 足够；跨区大带宽可到 16MB。"
        menu_section "设置上限"
        menu_option 1 "推荐值（${rec} MB，按内存兜底）"
        menu_option 2 "8 MB（均衡，~200Mbps/150ms）"
        menu_option 3 "16 MB（高带宽 / 高延迟）"
        menu_option 4 "32 MB（大内存 + 长肥管道）"
        menu_option 5 "自定义 MB"
        menu_option 6 "按 带宽×RTT 估算"
        menu_section "恢复"
        menu_option 7 "恢复内核默认（删除本面板覆盖）"
        menu_back
        read_menu_choice "请选择 [0-7]"; c="$REPLY"
        case "$c" in
            1) tcp_buf_apply "$rec" ;;
            2) tcp_buf_apply 8 ;;
            3) tcp_buf_apply 16 ;;
            4) tcp_buf_apply 32 ;;
            5) read -rp "  输入缓冲区上限 (MB, 1-512): " mb; tcp_buf_apply "$mb" ;;
            6) tcp_buf_estimate ;;
            7) tcp_buf_restore ;;
            0) return ;; *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
        pause
    done
}

menu_bbr() {
    while true; do
        menu_header "网络加速" "BBR / BBRv3 拥塞控制 + 内核 + TCP 缓冲区"
        bbr_status_short
        menu_section "切换（立即生效 + 写入持久化）"
        menu_option 1 "BBR + fq_codel（推荐；内核是 bbr3 就是 BBRv3）"
        menu_option 2 "BBR + fq（先实测内核支不支持 fq，不支持就拒绝）"
        menu_option 3 "CUBIC + fq_codel（恢复系统默认）"
        menu_section "内核"
        menu_option 4 "安装 BBRv3 内核（${BBR3_REPO}，仅 deb 系）"
        menu_option 5 "查看已安装内核"
        menu_section "TCP 调优"
        menu_option 6 "TCP 缓冲区调优（按 BDP 推荐 / 预设 / 自定义）"
        menu_section "查看"
        menu_option 7 "完整状态与判定依据"
        menu_back
        read_menu_choice "请选择 [0-7]"; c="$REPLY"
        case "$c" in
            1) bbr_set_bbr ;; 2) bbr_set_bbr_fq ;; 3) bbr_apply cubic fq_codel "CUBIC + fq_codel" ;;
            4) bbr_install_kernel ;; 5) bbr_list_kernels ;; 6) menu_tcp_buf ;; 7) bbr_show_status ;;
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
        menu_option 7 "回程路由测试（BestTrace / 三网及教育网）"
        menu_section "系统网络"
        menu_option 3 "DNS 设置"
        menu_option 4 "防火墙设置（ufw）"
        menu_option 5 "网络加速（BBR / BBRv3 + fq）"
        menu_option 6 "Swap 管理（添加 / 删除）"
        menu_back
        read_menu_choice "请选择 [0-7]"; c="$REPLY"
        case "$c" in
            1) media_check_quick; pause ;; 2) media_check_full; pause ;;
            3) menu_dns ;; 4) menu_firewall ;; 5) menu_bbr ;; 6) menu_swap ;;
            7) besttrace_check; pause ;; 0) return ;;
            *) echo -e "${RED}无效选项！${PLAIN}" ;;
        esac
    done
}

# ==================== Swap 管理 ====================
# 固定独立目录 + 所有权标记，只管理本面板创建的文件，不接管 /swapfile 或分区。
SB_SWAP_DIR="/var/lib/sb-swap"
SB_SWAP_FILE="$SB_SWAP_DIR/swapfile"
SB_SWAP_MARKER="$SB_SWAP_DIR/managed"
SB_SWAP_FSTAB="/etc/fstab"
SB_SWAP_PROC="/proc/swaps"
SB_SWAP_MEMINFO="/proc/meminfo"

swap_entry() {
    printf '%s none swap sw 0 0 # sb-managed-swap' "$SB_SWAP_FILE"
}

swap_active() {
    awk -v path="$SB_SWAP_FILE" 'NR > 1 && $1 == path {found=1} END {exit !found}' "$SB_SWAP_PROC"
}

swap_owned() {
    [ ! -L "$SB_SWAP_DIR" ] && [ -d "$SB_SWAP_DIR" ] && [ -O "$SB_SWAP_DIR" ] &&
        [ ! -L "$SB_SWAP_FILE" ] && [ -f "$SB_SWAP_FILE" ] &&
        [ ! -L "$SB_SWAP_MARKER" ] && [ -f "$SB_SWAP_MARKER" ] &&
        [ "$(cat "$SB_SWAP_MARKER")" = sb-managed-swap-v1 ]
}

swap_fstab_safe() {
    [ -f "$SB_SWAP_FSTAB" ] && [ ! -L "$SB_SWAP_FSTAB" ] || {
        printf 'fstab 不存在或为符号链接，拒绝自动修改。\n' >&2; return 1;
    }
    awk -v path="$SB_SWAP_FILE" -v entry="$(swap_entry)" '
        $1 == path && $0 != entry {bad=1}
        END {exit bad}
    ' "$SB_SWAP_FSTAB" || {
        printf 'fstab 中存在非本面板的同路径条目，请先人工核对。\n' >&2; return 1;
    }
}

swap_write_fstab() {
    local action="$1" tmp backup
    swap_fstab_safe || return 1
    tmp=$(mktemp "${SB_SWAP_FSTAB}.sb-tmp.XXXXXX") || return 1
    # 同目录原子替换，并保留权限；每次改动先保留可恢复的原文件。
    if ! cp -p "$SB_SWAP_FSTAB" "$tmp" || ! awk -v entry="$(swap_entry)" -v action="$action" '
        $0 != entry {print}
        END {if (action == "add") print entry}
    ' "$SB_SWAP_FSTAB" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    backup=$(mktemp "${SB_SWAP_FSTAB}.sb-swap.bak.XXXXXX") || { rm -f "$tmp"; return 1; }
    if ! cp -p "$SB_SWAP_FSTAB" "$backup" || ! mv -f "$tmp" "$SB_SWAP_FSTAB"; then
        rm -f "$tmp"
        printf '更新 fstab 失败；备份位置：%s\n' "$backup" >&2
        return 1
    fi
    printf 'fstab 已更新，原文件备份：%s\n' "$backup"
}

swap_status() {
    printf '\n当前系统 Swap（包含系统/其他工具创建的 Swap）：\n'
    cat "$SB_SWAP_PROC"
    printf '\n内存概况（kB）：\n'
    awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ {print}' "$SB_SWAP_MEMINFO"
    if swap_owned; then
        printf '\n本面板管理：%s（%s MiB）\n' "$SB_SWAP_FILE" "$(( $(stat -c %s "$SB_SWAP_FILE") / 1048576 ))"
        if swap_active; then printf '状态：已启用\n'; else printf '状态：未启用\n'; fi
    else
        printf '\n本面板尚未创建 Swap；不管理系统已有 Swap。\n'
    fi
}

swap_create() {
    local mb answer available fs cmd
    [ -r "$SB_SWAP_PROC" ] && [ -r "$SB_SWAP_MEMINFO" ] || {
        printf '无法读取内核 Swap/内存状态，拒绝操作。\n' >&2; return 1;
    }
    for cmd in dd df stat mkswap swapon swapoff; do
        command -v "$cmd" >/dev/null 2>&1 || {
            printf '缺少命令 %s，请先安装系统对应工具包（通常为 util-linux/coreutils）。\n' "$cmd" >&2
            return 1
        }
    done
    if [ -e "$SB_SWAP_DIR" ] || [ -L "$SB_SWAP_DIR" ]; then
        printf '目录 %s 已存在；不会覆盖。已有面板 Swap 请先删除，再重新创建。\n' "$SB_SWAP_DIR" >&2
        return 1
    fi
    swap_fstab_safe || return 1
    # 避免沿用悬空的旧持久化条目，创建过程失败时不留下开机引用。
    if awk -v path="$SB_SWAP_FILE" '$1 == path {found=1} END {exit !found}' "$SB_SWAP_FSTAB"; then
        printf 'fstab 中已有此路径条目，拒绝重复创建，请先人工核对。\n' >&2
        return 1
    fi
    read -rp "Swap 大小（MiB，128–65536；例如 1024 = 1 GiB）: " mb || return 1
    if ! [[ "$mb" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$mb" -lt 128 ] || [ "$mb" -gt 65536 ]; then
        printf '请输入 128–65536 范围内的整数 MiB。\n' >&2; return 1
    fi
    fs=$(stat -f -c %T /var/lib) || return 1
    case "$fs" in
        btrfs|zfs|tmpfs|ramfs|nfs*|overlay*)
            printf '当前文件系统 %s 不支持本面板的通用 Swap 文件流程，请使用系统原生方案。\n' "$fs" >&2
            return 1 ;;
    esac
    available=$(df -Pk /var/lib | awk 'END {print $4}')
    if ! [[ "$available" =~ ^[0-9]+$ ]] || [ "$available" -lt "$((mb * 1024 + 262144))" ]; then
        printf '磁盘空间不足：创建后至少需要保留 256 MiB 可用空间。\n' >&2; return 1
    fi
    printf '将创建 %s MiB Swap：%s，并写入 fstab 开机启用。\n' "$mb" "$SB_SWAP_FILE"
    read -rp "输入 确认 继续（其他输入取消）: " answer || return 1
    [ "$answer" = 确认 ] || { printf '已取消。\n'; return 0; }
    mkdir -m 700 "$SB_SWAP_DIR" || return 1
    # 先安全建文件，避免私有数据在权限收紧前暴露；dd 确保分配实际磁盘块。
    if ! (umask 077; printf 'sb-managed-swap-v1\n' > "$SB_SWAP_MARKER" &&
        : > "$SB_SWAP_FILE" && dd if=/dev/zero of="$SB_SWAP_FILE" bs=1M count="$mb" 2>/dev/null) ||
        ! mkswap "$SB_SWAP_FILE" || ! swapon "$SB_SWAP_FILE" || ! swap_active; then
        printf '创建/启用失败（容器可能没有 swapon 权限），未修改 fstab。\n' >&2
        if swap_active; then
            printf '检测到文件仍在使用，保留文件，请人工检查。\n' >&2
        else
            rm -f "$SB_SWAP_FILE" "$SB_SWAP_MARKER"
            rmdir "$SB_SWAP_DIR"
        fi
        return 1
    fi
    if ! swap_write_fstab add; then
        printf '持久化失败，正在撤销新建 Swap。\n' >&2
        if swapoff "$SB_SWAP_FILE" && ! swap_active; then
            rm -f "$SB_SWAP_FILE" "$SB_SWAP_MARKER"
            rmdir "$SB_SWAP_DIR"
        else
            printf '停用失败，已保留 Swap 文件；本次 Swap 未保证开机启用，请人工检查。\n' >&2
        fi
        return 1
    fi
    printf ' 已创建并启用 %s MiB Swap，开机自动启用。\n' "$mb"
}

swap_delete() {
    local answer used available was_active=0
    [ -r "$SB_SWAP_PROC" ] && [ -r "$SB_SWAP_MEMINFO" ] || {
        printf '无法读取内核 Swap/内存状态，拒绝操作。\n' >&2; return 1;
    }
    swap_owned || { printf '未找到本面板创建的 Swap，拒绝删除其他 Swap。\n' >&2; return 1; }
    swap_fstab_safe || return 1
    if swap_active; then
        was_active=1
        used=$(awk -v path="$SB_SWAP_FILE" 'NR > 1 && $1 == path {print $4}' "$SB_SWAP_PROC")
        available=$(awk '/^MemAvailable:/ {print $2}' "$SB_SWAP_MEMINFO")
        if ! [[ "$used" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] || [ "$available" -lt "$((used + 65536))" ]; then
            printf '可用内存不足或无法可靠读取：停用前至少需覆盖 Swap 已用量并余留 64 MiB。请先释放内存。\n' >&2
            return 1
        fi
    fi
    printf '将停用并删除 %s，移除对应开机条目；不动其他 Swap。\n' "$SB_SWAP_FILE"
    read -rp "输入 确认 删除（其他输入取消）: " answer || return 1
    [ "$answer" = 确认 ] || { printf '已取消。\n'; return 0; }
    if [ "$was_active" = 1 ]; then
        if ! swapoff "$SB_SWAP_FILE" || swap_active; then
            printf '停用失败或仍在使用，文件及 fstab 均保留，未执行删除。\n' >&2; return 1
        fi
    fi
    if ! swap_write_fstab remove; then
        if [ "$was_active" = 1 ]; then
            swapon "$SB_SWAP_FILE" || printf '恢复启用失败，文件仍保留，请人工检查。\n' >&2
        fi
        return 1
    fi
    if ! rm -f "$SB_SWAP_FILE"; then
        printf 'Swap 已停用且开机条目已移除，但文件删除失败：%s\n' "$SB_SWAP_FILE" >&2
        return 1
    fi
    rm -f "$SB_SWAP_MARKER"
    rmdir "$SB_SWAP_DIR" || printf '目录中还有其他文件，已保留目录。\n' >&2
    printf ' 已删除本面板创建的 Swap。\n'
}

menu_swap() {
    local c
    while true; do
        menu_header "Swap 管理" "只管理本面板创建的 Swap 文件"
        swap_status
        menu_option 1 "添加 Swap（自定义 MiB）"
        menu_option 2 "删除本面板 Swap"
        menu_back
        read_menu_choice "请选择 [0-2]" || return
        c="$REPLY"
        case "$c" in
            1) swap_create; pause ;; 2) swap_delete; pause ;; 0) return ;;
            *) printf '无效选项！\n' ;;
        esac
    done
}

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
