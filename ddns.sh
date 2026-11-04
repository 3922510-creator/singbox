#!/bin/sh
# Cloudflare NAT IPv4 DDNS. Runtime dependencies: curl, jq, CA certificates.
set -eu
CONFIG=${DDNS_CONFIG:-/etc/cloudflare-ddns/config.json}
API=https://api.cloudflare.com/client/v4
SELF=/usr/local/lib/cloudflare-ddns.sh
fail() { printf '%s\n' "错误：$*" >&2; exit 1; }
fetch() { curl -fsS --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 25 "$@"; }
public_ip() {
    printf '%s\n' "$1" | jq -Rer '
      capture("^(?<a>[0-9]{1,3})\\.(?<b>[0-9]{1,3})\\.(?<c>[0-9]{1,3})\\.(?<d>[0-9]{1,3})$") |
      [.a,.b,.c,.d] | map(tonumber) |
      select(all(.[]; . <= 255)) |
      select(.[0] != 0 and .[0] != 10 and .[0] != 127 and .[0] < 224) |
      select((.[0] == 100 and .[1] >= 64 and .[1] <= 127) | not) |
      select((.[0] == 169 and .[1] == 254) | not) |
      select((.[0] == 172 and .[1] >= 16 and .[1] <= 31) | not) |
      select((.[0] == 192 and (.[1] == 168 or (.[1] == 0 and (.[2] == 0 or .[2] == 2)))) | not) |
      select((.[0] == 198 and (.[1] == 18 or .[1] == 19 or (.[1] == 51 and .[2] == 100))) | not) |
      select((.[0] == 203 and .[1] == 0 and .[2] == 113) | not) |
      map(tostring) | join(".")' || fail '来源不是有效公网 IPv4，保留原 DNS'
}
valid_domain() {
    printf '%s\n' "$1" | jq -Re 'length <= 253 and contains(".") and
      (split(".") | all(.[]; test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")))' >/dev/null
}
get_ip() {
    case "$source_mode" in
        hostname)
            # Use DNS-over-HTTPS so no dig/getent/python package is required.
            result=$(fetch -H 'Accept: application/dns-json' --get --data-urlencode "name=$source" \
                --data-urlencode 'type=A' https://cloudflare-dns.com/dns-query) || return 1
            value=$(printf '%s' "$result" | jq -er 'select(.Status == 0) |
                [.Answer[]? | select(.type == 1) | .data] | unique | select(length == 1) | .[0]') || fail '商家域名必须解析到一个 IPv4'
            public_ip "$value" ;;
        url) value=$(fetch "$source") || return 1; public_ip "$value" ;;
        egress)
            first=$(fetch https://api4.ipify.org) || return 1
            second=$(fetch https://ipv4.icanhazip.com) || return 1
            [ "$first" = "$second" ] || fail '出口查询结果不一致，保留原 DNS'
            public_ip "$first" ;;
        *) fail '未知 IP 来源' ;;
    esac
}
api() {
    # Feed the credential via stdin, not the process argument list.
    response=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
        fetch --config - -H 'Content-Type: application/json' "$@") || return 1
    printf '%s' "$response" | jq -e '.success == true' >/dev/null || fail 'Cloudflare API 失败，请检查权限和 Zone ID'
    printf '%s' "$response"
}
load_config() {
    token=$(jq -er '.token' "$CONFIG") || return 1
    zone_id=$(jq -er '.zone_id' "$CONFIG") || return 1
    record=$(jq -er '.record' "$CONFIG") || return 1
    source_mode=$(jq -er '.source_mode' "$CONFIG") || return 1
    source=$(jq -r '.source // ""' "$CONFIG") || return 1
    validate
}
validate() {
    case "$token" in ''|*[!a-zA-Z0-9_-]*) fail 'Token 格式不正确' ;; esac
    printf '%s\n' "$zone_id" | grep -Eq '^[a-fA-F0-9]{32}$' || fail 'Zone ID 应为 32 位十六进制字符'
    valid_domain "$record" || fail '目标必须为完整域名，不带协议或端口'
    case "$source_mode" in
        hostname) valid_domain "$source" || fail '来源域名无效'; [ "$source" != "$record" ] || fail '来源不能是目标域名' ;;
        url) case "$source" in https://?*) ;; *) fail '来源接口必须是 HTTPS' ;; esac ;;
        egress) ;; *) fail '未知 IP 来源' ;;
    esac
}
update() {
    ip=$(get_ip) || return 1
    base="$API/zones/$zone_id/dns_records"
    response=$(api --get --data-urlencode "name=$record" --data-urlencode per_page=100 "$base") || return 1
    records=$(printf '%s' "$response" | jq -ec '.result | select(type == "array")') || fail 'DNS 响应无效'
    printf '%s' "$records" | jq -e 'any(.[]; .type == "CNAME")' >/dev/null && fail '已有同名 CNAME，请手动处理'
    count=$(printf '%s' "$records" | jq '[.[] | select(.type == "A")] | length')
    [ "$count" -le 1 ] || fail '存在多条同名 A 记录，请手动处理'
    if [ "$count" = 1 ]; then
        current=$(printf '%s' "$records" | jq -c '.[] | select(.type == "A")')
        if printf '%s' "$current" | jq -e --arg ip "$ip" '.content == $ip and .proxied == false' >/dev/null; then
            printf '%s 无变化：%s\n' "$record" "$ip"
            return
        fi
        id=$(printf '%s' "$current" | jq -er '.id')
        method=PATCH; endpoint="$base/$id"
    else
        method=POST; endpoint=$base
    fi
    data=$(jq -nc --arg name "$record" --arg ip "$ip" '{type:"A",name:$name,content:$ip,ttl:60,proxied:false}')
    api -X "$method" --data "$data" "$endpoint" >/dev/null || return 1
    printf '%s 已更新为 %s（仅 DNS）\n' "$record" "$ip"
}
ask() { printf '%s' "$1"; IFS= read -r answer || exit 1; }
install_ddns() {
    [ "$(id -u)" = 0 ] || fail '请用 root 安装'
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then init=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then init=openrc
    else fail '只支持 systemd / OpenRC'; fi
    for path in /etc/cloudflare-ddns "$SELF" /usr/local/lib/cloudflare-ddns.py /etc/systemd/system/cloudflare-ddns.service /etc/systemd/system/cloudflare-ddns.timer /etc/init.d/cloudflare-ddns; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || fail "已有安装或同名文件，拒绝覆盖：$path"
    done
    printf '%s\n' 'Cloudflare Token 需对应域名的 DNS 编辑、区域读取权限。仅本机输入，不要发给别人。'
    tty_state=$(stty -g)
    trap 'stty "$tty_state"' EXIT
    trap 'exit 1' HUP INT TERM
    printf 'API Token（隐藏输入）：'; stty -echo
    IFS= read -r token || exit 1
    stty "$tty_state"; trap - EXIT HUP INT TERM; printf '\n'
    ask 'Zone ID：'; zone_id=$answer
    ask '完整目标域名（如 nat.example.com）：'; record=$answer
    printf '%s\n' 'IP 来源：1 商家动态域名；2 HTTPS 纯文本 IPv4 接口；3 本机出口 IP'
    ask '选择 [1/2/3]：'
    case "$answer" in
        1) source_mode=hostname; ask '商家动态域名：'; source=$answer ;;
        2) source_mode=url; ask 'HTTPS 查询接口：'; source=$answer ;;
        3) source_mode=egress; source=''
           ask '必须确认出口 IP 等于入站映射 IP。确认请输入 YES：'
           [ "$answer" = YES ] || fail '未确认，不使用出口 IP' ;;
        *) fail '无效选择' ;;
    esac
    validate
    zone=$(api "$API/zones/$zone_id") || exit 1
    zone_name=$(printf '%s' "$zone" | jq -er '.result.name')
    case "$record" in "$zone_name"|*."$zone_name") ;; *) fail '目标域名不属于此 Zone' ;; esac
    ip=$(get_ip) || exit 1
    printf '将把 %s 更新为 %s，灰云，每 60 秒检查。不会改端口或 AAAA。\n' "$record" "$ip"
    ask '确认安装并修改 DNS？请输入 YES：'; [ "$answer" = YES ] || fail '已取消'
    update || exit 1
    umask 077
    mkdir /etc/cloudflare-ddns
    printf '%s' "$token" | jq -Rs --arg zone_id "$zone_id" --arg record "$record" \
        --arg source_mode "$source_mode" --arg source "$source" \
        '{token:.,zone_id:$zone_id,record:$record,source_mode:$source_mode,source:$source}' > "$CONFIG"
    mkdir -p /usr/local/lib
    cp "$0" "$SELF"; chmod 700 "$SELF"
    if [ "$init" = systemd ]; then
        cat > /etc/systemd/system/cloudflare-ddns.service <<'UNIT'
