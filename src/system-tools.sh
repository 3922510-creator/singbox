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
