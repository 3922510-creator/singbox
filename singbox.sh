#!/usr/bin/env bash
# ====================================================================
#  Sing-box 管理面板
#  版本: v3.8.5  |  快捷指令: SB / sb
# --------------------------------------------------------------------
#  特性:
#    • 同时支持 systemd（Debian/Ubuntu/RHEL）与 OpenRC（Alpine）发行版
#    • VLESS-Reality / AnyTLS-Reality / SS2022 节点管理（二维码 / 分享链接）
#    • TCP/UDP 端口转发
#    • Cloudflare WARP 出口（AI / 流媒体 / 自定义分流）
#    • 实用小工具（流媒体解锁检测 / 回程路由 / DNS / 防火墙 / Swap）
#    • 网络加速（BBR / BBRv3 拥塞控制切换 + BBRv3 内核安装）
#    • 配置校验 + 自动回滚 + 并发锁
#  备份策略: 仅当“校验通过”才刷新唯一备份(.bak)，失败备份不动
# ====================================================================

set -o pipefail

SCRIPT_VERSION="v3.8.5"
SSH_BARK_CONFIG="/etc/sb-ssh-bark.json"  # 不放进 sing-box 的配置扫描目录
SSH_BARK_UNIT="sb-ssh-bark.service"

# ---------- 颜色 ----------
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[36m"; CYAN="\033[35m"; PLAIN="\033[0m"

# ---------- 路径 ----------
CONFIG_FILE="/etc/sing-box/config.json"
BIN_FILE="/usr/local/bin/sing-box"
PANEL_FILE="/usr/local/bin/sb"
PANEL_ALIAS="/usr/local/bin/SB"
SERVICE_FILE="/etc/systemd/system/sing-box.service"   # systemd 单元（systemd 系统）
OPENRC_FILE="/etc/init.d/sing-box"                     # OpenRC 服务脚本（Alpine 等）
SINGBOX_LOG="/var/log/sing-box.log"                    # 无 journald 时 sing-box 的输出落这里
META_DIR="/etc/sing-box/.meta"
REALITY_META="$META_DIR/reality.txt"                          # Reality 系（VLESS / AnyTLS）公钥记录: tag|public_key
WARP_META="$META_DIR/warp.json"
NODE_NAMES_META="$META_DIR/node-names.json"                  # 备注独立保存，不改 tag / 路由 / 服务配置
LOCK_FILE="/var/run/sing-box-manager.lock"

# 服务定义版本：OpenRC / systemd 脚本内容有变更时靠它自动升级旧安装（见 ensure_service_def_fresh）
SERVICE_DEF_REV="2"
RESPAWN_DELAY="10"                                        # supervise-daemon 拉起间隔（秒）

# ---------- 平台检测（发行版家族 + init 系统）----------
# 脚本主体不直接写 systemctl/apk：统一走下面的 OS_FAMILY 与 svc_* 抽象，
# 这样同一份脚本在 systemd（Debian/Ubuntu/RHEL）和 OpenRC（Alpine）上都能跑。
OS_FAMILY="unknown"
OS_ID=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
OS_LIKE=$(. /etc/os-release 2>/dev/null; echo "${ID_LIKE:-}")
case "$OS_ID $OS_LIKE" in
    *alpine*)                                             OS_FAMILY="alpine" ;;
    *debian*|*ubuntu*|*kali*|*armbian*|*raspbian*)        OS_FAMILY="debian" ;;
    *rhel*|*centos*|*fedora*|*rocky*|*almalinux*|*amzn*)  OS_FAMILY="redhat" ;;
esac
if [ "$OS_FAMILY" = "unknown" ]; then
    [ -f /etc/alpine-release ] && OS_FAMILY="alpine"
    [ -f /etc/debian_version ] && OS_FAMILY="debian"
    [ -f /etc/redhat-release ] && OS_FAMILY="redhat"
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
else
    INIT_SYS="none"     # 容器里没有 init：退化成 nohup 托管（重启后要手动拉起）
fi

[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 若通过管道/进程替换（如 bash <(curl ...)）运行，stdin 不是终端，
# read 会立即读到 EOF 导致菜单空转或直接退出（表现为“执行完就断连”）。
# 强制把 stdin 重定向到终端，保证交互菜单始终从 TTY 读取。
if [ "${1:-}" != --ssh-bark-worker ] && [ ! -t 0 ] && [ -e /dev/tty ]; then exec < /dev/tty; fi

# ==================== 服务控制抽象（systemd / OpenRC / 无 init）====================
# 全脚本统一用这几个函数管 sing-box 服务（日志同理），不再散落 systemctl/journalctl。
# OpenRC 的原始状态串：started / starting / crashed / unsupervised / stopped ...
# crashed（进程被杀）、unsupervised（supervise-daemon 也挂了）都不是“已停止”，
# 但此时 rc-service start 会回一句 “already been started” 就成功返回（见 svc_ctl 注释）。
svc_state_raw() {
    rc-service sing-box status 2>/dev/null | sed -n 's/^[[:space:]]*\* status: //p' | head -1
}

svc_active() {
    case "$INIT_SYS" in
        systemd) systemctl is-active --quiet sing-box 2>/dev/null ;;
        openrc)  # 不用管道（顶部有 set -o pipefail：grep -q 命中即退出会让上游收 SIGPIPE，
                 # 整条管道被判失败，判断会随机为假）
                 case "$(svc_state_raw)" in started|starting) return 0 ;; *) return 1 ;; esac ;;
        *)       pgrep -f "$BIN_FILE run" >/dev/null 2>&1 ;;
    esac
}

svc_ctl() {
    local act="$1"
    case "$INIT_SYS" in
        systemd) systemctl "$act" sing-box ;;
        openrc)
            # OpenRC 的坑（2026-10-11 在 Alpine 机器上实测）：sing-box 被 OOM 杀掉、
            # 或 supervise-daemon 一起挂掉后，服务状态停在 crashed/unsupervised，
            # 这时 `rc-service sing-box start` 只回一句
            # "WARNING: sing-box has already been started" 并返回 0 ——
            # 面板显示“启动成功”，实际什么都没起（也不会自愈）。
            # 所以 start/restart 前先确认真实状态，必要时清状态 + 清残留进程。
            if [ "$act" = "start" ] || [ "$act" = "restart" ]; then
                if ! svc_active; then
                    rc-service sing-box zap >/dev/null 2>&1   # 把 crashed/unsupervised 手动重置为 stopped
                    rm -f /run/sing-box.pid 2>/dev/null
                    # supervisor 被单独杀掉时会留下孤儿进程占着监听端口，
                    # 新实例会因 “address already in use” 起不来 → 清理（已确认服务未运行）
                    pkill -f "$BIN_FILE run" 2>/dev/null
                    sleep 1
                fi
            fi
            # 子 shell 里关掉锁 fd 200，避免被服务进程继承（见 acquire_lock 注释）
            ( exec 200>&- 2>/dev/null; rc-service sing-box "$act" ) ;;
        *)
            # 无 init 系统：直接 nohup 托管（Alpine 容器 / 精简 rootfs 场景）
            case "$act" in
                stop)    pkill -f "$BIN_FILE run" 2>/dev/null; return 0 ;;
                start|restart)
                    ( exec 200>&- 2>/dev/null
                      [ "$act" = "restart" ] && { pkill -f "$BIN_FILE run" 2>/dev/null; sleep 1; }
                      nohup "$BIN_FILE" run -C /etc/sing-box >>"$SINGBOX_LOG" 2>&1 &
                      echo $! > /var/run/sing-box.pid ) ;;
            esac ;;
    esac
}
svc_start()   { svc_ctl start; }
svc_stop()    { svc_ctl stop; }
svc_restart() { svc_ctl restart; }

svc_enable() {
    case "$INIT_SYS" in
        systemd) systemctl enable sing-box &>/dev/null ;;
        openrc)  rc-update add sing-box default &>/dev/null ;;
    esac
}
svc_disable() {
    case "$INIT_SYS" in
        systemd) systemctl disable sing-box &>/dev/null ;;
        openrc)  rc-update del sing-box default &>/dev/null ;;
    esac
}
svc_daemon_reload() { [ "$INIT_SYS" = "systemd" ] && systemctl daemon-reload; }

svc_status() {
    case "$INIT_SYS" in
        systemd) systemctl status sing-box --no-pager ;;
        openrc)  rc-service sing-box status
                 if grep -q "sb-service-rev=$SERVICE_DEF_REV" "$OPENRC_FILE" 2>/dev/null; then
                     echo "自愈   : 已启用（supervise-daemon 托管，进程崩溃/被 OOM 杀掉后 ${RESPAWN_DELAY}s 内自动拉起）"
                 else
                     echo -e "${YELLOW}自愈   : 未启用（服务定义是旧版，下次运行面板会自动升级）${PLAIN}"
                 fi
                 # 注意：rc-update show 的列表走 stderr；且顶部 pipefail 下不能配合 grep -q
                 case "$(rc-update show default 2>&1)" in
                     *sing-box*) echo "自启动 : 已启用（default）" ;;
                     *)          echo "自启动 : 未启用（rc-update add sing-box default）" ;;
                 esac ;;
        *)       echo "（无 systemd / OpenRC，由 nohup 直接托管）"
                 if svc_active; then echo "状态   : 运行中（PID $(cat /var/run/sing-box.pid 2>/dev/null)）"; else echo "状态   : 已停止"; fi ;;
    esac
}

svc_logs() {
    local n="${1:-100}"
    case "$INIT_SYS" in
        systemd) journalctl -u sing-box -n "$n" --no-pager ;;
        *)       if [ -f "$SINGBOX_LOG" ]; then tail -n "$n" "$SINGBOX_LOG"
                 else echo -e "${YELLOW}暂无日志（${SINGBOX_LOG} 不存在）${PLAIN}"; fi ;;
    esac
}
svc_logs_follow() {
    case "$INIT_SYS" in
        systemd) journalctl -u sing-box -f ;;
        *)       tail -f "$SINGBOX_LOG" ;;
    esac
}

# 任意服务是否在运行（firewalld / ufw 这类第三方服务用）
svc_active_name() {
    local name="$1"
    case "$INIT_SYS" in
        systemd) systemctl is-active --quiet "$name" 2>/dev/null ;;
        openrc)  case "$(rc-service "$name" status 2>&1)" in *started*) return 0 ;; *) return 1 ;; esac ;;
        *)       return 1 ;;
    esac
}

# ---------- 通用交互 ----------
pause() { echo ""; read -rp "  按回车键继续..." _ || true; }

# ====================================================================
#  UI 渲染层（v3.8 统一布局）
#  硬约束：手机 SSH 客户端 + 中文 + ANSI 会让「固定宽度右边框」错位，所以全部
#  左对齐、只用水平规则线；规则线宽度随终端自适应（手机竖屏不折行）。
#  只用基础 ANSI + 粗体/暗色，不碰 256/truecolor，保证各终端渲染一致。
# ====================================================================
BOLD="\033[1m"; DIM="\033[2m"

# 规则线宽度：优先读 $COLUMNS，退回 tput；夹在 32..54 列（手机竖屏约 40-50 列）
ui_width() {
    local w="${COLUMNS:-0}"
    case "$w" in ''|*[!0-9]*) w=0 ;; esac
    [ "$w" -eq 0 ] && w=$(tput cols 2>/dev/null || echo 44)
    case "$w" in ''|*[!0-9]*) w=44 ;; esac
    [ "$w" -lt 32 ] && w=32
    [ "$w" -gt 54 ] && w=54
    printf '%s' "$w"
}
ui_rule() {
    local w i line=''
    w=$(ui_width); i=0
    while [ "$i" -lt "$w" ]; do line="${line}─"; i=$((i+1)); done
    printf '%b%s%b\n' "${DIM}${BLUE}" "$line" "$PLAIN"
}
ui_subrule() {
    local w i line=''
    w=$(ui_width); i=0
    while [ "$i" -lt "$w" ]; do line="${line}·"; i=$((i+1)); done
    printf '%b%s%b\n' "$DIM" "$line" "$PLAIN"
}
ui_title() { printf '\n  %b▌%b %b%s%b\n' "$CYAN" "$PLAIN" "$BOLD" "$1" "$PLAIN"; }
ui_kv() { printf '  %b%-8s%b %b\n' "$DIM" "$1" "$PLAIN" "$2"; }

# 标题区：规则线 → 粗体标题 → 暗色副标题 → 状态 → 规则线
menu_header() {
    local title="$1" subtitle="${2:-}" status="${3:-}"
    clear 2>/dev/null || true
    echo ""
    ui_rule
    printf '  %b%s%b\n' "$BOLD" "$title" "$PLAIN"
    [ -n "$subtitle" ] && printf '  %b%s%b\n' "$DIM" "$subtitle" "$PLAIN"
    [ -n "$status" ] && printf '  %b状态%b %b\n' "$DIM" "$PLAIN" "$status"
    ui_rule
}

# 分组：左侧强调条 + 粗体标签
menu_section() { printf '\n  %b▌%b %b%s%b\n' "$BLUE" "$PLAIN" "$BOLD" "$1" "$PLAIN"; }
# 选项：绿色右对齐序号 + 文本
menu_option() { printf '    %b%2s)%b %b\n' "$GREEN" "$1" "$PLAIN" "$2"; }
# 返回 / 退出
menu_back() { printf '\n    %b 0)%b 返回上一级\n\n' "$YELLOW" "$PLAIN"; }
menu_exit() { printf '\n    %b 0)%b 退出脚本\n\n' "$YELLOW" "$PLAIN"; }
# 输入提示：强调箭头（EOF 返回非 0，首尾去空白）
read_menu_choice() {
    local prompt="${1:-请选择}"
    printf '%b  ❯%b %s: ' "$BLUE" "$PLAIN" "$prompt"
    read -r REPLY || return 1
    REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"
    REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
    return 0
}
menu_invalid() {
    printf '  %b无效选项，请重新输入。%b\n' "$RED" "$PLAIN"
    sleep 0.6
}

# 摘要行辅助（主菜单 / 各子菜单顶栏复用）
nodes_total_count() {
    local v a s
    v=$(count_by_type vless)
    a=$(count_by_type anytls)
    s=$(ss2022_count 2>/dev/null || echo 0)
    echo $((v + a + s))
}
nodes_summary_line() {
    local v a s tot
    v=$(count_by_type vless)
    a=$(count_by_type anytls)
    s=$(ss2022_count 2>/dev/null || echo 0)
    tot=$((v + a + s))
    if [ "$tot" -eq 0 ]; then
        printf '%b暂无节点%b' "$YELLOW" "$PLAIN"
    else
        printf '%b共 %s 个%b（VLESS %s · AnyTLS %s · SS2022 %s）' "$GREEN" "$tot" "$PLAIN" "$v" "$a" "$s"
    fi
}
warp_summary_short() {
    if [ "$(has_warp_endpoint)" -gt 0 ]; then
        local rc
        rc=$(jq '[.route.rules[]? | select((.outbound? // "") == "warp")] | length' "$CONFIG_FILE" 2>/dev/null)
        printf '%b已配置%b（%s 条规则）' "$GREEN" "$PLAIN" "${rc:-0}"
    else
        printf '%b未配置%b' "$YELLOW" "$PLAIN"
    fi
}
home_status_line() {
    local sb_s n_cnt fw_cnt warp_tag
    sb_s=$(get_singbox_status)
    n_cnt=$(nodes_total_count)
    fw_cnt=$(count_by_type direct)
    if [ "$(has_warp_endpoint)" -gt 0 ]; then
        warp_tag="${GREEN}WARP开${PLAIN}"
    else
        warp_tag="${DIM}WARP关${PLAIN}"
    fi
    printf '%b · 节点 %s · 转发 %s · %b' "$sb_s" "$n_cnt" "$fw_cnt" "$warp_tag"
}

