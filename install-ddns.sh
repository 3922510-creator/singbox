#!/bin/sh
# Standalone installer: does not install or restart sing-box.
set -eu
[ "$(id -u)" = 0 ] || { echo '请使用 root 运行' >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y jq curl ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq curl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y jq curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq curl ca-certificates
    else
        echo '请先安装 jq、curl 和 ca-certificates' >&2
        exit 1
    fi
fi
work=$(mktemp -d)
trap 'rm -f "$work/ddns.sh"; rmdir "$work"' EXIT
trap 'exit 1' HUP INT TERM
curl -fSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 \
    https://raw.githubusercontent.com/3922510-creator/singbox/main/ddns.sh \
    -o "$work/ddns.sh"
# Keep interactive prompts working when the installer itself is piped to sh.
sh "$work/ddns.sh" --install </dev/tty
