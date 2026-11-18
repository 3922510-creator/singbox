#!/bin/sh
# ====================================================================
#  Sing-box 管理面板 —— 一键安装器
#  Debian / Ubuntu / RHEL / Alpine 通用
#
#  用法:
#    Debian/Ubuntu: bash <(curl -sL https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh)
#    Alpine (无 bash): wget -qO- https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh | sh
#
#  安装后使用命令: SB  或  sb
#
#  注：本安装器刻意写成 POSIX sh —— Alpine / 精简 rootfs 自带 ash 就能直接跑，
#      而主脚本 singbox.sh 需要 bash，所以这里会把 bash 一并装好。
# ====================================================================

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[36m"; PLAIN="\033[0m"

REPO_RAW="${SINGBOX_RAW:-https://raw.githubusercontent.com/3922510-creator/singbox/main/singbox.sh}"  # 可用 SINGBOX_RAW 指定镜像/加速地址
INSTALL_PATH="/usr/local/bin/sb"
ALIAS_PATH="/usr/local/bin/SB"

msg() { printf '%b[*]%b %b\n' "$BLUE" "$PLAIN" "$1"; }
ok()  { printf '%b[✓]%b %b\n' "$GREEN" "$PLAIN" "$1"; }
err() { printf '%b[✗]%b %b\n' "$RED" "$PLAIN" "$1" >&2; }

[ "$(id -u)" -ne 0 ] && err "请使用 root 用户运行安装器！" && exit 1

# ---------- 发行版判定 ----------
detect_family() {
    if [ -f /etc/alpine-release ]; then echo alpine; return; fi
    if [ -f /etc/debian_version ]; then echo debian; return; fi
    if [ -f /etc/redhat-release ]; then echo redhat; return; fi
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
            *alpine*) echo alpine; return ;;
            *debian*|*ubuntu*) echo debian; return ;;
            *rhel*|*centos*|*fedora*|*rocky*|*almalinux*) echo redhat; return ;;
        esac
    fi
    echo unknown
}

# Alpine 默认镜像可能只启用 main 仓库；qrencode 在 community 里
apk_ensure_community() {
    repos=/etc/apk/repositories
    [ -f "$repos" ] || return 0
    grep -qE '/community$' "$repos" && return 0
    base=$(sed -n 's#^\([^#]*\)/main$#\1#p' "$repos" | head -1)
    [ -n "$base" ] || return 0
    printf '%s/community\n' "$base" >> "$repos"
    msg "已启用 Alpine community 仓库：${base}/community"
}

# ---------- 安装依赖 ----------
install_deps() {
    family=$(detect_family)
    missing=0
    for c in curl jq wget qrencode flock bash; do
        command -v "$c" >/dev/null 2>&1 || missing=1
    done
    if [ "$missing" -eq 0 ]; then ok "依赖已就绪"; return 0; fi

    msg "安装依赖 (curl jq wget qrencode flock bash)  系统: ${family}"
    case "$family" in
        debian)
            apt-get update -qq && apt-get install -y -qq curl jq wget ufw qrencode util-linux bash
            ;;
        redhat)
            yum install -y -q curl jq wget firewalld qrencode util-linux bash
            ;;
        alpine)
            apk update -q 2>/dev/null
            apk add --no-cache curl jq wget util-linux bash ca-certificates kmod iproute2
            apk_ensure_community
            apk add --no-cache libqrencode-tools 2>/dev/null \
                || printf '%b提示：qrencode（二维码）未能安装，不影响节点功能%b\n' "$YELLOW" "$PLAIN"
            ;;
        *)
            err "暂不支持的系统（${family}），请手动安装 curl jq wget qrencode flock bash"
            return 1
            ;;
    esac
    ok "依赖安装完成"
}

# ---------- 下载主脚本 ----------
download_script() {
    msg "下载管理脚本 -> ${INSTALL_PATH}"
    tmp=$(mktemp)
    if ! curl -sL --max-time 60 -o "$tmp" "$REPO_RAW"; then
        err "下载失败，请检查网络或稍后重试"
        rm -f "$tmp"; return 1
    fi
    # 简单完整性校验：确认是 bash 脚本
    if ! head -n1 "$tmp" | grep -q 'bash'; then
        err "下载内容异常（非脚本），已放弃安装"
        rm -f "$tmp"; return 1
    fi
    install -m 755 "$tmp" "$INSTALL_PATH" || { cp "$tmp" "$INSTALL_PATH" && chmod 755 "$INSTALL_PATH"; }
    rm -f "$tmp"
    ok "主脚本已安装"
}

# ---------- 注册快捷指令 SB / sb ----------
register_shortcut() {
    ln -sf "$INSTALL_PATH" "$ALIAS_PATH"
    ok "快捷指令已注册：${GREEN}SB${PLAIN} 与 ${GREEN}sb${PLAIN}"
}

main() {
    printf '%b==================================================%b\n' "$BLUE" "$PLAIN"
    printf '        Sing-box 管理面板 · 一键安装\n'
    printf '%b==================================================%b\n' "$BLUE" "$PLAIN"
    install_deps      || exit 1
    download_script   || exit 1
    register_shortcut

    printf '%b--------------------------------------------------%b\n' "$BLUE" "$PLAIN"
    ok "安装完成！"
    printf '  运行命令： %bSB%b  或  %bsb%b\n' "$GREEN" "$PLAIN" "$GREEN" "$PLAIN"
    printf '  脚本路径： %s\n' "$INSTALL_PATH"
    printf '  更新脚本： 重新执行本安装器即可覆盖更新\n'
    printf '%b--------------------------------------------------%b\n' "$BLUE" "$PLAIN"
}

main "$@"