# 并发锁
# 坑（2026-10-11 实测）：面板用 flock 锁住 fd 200，而它调用的 rc-service/start-stop-daemon
# 是由本进程 fork 出去的，openrc 会把 fd 200 一并继承给自己的孩子
# （supervise-daemon / sing-box 都受影响）—— 服务一起，锁就被服务进程永久持有，
# 下一次运行面板会直接报「另一个管理实例正在运行」而进不去。
# 所以：① 启动服务时把 fd 200 关掉（不传给服务进程）；② 万一已经是旧版残留状态，
# 识别出持有者是服务进程就跳过，不把用户挡在外面。
lock_holder_is_service() {
    local p pid cmd
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        [ "$pid" = "$$" ] && continue
        for fd in "$p"/fd/*; do
            case "$(readlink "$fd" 2>/dev/null)" in
                *sing-box-manager.lock*)
                    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
                    case "$cmd" in
                        *sing-box*|*supervise-daemon*|*start-stop-daemon*)
                            echo -e "${YELLOW}提示：锁文件被服务进程持有（旧版面板的 fd 继承问题）：PID $pid $cmd${PLAIN}"
                            echo -e "${YELLOW}      已忽略该锁（新版面板启动服务时不再传递锁 fd）。${PLAIN}"
                            return 0 ;;
                        *)
                            echo -e "${RED}  占用者：PID $pid $cmd${PLAIN}" >&2
                            return 1 ;;
                    esac ;;
            esac
        done
    done
    return 1
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        if lock_holder_is_service; then
            return 0    # 历史残留，不阻塞（服务进程不会真的和面板抢操作）
        fi
        echo -e "${RED}错误：另一个管理实例正在运行，请稍后重试。${PLAIN}"
        exit 1
    fi
}

# ==================== 依赖安装 ====================
install_dependencies() {
    local missing=0
    for cmd in curl jq wget qrencode flock bash; do
        command -v "$cmd" &>/dev/null || missing=1
    done
    [ $missing -eq 0 ] && return

    echo -e "${BLUE}正在安装必要依赖 (curl jq wget qrencode flock bash)...${PLAIN}"
    case "$OS_FAMILY" in
        debian) apt-get update -qq && apt-get install -y -qq curl jq wget ufw qrencode util-linux bash ;;
        redhat) yum install -y -q curl jq wget firewalld qrencode util-linux bash ;;
        alpine)
            apk update -q 2>/dev/null
            apk add --no-cache curl jq wget util-linux bash ca-certificates kmod iproute2
            apk_ensure_community
            # Alpine 的 qrencode 由 libqrencode-tools 提供（community 仓库）；只用于显示二维码
            apk add --no-cache libqrencode-tools 2>/dev/null \
                || echo -e "${YELLOW}提示：qrencode（二维码）未能安装，其余功能不受影响${PLAIN}"
            ;;
        *)      echo -e "${RED}未知发行版（${OS_ID:-unknown}），请手动安装：curl jq wget qrencode flock bash${PLAIN}"
                return 1 ;;
    esac
}

# Alpine 默认可能只启用了 main 仓库；community 里才有 qrencode 等包，缺了就补一行
apk_ensure_community() {
    local repos=/etc/apk/repositories base
    [ -f "$repos" ] || return 0
    grep -qE '/community$' "$repos" && return 0
    base=$(sed -n 's#^\([^#]*\)/main$#\1#p' "$repos" | head -1)
    [ -n "$base" ] || return 0
    printf '%s/community\n' "$base" >> "$repos"
    echo -e "${BLUE}已为 Alpine 启用 community 仓库：${base}/community${PLAIN}"
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
    local test_file
    # 在同一目录准备候选配置，校验后用 rename 原子替换。
    test_file=$(mktemp "${CONFIG_FILE%/*}/.sb-config.XXXXXX") || return 1
    chmod 600 "$test_file" 2>/dev/null || true
    if ! printf '%s\n' "$new_json" > "$test_file"; then
        rm -f "$test_file"
        return 1
    fi

    echo -e "${BLUE}正在校验配置...${PLAIN}"
    if ! "$BIN_FILE" check -c "$test_file" &>/dev/null; then
        echo -e "${RED}配置校验失败，以下为错误详情：${PLAIN}"
        "$BIN_FILE" check -c "$test_file"
        rm -f "$test_file"
        echo -e "${YELLOW}已放弃更改：原配置与备份均保持不变。${PLAIN}"
        return 1
    fi

    if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" 2>/dev/null; then
        if ! install -m 600 "$CONFIG_FILE" "${CONFIG_FILE}.bak"; then
            rm -f "$test_file"
            return 1
        fi
    fi
    if ! mv -f -- "$test_file" "$CONFIG_FILE"; then
        rm -f "$test_file"
        return 1
    fi

    echo -e "${GREEN}配置校验通过，已保存；备份已刷新为上一版配置。${PLAIN}"
    return 0
}

apply_config_and_restart() {
    local new_json="$1" was_active=0 restore_file
    if svc_active; then was_active=1; fi
    save_and_check_config "$new_json" || return 1
    if svc_restart && sleep 1 && svc_active; then
        return 0
    fi
    printf '%b服务重启未生效，正在恢复上一份配置。%b\n' "$RED" "$PLAIN" >&2
    if [ -f "${CONFIG_FILE}.bak" ] && jq empty "${CONFIG_FILE}.bak" 2>/dev/null; then
        restore_file=$(mktemp "${CONFIG_FILE%/*}/.sb-restore.XXXXXX") || return 1
        if ! install -m 600 "${CONFIG_FILE}.bak" "$restore_file" || ! mv -f -- "$restore_file" "$CONFIG_FILE"; then
            rm -f -- "$restore_file"
            printf '自动恢复失败；备份仍在 %s.bak。\n' "$CONFIG_FILE" >&2
            return 1
        fi
    else
        printf '未找到有效备份，无法自动恢复配置。\n' >&2
        return 1
    fi
    if (( was_active )); then
        if ! { svc_restart && sleep 1 && svc_active; }; then
            printf '配置已恢复，但服务未能恢复运行，请查看日志。\n' >&2
        fi
    elif svc_active; then
        svc_stop || printf '配置已恢复，但未能恢复原来的停止状态。\n' >&2
    fi
    return 1
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
    install -m 600 "${CONFIG_FILE}.bak" "$CONFIG_FILE" || return 1
    if svc_restart && sleep 1 && svc_active; then
        echo -e "${GREEN}已回滚到上一次有效配置并重启服务。${PLAIN}"
    else
        echo -e "${RED}已回滚配置，但服务重启失败，请查看日志：${PLAIN}"
        svc_logs 20
        return 1
    fi
}

# ==================== 辅助工具函数 ====================
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

port_in_use() {
    local p="$1" n
    if [ -f "$CONFIG_FILE" ]; then
        n=$(jq --argjson p "$p" '[.inbounds[]? | select(.listen_port == $p)] | length' "$CONFIG_FILE" 2>/dev/null)
        [ "${n:-0}" -gt 0 ] && return 0
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | awk -v p="$p" 'NR > 1 && $5 ~ ("(^|:|\\])" p "$") {found=1; exit} END {exit !found}' && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | awk -v p="$p" 'NR > 2 && $4 ~ ("(^|:|\\])" p "$") {found=1; exit} END {exit !found}' && return 0
    fi
    return 1
}

is_valid_ip() {
    local ip="$1" o seg
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS=.
        read -r -a o <<< "$ip"
        for seg in "${o[@]}"; do
            (( 10#$seg >= 0 && 10#$seg <= 255 )) || return 1
        done
        return 0
    fi
    if [[ "$ip" == *:*:* && "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" != *:::* ]]; then
        return 0
    fi
    return 1
}

format_url_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

get_public_ip() {
    local ip="" candidate url
    for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://api64.ipify.org"; do
        if [[ "$url" == *api64* ]]; then
            candidate=$(curl -fsS -6 --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        else
            candidate=$(curl -fsS -4 --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        fi
        if is_valid_ip "$candidate"; then
            ip="$candidate"
            break
        fi
    done
    printf '%s\n' "${ip:-127.0.0.1}"
}

open_firewall_port() {
    local port="$1"
    if command -v ufw &>/dev/null && [[ $(LC_ALL=C ufw status 2>/dev/null) == 'Status: active'* ]]; then
        ufw allow "$port"/tcp &>/dev/null || return 1
        ufw allow "$port"/udp &>/dev/null || return 1
    elif command -v firewall-cmd &>/dev/null && svc_active_name firewalld; then
        firewall-cmd --zone=public --add-port="$port"/tcp --permanent &>/dev/null || return 1
        firewall-cmd --zone=public --add-port="$port"/udp --permanent &>/dev/null || return 1
        firewall-cmd --reload &>/dev/null || return 1
    elif command -v iptables &>/dev/null && case "$(iptables -S INPUT 2>/dev/null)" in *'-P INPUT DROP'*) true ;; *) false ;; esac; then
        # 无 ufw/firewalld 但 INPUT 是 DROP 策略（Alpine / 纯 iptables 环境）：显式放行
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || return 1
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$port" -j ACCEPT || return 1
        echo -e "${YELLOW}已用 iptables 放行 ${port}；持久化：rc-service iptables save（或写入 /etc/iptables/rules-save）${PLAIN}"
    fi
}

get_singbox_status() {
    if [ ! -f "$BIN_FILE" ]; then echo -e "${RED}未安装${PLAIN}"; return; fi
    local ver
    ver=$($BIN_FILE version 2>/dev/null | head -n1 | awk '{print $3}')
    if svc_active; then
        echo -e "${GREEN}运行中 [v${ver}]${PLAIN}"
    else
        echo -e "${YELLOW}已停止 [v${ver}]${PLAIN}"
    fi
}

# 启动服务并核对结果：OpenRC 在 crashed/unsupervised 残留状态下 start 会“成功返回但没起来”，
# 所以不能只看 rc-service 的返回码，必须回头确认真实运行状态。
start_service() {
    if [ ! -f "$BIN_FILE" ]; then echo -e "${RED}尚未安装 Sing-box！${PLAIN}"; return 1; fi
    echo -e "${BLUE}正在启动 sing-box...${PLAIN}"
    svc_start
    sleep 2
    if svc_active; then
        echo -e "${GREEN}启动成功！当前状态: $(get_singbox_status)${PLAIN}"
    else
        echo -e "${RED}启动失败：服务仍未运行，请按下面的日志定位（末尾 20 行）：${PLAIN}"
        svc_logs 20
        return 1
    fi
}

restart_service() {
    if [ ! -f "$BIN_FILE" ]; then echo -e "${RED}尚未安装 Sing-box！${PLAIN}"; return 1; fi
    echo -e "${BLUE}正在重启 sing-box...${PLAIN}"
    svc_restart
    sleep 1
    if svc_active; then
        echo -e "${GREEN}重启成功！当前状态: $(get_singbox_status)${PLAIN}"
    else
        echo -e "${RED}重启失败！请查看日志排查：${PLAIN}"
        svc_logs 20
        return 1
    fi
}

read_valid_port() {
    local prompt="$1" default="$2" check_dup="${3:-1}" p
    while true; do
        read -rp "$prompt" p || return 1
        p=${p:-$default}
        if ! [[ "$p" =~ ^[0-9]{1,5}$ ]] || ! validate_port "$((10#$p))"; then
            echo -e "${RED}端口无效！${PLAIN}" >&2
            continue
        fi
        p=$((10#$p))
        if [ "$check_dup" == "1" ] && port_in_use "$p"; then
            echo -e "${RED}端口 $p 已被占用！${PLAIN}" >&2
            continue
        fi
        echo "$p"; return 0
    done
}

# 核心版本是否 >= $1（如 1.12.0）：用 awk 逐段比较，不依赖 GNU sort -V（Alpine 的 busybox sort 没有 -V）
singbox_version_ge() {
    local want="$1" cur
    cur=$("$BIN_FILE" version 2>/dev/null | head -n1 | awk '{print $3}')
    [ -n "$cur" ] || return 1
    awk -v a="$cur" -v b="$want" 'BEGIN{
        sub(/^v/, "", a); sub(/^v/, "", b)
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if ((x[i] + 0) > (y[i] + 0)) exit 0
            if ((x[i] + 0) < (y[i] + 0)) exit 1
        }
        exit 0
    }'
}

save_reality_meta()   { mkdir -p "$META_DIR"; echo "$1|$2" >> "$REALITY_META"; }
get_reality_pubkey()  { [ -f "$REALITY_META" ] && grep -F "$1|" "$REALITY_META" | tail -1 | cut -d'|' -f2; }
remove_reality_meta() {
    [ -f "$REALITY_META" ] || return 0
    grep -vF "$1|" "$REALITY_META" > "${REALITY_META}.tmp" 2>/dev/null
    mv "${REALITY_META}.tmp" "$REALITY_META"
}

# 备注只影响展示与链接片段；旧节点没有记录时沿用 tag。
node_display_name() {
    local name
    name=$(jq -er --arg tag "$1" '.[$tag] | select(type == "string" and length > 0)' "$NODE_NAMES_META" 2>/dev/null) || name="$1"
    printf '%s' "$name"
}

read_node_name() {
    local name
    while true; do
        read -rp "节点备注（最多 80 字，留空使用默认名称）: " name || return 1
        if [ "${#name}" -gt 80 ] || [[ "$name" =~ [[:cntrl:]] ]]; then
            printf '备注不能超过 80 字或包含控制字符。\n' >&2
            continue
        fi
        printf '%s' "$name"
        return 0
    done
}

save_node_name() {
    local tag="$1" name="$2" tmp
    mkdir -p "$META_DIR" || return 1
    tmp=$(mktemp "${NODE_NAMES_META}.tmp.XXXXXX") || return 1
    # 损坏的备注文件不得被覆盖；写入失败保留原文件。
    if { if [ -e "$NODE_NAMES_META" ]; then cat "$NODE_NAMES_META"; else printf '{}'; fi; } |
        jq -e --arg tag "$tag" --arg name "$name" '
            if type != "object" then error("备注文件必须是对象")
            elif $name == "" then del(.[$tag]) else .[$tag] = $name end
        ' > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$NODE_NAMES_META"; then
        return 0
    fi
    rm -f "$tmp"
    printf '保存节点备注失败，原备注未变。\n' >&2
    return 1
}

node_link_fragment() {
    node_display_name "$1" | jq -sRr '@uri'
}

rename_node() {
    local idx tag name
    idx=$(prompt_delete_index "要修改备注的节点" node)
    [ -n "$idx" ] || return 0
    tag=$(inbound_field "$idx" tag)
    printf '  当前备注: %s\n  内部标识: %s\n' "$(node_display_name "$tag")" "$tag"
    name=$(read_node_name) || return 1
    if save_node_name "$tag" "$name"; then
        printf '  %b备注已更新为：%s（无需重启；已导入客户端的旧名称不会自动更新）%b\n' "$GREEN" "$(node_display_name "$tag")" "$PLAIN"
    else
        return 1
    fi
}

# ==================== 列表选择 ====================
inbound_node_type() {
    local type
    type=$(inbound_field "$1" type)
    # 仅把面板生成的 Shadowsocks 入站列入节点操作。
    if [[ "$type" == shadowsocks && $(inbound_field "$1" tag) == ss2022-* ]]; then
        type=ss2022
    fi
    printf '%s\n' "$type"
}

prompt_delete_index() {
    local title="$1" filter_type="$2"
    local total idxs=() i=0 n=0

    total=$(inbound_count)
    while [ $i -lt "$total" ]; do
        local t
        t=$(inbound_node_type "$i")
        if [ "$t" == "$filter_type" ] || { [ "$filter_type" = node ] && [[ "$t" = vless || "$t" = anytls || "$t" = ss2022 ]]; }; then
            idxs+=("$i")
        fi
        i=$((i+1))
    done

    if [ ${#idxs[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}没有可操作的${title}。${PLAIN}" >&2
        echo ""
        return
    fi

    echo -e "\n  ${CYAN}▌ 请选择${title}${PLAIN}" >&2
    for real in "${idxs[@]}"; do
        n=$((n+1))
        local tag port nt display extra=""
        tag=$(inbound_field "$real" "tag")
        port=$(inbound_field "$real" "listen_port")
        nt=$(inbound_node_type "$real")
        display="$tag"
        case "$nt" in
            vless)  display=$(node_display_name "$tag"); extra=" [VLESS]" ;;
            anytls) display=$(node_display_name "$tag"); extra=" [AnyTLS]" ;;
            ss2022) display=$(node_display_name "$tag"); extra=" [SS2022]" ;;
            direct)
                local rip rp
                rip=$(inbound_field "$real" "override_address")
                rp=$(inbound_field "$real" "override_port")
                extra=" -> ${rip}:${rp}"
                ;;
        esac
        printf '    %b%2s)%b %s%s (端口: %s)\n' "$GREEN" "$n" "$PLAIN" "$display" "$extra" "$port" >&2
    done
    printf '\n' >&2

    local choice
    read -rp "  请输入序号 (0 或回车取消): " choice || { echo ""; return; }
    [[ -z "$choice" || "$choice" == "0" ]] && { echo ""; return; }
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
        echo -e "  ${RED}无效序号！${PLAIN}" >&2
        echo ""
        return
    fi
    echo "${idxs[$((choice-1))]}"
}

# ==================== 系统管理 ====================
install_singbox() {
    echo -e "${BLUE}正在获取最新版 Sing-box...${PLAIN}"
    local tag arch url tmp new_bin old_bin="" bin_dir stage_bin
    tag=$(curl -fsSL --connect-timeout 10 --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | jq -r '.tag_name // empty' 2>/dev/null)
    if [[ -z "$tag" || ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo -e "${RED}获取最新版本失败（GitHub API 限流或网络异常），已取消安装/更新。${PLAIN}"
        return 1
    fi

    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        aarch64|arm64)  arch="arm64" ;;
        armv7l)         arch="armv7" ;;
        *) echo -e "${RED}不支持的架构：$(uname -m)${PLAIN}"; return 1 ;;
    esac

    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${tag#v}-linux-${arch}.tar.gz"
    echo -e "${BLUE}下载: ${url}${PLAIN}"

    tmp=$(mktemp -d /tmp/sb-install-XXXXXX) || return 1
    if ! curl -fSL --connect-timeout 15 --max-time 300 -o "$tmp/sing-box.tar.gz" "$url"; then
        rm -rf -- "$tmp"
        echo -e "${RED}下载失败，原核心未改动。${PLAIN}"
        return 1
    fi
    if ! tar -xzf "$tmp/sing-box.tar.gz" -C "$tmp"; then
        rm -rf -- "$tmp"
        echo -e "${RED}解压失败，原核心未改动。${PLAIN}"
        return 1
    fi

    new_bin="$tmp/sing-box-${tag#v}-linux-${arch}/sing-box"
    if [ ! -f "$new_bin" ]; then
        rm -rf -- "$tmp"
        echo -e "${RED}压缩包内未找到 sing-box 二进制，原核心未改动。${PLAIN}"
        return 1
    fi
    chmod +x "$new_bin"

    # 官方发布的 linux 二进制是 glibc 构建（interpreter /lib64/ld-linux-x86-64.so.2），
    # Alpine 是 musl：不装兼容层直接跑会报 “not found”。这里先在临时目录实测，不行就补 gcompat。
    if ! "$new_bin" version >/dev/null 2>&1; then
        if [ "$OS_FAMILY" = "alpine" ]; then
            echo -e "${YELLOW}官方二进制是 glibc 构建，Alpine（musl）需要 gcompat 兼容层，正在安装...${PLAIN}"
            apk add --no-cache gcompat libc6-compat
        fi
    fi
    if ! "$new_bin" version >/dev/null 2>&1; then
        echo -e "${RED}新二进制无法在当前系统上运行，原核心未改动。${PLAIN}"
        "$new_bin" version 2>&1 | head -3
        if [ "$OS_FAMILY" = "alpine" ]; then
            echo -e "${YELLOW}   Alpine 两条路：1) apk add gcompat libc6-compat；2) 用发行版自带包 apk add sing-box（musl 原生，版本略旧）${PLAIN}"
        fi
        rm -rf -- "$tmp"
        return 1
    fi

    # 若已有配置，先用新二进制校验兼容性，避免升级后配置直接不兼容挂掉
    if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" 2>/dev/null; then
        if ! "$new_bin" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${RED}当前配置与新版本 ${tag} 不兼容，已取消更新（原核心未改动）：${PLAIN}"
            "$new_bin" check -c "$CONFIG_FILE"
            rm -rf -- "$tmp"
            return 1
        fi
    fi

    mkdir -p /etc/sing-box
    bin_dir="${BIN_FILE%/*}"
    if [ -f "$BIN_FILE" ]; then
        old_bin="$tmp/sing-box.old"
        cp -p -- "$BIN_FILE" "$old_bin" || { rm -rf -- "$tmp"; return 1; }
    fi
    stage_bin=$(mktemp "${bin_dir}/.sing-box.new.XXXXXX") || { rm -rf -- "$tmp"; return 1; }
    if ! install -m 755 "$new_bin" "$stage_bin" || ! mv -f -- "$stage_bin" "$BIN_FILE"; then
        rm -f -- "$stage_bin"
        rm -rf -- "$tmp"
        echo -e "${RED}安装二进制失败。${PLAIN}"
        return 1
    fi

    if [ "$INIT_SYS" != "systemd" ] || [ ! -f "$SERVICE_FILE" ]; then
        install_service_file
    fi
    ensure_config
    if svc_restart && sleep 1 && svc_active; then
        rm -rf -- "$tmp"
        echo -e "${GREEN}安装/更新成功！版本: ${tag}${PLAIN}"
        return 0
    fi

    echo -e "${RED}新版本 ${tag} 启动失败！${PLAIN}"
    if [ -n "$old_bin" ] && [ -f "$old_bin" ]; then
        echo -e "${YELLOW}正在回滚到上一版核心...${PLAIN}"
        if install -m 755 "$old_bin" "$BIN_FILE" && svc_restart && sleep 1 && svc_active; then
            echo -e "${YELLOW}已回滚到上一版核心并恢复运行。${PLAIN}"
        else
            echo -e "${RED}回滚后服务仍未运行，请查看日志排查：${PLAIN}"
            svc_logs 20
        fi
    else
        svc_logs 20
    fi
    rm -rf -- "$tmp"
    return 1
}

# 按 init 系统写服务定义：systemd → unit 文件；OpenRC → /etc/init.d + rc-update；
# 两者都没有（容器/精简 rootfs）则给提示，由 svc_ctl 用 nohup 托管。
install_service_file() {
    case "$INIT_SYS" in
        systemd)
            [ -f "$SERVICE_FILE" ] && return 0
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
            svc_daemon_reload
            svc_enable
            ;;
        openrc)
            cat > "$OPENRC_FILE" <<EOF
#!/sbin/openrc-run
# sb-service-rev=$SERVICE_DEF_REV
# Sing-box 服务（OpenRC / Alpine）
# 由 sb 管理面板生成；手动改完请 rc-service sing-box restart

description="Sing-box Service"

command="$BIN_FILE"
command_args="run -C /etc/sing-box"
command_user="root:root"
# 用 supervise-daemon 托管：sing-box 被 OOM 杀掉 / 崩溃后 $RESPAWN_DELAY 秒内自动拉起。
# 注意别改回 command_background="yes"：那种写法进程死了服务会卡在 crashed，
# rc-service start 还会回 “already been started” 假成功（2026-10-11 实测）。
supervisor="supervise-daemon"
respawn_delay="$RESPAWN_DELAY"
respawn_max="0"          # 0 = 不限制重启次数
pidfile="/run/sing-box.pid"
output_log="$SINGBOX_LOG"
error_log="$SINGBOX_LOG"

need_root="yes"

depend() {
    need net
    after firewall
}
EOF
            chmod +x "$OPENRC_FILE"
            svc_enable
            echo -e "${GREEN}已生成 OpenRC 服务：${OPENRC_FILE}（开机自启已加入 default runlevel；崩溃自动拉起）${PLAIN}"
            ;;
        *)
            echo -e "${YELLOW}未检测到 systemd / OpenRC：sing-box 将由 nohup 直接托管（重启后需手动拉起）。${PLAIN}"
            echo -e "   手动启动：nohup $BIN_FILE run -C /etc/sing-box >> $SINGBOX_LOG 2>&1 &"
            ;;
    esac
}

# 旧安装的服务定义升级：老版本面板写的 OpenRC 脚本是 command_background（无 supervisor），
# 进程崩溃后不会自愈、启动还会假成功。检测到旧定义就重写一份（先备份，不重启服务，
# 下次重启即生效），避免必须重装核心才能拿到修复。
ensure_service_def_fresh() {
    [ "$INIT_SYS" = "openrc" ] || return 0
    [ -f "$OPENRC_FILE" ] || return 0
    grep -q "sb-service-rev=$SERVICE_DEF_REV" "$OPENRC_FILE" 2>/dev/null && return 0
    local bak; bak="${OPENRC_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$OPENRC_FILE" "$bak" 2>/dev/null
    install_service_file >/dev/null 2>&1
    echo -e "${YELLOW}已更新 OpenRC 服务定义（旧版缺陷：进程崩溃后不自愈、启动可能假成功）${PLAIN}"
    echo -e "  备份：${bak}；重启一次服务后新定义生效（面板「重启服务」或 rc-service sing-box restart）"
}

uninstall_singbox() {
    local mode="${1:-core}" c config_dir="${CONFIG_FILE%/*}"
    printf '将停止并卸载 Sing-box 核心和服务，并删除 %s（含节点、规则和备份）。防火墙规则不变。\n' "$config_dir"
    if [ "$mode" = full ]; then
        printf '同时删除 %s 和 %s，并退出面板。\n' "$PANEL_FILE" "$PANEL_ALIAS"
    fi
    read -rp '确认卸载？[y/N]: ' c || return 0
    [[ "$c" == y ]] || return 0
    if svc_active || [ -f "$SERVICE_FILE" ] || [ -f "$OPENRC_FILE" ]; then
        if ! svc_stop || svc_active; then
            printf '未能停止服务，未删除脚本或配置。\n' >&2
            return 1
        fi
        svc_disable
    fi
    rm -f -- "$SERVICE_FILE" "$OPENRC_FILE" "$BIN_FILE" || return 1
    if [ "$INIT_SYS" = systemd ]; then
        svc_daemon_reload || return 1
    fi
    rm -rf -- "$config_dir" || return 1
    if [ "$mode" = full ]; then
        rm -f -- "$PANEL_FILE" "$PANEL_ALIAS" || return 1
        printf '已卸载核心、服务、配置和面板。\n'
        exit 0
    fi
    printf '已卸载核心、服务和配置；面板保留。\n'
}

show_service_status() {
    [ ! -f "$BIN_FILE" ] && echo -e "  ${RED}尚未安装 Sing-box！${PLAIN}" && return
    echo -e "\n  ${CYAN}▌ Sing-box 服务状态${PLAIN}"
    svc_status
}

show_full_config() {
    echo -e "\n  ${CYAN}▌ 完整配置文件 (${CONFIG_FILE})${PLAIN}"
    [ -f "$CONFIG_FILE" ] && cat "$CONFIG_FILE" || echo -e "  ${RED}配置文件不存在！${PLAIN}"
}

view_logs() {
    echo -e "\n  ${CYAN}▌ Sing-box 日志 (最近 100 行)${PLAIN}"
    svc_logs 100
    ui_subrule
    read -rp "  是否进入实时日志? (Ctrl+C 退出) [y/N]: " f || return 0
    [[ "$f" =~ ^[Yy]$ ]] && svc_logs_follow
}

# ==================== 节点操作 ====================
add_reality_node() {
    [ ! -f "$BIN_FILE" ] && echo -e "${RED}请先安装 Sing-box！${PLAIN}" && return 1
    ensure_config

    echo -e "\n  ${CYAN}▌ 添加 VLESS-Reality 节点${PLAIN}"
    local port
    port=$(read_valid_port "监听端口 [默认 443]: " 443 1) || return 1

    read -rp "伪装域名 SNI [默认 yahoo.com]: " sni || return 1
    sni=${sni:-yahoo.com}

    echo -e "${BLUE}正在生成密钥对...${PLAIN}"
    local key_output private_key public_key uuid short_id
    key_output=$("$BIN_FILE" generate reality-keypair 2>/dev/null) || { echo -e "${RED}生成 Reality 密钥对失败！${PLAIN}" >&2; return 1; }
    private_key=$(echo "$key_output" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
    public_key=$(echo  "$key_output" | grep "PublicKey"  | awk '{print $2}' | tr -d '"')
    uuid=$("$BIN_FILE" generate uuid 2>/dev/null)
    short_id=$("$BIN_FILE" generate rand 8 --hex 2>/dev/null)
    if [[ -z "$private_key" || -z "$public_key" || -z "$uuid" || -z "$short_id" ]]; then
        echo -e "${RED}生成节点密钥或参数失败！${PLAIN}" >&2
        return 1
    fi

    local tag="vless-reality-$port" name
    name=$(read_node_name) || return 1
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
                   }]' "$CONFIG_FILE") || return 1

    if apply_config_and_restart "$temp_json"; then
        save_reality_meta "$tag" "$public_key"
        save_node_name "$tag" "$name" || printf '节点已创建，但备注保存失败，可稍后重新设置。\n' >&2
        open_firewall_port "$port" || printf '防火墙未能完全放行，请检查 TCP/UDP %s。\n' "$port" >&2
        local ip host
        ip=$(get_public_ip)
        host=$(format_url_host "$ip")
        local link="vless://$uuid@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp#$(node_link_fragment "$tag")"
        printf '节点备注   : %s\n' "$(node_display_name "$tag")"
        echo -e "  ${GREEN}节点添加成功！（已放行防火墙）${PLAIN}"
        declare -F ui_subrule >/dev/null && ui_subrule
        echo -e "  服务器 IP  : ${BLUE}$ip${PLAIN}"
        echo -e "  端口       : ${BLUE}$port${PLAIN}"
        echo -e "  UUID       : ${BLUE}$uuid${PLAIN}"
        echo -e "  公钥 (PK)  : ${BLUE}$public_key${PLAIN}"
        echo -e "  ShortId    : ${BLUE}$short_id${PLAIN}"
        echo -e "  SNI        : ${BLUE}$sni${PLAIN}"
        echo -e "  分享链接   : ${YELLOW}$link${PLAIN}"
        declare -F ui_subrule >/dev/null && ui_subrule

        if command -v qrencode &>/dev/null; then
            read -rp "  是否显示二维码？[y/N]: " show_qr || return 0
            if [[ "$show_qr" =~ ^[Yy]$ ]]; then
                echo -e "  ${BLUE}二维码:${PLAIN}"
                qrencode -t ANSIUTF8 "$link"
            fi
        fi
    else
        return 1
    fi
}

add_anytls_node() {
    [ ! -f "$BIN_FILE" ] && echo -e "${RED}请先安装 Sing-box！${PLAIN}" && return 1
    ensure_config
    if ! singbox_version_ge 1.12.0; then
        echo -e "${RED}当前核心不支持 AnyTLS（需要 sing-box >= 1.12.0）。${PLAIN}"
        echo -e "${YELLOW}请先到「系统管理 -> 安装 / 更新 Sing-box 核心」升级再来。${PLAIN}"
        return 1
    fi

    echo -e "\n  ${CYAN}▌ 添加 AnyTLS-Reality 节点${PLAIN}"
    local port
    port=$(read_valid_port "监听端口 [默认 8444]: " 8444 1) || return 1

    read -rp "伪装域名 SNI [默认 yahoo.com]: " sni || return 1
    sni=${sni:-yahoo.com}

    echo -e "${BLUE}正在生成密钥对与密码...${PLAIN}"
    local key_output private_key public_key password short_id
    key_output=$("$BIN_FILE" generate reality-keypair 2>/dev/null) || { echo -e "${RED}生成 Reality 密钥对失败！${PLAIN}" >&2; return 1; }
    private_key=$(echo "$key_output" | grep "PrivateKey" | awk '{print $2}' | tr -d '"')
    public_key=$(echo  "$key_output" | grep "PublicKey"  | awk '{print $2}' | tr -d '"')
    # 32 位十六进制：不含需要 URL 转义的字符，可直接拼进 anytls:// 分享链接
    password=$("$BIN_FILE" generate rand 16 --hex 2>/dev/null)
    short_id=$("$BIN_FILE" generate rand 8 --hex 2>/dev/null)
    if [[ -z "$private_key" || -z "$public_key" || -z "$password" || -z "$short_id" ]]; then
        echo -e "${RED}生成节点密钥或密码失败！${PLAIN}" >&2
        return 1
    fi

    local tag="anytls-reality-$port" name
    name=$(read_node_name) || return 1
    local temp_json
    temp_json=$(jq --argjson port "$port" --arg pw "$password" --arg pk "$private_key" \
                   --arg sni "$sni" --arg sid "$short_id" --arg tag "$tag" \
                   '.inbounds += [{
                       "type": "anytls", "tag": $tag, "listen": "::", "listen_port": $port,
                       "users": [{"password": $pw}],
                       "tls": {
                           "enabled": true, "server_name": $sni,
                           "reality": {
                               "enabled": true, "private_key": $pk, "short_id": [$sid],
                               "handshake": {"server": $sni, "server_port": 443}
                           }
                       }
                   }]' "$CONFIG_FILE") || return 1

    if apply_config_and_restart "$temp_json"; then
        save_reality_meta "$tag" "$public_key"
        save_node_name "$tag" "$name" || printf '节点已创建，但备注保存失败，可稍后重新设置。\n' >&2
        open_firewall_port "$port" || printf '防火墙未能完全放行，请检查 TCP/UDP %s。\n' "$port" >&2
        local ip host
        ip=$(get_public_ip)
        host=$(format_url_host "$ip")
        local link="anytls://$password@$host:$port/?security=reality&sni=$sni&fp=chrome&pbk=$public_key&sid=$short_id#$(node_link_fragment "$tag")"
        printf '节点备注   : %s\n' "$(node_display_name "$tag")"
        echo -e "  ${GREEN}节点添加成功！（已放行防火墙）${PLAIN}"
        declare -F ui_subrule >/dev/null && ui_subrule
        echo -e "  服务器 IP  : ${BLUE}$ip${PLAIN}"
        echo -e "  端口       : ${BLUE}$port${PLAIN}"
        echo -e "  密码       : ${BLUE}$password${PLAIN}"
        echo -e "  公钥 (PK)  : ${BLUE}$public_key${PLAIN}"
        echo -e "  ShortId    : ${BLUE}$short_id${PLAIN}"
        echo -e "  SNI        : ${BLUE}$sni${PLAIN}"
        echo -e "  分享链接   : ${YELLOW}$link${PLAIN}"
        declare -F ui_subrule >/dev/null && ui_subrule
        echo -e "${YELLOW}客户端要求：AnyTLS + Reality 需 sing-box 内核客户端（官方 sing-box /${PLAIN}"
        echo -e "${YELLOW}   Karing / Hiddify / v2rayN），或小火箭 Shadowrocket 2.2.65+（类型选 AnyTLS，${PLAIN}"
        echo -e "${YELLOW}   TLS 开启后填 SNI / 公钥 / 短 ID）；mihomo 不支持该组合。${PLAIN}"

        if command -v qrencode &>/dev/null; then
            read -rp "  是否显示二维码？[y/N]: " show_qr || return 0
            if [[ "$show_qr" =~ ^[Yy]$ ]]; then
                echo -e "  ${BLUE}二维码:${PLAIN}"
                qrencode -t ANSIUTF8 "$link"
            fi
        fi
    else
        return 1
    fi
}

# SIP002 要求 AEAD-2022 使用 URI 转义的明文 userinfo，而非整体 Base64。
ss2022_link() {
    local method="$1" password="$2" host="$3" port="$4" tag="$5" encoded
    encoded=$(jq -rn --arg p "$password" '$p | @uri') || return 1
    host=$(format_url_host "$host")
    printf 'ss://%s:%s@%s:%s#%s\n' "$method" "$encoded" "$host" "$port" "$(node_link_fragment "$tag")"
}

ss2022_count() {
    jq '[.inbounds[]? | select(.type == "shadowsocks" and ((.tag // "") | startswith("ss2022-")))] | length' "$CONFIG_FILE"
}

add_ss2022_node() {
    if [ ! -x "$BIN_FILE" ]; then
        printf '请先安装 Sing-box 核心。\n' >&2
        return 1
    fi
    ensure_config
    local port name tag password method=2022-blake3-aes-256-gcm temp_json ip link show_qr
    port=$(read_valid_port '监听端口 [默认 8388]: ' 8388 1) || return 0
    name=$(read_node_name) || return 1
    tag="ss2022-$port"
    password=$("$BIN_FILE" generate rand 32 --base64) || return 1
    if ! [[ "$password" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        printf '生成 SS2022 密钥失败。\n' >&2
        return 1
    fi
    temp_json=$(jq --argjson port "$port" --arg tag "$tag" --arg method "$method" \
        --arg pw "$password" '.inbounds += [{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:$method,password:$pw}]' "$CONFIG_FILE") || return 1
    apply_config_and_restart "$temp_json" || return 1
    save_node_name "$tag" "$name" || printf '节点已保存，但备注保存失败。\n' >&2
    open_firewall_port "$port" || printf '防火墙未能完全放行，请检查 TCP/UDP %s。\n' "$port" >&2
    ip=$(get_public_ip)
    if [[ "$ip" == 127.0.0.1 || -z "$ip" ]]; then
        printf '节点已保存；未获取到公网 IP，请稍后在节点管理中查看链接。\n'
        return 0
    fi
    link=$(ss2022_link "$method" "$password" "$ip" "$port" "$tag") || return 1
    printf 'SS2022 | %s | 端口: %s\n分享链接: %s\n' "$(node_display_name "$tag")" "$port" "$link"
    if command -v qrencode &>/dev/null; then
        read -rp '  显示二维码？[y/N]: ' show_qr || return 0
        [[ "$show_qr" =~ ^[Yy]$ ]] && qrencode -t ANSIUTF8 "$link"
    fi
    return 0
}

view_node_links() {
    ensure_config
    local ip host
    ip=$(get_public_ip)
    host=$(format_url_host "$ip")
    echo -e "\n  ${CYAN}▌ 节点分享链接${PLAIN}"
    echo -e "  ${BLUE}服务器 IP: $ip${PLAIN}"
    declare -F ui_subrule >/dev/null && ui_subrule

    local records
    records=$(jq -r '
      def rows(kind):
        .inbounds[]? | select(
          if kind == "ss2022" then (.type == "shadowsocks" and ((.tag // "") | startswith("ss2022-")))
          else .type == kind end
        ) | [
          kind,
          (.tag // ""),
          ((.listen_port // "") | tostring),
          (if kind == "vless" then (.users[0].uuid // "")
           elif kind == "anytls" then (.users[0].password // "")
           else (.method // "") end),
          (if kind == "ss2022" then (.password // "")
           else (.tls.server_name // "") end),
          (if kind == "ss2022" then ""
           else (.tls.reality.short_id[0] // "") end)
        ] | join("\u001f");
      (rows("vless"), rows("anytls"), rows("ss2022"))
    ' "$CONFIG_FILE" 2>/dev/null) || return 1

    if [ -z "$records" ]; then
        echo -e "${YELLOW}当前没有可分享的节点。${PLAIN}"
        return
    fi

    local links=() tags=() idx=0
    local kind tag port f4 f5 f6 display pbk link
    while IFS=$'\x1f' read -r kind tag port f4 f5 f6; do
        [ -n "$kind" ] || continue
        display=$(node_display_name "$tag")
        case "$kind" in
            vless)
                idx=$((idx+1))
                pbk=$(get_reality_pubkey "$tag")
                link="vless://$f4@$host:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$f5&fp=chrome&pbk=$pbk&sid=$f6&type=tcp#$(node_link_fragment "$tag")"
                links+=("$link")
                tags+=("$display")
                printf '  [%s] VLESS-Reality | %s | 端口: %s\n' "$idx" "$display" "$port"
                echo -e "      SNI : $f5  |  ShortId: $f6"
                echo -e "      公钥: ${pbk:-未记录}"
                echo -e "      链接: ${YELLOW}$link${PLAIN}"
                declare -F ui_subrule >/dev/null && ui_subrule
                ;;
            anytls)
                idx=$((idx+1))
                pbk=$(get_reality_pubkey "$tag")
                link="anytls://$f4@$host:$port/?security=reality&sni=$f5&fp=chrome&pbk=$pbk&sid=$f6#$(node_link_fragment "$tag")"
                links+=("$link")
                tags+=("$display")
                printf '  [%s] AnyTLS-Reality | %s | 端口: %s\n' "$idx" "$display" "$port"
                echo -e "      SNI : $f5  |  ShortId: $f6"
                echo -e "      公钥: ${pbk:-未记录}"
                echo -e "      密码: $f4"
                echo -e "      链接: ${YELLOW}$link${PLAIN}"
                declare -F ui_subrule >/dev/null && ui_subrule
                ;;
            ss2022)
                link=$(ss2022_link "$f4" "$f5" "$ip" "$port" "$tag") || continue
                links+=("$link")
                tags+=("$display")
                idx=$((idx+1))
                printf '  [%s] SS2022 | %s | 端口: %s\n      链接: %s\n' "$idx" "$display" "$port" "$link"
                declare -F ui_subrule >/dev/null && ui_subrule
                ;;
        esac
    done <<< "$records"

    if command -v qrencode &>/dev/null && [ "${#links[@]}" -gt 0 ]; then
        read -rp "  输入要显示二维码的序号 (0 或回车跳过): " qr_idx || return 0
        if [[ "$qr_idx" =~ ^[0-9]+$ ]] && [ "$qr_idx" -ge 1 ] && [ "$qr_idx" -le "${#links[@]}" ]; then
            local ridx=$((qr_idx - 1))
            printf '  二维码 [%s]:\n' "${tags[$ridx]}"
            qrencode -t ANSIUTF8 "${links[$ridx]}"
        fi
    fi
}

delete_node() {
    ensure_config
    local real_idx del_tag del_display yn
    real_idx=$(prompt_delete_index "要删除的节点" node)
    [ -z "$real_idx" ] && return 0

    del_tag=$(inbound_field "$real_idx" "tag")
    del_display=$(node_display_name "$del_tag")
    read -rp "  确认删除节点 [${del_display}]？[y/N]: " yn || return 0
    if ! [[ "$yn" =~ ^[Yy]$ ]]; then
        printf '  %b已取消。%b\n' "$YELLOW" "$PLAIN"
        return 0
    fi

    local temp_json
    temp_json=$(jq --argjson i "$real_idx" --arg tag "$del_tag" '
        .inbounds |= (.[:$i] + .[$i+1:]) |
        if .route.rules then
            .route.rules |= [.[] | select((.inbound? // []) | (if type == "array" then index($tag) == null else . != $tag end))]
        else . end
    ' "$CONFIG_FILE") || return 1

    if apply_config_and_restart "$temp_json"; then
        remove_reality_meta "$del_tag"
        if [ -e "$NODE_NAMES_META" ]; then
            save_node_name "$del_tag" "" || printf '节点已删除，但旧备注清理失败。\n' >&2
        fi
        echo -e "  ${GREEN}节点 [${del_display}] 已删除。${PLAIN}"
    fi
}

# ==================== 端口转发 ====================
add_port_forward() {
    [ ! -f "$BIN_FILE" ] && echo -e "${RED}请先安装 Sing-box！${PLAIN}" && return 1
    ensure_config

    echo -e "\n  ${CYAN}▌ 添加 TCP/UDP 端口转发${PLAIN}"
    local local_port remote_ip remote_port
    local_port=$(read_valid_port "本机监听端口: " "" 1) || return 1
    read -rp "目标远程 IP: " remote_ip || return 1
    [[ -z "$remote_ip" ]] && echo -e "${RED}IP 不能为空！${PLAIN}" && return 1
    remote_port=$(read_valid_port "目标远程端口: " "" 0) || return 1

    local tag="forward-$local_port-to-$remote_port"

    local temp_json
    temp_json=$(jq --argjson lport "$local_port" --arg rip "$remote_ip" \
                   --argjson rport "$remote_port" --arg tag "$tag" \
                   '.inbounds += [{
                       "type": "direct", "tag": $tag, "listen": "::",
                       "listen_port": $lport,
                       "override_address": $rip, "override_port": $rport
                   }] |
                    .route = (.route // {}) |
                    .route.rules = ((.route.rules // []) + [{"inbound": [$tag], "outbound": "direct"}])' \
                   "$CONFIG_FILE") || return 1

    if apply_config_and_restart "$temp_json"; then
        open_firewall_port "$local_port" || printf '防火墙未能完全放行，请检查 TCP/UDP %s。\n' "$local_port" >&2
        echo -e "${GREEN}转发成功：本机 [${local_port}] -> ${remote_ip}:${remote_port}${PLAIN}"
    fi
}

view_port_forwards() {
    ensure_config
    echo -e "\n  ${CYAN}▌ 端口转发列表${PLAIN}"
    ui_subrule

    local total
    total=$(count_by_type "direct")
    if [ "$total" -eq 0 ]; then
        echo -e "  ${YELLOW}当前没有端口转发。${PLAIN}"
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
            printf '    %b%2s)%b 监听 %b%s%b -> %s:%s  %b(%s)%b\n' "$GREEN" "$idx" "$PLAIN" "$BLUE" "$lp" "$PLAIN" "$rip" "$rp" "$DIM" "$tag" "$PLAIN"
        fi
        i=$((i+1))
    done
    ui_subrule
}

delete_port_forward() {
    ensure_config
    local total
    total=$(count_by_type "direct")
    if [ "$total" -eq 0 ]; then
        echo -e "  ${YELLOW}当前没有端口转发。${PLAIN}"; return
    fi

    local real_idx del_tag yn
    real_idx=$(prompt_delete_index "要删除的端口转发" "direct")
    [ -z "$real_idx" ] && return 0

    del_tag=$(inbound_field "$real_idx" "tag")
    read -rp "  确认删除转发 [${del_tag}]？[y/N]: " yn || return 0
    if ! [[ "$yn" =~ ^[Yy]$ ]]; then
        printf '  %b已取消。%b\n' "$YELLOW" "$PLAIN"
        return 0
    fi

    local temp_json
    temp_json=$(jq --argjson i "$real_idx" --arg tag "$del_tag" '
                   .inbounds |= (.[:$i] + .[$i+1:]) |
                   if .route.rules then
                       .route.rules |= [.[] | select((.inbound? // []) | (if type == "array" then index($tag) == null else . != $tag end))]
                   else . end' \
                   "$CONFIG_FILE") || return 1

    if apply_config_and_restart "$temp_json"; then
        echo -e "  ${GREEN}转发 [${del_tag}] 已删除。${PLAIN}"
    fi
}

# ==================== 配置诊断与回滚 ====================
diagnose_config() {
    local c cc
    while true; do
        local cfg_stat="${RED}不存在${PLAIN}"
        if [ -f "$CONFIG_FILE" ]; then
            local size
            size=$(wc -c < "$CONFIG_FILE" 2>/dev/null)
            if jq empty "$CONFIG_FILE" 2>/dev/null; then
                cfg_stat="${GREEN}有效${PLAIN}（${size}B · 入站 $(inbound_count)）"
            else
                cfg_stat="${RED}JSON 语法错误${PLAIN}（${size}B）"
            fi
        fi
        menu_header "配置管理与回滚" "$CONFIG_FILE" "$cfg_stat"
        ui_kv "入站明细" "VLESS $(count_by_type vless) · AnyTLS $(count_by_type anytls) · SS2022 $(ss2022_count 2>/dev/null || echo 0) · 转发 $(count_by_type direct)"
        ui_kv "上次备份" "$([ -f "${CONFIG_FILE}.bak" ] && echo "${GREEN}可用（上一版有效配置）${PLAIN}" || echo "${YELLOW}暂无备份${PLAIN}")"
        menu_section "查看与编辑"
        menu_option 1 "查看原始 JSON 配置"
        menu_option 2 "查看 Reality 公钥元数据"
        menu_option 3 "手动编辑并校验配置"
        menu_section "恢复与重置"
        menu_option 4 "回滚到上次有效备份"
        menu_option 5 "重置为空配置（自动备份旧文件）"
        menu_back
        read_menu_choice "请选择 [0-5]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) ui_title "原始 JSON ($CONFIG_FILE)"; cat "$CONFIG_FILE" 2>/dev/null; pause ;;
            2) ui_title "Reality 元数据"; [ -f "$REALITY_META" ] && cat "$REALITY_META" || echo -e "  ${YELLOW}无${PLAIN}"; pause ;;
            3) if [ ! -x "$BIN_FILE" ]; then
                   echo -e "  ${RED}请先安装 Sing-box 核心！${PLAIN}"
               else
                   local editor="vi" edit_tmp edited_json
                   command -v nano &>/dev/null && editor="nano"
                   ensure_config
                   if edit_tmp=$(mktemp "${CONFIG_FILE%/*}/.sb-edit.XXXXXX") && install -m 600 "$CONFIG_FILE" "$edit_tmp"; then
                       "$editor" "$edit_tmp"
                       if cmp -s "$CONFIG_FILE" "$edit_tmp"; then
                           rm -f -- "$edit_tmp"
                           echo -e "  ${YELLOW}配置未改动。${PLAIN}"
                       elif ! jq empty "$edit_tmp" 2>/dev/null; then
                           rm -f -- "$edit_tmp"
                           echo -e "  ${RED}JSON 语法错误，已放弃更改，原配置未改动。${PLAIN}"
                       else
                           edited_json=$(cat "$edit_tmp")
                           rm -f -- "$edit_tmp"
                           if apply_config_and_restart "$edited_json"; then
                               echo -e "  ${GREEN}配置校验通过，已保存并重启服务。${PLAIN}"
                           fi
                       fi
                   else
                       rm -f -- "${edit_tmp:-}"
                       echo -e "  ${RED}准备临时编辑文件失败。${PLAIN}"
                   fi
               fi
               pause ;;
            4) read -rp "  确定要回滚到上次有效备份吗？[y/N]: " cc || continue
               if [[ "$cc" =~ ^[Yy]$ ]]; then
                   rollback_config
                   pause
               fi ;;
            5) read -rp "  是否备份并重置为空配置？[y/N]: " cc || continue
               if [[ "$cc" =~ ^[Yy]$ ]]; then
                   cp "$CONFIG_FILE" "${CONFIG_FILE}.broken.$(date +%s)" 2>/dev/null
                   rm -f "$CONFIG_FILE"
                   ensure_config
                   echo -e "  ${GREEN}已重置（旧文件已备份）${PLAIN}"
                   pause
               fi ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

# ==================== 子菜单 ====================
menu_system() {
    local c
    while true; do
        menu_header "服务与核心管理" "Sing-box 核心、服务运行与日志" "$(get_singbox_status)"
        menu_section "核心与服务"
        menu_option 1 "安装 / 更新 Sing-box 核心"
        menu_option 2 "启动服务"
        menu_option 3 "停止服务"
        menu_option 4 "重启服务"
        menu_section "运行诊断"
        menu_option 5 "查看服务状态"
        menu_option 6 "查看运行日志"
        menu_option 7 "配置管理与回滚（查看 / 编辑 / 备份）"
        menu_section "卸载（危险操作）"
        menu_option 8 "卸载 Sing-box（保留 sb 面板）"
        menu_option 9 "彻底卸载（核心、配置与 sb 面板）"
        menu_back
        read_menu_choice "请选择 [0-9]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) install_singbox; pause ;;
            2) start_service; pause ;;
            3) svc_stop && echo -e "  ${YELLOW}已停止${PLAIN}"; pause ;;
            4) restart_service; pause ;;
            5) show_service_status; pause ;;
            6) view_logs; pause ;;
            7) diagnose_config ;;
            8) uninstall_singbox; pause ;;
            9) uninstall_singbox full; pause ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

menu_nodes() {
    local c
    while true; do
        menu_header "节点管理" "VLESS-Reality / AnyTLS-Reality / SS2022" "$(nodes_summary_line)"
        menu_section "日常操作"
        menu_option 1 "查看节点链接 / 二维码"
        menu_option 2 "修改节点备注（无需重启）"
        menu_option 3 "删除节点"
        menu_section "添加节点"
        menu_option 4 "添加 VLESS-Reality 节点"
        menu_option 5 "添加 AnyTLS-Reality 节点"
        menu_option 6 "添加 Shadowsocks 2022 节点"
        menu_back
        read_menu_choice "请选择 [0-6]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) view_node_links; pause ;;
            2) rename_node; pause ;;
            3) delete_node; pause ;;
            4) add_reality_node; pause ;;
            5) add_anytls_node; pause ;;
            6) add_ss2022_node; pause ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

menu_forward() {
    local c fw_count fw_stat
    while true; do
        fw_count=$(count_by_type direct)
        if [ "$fw_count" -gt 0 ]; then
            fw_stat="${GREEN}共 ${fw_count} 条转发规则${PLAIN}"
        else
            fw_stat="${YELLOW}暂无转发规则${PLAIN}"
        fi
        menu_header "端口转发" "TCP / UDP 端口转发规则" "$fw_stat"
        menu_section "转发操作"
        menu_option 1 "查看转发规则"
        menu_option 2 "添加端口转发"
        menu_option 3 "删除转发规则"
        menu_back
        read_menu_choice "请选择 [0-3]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) view_port_forwards; pause ;;
            2) add_port_forward; pause ;;
            3) delete_port_forward; pause ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

# ==================== 实用小工具 ====================
# 参考 VPSBox (github.com/vmenzo/VPSBox) 的工具集思路：流媒体检测 / DNS / 防火墙

_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"

# ---------- 流媒体解锁检测（本机出口）----------
media_check_quick() {
    echo -e "\n  ${CYAN}▌ 流媒体解锁检测（本机直连出口）${PLAIN}"
    echo -e "  ${BLUE}检测中，请稍候...${PLAIN}"

    # 出口 IP / 地区
    local geo ip country org
    geo=$(curl -s --max-time 10 https://ipinfo.io/json 2>/dev/null)
    ip=$(jq -r '.ip // "?"' <<<"$geo" 2>/dev/null)
    country=$(jq -r '.country // "?"' <<<"$geo" 2>/dev/null)
    org=$(jq -r '.org // "?"' <<<"$geo" 2>/dev/null)
    ui_subrule
    echo -e "  出口 IP : ${BLUE}${ip}${PLAIN}   地区: ${BLUE}${country}${PLAIN}"
    echo -e "  ISP     : ${org}"
    ui_subrule

    # ChatGPT / OpenAI
    local loc comp gpt
    loc=$(curl -s --max-time 10 "https://chat.openai.com/cdn-cgi/trace" 2>/dev/null | sed -n 's/^loc=\([A-Za-z]*\).*/\1/p' | head -1)
    comp=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "https://api.openai.com/compliance/cookie_requirements" -H "authorization: Bearer x" 2>/dev/null)
    if [[ -n "$loc" && "$comp" == "200" ]]; then
        gpt="${GREEN}可用${PLAIN} (地区: $loc)"
    elif [[ -n "$loc" ]]; then
        gpt="${YELLOW}网页可访问但 App/API 受限${PLAIN} (地区: $loc)"
    else
        gpt="${RED}不可用/超时${PLAIN}"
    fi
    printf ' %-12s: %b\n' "ChatGPT" "$gpt"

    # YouTube Premium 地区
    local yt ytc
    ytc=$(curl -s --max-time 12 -A "$_UA" -H "Accept-Language: en-US" "https://www.youtube.com/premium" 2>/dev/null | sed -n 's/.*"GL":"\([A-Z][A-Z]\)".*/\1/p' | head -1)
    if [[ -n "$ytc" ]]; then yt="${GREEN}可用${PLAIN} (地区: $ytc)"; else yt="${RED}不可用/超时${PLAIN}"; fi
    printf ' %-12s: %b\n' "YouTube" "$yt"

    # Netflix：非自制剧 81280792  200=完整解锁 / 404=仅自制剧 / 其它=不可用
    local nf nfc
    nfc=$(curl -sL --max-time 12 -A "$_UA" -o /dev/null -w "%{http_code}" "https://www.netflix.com/title/81280792" 2>/dev/null)
    case "$nfc" in
        200) nf="${GREEN}完整解锁${PLAIN}" ;;
        404) nf="${YELLOW}仅自制剧${PLAIN}" ;;
        *)   nf="${RED}不可用 (http=$nfc)${PLAIN}" ;;
    esac
    printf ' %-12s: %b\n' "Netflix" "$nf"

    # Disney+
    local dp dpc
    dpc=$(curl -s --max-time 12 -A "$_UA" -o /dev/null -w "%{http_code}" "https://www.disneyplus.com/" 2>/dev/null)
    if [[ "$dpc" == "200" ]]; then dp="${GREEN}可访问${PLAIN}"; else dp="${RED}不可用 (http=$dpc)${PLAIN}"; fi
    printf ' %-12s: %b\n' "Disney+" "$dp"

    # TikTok 地区
    local tt ttc
    ttc=$(curl -s --max-time 12 -A "$_UA" "https://www.tiktok.com/" 2>/dev/null | sed -n 's/.*"region":"\([A-Z][A-Z]\)".*/\1/p' | head -1)
    if [[ -n "$ttc" ]]; then tt="${GREEN}可用${PLAIN} (地区: $ttc)"; else tt="${YELLOW}未获取到地区${PLAIN}"; fi
    printf '  %-10s: %b\n' "TikTok" "$tt"
    ui_subrule
    echo -e "  ${YELLOW}提示：此结果为服务器本机直连出口。可在「WARP / SOCKS5 出口与分流」为节点流量设置规则。${PLAIN}"
}

