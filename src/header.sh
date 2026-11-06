#!/usr/bin/env bash
# Sing-box 管理面板 v4。源文件在 src/，tools/build.py 生成单文件分发。
# 不迁移 v3 或接管未知服务。打开菜单不安装依赖、不写配置、不更新服务定义。
set -o pipefail
SCRIPT_VERSION="v4.0.1"
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
