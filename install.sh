#!/usr/bin/env bash
# ====================================================================
#  Sing-box 管理面板 —— 一键安装器
#  用法: bash <(curl -sL https://raw.githubusercontent.com/3922510-creator/singbox/main/install.sh)
#  安装后使用命令: SB  或  sb
# ====================================================================

set -o pipefail

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
BLUE="\033[36m"; PLAIN="\033[0m"

REPO_RAW="https://raw.githubusercontent.com/3922510-creator/singbox/main/singbox.sh"
INSTALL_PATH="/usr/local/bin/sb"
ALIAS_PATH="/usr/local/bin/SB"

msg()  { echo -e "${BLUE}[*]${PLAIN} $1"; }
ok()   { echo -e "${GREEN}[✓]${PLAIN} $1"; }
err()  { echo -e "${RED}[✗]${PLAIN} $1" >&2; }

[[ $EUID -ne 0 ]] && err "请使用 root 用户运行安装器！" && exit 1

# ---------- 安装依赖 ----------
install_deps() {
    local missing=0
    for c in curl jq wget qrencode flock; do
        command -v "$c" &>/dev/null || missing=1
    done
    [ $missing -eq 0 ] && { ok "依赖已就绪"; return; }

    msg "安装依赖 (curl jq wget qrencode flock)..."
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y -qq curl jq wget ufw qrencode util-linux
    elif [ -f /etc/redhat-release ]; then
        yum install -y -q curl jq wget firewalld qrencode util-linux
    else
        err "暂不支持的系统，请手动安装 curl jq wget qrencode flock"
        return 1
    fi
    ok "依赖安装完成"
}

# ---------- 下载主脚本 ----------
download_script() {
    msg "下载管理脚本 -> ${INSTALL_PATH}"
    local tmp
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
    install -m 755 "$tmp" "$INSTALL_PATH"
    rm -f "$tmp"
    ok "主脚本已安装"
}

# ---------- 注册快捷指令 SB / sb ----------
register_shortcut() {
    ln -sf "$INSTALL_PATH" "$ALIAS_PATH"
    ok "快捷指令已注册：${GREEN}SB${PLAIN} 与 ${GREEN}sb${PLAIN}"
}

main() {
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e "        Sing-box 管理面板 · 一键安装"
    echo -e "${BLUE}==================================================${PLAIN}"
    install_deps      || exit 1
    download_script   || exit 1
    register_shortcut

    echo -e "${BLUE}--------------------------------------------------${PLAIN}"
    ok "安装完成！"
    echo -e "  运行命令： ${GREEN}SB${PLAIN}  或  ${GREEN}sb${PLAIN}"
    echo -e "  脚本路径： ${INSTALL_PATH}"
    echo -e "  更新脚本： 重新执行本安装器即可覆盖更新"
    echo -e "${BLUE}--------------------------------------------------${PLAIN}"
}

main "$@"