media_check_full() {
    local c rc tmp
    echo -e "\n  ${CYAN}▌ IP 质量与流媒体解锁体检（xykt/IPQuality 交互界面）${PLAIN}"
    echo "涵盖 IP 基础信息、风控评分、常见流媒体 / AI 解锁、邮局连通性与黑名单检测。"
    echo -e "${YELLOW}将以 root 权限下载并运行外部脚本，需能访问 GitHub / Check.Place；缺少依赖时脚本可能提示安装系统包。${PLAIN}"
    read -rp "继续？[y/N]: " c || return 0
    [[ "$c" =~ ^[Yy]$ ]] || return 0
    (
        exec 200>&-
        tmp=$(mktemp -d) || exit 1
        trap 'rm -rf -- "$tmp"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if ! curl --proto '=https' --proto-redir '=https' -fSL \
            --connect-timeout 15 --max-time 120 --retry 2 \
            https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh -o "$tmp/ip.sh"; then
            echo -e "${RED}检测脚本下载失败，未执行。${PLAIN}" >&2
            exit 1
        fi
        if [[ ! -s "$tmp/ip.sh" ]] || ! bash -n "$tmp/ip.sh"; then
            echo -e "${RED}检测脚本内容为空或语法检查失败，未执行。${PLAIN}" >&2
            exit 1
        fi
        bash "$tmp/ip.sh" -M
    )
    rc=$?
    if (( rc != 0 )); then
        echo -e "${YELLOW}IP 质量体检脚本未正常完成（退出码 ${rc}），已返回面板。${PLAIN}"
    fi
    return "$rc"
}

