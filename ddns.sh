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
            egress_ip ;;
        *) fail '未知 IP 来源' ;;
    esac
}
local_public_ip() {
    # Inspect the source address of the default IPv4 route, not Docker/VPN NICs.
    # A NAT guest normally has no public address on its own interfaces.
    local_ip=''
    if command -v ip >/dev/null 2>&1; then
        route=$(ip -4 route get 1.1.1.1 2>/dev/null) || route=''
        local_ip=$(printf '%s\n' "$route" | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    if local_ip=$(public_ip "$local_ip" 2>/dev/null); then
        printf '本机路由公网 IPv4：%s\n' "$local_ip" >&2
    else
        local_ip=$(fetch -4 --noproxy '*' https://api4.ipify.org) || return 1
        local_ip=$(public_ip "$local_ip") || return 1
        printf '网卡无可用公网地址，通过独立接口查询本机公网 IPv4：%s\n' "$local_ip" >&2
    fi
    printf '%s\n' "$local_ip"
}
egress_ip() {
    first=$(local_public_ip) || return 1
    second=$(fetch -4 --noproxy '*' -A 'curl/ddns' https://api.ip.sb/ip) || return 1
    second=$(public_ip "$second") || return 1
    [ "$first" = "$second" ] || fail '本机公网 IPv4 与 ip.sb 不一致，保留原 DNS'
    printf '%s\n' "$first"
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
confirm() {
    ask "$1 [y/N]："
    case "$answer" in y|Y) return 0 ;; *) return 1 ;; esac
}
detect_init() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then init=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then init=openrc
    else fail '只支持 systemd / OpenRC'; fi
}
select_source() {
    printf '%s\n' 'IP 来源：1 商家动态域名；2 HTTPS 纯文本 IPv4 接口；3 本机公网 IPv4 + ip.sb 交叉校验'
    ask '选择 [1/2/3]：'
    case "$answer" in
        1) source_mode=hostname; ask '商家动态域名：'; source=$answer ;;
        2) source_mode=url; ask 'HTTPS 查询接口：'; source=$answer ;;
        3) source_mode=egress; source=''
           confirm '出口 IP 已核实等于入站映射 IP？' || fail '未确认，不使用出口 IP' ;;
        *) fail '无效选择' ;;
    esac
    validate
}
check_entry() {
    if [ -e /usr/local/bin/ddns ] || [ -L /usr/local/bin/ddns ]; then
        [ -L /usr/local/bin/ddns ] && [ "$(readlink /usr/local/bin/ddns)" = "$SELF" ] || fail '/usr/local/bin/ddns 已被其他程序占用'
    fi
}
make_entry() {
    mkdir -p /usr/local/bin
    [ -L /usr/local/bin/ddns ] || ln -s "$SELF" /usr/local/bin/ddns
}
upgrade_ddns() {
    [ ! -L "$SELF" ] && [ ! -L "$CONFIG" ] || fail '不支持符号链接安装路径'
    load_config || return 1
    check_entry
    if [ "$init" = openrc ]; then
        grep -F "$SELF --daemon" /etc/init.d/cloudflare-ddns >/dev/null || fail '服务不是已知 DDNS 安装，拒绝重启'
    fi
    printf '%s\n' '将备份并升级 DDNS 脚本，保留域名、Token、IP 来源和自启设置，添加 ddns 菜单。'
    [ "$init" != openrc ] || printf '%s\n' 'OpenRC 会重启 DDNS 服务以加载新脚本（不影响 sing-box / SSH）。'
    confirm '升级 DDNS 脚本？' || fail '已取消'
    sh -n "$0" || return 1
    umask 077
    backup="${SELF}.bak.$(date +%Y%m%d-%H%M%S).$$"
    cp -p "$SELF" "$backup" || return 1
    # Atomic replacement keeps a running shell from reading mixed script versions.
    staged=$(mktemp "${SELF}.new.XXXXXX") || return 1
    trap 'rm -f "$staged"' EXIT
    trap 'exit 1' HUP INT TERM
    cp "$0" "$staged" && chmod 700 "$staged" && cmp -s "$0" "$staged" && mv "$staged" "$SELF" || return 1
    trap - EXIT HUP INT TERM
    make_entry
    if [ "$init" = openrc ]; then rc-service cloudflare-ddns restart; fi
    printf '升级完成，输入 ddns 打开菜单。旧脚本备份：%s\n' "$backup"
}
install_ddns() {
    [ "$(id -u)" = 0 ] || fail '请用 root 安装'
    detect_init
    if [ -f "$CONFIG" ] && [ -f "$SELF" ]; then upgrade_ddns; return; fi
    check_entry
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
    select_source
    zone=$(api "$API/zones/$zone_id") || exit 1
    zone_name=$(printf '%s' "$zone" | jq -er '.result.name')
    case "$record" in "$zone_name"|*."$zone_name") ;; *) fail '目标域名不属于此 Zone' ;; esac
    ip=$(get_ip) || exit 1
    printf '将把 %s 更新为 %s，灰云，每 60 秒检查。不会改端口或 AAAA。\n' "$record" "$ip"
    confirm '安装并修改 DNS？' || fail '已取消'
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
    make_entry
    printf '安装成功。输入 ddns 打开管理菜单。配置：%s\n' "$CONFIG"
}
show_status() {
    load_config || return 1
    detect_init
    printf '  目标域名 : %s\n  IP 来源  : %s\n' "$record" "$(source_label)"
    if [ "$init" = systemd ]; then
        if systemctl is-enabled --quiet cloudflare-ddns.timer; then enabled_text=已开启; else enabled_text=已关闭; fi
        if systemctl is-active --quiet cloudflare-ddns.timer; then active_text=运行中; else active_text=未运行; fi
        printf '  开机自启 : %s\n  定时检查 : %s\n' "$enabled_text" "$active_text"
    else
        if rc-service cloudflare-ddns status >/dev/null 2>&1; then active_text=运行中; else active_text=未运行; fi
        printf '  定时检查 : %s\n' "$active_text"
    fi
    response=$(api --get --data-urlencode "name=$record" "$API/zones/$zone_id/dns_records") || return 1
    printf '%s' "$response" | jq -r '
      [.result[] | select(.type == "A")] |
      if length == 0 then "  解析地址 : 尚无 A 记录"
      else .[] | "  解析地址 : \(.content)\n  代理状态 : \(if .proxied then "橙云代理" else "仅 DNS（灰云）" end)" end'
}
change_source() {
    load_config || return 1
    select_source
    ip=$(get_ip) || return 1
    printf '新的 IP 来源：%s；当前查询值：%s。保存后下次自动检查生效。\n' "$source_mode" "$ip"
    confirm '保存新的 IP 来源？' || return 0
    [ ! -L "$CONFIG" ] || fail '配置不能是符号链接'
    umask 077
    backup="$CONFIG.bak.$(date +%Y%m%d-%H%M%S).$$"
    cp -p "$CONFIG" "$backup" || return 1
    staged=$(mktemp "$CONFIG.new.XXXXXX") || return 1
    trap 'rm -f "$staged"' EXIT
    trap 'exit 1' HUP INT TERM
    jq --arg mode "$source_mode" --arg source "$source" '.source_mode=$mode | .source=$source' "$CONFIG" > "$staged" || return 1
    jq -e . "$staged" >/dev/null && chmod 600 "$staged" && mv "$staged" "$CONFIG" || return 1
    trap - EXIT HUP INT TERM
    printf '配置已保存，备份：%s\n' "$backup"
}
service_action() {
    detect_init
    case "$1" in enable) action_text=开启 ;; disable) action_text=关闭 ;; esac
    confirm "${action_text} DDNS 自动更新？" || return 0
    if [ "$init" = systemd ]; then
        case "$1" in
            enable) systemctl enable --now cloudflare-ddns.timer ;;
            disable) systemctl disable --now cloudflare-ddns.timer ;;
        esac
    else
        case "$1" in
            enable) rc-update add cloudflare-ddns default && rc-service cloudflare-ddns start ;;
            disable) rc-service cloudflare-ddns stop && rc-update del cloudflare-ddns default ;;
        esac
    fi
}
source_label() {
    case "$source_mode" in
        egress) printf '%s' '本机公网 + ip.sb' ;;
        hostname) printf '%s' '商家动态域名' ;;
        url) printf '%s' 'HTTPS 查询接口' ;;
    esac
}
ui_rule() {
    ui_width=${COLUMNS:-0}
    case "$ui_width" in ''|*[!0-9]*) ui_width=0 ;; esac
    if [ "$ui_width" -eq 0 ]; then
        ui_width=$(stty size 2>/dev/null | awk '{print $2}') || ui_width=''
    fi
    case "$ui_width" in ''|*[!0-9]*) ui_width=44 ;; esac
    [ "$ui_width" -le 54 ] || ui_width=54
    [ "$ui_width" -ge 8 ] || ui_width=8
    ui_line=''; ui_i=2
    while [ "$ui_i" -lt "$ui_width" ]; do ui_line="${ui_line}─"; ui_i=$((ui_i + 1)); done
    printf '  %s\n' "$ui_line"
}
ui_clear() {
    # No clear/tput dependency; leave redirected logs free of control characters.
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then printf '\033[H\033[2J'; fi
}
ui_header() {
    ui_clear
    printf '\n'
    ui_rule
    printf '  Cloudflare DDNS 管理面板\n  IPv4 动态解析 · 每 60 秒检查\n'
    ui_rule
}
menu_option() { printf '    %s) %s\n' "$1" "$2"; }
menu_pause() { printf '\n  按回车返回菜单...'; IFS= read -r answer || return 1; }
menu() {
    [ "$(id -u)" = 0 ] || fail '请用 root 打开管理菜单'
    while :; do
        ui_header
        printf '\n  解析管理\n'
        menu_option 1 '状态与解析记录'
        menu_option 2 '公网 IP 交叉校验'
        menu_option 3 '立即更新 DNS'
        menu_option 4 '修改 IP 来源'
        printf '\n  运行与服务\n'
        menu_option 5 '查看运行日志'
        menu_option 6 '开启自动更新'
        menu_option 7 '关闭自动更新'
        printf '\n'
        menu_option 0 '退出脚本'
        printf '\n'
        ask '  请选择 [0-7]：'
        case "$answer" in 0) return ;; esac
        ui_clear
        printf '\n'
        ui_rule
        case "$answer" in
            1) printf '  状态与解析记录\n' ;; 2) printf '  公网 IP 交叉校验\n' ;;
            3) printf '  立即更新 DNS\n' ;; 4) printf '  修改 IP 来源\n' ;;
            5) printf '  运行日志\n' ;; 6|7) printf '  自动更新设置\n' ;;
            *) printf '  提示\n' ;;
        esac
        ui_rule
        printf '\n'
        # Separate processes isolate fatal errors; a failed query must not close the menu.
        case "$answer" in
            1) (show_status) && : || printf '%s\n' '状态查询失败' ;;
            2) (egress_ip) && : || printf '%s\n' '出口校验失败，不修改 DNS' ;;
            3) if confirm '立即更新 DNS？'; then (load_config || exit 1; update) && : || printf '%s\n' '更新失败'; fi ;;
            4) (change_source) && : || printf '%s\n' '配置未完成修改' ;;
            5) (detect_init
                if [ "$init" = systemd ]; then journalctl -u cloudflare-ddns.service -n 30 --no-pager
                else tail -n 30 /var/log/cloudflare-ddns.log; fi) && : || printf '%s\n' '日志读取失败' ;;
            6) (service_action enable) && : || printf '%s\n' '操作失败' ;;
            7) (service_action disable) && : || printf '%s\n' '操作失败' ;;
            0) return ;;
            *) printf '%s\n' '  无效选择，请输入 0-7' ;;
        esac
        menu_pause || return 0
    done
}
main() {
    for dependency in curl jq; do command -v "$dependency" >/dev/null 2>&1 || fail "缺少 $dependency"; done
    case "${1:-}" in
        ''|--menu) menu ;;
        --install) install_ddns ;;
        --once) load_config; update ;;
        --daemon) while :; do
            # Isolate fatal failures; always retry and re-read config next time.
            (load_config || exit 1; update) || printf '%s\n' '更新失败，60 秒后重试' >&2
            sleep 60
        done ;;
        *) printf '用法：sh %s --menu | --install | --once | --daemon\n' "$0"; exit 1 ;;
    esac
}
# Test harness sources functions without invoking installation or network calls.
[ "${DDNS_TEST_SOURCE:-0}" = 1 ] || main "$@"
