"""Regression tests for v3.7.2 hardening & optimizations (isolated temp-only)."""
import pathlib
import re
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "singbox.sh"
INSTALLER = REPO / "install.sh"


def extract_funcs(source, names):
    blocks = []
    for name in names:
        m = re.search(r"^" + re.escape(name) + r"\(\) [\{\(]\n.*?^[\}\)]", source, re.M | re.S)
        if not m:
            line = next((l for l in source.splitlines() if l.startswith(name + "()")), None)
            if not line:
                raise AssertionError(f"function {name} not found")
            blocks.append(line)
        else:
            blocks.append(m.group())
    return "\n\n".join(blocks)


class HardeningTests(unittest.TestCase):
    def run_sb(self, names, body):
        source = SCRIPT.read_text(encoding="utf-8")
        funcs = extract_funcs(source, names)
        with tempfile.TemporaryDirectory(prefix="sb-harden-") as root:
            prelude = r'''
set -eo pipefail
ROOT="$1"
export TMPDIR="$ROOT"
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; PLAIN=""
CONFIG_FILE="$ROOT/etc/config.json"
META_DIR="$ROOT/etc/.meta"
REALITY_META="$META_DIR/reality.txt"
NODE_NAMES_META="$META_DIR/node-names.json"
DNS_BACKUP="$META_DIR/resolv.conf.bak"
BIN_FILE="$ROOT/bin/sing-box"
mkdir -p "$ROOT/etc/.meta" "$ROOT/bin"
sleep() { :; }
'''
            res = subprocess.run(
                ["bash", "-c", prelude + "\n" + funcs + "\n" + body, "test", root],
                capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            return res.stdout

    def test_ssh_port_detection_and_firewall_protection(self):
        self.run_sb(
            ["validate_port", "detect_ssh_ports", "is_ssh_port", "menu_firewall"],
            r'''
sshd() { printf 'port 62900\n'; }
SSH_CONNECTION="1.2.3.4 55555 5.6.7.8 62900"
[[ $(detect_ssh_ports) == "62900" ]]
is_ssh_port 62900
! is_ssh_port 22

# 多端口时合并去重
SSH_CONNECTION="1.2.3.4 55555 5.6.7.8 21187"
[[ $(detect_ssh_ports) == "21187 62900" ]]

# 启用防火墙保留真实 SSH 端口（而不是写死 22），且删 SSH 端口时拒绝后不会误删
CALLS="$ROOT/ufw-calls"
ufw() {
    printf '%s\n' "$*" >> "$CALLS"
    return 0
}
menu_header() { :; }
menu_section() { :; }
menu_option() { :; }
menu_back() { :; }
pause() { :; }
read_menu_choice() { read -r REPLY; }
RED="\\033[31m"; PLAIN="\\033[0m"
out=$(menu_firewall <<'IN'
3
2
62900
n
0
IN
)
grep -Fxq 'allow 21187/tcp' "$CALLS"
grep -Fxq 'allow 62900/tcp' "$CALLS"
! grep -Fxq 'allow 22/tcp' "$CALLS"
grep -Fxq 'enable' "$CALLS"
! grep -q 'delete allow 62900' "$CALLS"
[[ "$out" != *'\033[31m'* ]]
''',
        )

    def test_install_singbox_never_downgrades_and_validates_before_swap(self):
        self.run_sb(
            ["install_singbox"],
            r'''
INIT_SYS=systemd
OS_FAMILY=debian
SERVICE_FILE="$ROOT/service"
touch "$SERVICE_FILE"
printf 'old-binary\n' > "$BIN_FILE"
chmod +x "$BIN_FILE"
printf '{"inbounds":[]}\n' > "$CONFIG_FILE"
ensure_config() { :; }
svc_restart() { :; }
svc_active() { return 0; }
svc_logs() { :; }

# 1) GitHub API 失败时拒绝降级到 v1.8.8，原二进制保持不动
curl() { return 22; }
if install_singbox; then exit 1; fi
[[ $(cat "$BIN_FILE") == "old-binary" ]]

# 2) 新二进制 check 失败时不覆盖原二进制且清理临时目录
uname() { echo x86_64; }
curl() {
    if [[ "$*" == *releases/latest* ]]; then
        printf '{"tag_name":"v1.14.9"}\n'
        return 0
    fi
    local out=""
    while (( $# )); do
        if [[ "$1" == -o ]]; then out="$2"; shift; fi
        shift
    done
    local stage="$ROOT/pkg"
    mkdir -p "$stage/sing-box-1.14.9-linux-amd64"
    cat > "$stage/sing-box-1.14.9-linux-amd64/sing-box" <<'BIN'
#!/bin/bash
if [[ "$1" == version ]]; then echo "sing-box version 1.14.9"; exit 0; fi
if [[ "$1" == check ]]; then echo "incompatible config" >&2; exit 1; fi
BIN
    chmod +x "$stage/sing-box-1.14.9-linux-amd64/sing-box"
    tar -czf "$out" -C "$stage" "sing-box-1.14.9-linux-amd64"
}
if install_singbox; then exit 1; fi
[[ $(cat "$BIN_FILE") == "old-binary" ]]
[[ -z "$(find "$ROOT" -maxdepth 1 -name 'sb-install-*' -print)" ]]
''',
        )

    def test_port_in_use_checks_config_and_host_ss(self):
        self.run_sb(
            ["port_in_use"],
            r'''
printf '{"inbounds":[{"listen_port":8443}]}\n' > "$CONFIG_FILE"
ss() {
    cat <<'OUT'
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port
tcp   LISTEN 0      128       *:443                *:*
tcp   LISTEN 0      128    [::]:1443            [::]:*
udp   UNCONN 0      0   127.0.0.1:8765       0.0.0.0:*
OUT
}
port_in_use 8443
port_in_use 443
port_in_use 1443
port_in_use 8765
! port_in_use 444
! port_in_use 9443
! port_in_use 8444
''',
        )

    def test_ipv6_url_host_and_public_ip_validation(self):
        self.run_sb(
            ["is_valid_ip", "format_url_host", "get_public_ip", "node_display_name", "node_link_fragment", "ss2022_link"],
            r'''
is_valid_ip 1.2.3.4
is_valid_ip 2001:db8::1
! is_valid_ip 999.1.1.1
! is_valid_ip "<html>502</html>"
! is_valid_ip ""

[[ $(format_url_host 1.2.3.4) == "1.2.3.4" ]]
[[ $(format_url_host 2001:db8::1) == "[2001:db8::1]" ]]
[[ $(format_url_host "[2001:db8::1]") == "[2001:db8::1]" ]]

# 上游返回垃圾文本时跳过并回落到下一个接口，最终校验通过
curl() {
    case "$*" in
        *api.ipify.org*) printf '<html>429 Too Many Requests</html>\n' ;;
        *icanhazip.com*) return 22 ;;
        *api64.ipify.org*) printf '2001:db8::9\n' ;;
    esac
}
[[ $(get_public_ip) == "2001:db8::9" ]]
''',
        )

    def test_read_valid_port_eof_and_leading_zeros(self):
        self.run_sb(
            ["validate_port", "port_in_use", "read_valid_port"],
            r'''
printf '{"inbounds":[]}\n' > "$CONFIG_FILE"
ss() { return 1; }
netstat() { return 1; }
if read_valid_port "port: " "" 1 < /dev/null; then exit 1; fi
val=$(read_valid_port "port: " 443 1 <<< $'abc\n00443\n' 2>"$ROOT/err")
[[ "$val" == "443" ]]
grep -q '端口无效' "$ROOT/err"
''',
        )

    def test_delete_node_cleans_associated_route_rules_and_warp_supports_anytls(self):
        self.run_sb(
            [
                "inbound_count", "inbound_field", "inbound_node_type", "count_by_type",
                "ss2022_count", "node_display_name", "prompt_delete_index",
                "remove_reality_meta", "save_node_name", "save_and_check_config",
                "apply_config_and_restart", "delete_node", "has_warp_endpoint",
                "add_warp_node_route",
            ],
            r'''
cat > "$BIN_FILE" <<'BIN'
#!/bin/bash
exit 0
BIN
chmod +x "$BIN_FILE"
ensure_config() { :; }
svc_active() { return 0; }
svc_restart() { :; }
cat > "$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {"type": "vless", "tag": "vless-reality-443", "listen_port": 443},
    {"type": "anytls", "tag": "anytls-reality-8444", "listen_port": 8444}
  ],
  "endpoints": [{"type": "wireguard", "tag": "warp"}],
  "route": {
    "rules": [
      {"inbound": ["vless-reality-443"], "outbound": "warp"},
      {"domain_suffix": ["openai.com"], "outbound": "warp"}
    ]
  }
}
JSON
# 1) add_warp_node_route 支持 AnyTLS 节点
add_warp_node_route <<< '2'
jq -e '.route.rules | any(.inbound == ["anytls-reality-8444"] and .outbound == "warp")' "$CONFIG_FILE" >/dev/null

# 2) delete_node 删除 vless 节点时同步清理它的路由规则
delete_node <<< $'1\n1\n'
jq -e '[.route.rules[] | select((.inbound? // []) | index("vless-reality-443"))] | length == 0' "$CONFIG_FILE" >/dev/null
jq -e '.route.rules | any(.inbound == ["anytls-reality-8444"])' "$CONFIG_FILE" >/dev/null
''',
        )

    def test_bbr_apply_loads_module_first_and_cleans_bak(self):
        self.run_sb(
            ["bbr_apply"],
            r'''
BBR_CONF="$ROOT/99-zz-bbr-mode.conf"
printf 'old\n' > "$BBR_CONF"
MOD_LOADED="$ROOT/mod-loaded"
bbr_require_tc() { return 1; }
bbr_default_iface() { echo ""; }
modprobe() {
    [[ "$1" == tcp_bbr ]] && touch "$MOD_LOADED"
}
sysctl() {
    if [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_available_congestion_control" ]]; then
        if [[ -f "$MOD_LOADED" ]]; then echo "cubic bbr"; else echo "cubic"; fi
        return 0
    fi
    if [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_congestion_control" ]]; then echo "bbr"; return 0; fi
    if [[ "$1" == "-n" && "$2" == "net.core.default_qdisc" ]]; then echo "fq_codel"; return 0; fi
    return 0
}
bbr_apply bbr fq_codel "BBR + fq_codel"
[[ -f "$MOD_LOADED" ]]
[[ -z "$(find "$ROOT" -maxdepth 1 -name 'tmp.*' -print)" ]]
''',
        )

    def test_set_dns_preserves_initial_backup_and_validates_ips(self):
        source = SCRIPT.read_text(encoding="utf-8")
        # Redirect /etc/resolv.conf in isolated test copy so host resolv.conf is never touched
        patched = extract_funcs(source, ["is_valid_ip", "set_dns"]).replace("/etc/resolv.conf", "$TEST_RESOLV")
        with tempfile.TemporaryDirectory(prefix="sb-dns-") as root:
            res = subprocess.run(
                [
                    "bash", "-c",
                    r'''
set -eo pipefail
ROOT="$1"
RED=""; GREEN=""; YELLOW=""; PLAIN=""
META_DIR="$ROOT/meta"
DNS_BACKUP="$META_DIR/resolv.conf.bak"
TEST_RESOLV="$ROOT/resolv.conf"
printf 'nameserver 9.9.9.9\n' > "$TEST_RESOLV"
show_dns() { :; }
''' + patched + r'''
# 非法输入与通配符拒绝写入
if set_dns "1.1.1.1 *" "bad"; then exit 1; fi
if set_dns "not-an-ip" "bad"; then exit 1; fi
[[ $(cat "$TEST_RESOLV") == "nameserver 9.9.9.9" ]]

# 连续切换两次后，DNS_BACKUP 仍保留最初的 9.9.9.9
set_dns "1.1.1.1 1.0.0.1" "CF"
set_dns "8.8.8.8" "Google"
[[ $(cat "$DNS_BACKUP") == "nameserver 9.9.9.9" ]]
grep -Fxq 'nameserver 8.8.8.8' "$TEST_RESOLV"
''',
                    "test", root,
                ],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_media_check_full_isolation(self):
        self.run_sb(
            ["media_check_full"],
            r'''
MARKER="$ROOT/ran"
curl() {
    local out=""
    while (( $# )); do
        if [[ "$1" == -o ]]; then out="$2"; shift; fi
        shift
    done
    printf '%s' "$PAYLOAD" > "$out"
    return "${DL_RC:-0}"
}
media_check_full <<< n
[[ ! -e "$MARKER" ]]
DL_RC=22
if media_check_full <<< y; then exit 1; fi
[[ ! -e "$MARKER" ]]
DL_RC=0; PAYLOAD='if then'
if media_check_full <<< y; then exit 1; fi
[[ ! -e "$MARKER" ]]
exec 200>"$ROOT/lock"
PAYLOAD='[[ ! -e /proc/$$/fd/200 ]] || exit 91; touch "'"$MARKER"'"'
media_check_full <<< y
[[ -e "$MARKER" && -e /proc/$$/fd/200 ]]
''',
        )

    def test_installer_rejects_truncated_script(self):
        source = INSTALLER.read_text(encoding="utf-8")
        func = re.search(r"^download_script\(\) \{\n.*?^\}", source, re.M | re.S).group()
        with tempfile.TemporaryDirectory(prefix="sb-inst-") as root:
            res = subprocess.run(
                [
                    "sh", "-c",
                    r'''
set -e
ROOT="$1"
BLUE=""; GREEN=""; RED=""; PLAIN=""
msg() { :; }; ok() { :; }; err() { printf '%s\n' "$1" >&2; }
INSTALL_PATH="$ROOT/sb"
REPO_RAW="https://example.invalid/singbox.sh"
printf 'existing-good\n' > "$INSTALL_PATH"
''' + func + r'''
# 1) 截断脚本（bash -n 失败）不得覆盖现有文件
curl() {
    while [ $# -gt 0 ]; do
        if [ "$1" = -o ]; then out="$2"; shift; fi
        shift
    done
    printf '#!/usr/bin/env bash\nif true; then\n' > "$out"
}
if download_script; then exit 1; fi
[ "$(cat "$INSTALL_PATH")" = "existing-good" ]

# 2) 合法脚本覆盖成功
curl() {
    while [ $# -gt 0 ]; do
        if [ "$1" = -o ]; then out="$2"; shift; fi
        shift
    done
    printf '#!/usr/bin/env bash\necho ok\n' > "$out"
}
download_script
grep -q 'echo ok' "$INSTALL_PATH"
''',
                    "test", root,
                ],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


if __name__ == "__main__":
    unittest.main()