# IPv6 使用独立目标，不能套用 BestTrace 的 IPv4 线路识别规则。
besttrace_ipv6() {
    local choice target answer rc=0 failed=0 tmp i
    local -a names=("电信" "联通" "移动" "教育网")
    local -a targets=("240e:4c:4008::1" "2408:8899::8" "2409:8088::a" "2001:da8::666")
    echo "IPv6 回程：1) 三网及教育网  2) 电信  3) 联通  4) 移动  5) 教育网  6) 自定义  0) 返回"
    echo "预设目标为国内运营商 DNS；仅显示实际路由，不套用 IPv4 线路评级。"
    echo "需要本机有可用 IPv6 出口；隧道出口测到的是隧道后的路径。"
    read -rp "请选择 [0-6]: " choice || return 0
    case "$choice" in
        0|'') return 0 ;;
        1) ;;
        2|3|4|5) i=$((choice - 2)); names=("${names[i]}"); targets=("${targets[i]}") ;;
        6)
            read -rp "请输入目标 IPv6 地址（不带方括号）: " target || return 0
            # 只收地址，不接受主机名、选项或带 shell 语法的输入。
            if ! python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$target" 2>/dev/null; then
                echo "IPv6 地址无效。"; return 1
            fi
            names=("自定义"); targets=("$target") ;;
        *) echo "无效选项。"; return 1 ;;
    esac
    if ! command -v nexttrace >/dev/null 2>&1; then
        echo "尚未安装 NextTrace，将以 root 权限下载并运行 https://nxtrace.org/nt 安装脚本。"
        read -rp "确认安装 NextTrace？[y/N]: " answer || return 0
        [[ "$answer" =~ ^[Yy]$ ]] || return 0
        (
            exec 200>&-
            tmp=$(mktemp -d) || exit 1
            trap 'rm -rf -- "$tmp"' EXIT
            trap 'exit 130' INT
            trap 'exit 143' TERM
            curl --proto '=https' --proto-redir '=https' -fSL --connect-timeout 15 \
                --max-time 120 --retry 2 https://nxtrace.org/nt -o "$tmp/install.sh" || exit 1
            [[ -s "$tmp/install.sh" ]] && bash -n "$tmp/install.sh" || exit 1
            bash "$tmp/install.sh"
        )
        rc=$?
        if (( rc != 0 )) || ! command -v nexttrace >/dev/null 2>&1; then
            echo "NextTrace 安装未完成，已返回面板。"; return 1
        fi
    fi
    for i in "${!targets[@]}"; do
        printf '\nIPv6 回程：%s [%s]\n' "${names[i]}" "${targets[i]}"
        # 单个目标失败不阻止其余运营商；中断则立即返回。
        ( exec 200>&-; nexttrace -6 "${targets[i]}" -q 1 -M )
        rc=$?
        case "$rc" in
            0) ;;
            130|143) return "$rc" ;;
            *) failed=1; echo "该目标测试失败（退出码 $rc），请检查 IPv6 出口或换自定义目标。" ;;
        esac
    done
    return "$failed"
}