[Unit]
Description=Cloudflare NAT DDNS
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/lib/cloudflare-ddns.sh --once
TimeoutStartSec=180
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
UNIT
        cat > /etc/systemd/system/cloudflare-ddns.timer <<'UNIT'
[Unit]
Description=Check Cloudflare DDNS every minute
[Timer]
OnBootSec=30s
OnUnitInactiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
UNIT
        systemctl daemon-reload
        systemctl enable --now cloudflare-ddns.timer
    else
        cat > /etc/init.d/cloudflare-ddns <<'UNIT'
#!/sbin/openrc-run
description="Cloudflare NAT DDNS"
supervisor="supervise-daemon"
command="/bin/sh"
command_args="/usr/local/lib/cloudflare-ddns.sh --daemon"
respawn_delay=5
respawn_max=0
output_log="/var/log/cloudflare-ddns.log"
error_log="/var/log/cloudflare-ddns.log"
depend() { need net; after firewall; }
UNIT
        chmod 755 /etc/init.d/cloudflare-ddns
        rc-update add cloudflare-ddns default
        rc-service cloudflare-ddns start
    fi
    printf '安装成功。配置：%s\n手动检查：sh %s --once\n' "$CONFIG" "$SELF"
}
main() {
    for dependency in curl jq; do command -v "$dependency" >/dev/null 2>&1 || fail "缺少 $dependency"; done
    case "${1:-}" in
        --install) install_ddns ;;
        --once) load_config; update ;;
        --daemon) while :; do
            # Isolate fatal failures; always retry and re-read config next time.
            (load_config || exit 1; update) || printf '%s\n' '更新失败，60 秒后重试' >&2
            sleep 60
        done ;;
        *) printf '用法：sh %s --install | --once | --daemon\n' "$0"; exit 1 ;;
    esac
}
# Test harness sources functions without invoking installation or network calls.
[ "${DDNS_TEST_SOURCE:-0}" = 1 ] || main "$@"
