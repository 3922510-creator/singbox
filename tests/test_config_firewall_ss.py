"""Isolated regressions: damaged configs, protocol-specific firewall and SS routing."""
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'singbox.sh'
CORE = os.environ.get('SING_BOX_TEST_BIN') or shutil.which('sing-box') or ('/usr/local/bin/sing-box' if Path('/usr/local/bin/sing-box').is_file() else None)


def extract(source, names):
    # Stop at the next top-level function, not a JSON/heredoc closing brace.
    blocks = []
    for name in names:
        start = re.search(r'^' + re.escape(name) + r'\(\) [\{\(]', source, re.M)
        if not start:
            raise AssertionError('missing function: ' + name)
        rest = source[start.end():]
        end = re.search(r'^\w+\(\) [\{\(]', rest, re.M)
        blocks.append(source[start.start(): start.end() + end.start()] if end else source[start.start():].split('# ==================== 入口')[0])
    return '\n'.join(blocks)


class SafetyAndSSTests(unittest.TestCase):
    def run_functions(self, names, body, real_core=False):
        source = SCRIPT.read_text()
        with tempfile.TemporaryDirectory(prefix='sb-safety-') as folder:
            # Relocate the one hardcoded bootstrap directory too.
            funcs = extract(source, names).replace('/etc/sing-box', folder + '/etc')
            prelude = r'''
set -eo pipefail
ROOT="$1"; BIN_FILE="$2"
export TMPDIR="$ROOT"
CONFIG_FILE="$ROOT/etc/config.json"; META_DIR="$ROOT/etc/.meta"
RED=''; GREEN=''; BLUE=''; YELLOW=''; PLAIN=''; CYAN=''
mkdir -p "$META_DIR"
ensure_config() { :; }
svc_active() { return 0; }
svc_restart() { :; }
sleep() { :; }
menu_invalid() { echo invalid >&2; }
'''
            result = subprocess.run(['bash', '-c', prelude + funcs + '\n' + body,
                                     'test', folder, CORE if real_core else '/bin/true'],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result

    def test_damaged_config_and_backup_untouched(self):
        self.run_functions(['ensure_config'], r'''
for bad in '{broken' '' 'null' '[]'; do
    printf '%s' "$bad" > "$CONFIG_FILE"
    printf 'precious-backup' > "$CONFIG_FILE.bak"
    cp "$CONFIG_FILE" "$ROOT/original"
    if ensure_config; then exit 11; fi
    cmp "$CONFIG_FILE" "$ROOT/original"
    [[ $(cat "$CONFIG_FILE.bak") == precious-backup ]]
done
rm "$CONFIG_FILE"
ensure_config
jq -e '.inbounds == [] and .outbounds[0].type == "direct"' "$CONFIG_FILE"
[[ $(stat -c %a "$CONFIG_FILE") == 600 ]]
printf '{"custom":"keep"}' > "$CONFIG_FILE"
ensure_config
jq -e '.custom == "keep"' "$CONFIG_FILE"
''')

    def test_callers_abort_when_config_is_bad(self):
        source = SCRIPT.read_text()
        bare = re.findall(r'^\s*ensure_config\s*$', source, re.M)
        self.assertEqual(bare, [], 'all callers must propagate bootstrap failure')
        self.assertIn('ensure_config || exit 1', source)

    def test_ufw_protocols_and_failure_reporting(self):
        self.run_functions(['validate_port', 'open_firewall_port', 'report_firewall_port'], r'''
CALLS="$ROOT/calls"
ufw() {
    if [[ "$1" == status ]]; then echo 'Status: active'; return 0; fi
    echo "$*" >> "$CALLS"
    [[ "${FAIL:-0}" == 0 ]]
}
report_firewall_port 443 tcp > "$ROOT/result"
grep -Fx 'allow 443/tcp' "$CALLS"
! grep -q udp "$CALLS"
grep -q '已放行' "$ROOT/result"
: > "$CALLS"
report_firewall_port 8388 tcp,udp
[[ $(wc -l < "$CALLS") == 2 ]]
grep -Fx 'allow 8388/tcp' "$CALLS"
grep -Fx 'allow 8388/udp' "$CALLS"
FAIL=1
report_firewall_port 8443 tcp > "$ROOT/result" 2>&1
! grep -q '已放行' "$ROOT/result"
grep -q '失败' "$ROOT/result"
# TCP 成功、UDP 失败也不能整体报告成功。
ufw() {
    if [[ "$1" == status ]]; then echo 'Status: active'; return 0; fi
    [[ "$2" != */udp ]]
}
report_firewall_port 8388 tcp,udp > "$ROOT/result" 2>&1
grep -q '部分成功' "$ROOT/result"
! grep -q '已放行' "$ROOT/result"
if open_firewall_port 443 unknown; then exit 12; fi
''')

    def test_firewalld_protocols_and_reload_failure(self):
        self.run_functions(['validate_port', 'open_firewall_port', 'report_firewall_port'], r'''
CALLS="$ROOT/calls"
command() {
    if [[ "$1" == -v && "$2" == ufw ]]; then return 1; fi
    builtin command "$@"
}
svc_active_name() { [[ "$1" == firewalld ]]; }
firewall-cmd() {
    echo "$*" >> "$CALLS"
    [[ "$*" != --reload || "${FAIL:-0}" == 0 ]]
}
report_firewall_port 443 tcp > "$ROOT/result"
grep -q -- '--add-port=443/tcp --permanent' "$CALLS"
! grep -q udp "$CALLS"
grep -Fx -- '--reload' "$CALLS"
FAIL=1
report_firewall_port 8388 tcp,udp > "$ROOT/result" 2>&1
grep -q -- '--add-port=8388/udp --permanent' "$CALLS"
grep -q '失败' "$ROOT/result"
! grep -q '已放行' "$ROOT/result"
''')

    def test_native_firewall_both_families_not_false_success(self):
        self.run_functions(['validate_port', 'open_firewall_port', 'report_firewall_port'], r'''
CALLS="$ROOT/calls"
# Hide host firewall tools without changing other shell dependencies.
command() {
    if [[ "$1" == -v ]]; then
        case "$2" in ufw|firewall-cmd) return 1 ;; esac
    fi
    builtin command "$@"
}
iptables() {
    case "$1" in -S) echo '-P INPUT DROP' ;; -C) return 1 ;; *) echo "v4 $*" >> "$CALLS" ;; esac
}
ip6tables() {
    case "$1" in -S) echo '-P INPUT DROP' ;; -C) return 1 ;; *) echo "v6 $*" >> "$CALLS" ;; esac
}
report_firewall_port 443 tcp > "$ROOT/result" 2>&1
[[ $(wc -l < "$CALLS") == 2 ]]
grep -q '^v4 .* -p tcp ' "$CALLS"
grep -q '^v6 .* -p tcp ' "$CALLS"
! grep -q udp "$CALLS"
! grep -q '已放行' "$ROOT/result"
grep -q '未确认' "$ROOT/result"
''')

    def test_node_firewall_call_sites(self):
        source = SCRIPT.read_text()
        for func in ('add_reality_node', 'add_anytls_node'):
            block = extract(source, [func])
            self.assertIn('report_firewall_port "$port" tcp\n', block)
            self.assertNotIn('已放行防火墙', block)
        self.assertIn('report_firewall_port "$port" tcp,udp', extract(source, ['add_ss2022_node']))
        self.assertIn('report_firewall_port "$local_port" tcp,udp', extract(source, ['add_port_forward']))

    @unittest.skipUnless(CORE, 'real sing-box required')
    def test_ss_add_update_invalid_key_and_collision(self):
        self.run_functions(['has_ss_outbound', 'add_ss_outbound', 'save_and_check_config', 'apply_config_and_restart'], r'''
printf '{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$CONFIG_FILE"
add_ss_outbound <<< $'203.0.113.2\n22880\n1\nAAAAAAAAAAAAAAAAAAAAAA==\n'
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.outbounds[1] | .tag == "isp-ss" and .method == "2022-blake3-aes-128-gcm" and .server_port == 22880' "$CONFIG_FILE"
jq '.route.rules = [{domain_suffix:["example.com"],outbound:"isp-ss"}] | .outbounds[1].connect_timeout="8s"' "$CONFIG_FILE" > "$ROOT/update"
mv "$ROOT/update" "$CONFIG_FILE"
add_ss_outbound <<< $'203.0.113.3\n22881\n2\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
jq -e '.route.rules[0].outbound == "isp-ss" and .outbounds[1].connect_timeout == "8s" and .outbounds[1].server_port == 22881' "$CONFIG_FILE"
cp "$CONFIG_FILE" "$ROOT/before"
cp "$CONFIG_FILE.bak" "$ROOT/before-bak"
if add_ss_outbound <<< $'203.0.113.3\n22881\n1\nbad-key\n'; then exit 13; fi
cmp "$CONFIG_FILE" "$ROOT/before"
cmp "$CONFIG_FILE.bak" "$ROOT/before-bak"
# 配置可校验但服务启动失败时恢复旧配置，不能打印保存成功。
attempt=0
svc_restart() { attempt=$((attempt+1)); [[ "$attempt" -eq 2 ]]; }
if add_ss_outbound <<< $'203.0.113.9\n22881\n1\nAAAAAAAAAAAAAAAAAAAAAA==\n' > "$ROOT/failed"; then exit 17; fi
cmp "$CONFIG_FILE" "$ROOT/before"
[[ "$attempt" == 2 ]]
! grep -q 'SS 家宽已保存' "$ROOT/failed"
printf '{"outbounds":[{"type":"direct","tag":"isp-ss"}]}' > "$CONFIG_FILE"
cp "$CONFIG_FILE" "$ROOT/before"
if add_ss_outbound < /dev/null; then exit 14; fi
cmp "$CONFIG_FILE" "$ROOT/before"
''', real_core=True)

    @unittest.skipUnless(CORE, 'real sing-box required')
    def test_ss_shares_routes_rulesets_and_delete(self):
        self.run_functions([
            'has_ss_outbound', 'has_socks5_outbound', 'has_warp_endpoint', 'choose_split_outbound',
            'add_warp_route', 'add_warp_node_route', 'split_ruleset_outbound', 'toggle_warp_ruleset',
            'count_split_rules', 'view_warp_rules', 'delete_warp_rule', 'delete_ss_outbound',
            'config_without_split_outbound', 'save_and_check_config', 'apply_config_and_restart',
        ], r'''
WARP_AI_RULE_TAG=geosite-ai; WARP_MEDIA_RULE_TAG=geosite-stream
GEOSITE_BASE=https://example.com
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"shadowsocks","tag":"isp-ss","server":"203.0.113.2","server_port":22880,"method":"2022-blake3-aes-128-gcm","password":"AAAAAAAAAAAAAAAAAAAAAA=="}],"route":{"rules":[]}}
JSON
[[ $(choose_split_outbound) == isp-ss ]]
add_warp_route <<< 'example.com'
prompt_delete_index() { echo 0; }
inbound_field() { echo test-in; }
node_display_name() { echo test-in; }
add_warp_node_route
[[ $(count_split_rules) == 2 ]]
view_warp_rules | grep -q ISP-SS
toggle_warp_ruleset geosite-ai 'AI' ai.srs
[[ $(split_ruleset_outbound geosite-ai) == isp-ss ]]
# 同一规则集在 SS 与 SOCKS5 间切换，不重复创建规则。
jq '.outbounds += [{type:"socks",tag:"socks5",version:"5",server:"203.0.113.5",server_port:1080}]' "$CONFIG_FILE" > "$ROOT/update"
mv "$ROOT/update" "$CONFIG_FILE"
toggle_warp_ruleset geosite-ai 'AI' ai.srs <<< 1
[[ $(split_ruleset_outbound geosite-ai) == socks5 ]]
toggle_warp_ruleset geosite-ai 'AI' ai.srs <<< 2
[[ $(split_ruleset_outbound geosite-ai) == isp-ss ]]
toggle_warp_ruleset geosite-ai 'AI' ai.srs <<< 2
[[ -z $(split_ruleset_outbound geosite-ai) ]]
delete_warp_rule <<< '1'
[[ $(count_split_rules) == 1 ]]
# Deleting SS must preserve unrelated rules and outbounds.
jq '.route.rules += [{domain_suffix:["keep.example"],outbound:"direct"}]' "$CONFIG_FILE" > "$ROOT/update"
mv "$ROOT/update" "$CONFIG_FILE"
delete_ss_outbound
! has_ss_outbound
jq -e '.outbounds | map(.tag) == ["direct","socks5"]' "$CONFIG_FILE"
jq -e '.route.rules == [{domain_suffix:["keep.example"],outbound:"direct"}]' "$CONFIG_FILE"
"$BIN_FILE" check -c "$CONFIG_FILE"
''', real_core=True)

    @unittest.skipUnless(CORE and shutil.which('curl'), 'core/curl required')
    def test_real_ss_loopback_transport(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'ss-loopback-ok')

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        processes = []
        try:
            with tempfile.TemporaryDirectory(prefix='sb-ss-loopback-') as folder:
                def start_core(name, config):
                    config_path = Path(folder) / (name + '.json')
                    log_path = Path(folder) / (name + '.log')
                    config_path.write_text(json.dumps(config))
                    config_path.chmod(0o600)
                    with log_path.open('w') as log:
                        proc = subprocess.Popen([CORE, 'run', '-c', str(config_path)], stdout=log, stderr=log)
                    processes.append(proc)
                    for _ in range(60):
                        text = log_path.read_text()
                        match = re.search(r'tcp server started at 127\.0\.0\.1:(\d+)', text)
                        if match:
                            return int(match.group(1))
                        if proc.poll() is not None:
                            self.fail(text)
                        time.sleep(0.05)
                    self.fail('temporary core did not start: ' + log_path.read_text())

                ss_port = start_core('server', {
                    'inbounds': [{'type': 'shadowsocks', 'tag': 'ss-in', 'listen': '127.0.0.1',
                                  'listen_port': 0, 'method': '2022-blake3-aes-128-gcm',
                                  'password': 'AAAAAAAAAAAAAAAAAAAAAA=='}],
                    'outbounds': [{'type': 'direct', 'tag': 'direct'}],
                })
                mixed_port = start_core('client', {
                    'inbounds': [{'type': 'mixed', 'tag': 'test', 'listen': '127.0.0.1', 'listen_port': 0}],
                    'outbounds': [{'type': 'shadowsocks', 'tag': 'isp-ss', 'server': '127.0.0.1',
                                   'server_port': ss_port, 'method': '2022-blake3-aes-128-gcm',
                                   'password': 'AAAAAAAAAAAAAAAAAAAAAA=='}],
                    'route': {'final': 'isp-ss'},
                })
                result = subprocess.run(['curl', '-fsS', '--max-time', '5', '--noproxy', '',
                                         '--proxy', f'socks5h://127.0.0.1:{mixed_port}',
                                         f'http://127.0.0.1:{server.server_port}/'],
                                        text=True, capture_output=True, timeout=8)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, 'ss-loopback-ok')
        finally:
            for proc in processes:
                proc.terminate()
            for proc in processes:
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=3)
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_three_way_selection_and_ss_default_delete_guard(self):
        self.run_functions(['has_ss_outbound', 'has_socks5_outbound', 'has_warp_endpoint', 'choose_split_outbound', 'delete_ss_outbound'], r'''
printf '{"outbounds":[{"type":"shadowsocks","tag":"isp-ss"},{"type":"socks","tag":"socks5","version":"5"}],"endpoints":[{"tag":"warp"}],"route":{"final":"isp-ss"}}' > "$CONFIG_FILE"
[[ $(choose_split_outbound <<< 1) == warp ]]
[[ $(choose_split_outbound <<< 2) == socks5 ]]
[[ $(choose_split_outbound <<< 3) == isp-ss ]]
if choose_split_outbound <<< 4; then exit 15; fi
cp "$CONFIG_FILE" "$ROOT/before"
if delete_ss_outbound; then exit 16; fi
cmp "$CONFIG_FILE" "$ROOT/before"
''')


if __name__ == '__main__':
    unittest.main()