# BestTrace 保持独立子进程，避免上游的变量、exit 和 trap 影响面板。
besttrace_check() {
    local answer rc tmp family
    echo "回程地址族：1) IPv4（BestTrace）  2) IPv6（NextTrace）  0) 返回"
    read -rp "请选择 [1/2/0]: " family || return 0
    case "$family" in
        1) ;;
        2) besttrace_ipv6; return $? ;;
        0|'') return 0 ;;
        *) echo "无效选项。"; return 1 ;;
    esac
    echo -e "\n  ${CYAN}▌ 回程路由测试（BestTrace.sh）${PLAIN}"
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
DNS_BACKUP="$META_DIR/resolv.conf.bak"

show_dns() {
    local ns
    ns=$(awk '/^nameserver[[:space:]]+/{out = (out ? out ", " : "") $2} END{print out}' /etc/resolv.conf 2>/dev/null)
    if [ -n "$ns" ]; then
        printf '  %b当前 DNS%b  %b%s%b\n' "$DIM" "$PLAIN" "$BLUE" "$ns" "$PLAIN"
    else
        printf '  %b当前 DNS%b  %b未配置 nameserver%b\n' "$DIM" "$PLAIN" "$YELLOW" "$PLAIN"
    fi
    if [ "$INIT_SYS" = "systemd" ] && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        printf '  %b提示：systemd-resolved 正在运行，直改 resolv.conf 可能被覆盖。%b\n' "$YELLOW" "$PLAIN"
    fi
}

set_dns() {
    local servers="$1" label="$2" s tmp
    local -a list=()
    read -r -a list <<< "$servers"
    if [ "${#list[@]}" -eq 0 ]; then
        echo -e "${RED}未提供有效 DNS 地址。${PLAIN}" >&2
        return 1
    fi
    for s in "${list[@]}"; do
        if ! is_valid_ip "$s"; then
            echo -e "${RED}无效的 DNS IP 地址：${s}（原配置未改动）${PLAIN}" >&2
            return 1
        fi
    done
    mkdir -p "$META_DIR" || return 1
    # 仅在首次切换前备份原始 resolv.conf，避免多次切换冲掉初始备份
    if [ ! -f "$DNS_BACKUP" ] && [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$DNS_BACKUP" 2>/dev/null
    fi
    tmp=$(mktemp) || return 1
    {
        echo "# generated by sb $(date '+%F %T')"
        for s in "${list[@]}"; do printf 'nameserver %s\n' "$s"; done
    } > "$tmp"
    if ! cat "$tmp" > /etc/resolv.conf; then
        rm -f -- "$tmp"
        echo -e "${RED}写入 /etc/resolv.conf 失败。${PLAIN}" >&2
        return 1
    fi
    rm -f -- "$tmp"
    echo -e "${GREEN}已切换 DNS 为：$label${PLAIN}"
    show_dns
}

menu_dns() {
    local c custom
    while true; do
        menu_header "DNS 设置" "/etc/resolv.conf 解析配置"
        show_dns
        menu_section "常用 DNS"
        menu_option 1 "Cloudflare（1.1.1.1 / 1.0.0.1）"
        menu_option 2 "Google（8.8.8.8 / 8.8.4.4）"
        menu_option 3 "Quad9（9.9.9.9 / 149.112.112.112）"
        menu_option 4 "AliDNS（223.5.5.5 / 223.6.6.6）"
        menu_section "高级"
        menu_option 5 "自定义 DNS（空格分隔多个）"
        menu_option 6 "恢复原始 resolv.conf 备份"
        menu_back
        read_menu_choice "请选择 [0-6]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) set_dns "1.1.1.1 1.0.0.1 2606:4700:4700::1111" "Cloudflare"; pause ;;
            2) set_dns "8.8.8.8 8.8.4.4 2001:4860:4860::8888" "Google"; pause ;;
            3) set_dns "9.9.9.9 149.112.112.112" "Quad9"; pause ;;
            4) set_dns "223.5.5.5 223.6.6.6" "AliDNS"; pause ;;
            5) read -rp "  输入 DNS（空格分隔，回车取消）: " custom || continue
               if [[ -n "$custom" ]]; then
                   set_dns "$custom" "自定义"
                   pause
               fi ;;
            6) if [ -f "$DNS_BACKUP" ]; then
                   cp "$DNS_BACKUP" /etc/resolv.conf
                   echo -e "  ${GREEN}已恢复备份。${PLAIN}"
                   show_dns
               else
                   echo -e "  ${YELLOW}无备份。${PLAIN}"
               fi
               pause ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

# ---------- 防火墙 (ufw) 设置 ----------
detect_ssh_ports() {
    local ports=() p conn_port sshd_bin="" cfg_found=0
    if [ -n "${SSH_CONNECTION:-}" ]; then
        conn_port=$(awk '{print $4}' <<< "$SSH_CONNECTION")
        if [[ "$conn_port" =~ ^[0-9]{1,5}$ ]] && validate_port "$((10#$conn_port))"; then
            ports+=("$((10#$conn_port))")
        fi
    fi
    sshd_bin=$(command -v sshd 2>/dev/null || { [ -x /usr/sbin/sshd ] && echo /usr/sbin/sshd; })
    if [ -n "$sshd_bin" ]; then
        while read -r p; do
            if [[ "$p" =~ ^[0-9]{1,5}$ ]] && validate_port "$((10#$p))"; then
                ports+=("$((10#$p))")
                cfg_found=1
            fi
        done < <("$sshd_bin" -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}')
    fi
    if [ "$cfg_found" -eq 0 ]; then
        local cfg_files=() f
        for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
            [ -r "$f" ] && cfg_files+=("$f")
        done
        if [ "${#cfg_files[@]}" -gt 0 ]; then
            while read -r p; do
                if [[ "$p" =~ ^[0-9]{1,5}$ ]] && validate_port "$((10#$p))"; then
                    ports+=("$((10#$p))")
                fi
            done < <(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ {print $2}' "${cfg_files[@]}" 2>/dev/null)
        fi
    fi
    if [ "${#ports[@]}" -eq 0 ]; then
        ports=(22)
    fi
    printf '%s\n' "${ports[@]}" | sort -un | awk '{out = (out ? out " " : "") $0} END {print out}'
}

is_ssh_port() {
    local target="$1" ssh_ports
    ssh_ports=$(detect_ssh_ports)
    case " $ssh_ports " in
        *" $target "*) return 0 ;;
        *) return 1 ;;
    esac
}

menu_firewall() {
    if ! command -v ufw &>/dev/null; then
        echo -e "  ${YELLOW}未安装 ufw，正在尝试安装...${PLAIN}"
        case "$OS_FAMILY" in
            debian) apt-get update -qq && apt-get install -y -qq ufw ;;
            redhat) yum install -y -q firewalld 2>/dev/null ;;
            alpine) apk add --no-cache ufw iptables ip6tables >/dev/null 2>&1 ;;
            *)      : ;;
        esac
    fi
    if ! command -v ufw &>/dev/null; then
        echo -e "  ${YELLOW}当前系统没有 ufw。${PLAIN}"
        echo -e "  Alpine : apk add ufw iptables && rc-update add ufw default && rc-service ufw start"
        echo -e "  其它   : 手动安装 ufw，或直接用 iptables / nftables 放行端口"
        echo -e "  ${YELLOW}注：Alpine 默认不启用任何防火墙（端口本来就全开），一般无需额外放行。${PLAIN}"
        pause
        return
    fi
    local c
    while true; do
        local detected_ssh ufw_out ufw_stat
        detected_ssh=$(detect_ssh_ports)
        ufw_out=$(LC_ALL=C ufw status 2>/dev/null)
        if [[ "$ufw_out" == 'Status: active'* ]]; then
            ufw_stat="${GREEN}已启用${PLAIN}（SSH: ${detected_ssh}）"
        else
            ufw_stat="${YELLOW}未启用${PLAIN}（SSH: ${detected_ssh}）"
        fi
        menu_header "防火墙管理 (ufw)" "端口放行与安全策略" "$ufw_stat"
        ufw status verbose 2>/dev/null | head -18 | sed 's/^/  /'
        menu_section "规则操作"
        menu_option 1 "开放端口（TCP + UDP）"
        menu_option 2 "关闭 / 删除端口规则"
        menu_section "开关"
        menu_option 3 "启用防火墙（自动保留 SSH: ${detected_ssh}）"
        menu_option 4 "关闭防火墙"
        menu_option 5 "重载防火墙"
        menu_back
        read_menu_choice "请选择 [0-5]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) local p
               read -rp "  要开放的端口（回车取消）: " p || continue
               [[ -z "$p" ]] && continue
               if [[ "$p" =~ ^[0-9]{1,5}$ ]] && validate_port "$((10#$p))"; then
                   p=$((10#$p))
                   ufw allow "$p"/tcp && ufw allow "$p"/udp && echo -e "  ${GREEN}已开放 $p (tcp+udp)${PLAIN}"
               else echo -e "  ${RED}端口无效！${PLAIN}"; fi
               pause ;;
            2) local p yn
               read -rp "  要关闭的端口（回车取消）: " p || continue
               [[ -z "$p" ]] && continue
               if ! [[ "$p" =~ ^[0-9]{1,5}$ ]] || ! validate_port "$((10#$p))"; then
                   echo -e "  ${RED}端口无效！${PLAIN}"
               else
                   p=$((10#$p))
                   if is_ssh_port "$p"; then
                       printf '  %b警告：关闭 %s 可能导致当前 SSH 无法登录，确定？[y/N]: %b' "$RED" "$p" "$PLAIN"
                       read -r yn || continue
                       [[ ! "$yn" =~ ^[Yy]$ ]] && { echo "  已取消。"; pause; continue; }
                   fi
                   ufw delete allow "$p"/tcp 2>/dev/null; ufw delete allow "$p"/udp 2>/dev/null
                   echo -e "  ${GREEN}已删除 $p 的开放规则${PLAIN}"
               fi
               pause ;;
            3) local sp allow_ok=1
               for sp in $detected_ssh; do
                   if ! ufw allow "${sp}/tcp" &>/dev/null; then
                       echo -e "  ${RED}放行 SSH 端口 ${sp}/tcp 失败，已取消启用防火墙。${PLAIN}"
                       allow_ok=0
                       break
                   fi
               done
               if [ "$allow_ok" -eq 1 ]; then
                   echo -e "  ${YELLOW}已自动保留 SSH 端口：${detected_ssh} (tcp)，防止锁死。${PLAIN}"
                   yes | ufw enable && echo -e "  ${GREEN}防火墙已启用${PLAIN}"
               fi
               pause ;;
            4) ufw disable && echo -e "  ${YELLOW}防火墙已关闭${PLAIN}"; pause ;;
            5) ufw reload && echo -e "  ${GREEN}已重载${PLAIN}"; pause ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

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
    command -v tc >/dev/null 2>&1 || bbr_require_tc
    tc qdisc add dev lo root fq >/dev/null 2>&1 && { tc qdisc del dev lo root >/dev/null 2>&1; return 0; }
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
        echo -e "${BLUE}正在安装 iproute2（提供 tc）...${PLAIN}"
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
    if bbr_fq_available; then echo -e "  fq 队列   : ${GREEN}可用${PLAIN}"; else echo -e "  fq 队列   : ${YELLOW}不可用（本机内核只有 fq_codel）${PLAIN}"; fi
    if [ -n "$iface" ] && command -v tc >/dev/null 2>&1; then
        echo -e "  ${iface} 实际队列: $(tc qdisc show dev "$iface" 2>/dev/null | head -1)"
    fi
}

