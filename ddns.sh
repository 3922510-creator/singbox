#!/bin/sh
# Cloudflare NAT IPv4 DDNS. Runtime dependencies: curl, jq, CA certificates.
set -eu
CONFIG=${DDNS_CONFIG:-/etc/cloudflare-ddns/config.json}
API=https://api.cloudflare.com/client/v4
SELF=/usr/local/lib/cloudflare-ddns.sh
STATE=${DDNS_STATE:-/var/lib/cloudflare-ddns}
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
# Three separate free HTTPS services. No NIC inspection or provider DNS lookup.
ip_endpoints() {
    printf '%s\n' https://api.ip.sb/ip https://api4.ipify.org https://ipv4.icanhazip.com
}
get_ip() {
    agreed=''
    for endpoint in $(ip_endpoints); do
        value=$(fetch -4 --noproxy '*' -A 'curl/ddns' "$endpoint") || {
            printf '接口查询失败：%s；保留原 DNS\n' "$endpoint" >&2
            return 1
        }
        value=$(public_ip "$value") || return 1
        case "$endpoint" in
            *api.ip.sb*) endpoint_name=ip.sb ;;
            *ipify.org*) endpoint_name=ipify ;;
            *icanhazip.com*) endpoint_name=icanhazip ;;
        esac
        printf '  %-10s : %s\n' "$endpoint_name" "$value" >&2
        if [ -n "$agreed" ] && [ "$agreed" != "$value" ]; then
            fail '三个接口的公网 IPv4 不一致，保留原 DNS'
        fi
        agreed=$value
    done
    [ -n "$agreed" ] || return 1
    printf '%s\n' "$agreed"
}
init_state() {
    umask 077
    [ ! -L "$STATE" ] || fail '日志目录不能是符号链接'
    mkdir -p "$STATE" && chmod 700 "$STATE" || return 1
}
record_change() (
    # update() holds the writer lock; replace atomically so readers never see a partial log.
    staged=$(mktemp "$STATE/changes.XXXXXX") || exit 1
    trap 'rm -f "$staged"' EXIT
    trap 'exit 1' HUP INT TERM
    if [ -f "$STATE/changes.log" ]; then tail -n 9 "$STATE/changes.log" > "$staged" || exit 1; fi
    printf '%s  %s  %s -> %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$record" "$1" "$2" >> "$staged"
    chmod 600 "$staged" && mv "$staged" "$STATE/changes.log"
)
show_changes() {
    if [ -s "$STATE/changes.log" ]; then cat "$STATE/changes.log"
    else printf '%s\n' '  暂无 IP 更换记录（只保留最近 10 条）'; fi
}
validate_bark() {
    # Optional user:password@ is handled by curl as Basic Auth, over the same URL.
    # Reject quotes, backslashes and controls before feeding the URL to curl's config.
    printf '%s' "$1" | jq -Rse 'test("^https?://([^/?#[:space:]@]+:[^/?#[:space:]@]*@)?[^/?#[:space:]@]+(/[A-Za-z0-9_.~%-]+)+/?$") and
        (contains("\"") | not) and (contains("\\") | not) and
        (test("[[:cntrl:]]") | not)' >/dev/null
}
send_bark() {
    [ -n "${bark_url:-}" ] || return 0
    validate_bark "$bark_url" || { printf '%s\n' 'Bark 链接格式无效' >&2; return 1; }
    payload=$(jq -nc --arg title "$1" --arg body "$2" '{title:$title,body:$body,group:"DDNS"}') || return 1
    # The device key and Basic Auth credentials stay out of argv and error messages.
    notify_response=$(printf 'url = "%s"\n' "${bark_url%/}" |
        curl -fsS --noproxy '*' --proto '=http,https' --connect-timeout 10 --max-time 25 \
            --config - --basic -X POST -H 'Content-Type: application/json' --data "$payload" 2>/dev/null) || {
        printf '%s\n' 'Bark 请求失败（网络、证书或 HTTP 错误）' >&2; return 1;
    }
    printf '%s' "$notify_response" | jq -e '.code == 200' >/dev/null 2>&1 || {
        printf '%s\n' 'Bark 服务端未确认接收，请检查链接和设备 Key' >&2; return 1;
    }
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
    bark_url=$(jq -r '.bark_url // ""' "$CONFIG") || return 1
    validate
}
validate() {
    case "$token" in ''|*[!a-zA-Z0-9_-]*) fail 'Token 格式不正确' ;; esac
    printf '%s\n' "$zone_id" | grep -Eq '^[a-fA-F0-9]{32}$' || fail 'Zone ID 应为 32 位十六进制字符'
    valid_domain "$record" || fail '目标必须为完整域名，不带协议或端口'
}
update() (
    init_state || exit 1
    lock="$STATE/update.lock"
    if ! mkdir "$lock" 2>/dev/null; then
        # Reclaim only a dead, numeric PID. Never kill a process to obtain this lock.
        owner=$(cat "$lock/pid" 2>/dev/null) || owner=''
        case "$owner" in ''|*[!0-9]*) fail 'DDNS 正在更新，稍后重试' ;; esac
        if kill -0 "$owner" 2>/dev/null; then fail 'DDNS 正在更新，稍后重试'; fi
        rm -f "$lock/pid" && rmdir "$lock" && mkdir "$lock" || exit 1
    fi
    trap 'rm -f "$lock/pid"; rmdir "$lock"' EXIT
    trap 'exit 1' HUP INT TERM
    # $$ stays equal to the parent in POSIX subshells; /proc gives this worker's PID.
    update_pid=$$
    if [ -r /proc/self/stat ]; then IFS=' ' read -r update_pid ignored < /proc/self/stat; fi
    printf '%s\n' "$update_pid" > "$lock/pid"
    update_dns
)
update_dns() {
    ip=$(get_ip) || return 1
    base="$API/zones/$zone_id/dns_records"
    response=$(api --get --data-urlencode "name=$record" --data-urlencode per_page=100 "$base") || return 1
    records=$(printf '%s' "$response" | jq -ec '.result | select(type == "array")') || fail 'DNS 响应无效'
    printf '%s' "$records" | jq -e 'any(.[]; .type == "CNAME")' >/dev/null && fail '已有同名 CNAME，请手动处理'
    count=$(printf '%s' "$records" | jq '[.[] | select(.type == "A")] | length')
    [ "$count" -le 1 ] || fail '存在多条同名 A 记录，请手动处理'
    if [ "$count" = 1 ]; then
        current=$(printf '%s' "$records" | jq -c '.[] | select(.type == "A")')
        previous=$(printf '%s' "$current" | jq -er '.content') || return 1
        if printf '%s' "$current" | jq -e --arg ip "$ip" '.content == $ip and .proxied == false' >/dev/null; then
            printf '%s 无变化：%s\n' "$record" "$ip"
            return
        fi
        id=$(printf '%s' "$current" | jq -er '.id')
        method=PATCH; endpoint="$base/$id"
    else
        method=POST; endpoint=$base; previous=''
    fi
    data=$(jq -nc --arg name "$record" --arg ip "$ip" '{type:"A",name:$name,content:$ip,ttl:60,proxied:false}')
    api -X "$method" --data "$data" "$endpoint" >/dev/null || return 1
    printf '%s 已更新为 %s（仅 DNS）\n' "$record" "$ip"
    # Initial creation and changing only the proxy flag are not IP changes.
    if [ -n "$previous" ] && [ "$previous" != "$ip" ]; then
        record_change "$previous" "$ip" || { printf '%s\n' 'DNS 已更新，但换 IP 记录写入失败' >&2; return 1; }
        if [ -n "${bark_url:-}" ]; then
            send_bark 'DDNS IP 已更换' "$record: $previous -> $ip" || printf '%s\n' 'DNS 已更新，Bark 通知失败；可从菜单测试通知' >&2
        fi
    fi
}
ask() { printf '%s' "$1"; IFS= read -r answer || exit 1; }
confirm() {
    ask "$1 [y/N]："
    case "$answer" in y|Y) return 0 ;; *) return 1 ;; esac
}
save_bark() (
    umask 077
    [ ! -L "$CONFIG" ] || fail '配置不能是符号链接'
    backup="$CONFIG.bak.$(date +%Y%m%d-%H%M%S).$$"
    cp -p "$CONFIG" "$backup" || exit 1
    staged=$(mktemp "$CONFIG.new.XXXXXX") || exit 1
    trap 'rm -f "$staged"' EXIT
    trap 'exit 1' HUP INT TERM
    # The webhook key is supplied on stdin, not exposed in jq's argv.
    printf '%s' "$bark_url" | jq -Rs --slurpfile old "$CONFIG" '$old[0] + {bark_url:.}' > "$staged" || exit 1
    jq -e . "$staged" >/dev/null && chmod 600 "$staged" && mv "$staged" "$CONFIG" || exit 1
    printf '  配置已保存，备份：%s\n' "$backup"
)
configure_bark() {
    load_config || return 1
    printf '%s\n' '  填自建或官方 Bark 基础推送链接：' '  http(s)://[用户名:密码@]服务器[:端口]/[反代前缀/]设备Key' '  不要带标题、正文或查询参数；留空关闭通知。' '  链接隐藏输入，不会显示或写入日志。'
    tty_state=$(stty -g) || return 1
    trap 'stty "$tty_state"' EXIT
    trap 'exit 1' HUP INT TERM
    printf '  Bark 链接：'; stty -echo
    IFS= read -r bark_url || exit 1
    stty "$tty_state"; trap - EXIT HUP INT TERM; printf '\n'
    if [ -n "$bark_url" ]; then validate_bark "$bark_url" || fail 'Bark 链接格式无效'; fi
    case "$bark_url" in http://*) printf '%s\n' '  注意：HTTP 明文传输 Key，跨公网建议 HTTPS。' ;; esac
    if [ -n "$bark_url" ]; then action_text='保存 Bark Webhook？'; else action_text='关闭 Bark 通知？'; fi
    confirm "$action_text" || return 0
    save_bark || return 1
    printf '%s\n' '  换 IP 后自动推送；可选 9 发送测试通知。'
}
test_bark() {
    load_config || return 1
    [ -n "$bark_url" ] || fail '尚未配置 Bark，请先选 8'
    confirm '发送一条 Bark 测试通知？' || return 0
    send_bark 'DDNS 测试通知' "$record: Bark Webhook 连接测试，未修改 DNS。" || return 1
    printf '%s\n' '  Bark 服务端已确认接收（code=200），请检查手机是否收到。'
}
detect_init() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then init=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then init=openrc
    else fail '只支持 systemd / OpenRC'; fi
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
upgrade_unit() (
    [ "$init" = systemd ] || exit 0
    unit=/etc/systemd/system/cloudflare-ddns.service
    [ -f "$unit" ] && [ ! -L "$unit" ] || fail '未找到标准 DDNS service，拒绝自动修改'
    grep -Fx "ExecStart=/bin/sh $SELF --once" "$unit" >/dev/null ||
        grep -Fx "ExecStart=/bin/sh $SELF --scheduled" "$unit" >/dev/null || fail '不是已知 DDNS service，拒绝修改'
    if grep -q '^StateDirectory=' "$unit"; then
        grep -Fx 'StateDirectory=cloudflare-ddns' "$unit" >/dev/null || fail '已有不同的 StateDirectory，请先人工核对'
    fi
    [ "$(grep -c '^\[Service\]$' "$unit")" = 1 ] || fail 'Service 段格式异常'
    umask 077
    staged=$(mktemp "$unit.new.XXXXXX") || exit 1
    trap 'rm -f "$staged"' EXIT
    trap 'exit 1' HUP INT TERM
    awk -v command="ExecStart=/bin/sh $SELF --scheduled" '
      /^StateDirectory(Mode)?=/ {next}
      /^ExecStart=/ {$0=command}
      {print}
      $0=="[Service]" {print "StateDirectory=cloudflare-ddns"; print "StateDirectoryMode=0700"}
      ' "$unit" > "$staged" || exit 1
    grep -Fx 'StateDirectory=cloudflare-ddns' "$staged" >/dev/null &&
        grep -Fx "ExecStart=/bin/sh $SELF --scheduled" "$staged" >/dev/null || exit 1
    if cmp -s "$unit" "$staged"; then exit 0; fi
    unit_backup="$unit.bak.$(date +%Y%m%d-%H%M%S).$$"
    cp -p "$unit" "$unit_backup" && chmod 600 "$staged" || exit 1
    # Only ExecStart and the two StateDirectory directives may differ.
    diff -u "$unit" "$staged" || [ "$?" = 1 ] || exit 1
    mv "$staged" "$unit" || exit 1
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$unit" || { cp -p "$unit_backup" "$unit"; exit 1; }
    fi
    systemctl daemon-reload || { cp -p "$unit_backup" "$unit"; systemctl daemon-reload; exit 1; }
    printf '  service 已更新，备份：%s\n' "$unit_backup"
)
upgrade_ddns() {
    [ ! -L "$SELF" ] && [ ! -L "$CONFIG" ] || fail '不支持符号链接安装路径'
    load_config || return 1
    check_entry
    if [ "$init" = openrc ]; then
        grep -F "$SELF --daemon" /etc/init.d/cloudflare-ddns >/dev/null || fail '服务不是已知 DDNS 安装，拒绝重启'
    fi
    printf '%s\n' '将备份并升级 DDNS 脚本，保留域名、Token、自启和 Bark 设置。日志改为最近 10 条成功换 IP 记录。' 'systemd 会备份并更新 DDNS service 的日志目录权限和静默运行参数，不启停服务。'
    [ "$init" != openrc ] || printf '%s\n' 'OpenRC 会重启 DDNS 服务以加载新脚本（不影响 sing-box / SSH）。'
    confirm '升级 DDNS 脚本？' || fail '已取消'
    sh -n "$0" || return 1
    upgrade_unit || return 1
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
    validate
    zone=$(api "$API/zones/$zone_id") || exit 1
    zone_name=$(printf '%s' "$zone" | jq -er '.result.name')
    case "$record" in "$zone_name"|*."$zone_name") ;; *) fail '目标域名不属于此 Zone' ;; esac
    ip=$(get_ip) || exit 1
    printf '将把 %s 更新为 %s，灰云，每 60 秒检查，三个接口全部一致才更新。不会改端口或 AAAA。\n' "$record" "$ip"
    printf '%s\n' '注意：接口获取的是公网出口 IPv4，请确保它与商家入站映射 IP 相同。'
    confirm '安装并修改 DNS？' || fail '已取消'
    update || exit 1
    umask 077
    mkdir /etc/cloudflare-ddns
    printf '%s' "$token" | jq -Rs --arg zone_id "$zone_id" --arg record "$record" \
        '{token:.,zone_id:$zone_id,record:$record}' > "$CONFIG"
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
ExecStart=/bin/sh /usr/local/lib/cloudflare-ddns.sh --scheduled
StateDirectory=cloudflare-ddns
StateDirectoryMode=0700
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
    printf '  目标域名 : %s\n  IP 校验  : 三接口全部一致\n' "$record"
    if [ -n "$bark_url" ]; then printf '  Bark通知 : 已配置\n'; else printf '  Bark通知 : 未配置\n'; fi
    if [ "$init" = systemd ]; then
        if systemctl is-enabled --quiet cloudflare-ddns.timer; then enabled_text=已开启; else enabled_text=已关闭; fi
        if systemctl is-active --quiet cloudflare-ddns.timer; then active_text=运行中; else active_text=未运行; fi
        printf '  开机自启 : %s\n  定时检查 : %s\n' "$enabled_text" "$active_text"
    else
        if rc-service cloudflare-ddns status >/dev/null 2>&1; then active_text=运行中; else active_text=未运行; fi
        if rc-update show default 2>/dev/null | grep -Eq '^[[:space:]]*cloudflare-ddns[[:space:]]'; then enabled_text=已开启; else enabled_text=已关闭; fi
        printf '  开机自启 : %s\n  定时检查 : %s\n' "$enabled_text" "$active_text"
    fi
    response=$(api --get --data-urlencode "name=$record" "$API/zones/$zone_id/dns_records") || return 1
    printf '%s' "$response" | jq -r '
      [.result[] | select(.type == "A")] |
      if length == 0 then "  解析地址 : 尚无 A 记录"
      else .[] | "  解析地址 : \(.content)\n  代理状态 : \(if .proxied then "橙云代理" else "仅 DNS（灰云）" end)" end'
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
    (show_status) && : || printf '%s\n' '  状态读取不完整，请查看日志'
    ui_rule
}
menu_option() { printf '    %s) %s\n' "$1" "$2"; }
menu_pause() { printf '\n  按回车返回菜单...'; IFS= read -r answer || return 1; }
menu() {
    [ "$(id -u)" = 0 ] || fail '请用 root 打开管理菜单'
    while :; do
        ui_header
        printf '\n  解析管理\n'
        menu_option 1 '刷新首页状态'
        menu_option 2 '公网 IP 交叉校验'
        menu_option 3 '立即更新 DNS'
        menu_option 4 '查看查询接口'
        printf '\n  运行与服务\n'
        menu_option 5 '最近 10 条换 IP 记录'
        menu_option 6 '开启自动更新'
        menu_option 7 '关闭自动更新'
        menu_option 8 'Bark 通知设置'
        menu_option 9 '发送测试通知'
        printf '\n'
        menu_option 0 '退出脚本'
        printf '\n'
        ask '  请选择 [0-9]：'
        case "$answer" in 0) return ;; 1) continue ;; esac
        ui_clear
        printf '\n'
        ui_rule
        case "$answer" in
            2) printf '  公网 IP 交叉校验\n' ;;
            3) printf '  立即更新 DNS\n' ;; 4) printf '  查询接口\n' ;;
            5) printf '  最近 10 条换 IP 记录\n' ;; 6|7) printf '  自动更新设置\n' ;;
            8) printf '  Bark 通知设置\n' ;; 9) printf '  测试通知\n' ;;
            *) printf '  提示\n' ;;
        esac
        ui_rule
        printf '\n'
        # Separate processes isolate fatal errors; a failed query must not close the menu.
        case "$answer" in
            2) (verified=$(get_ip) || exit 1; printf '\n  三接口校验通过：%s\n' "$verified") && : || printf '%s\n' '接口校验失败，不修改 DNS' ;;
            3) if confirm '立即更新 DNS？'; then (load_config || exit 1; update) && : || printf '%s\n' '更新失败'; fi ;;
            4) ip_endpoints; printf '\n  三个接口均返回相同公网 IPv4 才更新。\n  任一失败、返回无效值或不一致，均保留原 DNS。\n' ;;
            5) (show_changes) && : || printf '%s\n' '日志读取失败' ;;
            6) (service_action enable) && : || printf '%s\n' '操作失败' ;;
            7) (service_action disable) && : || printf '%s\n' '操作失败' ;;
            8) (configure_bark) && : || printf '%s\n' 'Bark 配置失败' ;;
            9) (test_bark) && : || printf '%s\n' '测试通知失败' ;;
            0) return ;;
            *) printf '%s\n' '  无效选择，请输入 0-9' ;;
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
        --scheduled) (load_config || exit 1; update) >/dev/null 2>&1 ;;
        --daemon) while :; do
            # Isolate fatal failures; always retry and re-read config next time.
            (load_config || exit 1; update) >/dev/null 2>&1 || :
            sleep 60
        done ;;
        *) printf '用法：sh %s --menu | --install | --once | --daemon\n' "$0"; exit 1 ;;
    esac
}
# Test harness sources functions without invoking installation or network calls.
[ "${DDNS_TEST_SOURCE:-0}" = 1 ] || main "$@"