bbr_show_status() {
    echo -e "\n  ${CYAN}▌ 拥塞控制状态${PLAIN}"
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
    local cc="$1" qdisc="$2" label="$3" avail iface cur_cc cur_qd cur_qd_live bak="" have_tc=0
    bbr_require_tc && have_tc=1
    if [ "$cc" = "bbr" ]; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    if ! printf '%s\n' $avail | grep -x -- "$cc" >/dev/null; then
        echo -e "${RED}当前内核不支持 ${cc}（可用: ${avail}）${PLAIN}"
        return 1
    fi

    iface=$(bbr_default_iface)
    if [ -n "$iface" ] && [ "$have_tc" = "1" ]; then
        cur_qd_live=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1{print $2}')
        if [ "$cur_qd_live" != "$qdisc" ]; then
            # 默认队列只影响新建的网卡队列，已在跑的网卡必须手动替换；顺便用它验证内核是否支持
            if ! tc qdisc replace dev "$iface" root "$qdisc" >/dev/null 2>&1; then
                echo -e "${RED}当前内核没有 ${qdisc} 这个队列算法（tc 替换失败），配置未做任何改动。${PLAIN}"
                echo -e "${YELLOW}   ${iface} 现用 ${cur_qd_live}；要 ${qdisc} 只能换一个带该算法（CONFIG_NET_SCH_FQ）的内核。${PLAIN}"
                return 1
            fi
        fi
    fi

    [ "$have_tc" = "0" ] && echo -e "${YELLOW}没有 tc（iproute2 未装）-> 跳过队列实测/替换，只写 sysctl 持久化。${PLAIN}"

    mkdir -p /etc/sysctl.d
    [ -f "$BBR_CONF" ] && { bak=$(mktemp); cp -p "$BBR_CONF" "$bak"; }
    {
        echo "# ${label} —— 由 sb 管理面板写入 $(date '+%Y-%m-%d %H:%M')"
        echo "net.core.default_qdisc = ${qdisc}"
        echo "net.ipv4.tcp_congestion_control = ${cc}"
    } > "$BBR_CONF"
    chmod 644 "$BBR_CONF"

    sysctl -q -w "net.core.default_qdisc=${qdisc}" "net.ipv4.tcp_congestion_control=${cc}" >/dev/null 2>&1

    cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    cur_qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ "$cur_cc" = "$cc" ] && [ "$cur_qd" = "$qdisc" ]; then
        rm -f "$bak"
        local live="n/a"
        [ "$have_tc" = "1" ] && live=$(tc qdisc show dev "${iface:-eth0}" 2>/dev/null | awk 'NR==1{print $2}')
        echo -e "${GREEN}已切换到 ${label}${PLAIN}"
        echo -e "   算法=${cur_cc}  默认队列=${cur_qd}  ${iface:-?} 实际队列=${live}"
        echo -e "   持久化=${BBR_CONF}（重启后自动生效）"
        echo -e "${YELLOW}   注意：已建立的 TCP 连接沿用旧算法，新连接才生效。${PLAIN}"
    else
        if [ -n "$bak" ]; then cp -p "$bak" "$BBR_CONF"; else rm -f "$BBR_CONF"; fi
        rm -f "$bak"
        echo -e "${RED}回读校验不一致：算法=${cur_cc} 队列=${cur_qd}（期望 ${cc} / ${qdisc}）${PLAIN}"
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
        echo -e "\n  ${CYAN}▌ 已安装内核（dpkg）${PLAIN}"
        dpkg-query -W -f='${db:Status-Abbrev}|${Package}|${Version}\n' 'linux-image*' 2>/dev/null \
            | awk -F'|' '$1 ~ /^ii/ && $2 !~ /-common$/ {printf "  %s  %s\n", $2, $3}'
    elif command -v rpm >/dev/null 2>&1; then
        echo -e "\n  ${CYAN}▌ 已安装内核（rpm）${PLAIN}"
        rpm -qa 2>/dev/null | grep -E '^kernel' | sort -V | sed 's/^/  /'
    else
        echo -e "${RED}未找到 dpkg / rpm，无法列出内核。${PLAIN}"; return
    fi
    echo -e "  当前运行 : ${GREEN}$(uname -r)${PLAIN}"
}

# 从 BBR3_REPO 安装 BBRv3 内核（deb 系；不自动重启）
# 注：这些包是 defconfig 构建，没有 CONFIG_NET_SCH_FQ → 装完用 fq_codel。
bbr_install_kernel() {
    local arch fam resp tags sel tag url_img url_hdr tmp i hdr_file
    arch=$(uname -m)
    [ "$arch" = "x86_64" ] || { echo -e "${RED}${BBR3_REPO} 只提供 amd64 的 deb（当前 ${arch}）。ARM 请用发行版自带内核。${PLAIN}"; return 1; }
    fam=$(bbr_os_family)
    [ "$fam" = "debian" ] || {
        echo -e "${RED}BBRv3 内核安装只处理 deb 系（Debian / Ubuntu），当前系统判定为 ${fam}。${PLAIN}"
        [ "$fam" = "alpine" ] && echo -e "${YELLOW}   Alpine 请用官方内核：apk add linux-lts（或 linux-virt / linux-edge），重启后在菜单里选一次「BBR + fq_codel」。${PLAIN}"
        return 1
    }

    echo -e "${BLUE}正在从 ${BBR3_REPO} 获取可用版本...${PLAIN}"
    resp=$(curl -sL --max-time 25 "https://api.github.com/repos/${BBR3_REPO}/releases?per_page=100" 2>/dev/null)
    tags=$(jq -r '.[].tag_name' <<<"$resp" 2>/dev/null | grep -E -- '-bbr3-amd64$' | head -6)
    if [ -z "$tags" ]; then
        echo -e "${RED}取不到版本列表（GitHub API 限流 / 无外网）。退路：VPSBox 的 BBR 菜单，或手动 dpkg 安装 deb。${PLAIN}"
        return 1
    fi

    echo -e "${BLUE}可用 BBRv3 内核（新 -> 旧）：${PLAIN}"
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
    [ -n "$url_img" ] || { echo -e "${RED}该版本没有 amd64 image 资产。${PLAIN}"; return 1; }

    tmp=$(mktemp -d /tmp/bbr3-XXXXXX) || return 1
    echo -e "${BLUE}正在下载 $(basename "$url_img") ...${PLAIN}"
    if ! curl -fL --max-time 600 -o "$tmp/$(basename "$url_img")" "$url_img"; then
        rm -rf -- "$tmp"
        echo -e "${RED}image 下载失败，已清理临时目录。${PLAIN}"
        return 1
    fi
    if [ -n "$url_hdr" ]; then
        hdr_file="$tmp/$(basename "$url_hdr")"
        echo -e "${BLUE}正在下载 $(basename "$url_hdr") ...${PLAIN}"
        if ! curl -fL --max-time 600 -o "$hdr_file" "$url_hdr"; then
            rm -f -- "$hdr_file"
            echo -e "${YELLOW}  headers 下载失败（已移除残余文件），只装 image。${PLAIN}"
        fi
    fi

    echo -e "\n${YELLOW}即将 dpkg 安装 ${tag} 并更新 GRUB 默认项。${PLAIN}"
    echo -e "${RED}注意：需要重启才生效；新内核起不来时用 VPS 控制台（VNC）选旧内核回退。${PLAIN}"
    echo -e "${YELLOW}  注：${BBR3_REPO} 的内核是 defconfig 构建 -> 没有 fq（只有 fq_codel）。${PLAIN}"
    read -rp "确认安装？输入 yes 继续: " conf
    [ "$conf" = "yes" ] || { rm -rf -- "$tmp"; echo -e "${YELLOW}已取消并清理临时文件。${PLAIN}"; return; }

    if dpkg -i "$tmp"/*.deb; then
        rm -rf -- "$tmp"
        command -v update-grub >/dev/null 2>&1 && update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null
        echo -e "${GREEN}安装完成，重启后生效： ${YELLOW}reboot${PLAIN}"
        bbr_post_install_check
        echo -e "   重启回来后在「网络加速」里选一次「BBR + fq_codel」确认即可。"
    else
        echo -e "${RED}dpkg 安装失败，尝试补齐依赖...${PLAIN}"
        if apt-get -f install -y && update-grub 2>/dev/null; then
            rm -rf -- "$tmp"
            echo -e "${GREEN}依赖已补齐并完成安装。${PLAIN}"
        else
            echo -e "${YELLOW}若仍失败，deb 文件保留在 ${tmp} 可手动处理。${PLAIN}"
            return 1
        fi
    fi
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
    local mb="$1" ram max cur_rm cur_wm def_r def_w bak=""
    case "$mb" in ''|*[!0-9]*) echo -e "${RED}请输入纯数字 MB。${PLAIN}"; return 1 ;; esac
    if [ "$mb" -lt 1 ] || [ "$mb" -gt 512 ]; then
        echo -e "${RED}请输入 1-512 之间的 MB。${PLAIN}"; return 1
    fi
    ram=$(tcp_mem_total_mb); max=$(( mb * 1024 * 1024 ))
    # 内存护栏：单条上限 > 内存 1/8 时要人确认（连接多可能吃光内存）
    if [ "$max" -gt $(( ram * 1024 * 1024 / 8 )) ]; then
        echo -e "${YELLOW}${mb}MB 超过物理内存(${ram}MB)的 1/8，连接多时有 OOM 风险。${PLAIN}"
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
        echo -e "${GREEN}TCP 缓冲区上限已设为 ${mb} MB（min/default 保持内核默认，队列不变）${PLAIN}"
        echo -e "   持久化=${TCP_BUF_CONF}（重启后自动生效）"
        echo -e "${YELLOW}   注意：只影响新建连接；代理转发瓶颈通常在 CPU/队列，缓冲区够用即可。${PLAIN}"
    else
        if [ -n "$bak" ]; then cp -p "$bak" "$TCP_BUF_CONF"; else rm -f "$TCP_BUF_CONF"; fi
        rm -f "$bak"
        echo -e "${RED}回读不一致：rmem_max=${cur_rm} wmem_max=${cur_wm}（期望 ${max}）-> 已回滚配置。${PLAIN}"
        return 1
    fi
}

# 带宽(Mbps) × RTT(ms) 估算 BDP -> 推荐 MB
tcp_buf_estimate() {
    local bw rtt bdp mb
    read -rp "  估算带宽 (Mbps, 回车默认 200): " bw; bw=${bw:-200}
    read -rp "  往返延迟 RTT (ms, 回车默认 150): " rtt; rtt=${rtt:-150}
    case "${bw}${rtt}" in *[!0-9]*) echo -e "${RED}带宽/RTT 需为纯数字。${PLAIN}"; return 1 ;; esac
    { [ "$bw" -gt 0 ] && [ "$rtt" -gt 0 ]; } || { echo -e "${RED}带宽/RTT 需大于 0。${PLAIN}"; return 1; }
    # BDP(字节) = 带宽(bit/s) × RTT(s) ÷ 8；取 2× 余量后向上取整到整数 MB
    bdp=$(( bw * 1000000 / 8 * rtt / 1000 ))
    mb=$(( (bdp * 2 + 1048575) / 1048576 )); [ "$mb" -lt 1 ] && mb=1
    echo -e "  BDP ≈ $(tcp_bytes_to_mb "$bdp") MB -> 含 2× 余量推荐 ${GREEN}${mb} MB${PLAIN}"
    read -rp "  按此值应用？[Y/n]: " y; case "$y" in n|N) echo -e "${YELLOW}已取消。${PLAIN}"; return ;; esac
    tcp_buf_apply "$mb"
}

tcp_buf_restore() {
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
        echo -e "${GREEN}已恢复到首次调优前的内核原值，并删除面板覆盖。${PLAIN}"
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
        echo -e "\n  ${DIM}参考：BDP = 带宽 × RTT ÷ 8，200Mbps/150ms 约 8MB；跨区大带宽可到 16MB。${PLAIN}"
        menu_section "设置上限"
        menu_option 1 "推荐值（${rec} MB，按内存兜底）"
        menu_option 2 "8 MB（均衡）"
        menu_option 3 "16 MB（高带宽 / 高延迟）"
        menu_option 4 "32 MB（大内存 + 长肥管道）"
        menu_option 5 "自定义 MB"
        menu_option 6 "按 带宽×RTT 估算"
        menu_section "恢复"
        menu_option 7 "恢复内核默认（删除本面板覆盖）"
        menu_back
        read_menu_choice "请选择 [0-7]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) tcp_buf_apply "$rec"; pause ;;
            2) tcp_buf_apply 8; pause ;;
            3) tcp_buf_apply 16; pause ;;
            4) tcp_buf_apply 32; pause ;;
            5) read -rp "  输入缓冲区上限 (MB, 1-512, 回车取消): " mb || continue
               [[ -n "$mb" ]] && { tcp_buf_apply "$mb"; pause; } ;;
            6) tcp_buf_estimate; pause ;;
            7) tcp_buf_restore; pause ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

menu_bbr() {
    local c cc_now qd_now
    while true; do
        cc_now=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        qd_now=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        menu_header "网络加速" "BBR / BBRv3 拥塞控制 · 内核 · TCP 缓冲区" "${YELLOW}${cc_now:-?} + ${qd_now:-?}${PLAIN}（$(bbr_kernel_desc)）"
        bbr_status_short
        menu_section "拥塞控制切换（立即生效 + 持久化）"
        menu_option 1 "BBR + fq_codel（推荐；bbr3 内核即 BBRv3）"
        menu_option 2 "BBR + fq（实测支持 fq 才切换）"
        menu_option 3 "CUBIC + fq_codel（恢复默认）"
        menu_section "内核与缓冲区"
        menu_option 4 "安装 BBRv3 内核（${BBR3_REPO}，仅 deb 系）"
        menu_option 5 "查看已安装内核"
        menu_option 6 "TCP 缓冲区调优"
        menu_option 7 "完整状态与判定依据"
        menu_back
        read_menu_choice "请选择 [0-7]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) bbr_set_bbr; pause ;;
            2) bbr_set_bbr_fq; pause ;;
            3) bbr_apply cubic fq_codel "CUBIC + fq_codel"; pause ;;
            4) bbr_install_kernel; pause ;;
            5) bbr_list_kernels; pause ;;
            6) menu_tcp_buf ;;
            7) bbr_show_status; pause ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

# ==================== SSH Bark 告警（systemd / journald） ====================
ssh_bark_worker() {
    python3 -c "$(cat <<'PY'
import base64, datetime, ipaddress, json, os, re, socket, subprocess, sys, tempfile
from collections import OrderedDict
from urllib import request
from urllib.parse import unquote, urlsplit

success = re.compile(r"^Accepted \S+ for (\S+) from (\S+) port \d+\b")
failure = re.compile(r"^Failed \S+ for (?:invalid user )?(\S+) from (\S+) port \d+\b")

class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

opener = request.build_opener(request.ProxyHandler({}), NoRedirect())

def config(server, key):
    if not re.fullmatch(r"https://[^\s\\]+", server):
        raise ValueError()
    url = urlsplit(server)
    if not url.hostname or url.username is not None or url.port == 0 or any(c in server for c in '?#'):
        raise ValueError()
    if not re.fullmatch(r"[-A-Za-z0-9_]{8,128}", key):
        raise ValueError()
    return {"endpoint": server.rstrip('/') + '/push', "key": key}

def webhook_config(value):
    if not re.fullmatch(r"https://[^\s\\]+", value) or any(c in value for c in '?#'):
        raise ValueError()
    url = urlsplit(value)
    if url.netloc.count('@') > 1:
        raise ValueError()
    prefix, _, key = url.path.rstrip('/').rpartition('/')
    host = url.netloc.rsplit('@', 1)[-1]
    cfg = config(f'https://{host}{prefix}', key)
    if url.username is not None:
        user = unquote(url.username, errors='strict')
        password = unquote(url.password or '', errors='strict')
        if not user or not password or ':' in user or any(ord(c) < 32 or ord(c) == 127 for c in user + password):
            raise ValueError()
        cfg['basic_auth'] = [user, password]
    return cfg

def notify(cfg, title, body, label=''):
    if label:
        title = f'[{label}] {title}'
    group = f'SSH · {label}' if label else 'SSH'
    data = json.dumps({"device_key": cfg['key'], "title": title, "body": body, "group": group}).encode()
    req = request.Request(cfg['endpoint'], data=data, headers={"Content-Type": "application/json"})
    if 'basic_auth' in cfg:
        token = base64.b64encode(':'.join(cfg['basic_auth']).encode()).decode('ascii')
        req.add_header('Authorization', 'Basic ' + token)
    with opener.open(req, timeout=5) as res:
        if json.loads(res.read(8192)).get('code') != 200:
            raise ValueError()

def events(lines):
    # Only count the final Failed line: Invalid user/PAM often report the same attempt again.
    seen = OrderedDict()
    for line in lines:
        try:
            event = json.loads(line)
            msg = event['MESSAGE']
            ok = success.match(msg)
            match = ok or failure.match(msg)
            if not match:
                continue
            user, addr = match.groups()
            addr = str(ipaddress.ip_address(addr))
            when = int(event['__REALTIME_TIMESTAMP']) / 1_000_000
            tick = int(event['__MONOTONIC_TIMESTAMP']) / 1_000_000
            stamp = datetime.datetime.fromtimestamp(when).astimezone().isoformat(timespec='seconds')
        except (KeyError, TypeError, ValueError, OverflowError, OSError):
            continue
        if ok:
            yield 'SSH 登录成功', f'账号：{user}\n来源：{addr}\n时间：{stamp}'
            continue
        attempts, last = seen.pop(addr, ([], float('-inf')))
        attempts = ([t for t in attempts if tick - t <= 300] + [tick])[-5:]
        alert = len(attempts) == 5 and tick - last >= 1800
        seen[addr] = (attempts, tick if alert else last)
        # Bound state during large distributed scans; old entries may be evicted.
        if len(seen) > 4096:
            seen.popitem(last=False)
        if alert:
            yield 'SSH 疑似暴力破解', f'来源：{addr}\n5 分钟内至少失败 5 次\n时间：{stamp}'

def valid_label(value):
    return len(value) <= 40 and (not value or value.isprintable())

def host_label(path, host):
    try:
        with open(path + '.label', encoding='utf-8') as f:
            label = f.read(161).strip()
        if label and valid_label(label):
            return label
    except (OSError, UnicodeError):
        pass
    return host

def write_private(path, contents):
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=os.path.dirname(path), delete=False) as out:
        name = out.name
        try:
            out.write(contents)
            out.flush()
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

def main(mode, path):
    if mode == 'label':
        label = sys.stdin.readline().strip()
        if not valid_label(label):
            raise ValueError()
        write_private(path + '.label', label)
        return
    if mode in ('configure', 'configure-webhook'):
        value = sys.stdin.readline().rstrip('\n')
        cfg = webhook_config(value) if mode == 'configure-webhook' else config(value, sys.stdin.readline().rstrip('\n'))
        write_private(path, json.dumps(cfg))
        return
    with open(path) as f:
        cfg = json.load(f)
    host = socket.gethostname()
    if mode == 'test':
        notify(cfg, 'SSH Bark 测试', f'主机：{host}\n推送配置可用', host_label(path, host))
        return
    if mode != 'follow':
        raise ValueError()
    proc = subprocess.Popen(['journalctl', '--follow', '--lines=0', '--output=json', '--no-pager',
                             '-u', 'ssh.service', '-u', 'sshd.service', '-u', 'ssh@*.service', '-u', 'sshd@*.service'],
                            stdout=subprocess.PIPE, text=True, encoding='utf-8', errors='replace')
    for title, body in events(proc.stdout):
        try:
            notify(cfg, title, f'主机：{host}\n{body}', host_label(path, host))
        except (ValueError, OSError, AttributeError):
            print('SSH Bark 推送失败', file=sys.stderr, flush=True)
    proc.wait()
    raise OSError()

if __name__ == '__main__':
    try:
        main(*sys.argv[1:])
    except Exception:
        # URL、推送响应和凭据都不写入终端或 journal。
        print('SSH Bark 操作失败，请检查配置、网络和服务状态。', file=sys.stderr)
        sys.exit(1)
PY
)" "$1" "$SSH_BARK_CONFIG"
}

menu_ssh_bark() {
    local status server key webhook label
    if [ "$INIT_SYS" != systemd ] || ! command -v python3 >/dev/null || ! command -v journalctl >/dev/null; then
        echo 'SSH Bark 需要 systemd、journald 和 Python 3。'
        pause
        return
    fi
    while true; do
        status=未运行
        systemctl is-active --quiet "$SSH_BARK_UNIT" && status=运行中
        menu_header 'SSH Bark 告警' '仅通知，不封禁 IP' "$status"
        menu_option 1 '配置 Bark 并启用'
        menu_option 2 '发送测试通知'
        menu_option 3 '停用告警（保留配置）'
        menu_option 4 '设置机器备注'
        menu_back
        read_menu_choice '请选择 [0-4]' || return
        case "$REPLY" in
            1)
                if [ ! -f "$PANEL_FILE" ] || ! grep -q '^ssh_bark_worker() {' "$PANEL_FILE"; then
                    echo "请先将新版 sb 安装到 $PANEL_FILE。"; pause; continue
                fi
                read -rs -p 'Bark Webhook URL（以 Device Key 结尾，不回显；留空则分开填写）：' webhook || return
                echo
                if [ -n "$webhook" ]; then
                    if ! printf '%s\n' "$webhook" | ssh_bark_worker configure-webhook; then
                        unset webhook; pause; continue
                    fi
                    unset webhook
                else
                    read -r -p 'Bark 服务地址 [https://api.day.app]：' server || return
                    read -rs -p 'Bark Device Key（不回显）：' key || return
                    echo
                    if ! printf '%s\n%s\n' "${server:-https://api.day.app}" "$key" | ssh_bark_worker configure; then
                        unset key; pause; continue
                    fi
                    unset key
                fi
                if cat > "/etc/systemd/system/$SSH_BARK_UNIT" <<EOF
[Unit]
Description=SSH login and brute-force alerts via Bark
After=network-online.target systemd-journald.service
Wants=network-online.target

[Service]
ExecStart=/bin/bash $PANEL_FILE --ssh-bark-worker
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectHome=yes
ProtectSystem=strict
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
                then
                    if systemctl daemon-reload && systemctl enable "$SSH_BARK_UNIT" && systemctl restart "$SSH_BARK_UNIT"; then
                        echo '已启用，建议用菜单 2 测试推送。'
                    else
                        echo '启用失败，请检查服务状态。'
                    fi
                else
                    echo '无法写入 SSH Bark 服务定义。'
                fi
                pause ;;
            2) ssh_bark_worker test && echo '测试推送已提交。'; pause ;;
            3)
                if [ -f "/etc/systemd/system/$SSH_BARK_UNIT" ]; then
                    systemctl disable --now "$SSH_BARK_UNIT" && echo '已停用。'
                else
                    echo '尚未配置告警。'
                fi
                pause ;;
            4)
                read -r -p '机器备注（最多 40 个字符，留空使用主机名）：' label || return
                printf '%s\n' "$label" | ssh_bark_worker label && echo '已保存，后续通知将使用此备注。'
                pause ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

menu_tools() {
    local c
    while true; do
        menu_header "网络检测与系统运维" "解锁检测、回程路由、DNS 与 Swap"
        menu_section "网络与路由检测"
        menu_option 1 "流媒体解锁检测（快速）"
        menu_option 2 "IP 质量与流媒体体检（xykt/IPQuality）"
        menu_option 3 "回程路由测试（BestTrace / 三网及教育网）"
        menu_section "系统运维"
        menu_option 4 "DNS 设置（/etc/resolv.conf）"
        menu_option 5 "Swap 虚拟内存管理"
        menu_option 6 "防火墙管理（ufw）"
        menu_option 7 "网络加速（BBR / BBRv3 + TCP 缓冲区）"
        menu_option 8 "SSH Bark 告警"
        menu_back
        read_menu_choice "请选择 [0-8]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) media_check_quick; pause ;;
            2) media_check_full; pause ;;
            3) besttrace_check; pause ;;
            4) menu_dns ;;
            5) menu_swap ;;
            6) menu_firewall ;;
            7) menu_bbr ;;
            8) menu_ssh_bark ;;
            0) return ;;
            *) menu_invalid ;;
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
    local mem_tot mem_avail sw_tot sw_free
    mem_tot=$(awk '/^MemTotal:/{printf "%.0f MiB", $2/1024}' "$SB_SWAP_MEMINFO" 2>/dev/null)
    mem_avail=$(awk '/^MemAvailable:/{printf "%.0f MiB", $2/1024}' "$SB_SWAP_MEMINFO" 2>/dev/null)
    sw_tot=$(awk '/^SwapTotal:/{printf "%.0f MiB", $2/1024}' "$SB_SWAP_MEMINFO" 2>/dev/null)
    sw_free=$(awk '/^SwapFree:/{printf "%.0f MiB", $2/1024}' "$SB_SWAP_MEMINFO" 2>/dev/null)
    printf '  %b内存概况%b  总计 %s · 可用 %s\n' "$DIM" "$PLAIN" "${mem_tot:-?}" "${mem_avail:-?}"
    printf '  %bSwap概况%b  总计 %s · 空闲 %s\n' "$DIM" "$PLAIN" "${sw_tot:-?}" "${sw_free:-?}"
    local swaps
    swaps=$(awk 'NR > 1 {printf "    %s (%s, %.0f MiB, 已用 %.0f MiB)\n", $1, $2, $3/1024, $4/1024}' "$SB_SWAP_PROC" 2>/dev/null)
    if [ -n "$swaps" ]; then
        printf '  %b已启用项%b\n%s\n' "$DIM" "$PLAIN" "$swaps"
    else
        printf '  %b已启用项%b  无\n' "$DIM" "$PLAIN"
    fi
    if swap_owned; then
        local sz st
        sz="$(( $(stat -c %s "$SB_SWAP_FILE") / 1048576 ))"
        if swap_active; then st="${GREEN}已启用${PLAIN}"; else st="${YELLOW}未启用${PLAIN}"; fi
        printf '  %b面板管理%b  %s（%s MiB · %b）\n' "$DIM" "$PLAIN" "$SB_SWAP_FILE" "$sz" "$st"
    else
        printf '  %b面板管理%b  %b尚未创建（不动系统已有 Swap）%b\n' "$DIM" "$PLAIN" "$YELLOW" "$PLAIN"
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
    printf '已创建并启用 %s MiB Swap，开机自动启用。\n' "$mb"
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
    printf '已删除本面板创建的 Swap。\n'
}

menu_swap() {
    local c
    while true; do
        menu_header "Swap 管理" "只管理本面板创建的 Swap 文件"
        swap_status
        menu_section "操作"
        menu_option 1 "添加 Swap（自定义 MiB）"
        menu_option 2 "删除本面板 Swap"
        menu_back
        read_menu_choice "请选择 [0-2]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) swap_create; pause ;;
            2) swap_delete; pause ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

# ==================== 主菜单 ====================
show_menu() {
    local choice
    menu_header "Sing-box 管理面板" "Reality / SS2022 / 转发 / WARP  ·  ${SCRIPT_VERSION}" "$(home_status_line)"
    menu_section "代理与分流"
    menu_option 1 "节点管理（链接 / 备注 / 增删）"
    menu_option 2 "端口转发（TCP / UDP）"
    menu_option 3 "WARP / SOCKS5 出口与分流"
    menu_section "核心与配置"
    menu_option 4 "服务与核心（启停 / 更新 / 日志 / 卸载）"
    menu_option 5 "配置管理（查看 / 编辑 / 回滚）"
    menu_section "网络与系统"
    menu_option 6 "网络加速（BBR / BBRv3 / TCP 缓冲区）"
    menu_option 7 "防火墙管理（ufw）"
    menu_option 8 "网络检测与系统运维（解锁 / 路由 / DNS / Swap）"
    menu_exit
    read_menu_choice "请选择 [0-8]" || exit 0
    choice="$REPLY"
    case "$choice" in
        "") return ;;
        1) menu_nodes ;;
        2) menu_forward ;;
        3) menu_warp ;;
        4) menu_system ;;
        5) diagnose_config ;;
        6) menu_bbr ;;
        7) menu_firewall ;;
        8) menu_tools ;;
        0) exit 0 ;;
        *) menu_invalid ;;
    esac
}

# ==================== WARP 出口 ====================
# sing-box 1.11+ 将 wireguard 从 outbound 迁移为 endpoint，这里采用 endpoint 架构。
# 账号直连 Cloudflare 官方 API 免费注册（不依赖第三方注册工具）。
_warp_decode_reserved() {
    local cid="$1" bytes
    [[ "$cid" =~ ^[A-Za-z0-9+/=]{4,8}$ ]] || { printf '[]\n'; return 0; }
    bytes=$(printf '%s' "$cid" | base64 -d 2>/dev/null | od -An -v -tu1 2>/dev/null | awk '
        { for (i = 1; i <= NF; i++) { a[++n] = $i } }
        END {
            if (n == 3) printf "[%s,%s,%s]\n", a[1], a[2], a[3]
            else print "[]"
        }
    ')
    printf '%s\n' "${bytes:-[]}"
}

_warp_registration_endpoint() {
    local payload reserved
    payload=$(cat)
    reserved=$(_warp_decode_reserved "$(jq -r '.config.client_id // empty' <<< "$payload" 2>/dev/null)")
    # 留足 WireGuard 封装开销，避免大包 sendmmsg: message too long。
    jq -ce --rawfile priv /dev/fd/3 --argjson reserved "$reserved" '
      .config.interface.addresses as $addr | .config.peers[0].public_key as $peer |
      select(($addr.v4 | strings | test("^[0-9]+(\\.[0-9]+){3}$")) and
        ($peer | strings | test("^[A-Za-z0-9+/]{43}=$"))) |
      {type: "wireguard", tag: "warp", mtu: 1280, private_key: ($priv | rtrimstr("\n")),
        address: ([$addr.v4 + "/32"] + (if ($addr.v6 // "") == "" then [] else [$addr.v6 + "/128"] end)),
        peers: [({address: "162.159.192.8", port: 2408, public_key: $peer, allowed_ips: ["0.0.0.0/0", "::/0"]} +
          (if ($reserved | length) == 3 then {reserved: $reserved} else {} end))]}
    ' 3<<< "$1" <<< "$payload"
}

# geosite 规则集（SagerNet/sing-geosite rule-set 分支，.srs 二进制，与 sbx 保持一致）
GEOSITE_BASE="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
WARP_AI_RULE_TAG="geosite-ai"
WARP_AI_RULE_FILE="geosite-category-ai-chat-!cn.srs"
WARP_MEDIA_RULE_TAG="geosite-stream"
WARP_MEDIA_RULE_FILE="geosite-category-entertainment@!cn.srs"

has_warp_endpoint() {
    local c
    c=$(jq '[.endpoints[]? | select(.tag == "warp")] | length' "$CONFIG_FILE" 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo "0"
}

add_warp() (
    set +x
    umask 077
    local keys priv pub id payload response endpoint candidate addresses
    if [ ! -x "$BIN_FILE" ]; then
        printf '%b请先安装 Sing-box。%b\n' "$RED" "$PLAIN" >&2; exit 1
    fi
    ensure_config
    if [ "$(has_warp_endpoint)" -gt 0 ]; then
        printf '%b已存在 WARP 出口，将重新注册并覆盖（保留现有分流规则）。%b\n' "$YELLOW" "$PLAIN"
    fi
    printf '%b正在向 Cloudflare 注册免费 WARP 账号...%b\n' "$BLUE" "$PLAIN"
    keys=$("$BIN_FILE" generate wg-keypair 2>/dev/null) || {
        printf '%b生成 WireGuard 密钥失败。%b\n' "$RED" "$PLAIN" >&2; exit 1
    }
    read -r priv pub < <(awk '/^PrivateKey:/{p=$2} /^PublicKey:/{q=$2} END{print p, q}' <<< "$keys")
    if [ -z "$priv" ] || [ -z "$pub" ]; then
        printf '%b生成 WireGuard 密钥失败。%b\n' "$RED" "$PLAIN" >&2; exit 1
    fi
    if [ -r /proc/sys/kernel/random/uuid ]; then
        read -r id < /proc/sys/kernel/random/uuid || exit 1
    else
        id=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    fi
    payload=$(jq -nc --arg key "$pub" --arg id "${id//-/}" '
      {key: $key, install_id: $id, fcm_token: "", tos: (now | todateiso8601), model: "Linux", serial_number: $id, locale: "en_US"}
    ') || exit 1
    if ! response=$(curl -qfsS --connect-timeout 8 --max-time 20 https://api.cloudflareclient.com/v0a2158/reg \
      -H 'User-Agent: okhttp/3.12.1' -H 'CF-Client-Version: a-6.3-2158' -H 'Content-Type: application/json' --data "$payload") ||
       ! endpoint=$(_warp_registration_endpoint "$priv" <<< "$response" 2>/dev/null); then
        printf '%bWARP 注册失败或返回缺少地址/公钥，原配置未改动。%b\n' "$RED" "$PLAIN" >&2
        exit 1
    fi
    candidate=$(jq --slurpfile ep /dev/fd/3 '
        .endpoints = ([.endpoints[]? | select(.tag != "warp")] + $ep) |
        .outbounds = [.outbounds[]? | select(.tag != "warp")]' 3<<< "$endpoint" "$CONFIG_FILE") || exit 1
    apply_config_and_restart "$candidate" || exit 1
    rm -f "$WARP_META"
    addresses=$(jq -r '.address | join(" / ")' <<< "$endpoint")
    printf '%bWARP 出口添加成功。%b\n' "$GREEN" "$PLAIN"
    printf '  出口标签 : %bwarp%b（wireguard endpoint）\n' "$BLUE" "$PLAIN"
    printf '  隧道地址 : %b%s%b\n' "$BLUE" "$addresses" "$PLAIN"
    printf '%b提示：返回菜单即可开启 AI / 流媒体分流，或按域名 / 节点分流。%b\n' "$YELLOW" "$PLAIN"
)

has_socks5_outbound() {
    jq -e 'any(.outbounds[]?; .tag == "socks5" and .type == "socks" and .version == "5")' \
        "$CONFIG_FILE" >/dev/null 2>&1
}

# stdout 只返回出口标签，菜单提示走 stderr。
choose_split_outbound() {
    local warp=0 socks=0 choice
    [ "$(has_warp_endpoint)" -gt 0 ] && warp=1
    has_socks5_outbound && socks=1
    case "$warp$socks" in
        10) printf 'warp\n' ;;
        01) printf 'socks5\n' ;;
        11) read -rp '  选择出口 [1. WARP / 2. SOCKS5，回车取消]: ' choice || return 1
            case "$choice" in
                1) printf 'warp\n' ;;
                2) printf 'socks5\n' ;;
                '') return 1 ;;
                *) menu_invalid >&2; return 1 ;;
            esac ;;
        *) printf '%b请先添加 WARP 或 SOCKS5 出口。%b\n' "$YELLOW" "$PLAIN" >&2; return 1 ;;
    esac
}

add_socks5_outbound() {
    ensure_config
    local host port username password='' temp_json
    if ! has_socks5_outbound && jq -e 'any((.outbounds[]?, .endpoints[]?); .tag == "socks5")' "$CONFIG_FILE" >/dev/null; then
        printf '%b标签 socks5 已被其他出口占用，未修改配置。%b\n' "$RED" "$PLAIN"
        return 1
    fi
    if has_socks5_outbound; then
        printf '  当前 SOCKS5：'
        jq -r '.outbounds[] | select(.tag == "socks5") | "\(.server) 端口 \(.server_port)"' "$CONFIG_FILE"
        printf '  重新设置会保留关联分流规则。\n'
    fi
    read -rp '  SOCKS5 地址（域名 / IP，回车取消）: ' host || return 0
    [ -n "$host" ] || return 0
    host=${host#\[}; host=${host%\]}
    read -rp '  SOCKS5 端口: ' port || return 0
    if ! [[ "$host" =~ ^[A-Za-z0-9_.:-]+$ && "$port" =~ ^[0-9]{1,5}$ ]] ||
        (( 10#$port < 1 || 10#$port > 65535 )); then
        printf '%b地址或端口无效。%b\n' "$RED" "$PLAIN"
        return 1
    fi
    read -rp '  用户名（无需认证则留空）: ' username || return 0
    if [ -n "$username" ]; then
        read -rsp '  密码（不回显）: ' password || { printf '\n'; return 0; }
        printf '\n'
        [ -n "$password" ] || { printf '%b密码不能为空。%b\n' "$RED" "$PLAIN"; return 1; }
    fi
    temp_json=$(jq --arg host "$host" --argjson port "$((10#$port))" \
        --rawfile username /dev/fd/3 --rawfile password /dev/fd/4 '
        ({type:"socks", tag:"socks5", version:"5", server:$host, server_port:$port} +
          (if $username == "" then {} else {username:$username, password:$password} end)) as $proxy |
        if any(.outbounds[]?; .tag == "socks5") then
            .outbounds |= map(if .tag == "socks5" then $proxy else . end)
        else .outbounds = ((.outbounds // []) + [$proxy]) end
    ' "$CONFIG_FILE" 3< <(printf '%s' "$username") 4< <(printf '%s' "$password")) || return 1
    if apply_config_and_restart "$temp_json"; then
        printf '%bSOCKS5 已保存；未自动开启分流或修改默认出口。%b\n' "$GREEN" "$PLAIN"
    fi
}

add_warp_node_route() {
    ensure_config
    local real_idx selected outbound temp_json
    outbound=$(choose_split_outbound) || return 0
    real_idx=$(prompt_delete_index "要全部走 ${outbound^^} 的节点" node)
    [ -z "$real_idx" ] && return
    selected=$(inbound_field "$real_idx" "tag")
    [ -n "$selected" ] || return 1

    temp_json=$(jq --arg tag "$selected" --arg to "$outbound" '
        .route.rules |= (
          [(. // [])[] | select((.outbound != "warp" and .outbound != "socks5") or
            ((.inbound != [$tag] and .inbound != $tag) or ((keys - ["inbound","outbound","action"]) | length > 0)))] |
          ((map(.outbound != null) | index(true)) // length) as $i |
          .[:$i] + [{inbound:[$tag],outbound:$to}] + .[$i:])
    ' "$CONFIG_FILE") || return 1
    if apply_config_and_restart "$temp_json"; then
        echo -e "${GREEN}节点 [$(node_display_name "$selected")] 已设置为全部走 ${outbound^^}。${PLAIN}"
    fi
}

add_warp_route() {
    ensure_config
    local outbound doms
    outbound=$(choose_split_outbound) || return 0
    read -rp "  输入要走 ${outbound^^} 的域名后缀（逗号分隔，如 openai.com,claude.ai，回车取消）: " doms || return 0
    [[ -z "$doms" ]] && { echo -e "  ${YELLOW}已取消。${PLAIN}"; return 0; }
    local arr
    arr=$(printf '%s' "$doms" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | jq -R . | jq -cs .)
    if [[ "$arr" == "[]" || -z "$arr" ]]; then
        echo -e "${RED}域名解析为空。${PLAIN}"; return
    fi
    local temp_json
    temp_json=$(jq --argjson doms "$arr" --arg to "$outbound" '
        def same_domains: (.outbound == "warp" or .outbound == "socks5") and
          ((keys - ["domain_suffix","outbound","action"]) | length == 0) and
          (([.domain_suffix? | if type == "array" then .[] else strings end] | unique) == ($doms | unique));
        .route.rules |= ((. // []) |
          if any(.[]; same_domains) then map(if same_domains then .outbound = $to else . end)
          else . + [{domain_suffix:$doms,outbound:$to}] end)' "$CONFIG_FILE") || return 1
    if apply_config_and_restart "$temp_json"; then
        echo -e "${GREEN}已设置分流规则：$doms -> ${outbound^^}${PLAIN}"
    fi
}

split_ruleset_outbound() {
    jq -r --arg t "$1" '
      first(.route.rules[]? | select((.outbound == "warp" or .outbound == "socks5") and
        (.rule_set == $t or ((.rule_set | type) == "array" and (.rule_set | index($t)) != null))) | .outbound)
    ' "$CONFIG_FILE" 2>/dev/null
}

has_warp_ruleset() {
    [ "$(split_ruleset_outbound "$1")" = warp ]
}

# 开关式管理 WARP 远程规则集（与 sbx 一致）；参数：tag 名称 .srs文件名 [旧tag...]
toggle_warp_ruleset() {
    local r_tag="$1" r_name="$2" r_file="$3"
    shift 3
    local legacy_json='[]'
    if [ "$#" -gt 0 ]; then
        legacy_json=$(printf '%s\n' "$@" | jq -R . | jq -cs .)
    fi
    local temp_json outbound current
    outbound=$(choose_split_outbound) || return 0
    current=$(split_ruleset_outbound "$r_tag")
    if [ -n "$current" ] && [ "$current" != "$outbound" ]; then
        temp_json=$(jq --arg t "$r_tag" --arg from "$current" --arg to "$outbound" '
          .route.rules |= map(if .outbound == $from and
            (.rule_set == $t or ((.rule_set | type) == "array" and (.rule_set | index($t)) != null))
            then .outbound = $to else . end)' "$CONFIG_FILE") || return 1
        if apply_config_and_restart "$temp_json"; then
            printf '%b%s 已切换 -> %s。%b\n' "$GREEN" "$r_name" "${outbound^^}" "$PLAIN"
        fi
    elif [ -n "$current" ]; then
        temp_json=$(jq --arg t "$r_tag" --argjson legacy "$legacy_json" '
          ($legacy + [$t]) as $drop |
          .route = (.route // {}) |
          .route.rule_set = [.route.rule_set[]? | select(.tag as $x | ($drop | index($x)) == null)] |
          .route.rules = [.route.rules[]? | select(
            (.outbound != "warp" and .outbound != "socks5") or (
              .rule_set as $rs |
              (($rs | type) != "string" or ($drop | index($rs)) == null) and
              (($rs | type) != "array" or (all($rs[]; . as $x | ($drop | index($x)) == null)))
            )
          )]
        ' "$CONFIG_FILE") || return 1
        if apply_config_and_restart "$temp_json"; then
            printf '%b%s 已关闭。%b\n' "$GREEN" "$r_name" "$PLAIN"
        fi
    else
        temp_json=$(jq --arg t "$r_tag" --arg to "$outbound" --arg url "${GEOSITE_BASE}/${r_file}" --argjson legacy "$legacy_json" '
          ($legacy + [$t]) as $drop |
          # sing-box 1.14+: 以 http_clients + default_http_client 代替已弃用的 download_detour
          .http_clients = ((.http_clients // []) + [{"tag":"rs-http"}] | group_by(.tag) | map(.[0])) |
          .route = (.route // {}) |
          .route.default_http_client = "rs-http" |
          .route.rule_set = (
            [.route.rule_set[]? | select(.tag as $x | ($drop | index($x)) == null) | del(.download_detour)] +
            [{"tag": $t, "type": "remote", "format": "binary", "url": $url}]
          ) |
          .route.rules = (
            [.route.rules[]? | select(
              (.outbound != "warp" and .outbound != "socks5") or (
                .rule_set as $rs |
                (($rs | type) != "string" or ($drop | index($rs)) == null) and
                (($rs | type) != "array" or (all($rs[]; . as $x | ($drop | index($x)) == null)))
              )
            )] +
            [{"action": "route", "rule_set": $t, "outbound": $to}]
          )
        ' "$CONFIG_FILE") || return 1
        if apply_config_and_restart "$temp_json"; then
            printf '%b%s 已开启 -> %s（%s）。%b\n' "$GREEN" "$r_name" "${outbound^^}" "$r_file" "$PLAIN"
            printf '%b首次启动会自动下载规则集，默认每 24 小时自动更新。%b\n' "$YELLOW" "$PLAIN"
        fi
    fi
}

add_warp_ai() {
    ensure_config
    toggle_warp_ruleset "$WARP_AI_RULE_TAG" "AI 分流" "$WARP_AI_RULE_FILE" \
        geosite-category-ai-!cn geosite-openai geosite-anthropic
}

add_warp_media() {
    ensure_config
    toggle_warp_ruleset "$WARP_MEDIA_RULE_TAG" "流媒体分流" "$WARP_MEDIA_RULE_FILE" \
        geosite-netflix geosite-disney geosite-hbo geosite-youtube \
        geosite-primevideo geosite-tiktok geosite-spotify geosite-hulu
}

count_split_rules() {
    jq '[.route.rules[]? | select(.outbound == "warp" or .outbound == "socks5")] | length' "$CONFIG_FILE" 2>/dev/null
}

view_warp_rules() {
    ensure_config
    local n
    n=$(count_split_rules)
    echo -e "\n  ${CYAN}▌ WARP / SOCKS5 分流规则（共 ${n:-0} 条）${PLAIN}"
    if [ "${n:-0}" -eq 0 ]; then
        echo -e "  ${YELLOW}暂无规则，可在分流菜单中开启规则集或添加自定义规则。${PLAIN}"; return
    fi
    jq -r '
      [.route.rules[]? | select(.outbound == "warp" or .outbound == "socks5")]
      | to_entries[]
      | .value as $r
      | ([
          (if ($r.inbound?       // null) != null then "入站: "     + (($r.inbound       | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.rule_set?      // null) != null then "规则集: "   + (($r.rule_set      | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.domain_suffix? // null) != null then "域名后缀: " + (($r.domain_suffix | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.domain?        // null) != null then "域名: "     + (($r.domain        | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.domain_keyword? // null) != null then "关键词: "   + (($r.domain_keyword | if type == "array" then join(",") else tostring end)) else empty end),
          (if ($r.ip_cidr?       // null) != null then "IP: "       + (($r.ip_cidr       | if type == "array" then join(",") else tostring end)) else empty end)
        ] | map(select(. != "")) | join("  |  ")) as $detail
      | "  [\(.key + 1)] " + (if $detail == "" then "全部流量" else $detail end) + " -> \($r.outbound | ascii_upcase)"
    ' "$CONFIG_FILE"
}

delete_warp_rule() {
    ensure_config
    local n
    n=$(count_split_rules)
    if [ "${n:-0}" -eq 0 ]; then
        echo -e "${YELLOW}暂无 WARP / SOCKS5 分流规则。${PLAIN}"; return
    fi
    view_warp_rules
    declare -F ui_subrule >/dev/null && ui_subrule
    local idx
    read -rp "  输入要删除的规则序号 (0 或回车取消): " idx || return 0
    [[ -z "$idx" || "$idx" == "0" ]] && return 0
    if ! [[ "$idx" =~ ^[0-9]{1,9}$ ]] || (( 10#$idx < 1 || 10#$idx > n )); then
        echo -e "${RED}无效序号！${PLAIN}"; return
    fi
    local abs
    abs=$(jq --argjson k "$((10#$idx-1))" '
      [.route.rules | to_entries[] | select(.value.outbound == "warp" or .value.outbound == "socks5") | .key][$k]' "$CONFIG_FILE") || return 1
    local temp_json
    temp_json=$(jq --argjson i "$abs" --arg ai "$WARP_AI_RULE_TAG" --arg media "$WARP_MEDIA_RULE_TAG" '
      .route.rules |= (.[:$i] + .[$i+1:]) |
      if .route.rule_set then
        ([.route.rules[]?.rule_set? | if type == "array" then .[] else . end] | map(strings)) as $used |
        .route.rule_set |= [.[] | select(
          .tag as $x | ($x != $ai and $x != $media) or (($used | index($x)) != null)
        )]
      else . end' "$CONFIG_FILE") || return 1
    if apply_config_and_restart "$temp_json"; then
        echo -e "${GREEN}已删除第 $idx 条分流规则。${PLAIN}"
    fi
}

delete_warp() {
    ensure_config
    if [ "$(has_warp_endpoint)" -eq 0 ]; then
        echo -e "${YELLOW}当前没有 WARP 出口。${PLAIN}"; return
    fi
    local temp_json
    temp_json=$(config_without_split_outbound warp) || return 1
    if apply_config_and_restart "$temp_json"; then
        rm -f "$WARP_META"
        printf '%bWARP 出口已删除（含指向 warp 的路由规则与规则集）。%b\n' "$GREEN" "$PLAIN"
    fi
}

config_without_split_outbound() {
    jq --arg to "$1" --arg ai "$WARP_AI_RULE_TAG" --arg media "$WARP_MEDIA_RULE_TAG" '
        if $to == "warp" then .endpoints |= map(select(.tag != $to))
        else .outbounds |= map(select(.tag != $to)) end |
        if .route.rules then .route.rules |= map(select(.outbound != $to)) else . end |
        if .route.rule_set then
          ([.route.rules[]?.rule_set? | if type == "array" then .[] else . end] | map(strings)) as $used |
          .route.rule_set |= map(select(.tag as $x | ($x != $ai and $x != $media) or (($used | index($x)) != null)))
        else . end' "$CONFIG_FILE"
}

delete_socks5_outbound() {
    local temp_json
    has_socks5_outbound || { printf '  尚未设置 SOCKS5 出口。\n'; return 1; }
    temp_json=$(config_without_split_outbound socks5) || return 1
    if apply_config_and_restart "$temp_json"; then
        printf '%bSOCKS5 出口及其分流规则已删除。%b\n' "$GREEN" "$PLAIN"
    fi
}

# 用独立临时核心测试指定出口；端口由系统分配，不改生产配置/路由。
probe_split_outbound() (
    local tag="$1" label="$2" work pid='' port='' ip family host i result=''
    work=$(mktemp -d) || return 1
    chmod 700 "$work"
    trap '[ -z "$pid" ] || { kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; }; rm -f -- "$work/config.json" "$work/core.log"; rmdir "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    umask 077
    jq --arg tag "$tag" '
      {log:{level:"info", timestamp:false},
       dns:{servers:[{type:"local",tag:"probe-local"}]},
       inbounds:[{type:"mixed",tag:"probe",listen:"127.0.0.1",listen_port:0}],
       outbounds:[.outbounds[]? | select(.tag == $tag) | .domain_resolver = "probe-local"],
       endpoints:[.endpoints[]? | select(.tag == $tag)],
       route:{final:$tag,default_domain_resolver:"probe-local"}}
    ' "$CONFIG_FILE" > "$work/config.json" || return 1
    if ! "$BIN_FILE" check -c "$work/config.json" > "$work/core.log" 2>&1; then
        return 1
    fi
    "$BIN_FILE" run -c "$work/config.json" > "$work/core.log" 2>&1 &
    pid=$!
    for ((i=0; i<30; i++)); do
        port=$(sed -n 's/.*inbound\/mixed\[probe\]: tcp server started at 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$work/core.log" | head -1)
        [ -z "$port" ] || break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if [ -z "$port" ] || ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    for family in 4 6; do
        host="api${family}.ipify.org"
        ip=$(curl --silent --fail --connect-timeout 5 --max-time 10 --noproxy '' \
            --proxy "socks5h://127.0.0.1:$port" "https://$host" 2>/dev/null) || ip=''
        if [[ "$family" == 4 && "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
            [[ "$family" == 6 && "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
            if [ "$family" == 4 ]; then
                result="${result} IP: $ip"
            else
                result="${result} IPV6: $ip"
            fi
        fi
    done
    if [ -n "$result" ]; then printf '  %s%s\n' "$label" "$result"; fi
)

view_split_exit_ips() {
    if has_socks5_outbound; then
        probe_split_outbound socks5 S5 || :
    fi
    if [ "$(has_warp_endpoint)" -gt 0 ]; then
        probe_split_outbound warp WARP || :
    fi
    return 0
}

view_warp() {
    ensure_config
    if [ "$(has_warp_endpoint)" -eq 0 ]; then
        echo -e "${YELLOW}当前没有 WARP 出口。${PLAIN}"; return
    fi
    echo -e "\n  ${CYAN}▌ WARP 出口 (wireguard endpoint)${PLAIN}"
    jq '.endpoints[] | select(.tag == "warp")' "$CONFIG_FILE"
    local rc
    rc=$(jq '[.route.rules[]? | select((.outbound? // "") == "warp")] | length' "$CONFIG_FILE" 2>/dev/null)
    echo -e "  指向 warp 的路由规则数: ${BLUE}${rc:-0}${PLAIN}"
    [ -f "$WARP_META" ] && echo -e "  账号元数据: $WARP_META"
}

menu_warp() {
    local c yn exit_ip_cache='' exit_ip_config='' current_config
    while true; do
        local warp_has warp_status ai_state media_state rule_count socks_status
        warp_has=$(has_warp_endpoint)
        warp_status=$(warp_summary_short)
        socks_status=未配置
        has_socks5_outbound && socks_status=已配置
        current_config=$(sha256sum "$CONFIG_FILE")
        if [ "$current_config" != "$exit_ip_config" ]; then
            exit_ip_cache=$(view_split_exit_ips)
            exit_ip_config=$current_config
        fi
        local header_status="$warp_status / SOCKS5 $socks_status"
        [ -z "$exit_ip_cache" ] || header_status+=$'\n'"$exit_ip_cache"
        menu_header "WARP / SOCKS5 出口与分流" "" "$header_status"
        menu_section "分流规则（再次选择当前出口可关闭规则集）"
        ai_state=$(split_ruleset_outbound "$WARP_AI_RULE_TAG")
        media_state=$(split_ruleset_outbound "$WARP_MEDIA_RULE_TAG")
        ai_state=${ai_state^^}; ai_state=${ai_state:-关}
        media_state=${media_state^^}; media_state=${media_state:-关}
        rule_count=$(count_split_rules)
        menu_option 1 "AI 分流开关 [${ai_state}]"
        menu_option 2 "流媒体分流开关 [${media_state}]"
        menu_option 3 "添加自定义域名分流"
        menu_option 4 "指定节点的全部流量出口"
        menu_option 5 "查看分流规则（${rule_count:-0} 条）"
        menu_option 6 "删除指定规则"
        menu_section "出口管理"
        if [ "$warp_has" -gt 0 ]; then
            menu_option 7 "重新注册 / 重置 WARP 出口"
        else
            menu_option 7 "添加 WARP 出口（免费自动注册）"
        fi
        menu_option 8 "查看 WARP 出口详情"
        menu_option 9 "删除 WARP 出口及全部关联规则"
        menu_option 10 "添加 / 更新 SOCKS5 出口"
        menu_option 11 "删除 SOCKS5 出口及全部关联规则"
        menu_back
        read_menu_choice "请选择 [0-11]" || return 0
        c="$REPLY"
        case "$c" in
            "") continue ;;
            1) add_warp_ai; pause ;;
            2) add_warp_media; pause ;;
            3) add_warp_route; pause ;;
            4) add_warp_node_route; pause ;;
            5) view_warp_rules; pause ;;
            6) delete_warp_rule; pause ;;
            7) add_warp; pause ;;
            8) view_warp; pause ;;
            9) if [ "$(has_warp_endpoint)" -eq 0 ]; then
                   echo -e "  ${YELLOW}当前没有 WARP 出口。${PLAIN}"; pause
               else
                   read -rp "  确认删除 WARP 出口及全部关联分流规则？[y/N]: " yn || continue
                   if [[ "$yn" =~ ^[Yy]$ ]]; then
                       delete_warp
                       pause
                   fi
               fi ;;
            10) add_socks5_outbound; pause ;;
            11) if ! has_socks5_outbound; then
                    printf '  尚未设置 SOCKS5 出口。\n'; pause
                else
                    read -rp '  确认删除 SOCKS5 出口及全部关联分流规则？[y/N]: ' yn || continue
                    if [[ "$yn" =~ ^[Yy]$ ]]; then delete_socks5_outbound; pause; fi
                fi ;;
            0) return ;;
            *) menu_invalid ;;
        esac
    done
}

# ==================== 入口 ====================
if [ "${1:-}" = --ssh-bark-worker ]; then
    ssh_bark_worker follow
    exit $?
fi
# 只有交互面板会修改代理配置；只读告警进程不应争用面板锁。
acquire_lock
install_dependencies
ensure_config
ensure_service_def_fresh
while true; do
    show_menu
done
