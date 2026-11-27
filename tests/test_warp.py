"""Regression tests for direct free Cloudflare WARP registration."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'singbox.sh'


def extract_funcs(source, names):
    blocks = []
    for name in names:
        m = re.search(r'^' + re.escape(name) + r'\(\) [\{\(]\n.*?^[\}\)]', source, re.M | re.S)
        if not m:
            raise AssertionError(f'function {name} not found in singbox.sh')
        blocks.append(m.group())
    return '\n\n'.join(blocks)


@unittest.skipUnless(shutil.which('jq'), 'jq is required')
class WarpRegistrationTests(unittest.TestCase):
    def test_syntax_and_no_zero_trust(self):
        res = subprocess.run(['bash', '-n', str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        content = SCRIPT.read_text(encoding='utf-8')
        self.assertNotIn('_zero_trust_enroll', content)
        self.assertNotIn('Zero Trust', content)

    def test_decode_reserved_and_endpoint_validation(self):
        source = SCRIPT.read_text(encoding='utf-8')
        funcs = extract_funcs(source, ['_warp_decode_reserved', '_warp_registration_endpoint'])
        res = subprocess.run(
            ['bash', '-c', funcs + r'''
set -euo pipefail
[[ $(_warp_decode_reserved '') == '[]' ]]
[[ $(_warp_decode_reserved '1fbA') == '[213,246,192]' ]]
[[ $(_warp_decode_reserved 'AAAA') == '[0,0,0]' ]]
[[ $(_warp_decode_reserved 'bad!!!') == '[]' ]]
if _warp_registration_endpoint sample-key <<< '{"errors":[]}'; then exit 1; fi
ep=$(_warp_registration_endpoint sample-key <<< '{"config":{"client_id":"1fbA","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700::2"}},"peers":[{"public_key":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa="}]}}')
printf '%s\n' "$ep"
'''],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        ep = json.loads(res.stdout)
        self.assertEqual(ep['tag'], 'warp')
        self.assertEqual(ep['mtu'], 1280)
        self.assertEqual(ep['private_key'], 'sample-key')
        self.assertEqual(ep['address'], ['172.16.0.2/32', '2606:4700::2/128'])
        self.assertEqual(ep['peers'][0]['address'], '162.159.192.8')
        self.assertEqual(ep['peers'][0]['port'], 2408)
        self.assertEqual(ep['peers'][0]['reserved'], [213, 246, 192])

    def test_add_warp_replaces_endpoint_keeps_rules_and_passes_core_check(self):
        core = os.environ.get('SING_BOX_TEST_BIN') or shutil.which('sing-box')
        if not core:
            self.skipTest('sing-box binary is required')
        source = SCRIPT.read_text(encoding='utf-8')
        funcs = extract_funcs(source, [
            '_warp_decode_reserved',
            '_warp_registration_endpoint',
            'has_warp_endpoint',
            'save_and_check_config',
            'apply_config_and_restart',
            'add_warp',
        ])
        with tempfile.TemporaryDirectory() as folder:
            res = subprocess.run(
                ['bash', '-c', '''
set -euo pipefail
D="$1"; BIN_FILE="$2"
CONFIG_FILE="$D/etc/config.json"; WARP_META="$D/etc/.meta/warp.json"
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; PLAIN=""
mkdir -p "$D/etc/.meta"
touch "$WARP_META"
cat > "$CONFIG_FILE" <<'JSON'
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "direct", "tag": "warp"}
  ],
  "route": {
    "rules": [{"domain_suffix": ["example.com"], "outbound": "warp"}],
    "final": "direct"
  }
}
JSON
ensure_config() { test -f "$CONFIG_FILE"; }
svc_active() { return 0; }
svc_restart() { :; }
sleep() { :; }
curl() {
    [[ "$*" == *api.cloudflareclient.com/v0a2158/reg* ]] || return 1
    printf '{"config":{"client_id":"1fbA","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700::2"}},"peers":[{"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="}]}}\n'
}
''' + funcs + r'''
add_warp
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.endpoints | length == 1 and .[0].tag == "warp" and .[0].type == "wireguard" and .[0].mtu == 1280 and .[0].peers[0].reserved == [213,246,192]' "$CONFIG_FILE" >/dev/null
jq -e '[.outbounds[] | select(.tag == "warp")] | length == 0' "$CONFIG_FILE" >/dev/null
jq -e '.route.rules[0].domain_suffix == ["example.com"] and .route.final == "direct"' "$CONFIG_FILE" >/dev/null
test ! -e "$WARP_META"
''', 'test_warp', folder, core],
                capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_warp_ai_and_media_toggle_matches_sbx_rulesets(self):
        core = os.environ.get('SING_BOX_TEST_BIN') or shutil.which('sing-box')
        if not core:
            self.skipTest('sing-box binary is required')
        source = SCRIPT.read_text(encoding='utf-8')
        consts = '\n'.join(
            line for line in source.splitlines()
            if line.startswith(('GEOSITE_BASE=', 'WARP_AI_RULE_', 'WARP_MEDIA_RULE_'))
        )
        funcs = extract_funcs(source, [
            'has_warp_endpoint',
            'has_warp_ruleset',
            'has_socks5_outbound',
            'choose_split_outbound',
            'add_socks5_outbound',
            'delete_socks5_outbound',
            'add_warp_route',
            'add_warp_node_route',
            'split_ruleset_outbound',
            'count_split_rules',
            'config_without_split_outbound',
            'save_and_check_config',
            'apply_config_and_restart',
            'toggle_warp_ruleset',
            'add_warp_ai',
            'add_warp_media',
            'view_warp_rules',
            'delete_warp_rule',
            'delete_warp',
        ])
        with tempfile.TemporaryDirectory() as folder:
            res = subprocess.run(
                ['bash', '-c', '''
set -euo pipefail
D="$1"; BIN_FILE="$2"
CONFIG_FILE="$D/etc/config.json"; WARP_META="$D/etc/.meta/warp.json"
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; PLAIN=""
mkdir -p "$D/etc/.meta"
keys=$("$BIN_FILE" generate wg-keypair)
priv=$(awk '/^PrivateKey:/{print $2}' <<< "$keys")
jq -n --arg priv "$priv" '{
  endpoints: [{
    type: "wireguard",
    tag: "warp",
    mtu: 1280,
    address: ["172.16.0.2/32"],
    private_key: $priv,
    peers: [{address: "162.159.192.8", port: 2408, public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", allowed_ips: ["0.0.0.0/0", "::/0"]}]
  }],
  outbounds: [{type: "direct", tag: "direct"}],
  route: {
    rule_set: [
      {tag: "geosite-openai", type: "remote", format: "binary", url: "https://example.invalid/old.srs"},
      {tag: "geosite-anthropic", type: "remote", format: "binary", url: "https://example.invalid/old2.srs"},
      {tag: "custom-keep", type: "remote", format: "binary", url: "https://example.invalid/keep.srs"}
    ],
    rules: [
      {rule_set: ["geosite-openai"], outbound: "warp"},
      {rule_set: "geosite-anthropic", outbound: "warp"},
      {domain_suffix: ["keep.example"], outbound: "warp"}
    ],
    final: "direct"
  }
}' > "$CONFIG_FILE"
ensure_config() { test -f "$CONFIG_FILE"; }
svc_active() { return 0; }
svc_restart() { :; }
sleep() { :; }
''' + consts + '\n' + funcs + r'''
add_warp_ai
"$BIN_FILE" check -c "$CONFIG_FILE"
has_warp_ruleset geosite-ai
jq -e '.route.rule_set | map(.tag) == ["custom-keep", "geosite-ai"]' "$CONFIG_FILE" >/dev/null
jq -e '.route.rule_set[] | select(.tag == "geosite-ai") | .url == "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ai-chat-!cn.srs" and (has("download_detour") | not)' "$CONFIG_FILE" >/dev/null
jq -e '.route.default_http_client == "rs-http" and (.http_clients | map(.tag) == ["rs-http"])' "$CONFIG_FILE" >/dev/null
jq -e '.route.rules | any(.rule_set == "geosite-ai" and .outbound == "warp") and any(.domain_suffix == ["keep.example"]) and (any(.rule_set == ["geosite-openai"]) | not) and (any(.rule_set == "geosite-anthropic") | not)' "$CONFIG_FILE" >/dev/null

add_warp_media
"$BIN_FILE" check -c "$CONFIG_FILE"
has_warp_ruleset geosite-stream
jq -e '.route.rule_set[] | select(.tag == "geosite-stream") | .url == "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-entertainment@!cn.srs"' "$CONFIG_FILE" >/dev/null

add_warp_ai
"$BIN_FILE" check -c "$CONFIG_FILE"
! has_warp_ruleset geosite-ai
jq -e '.route.rule_set | map(.tag) == ["custom-keep", "geosite-stream"]' "$CONFIG_FILE" >/dev/null

# 删除规则集对应的路由规则时，同步清理不再被引用的 geosite-stream 定义
delete_warp_rule <<< '2'
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.route.rule_set | map(.tag) == ["custom-keep"]' "$CONFIG_FILE" >/dev/null

delete_warp_rule <<< '1'
[[ $(count_split_rules) == 0 ]]

# Adding SOCKS5 preserves default/other routes and supports password auth.
cp "$CONFIG_FILE" "$D/before.json"
if add_socks5_outbound <<< $'proxy.example\n65536'; then exit 1; fi
cmp "$CONFIG_FILE" "$D/before.json"
add_socks5_outbound <<< $'proxy.example\n01080\ndemo-user\npass word'
"$BIN_FILE" check -c "$CONFIG_FILE"
[[ $(stat -c %a "$CONFIG_FILE") == 600 ]]
jq -e --slurpfile before "$D/before.json" '
  .route == $before[0].route and .outbounds[-1] ==
  {tag:"socks5",type:"socks",version:"5",server:"proxy.example",server_port:1080,username:"demo-user",password:"pass word"}' "$CONFIG_FILE" >/dev/null

add_warp_ai <<< '2'
add_warp_ai <<< '1'
[[ $(split_ruleset_outbound geosite-ai) == warp ]]
add_warp_ai <<< '2'
[[ $(split_ruleset_outbound geosite-ai) == socks5 ]]
add_warp_media <<< '1'
add_warp_route <<< $'1\nshift.example'
add_warp_route <<< $'2\nshift.example'
jq -e '[.route.rules[] | select(.domain_suffix == ["shift.example"]) | .outbound] == ["socks5"]' "$CONFIG_FILE" >/dev/null

# Relinking a node keeps preprocessing and existing unrelated routes.
prompt_delete_index() { echo 0; }
inbound_field() { echo node-test; }
node_display_name() { echo "$1"; }
add_warp_node_route <<< '1'
add_warp_node_route <<< '2'
jq -e '[.route.rules[] | select(.inbound == ["node-test"]) | .outbound] == ["socks5"]' "$CONFIG_FILE" >/dev/null

add_socks5_outbound <<< $'[2001:db8::1]\n1081\n'
jq -e '[.outbounds[] | select(.tag == "socks5")] ==
  [{tag:"socks5",type:"socks",version:"5",server:"2001:db8::1",server_port:1081}]' "$CONFIG_FILE" >/dev/null
delete_warp
"$BIN_FILE" check -c "$CONFIG_FILE"
[[ $(choose_split_outbound) == socks5 ]]
[[ $(split_ruleset_outbound geosite-ai) == socks5 ]]
[[ -z $(split_ruleset_outbound geosite-stream) ]]
[[ $(count_split_rules) == 3 ]]
delete_warp_rule <<< '02'
[[ -z $(split_ruleset_outbound geosite-ai) ]]
delete_socks5_outbound
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.route.rule_set | map(.tag) == ["custom-keep"]' "$CONFIG_FILE" >/dev/null
jq -e '.route.rules | length == 0' "$CONFIG_FILE" >/dev/null
''', 'test_warp_rulesets', folder, core],
                capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_warp_peer_extract_ipv6_fallback_and_switch(self):
        core = os.environ.get('SING_BOX_TEST_BIN') or shutil.which('sing-box')
        if not core:
            self.skipTest('sing-box binary is required')
        source = SCRIPT.read_text(encoding='utf-8')
        consts = '\n'.join(
            line for line in source.splitlines()
            if line.startswith(('WARP_DEFAULT_', 'WARP_DNS_TAG=', 'WARP_LOCAL_DNS_TAG='))
        )
        funcs = extract_funcs(source, [
            '_warp_decode_reserved',
            '_warp_extract_peer_hosts',
            '_warp_registration_endpoint',
            '_warp_auto_pick_peer',
            'has_warp_endpoint',
            'get_warp_peer_summary',
            'switch_warp_peer',
            'save_and_check_config',
            'apply_config_and_restart',
            'add_warp',
        ])
        with tempfile.TemporaryDirectory() as folder:
            res = subprocess.run(
                ['bash', '-c', '''
set -euo pipefail
D="$1"; BIN_FILE="$2"
CONFIG_FILE="$D/etc/config.json"; WARP_META="$D/etc/.meta/warp.json"
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; DIM=""; PLAIN=""
mkdir -p "$D/etc/.meta"
cat > "$CONFIG_FILE" <<'JSON'
{"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}
JSON
ensure_config() { test -f "$CONFIG_FILE"; }
svc_active() { return 0; }
svc_restart() { :; }
sleep() { :; }
menu_invalid() { return 1; }
''' + consts + '\n' + funcs + r'''
# 1. 提取 API 返回的 v4/v6 对端及异常兜底
IFS=$'\t' read -r h4 h6 < <(_warp_extract_peer_hosts <<< '{"config":{"peers":[{"endpoint":{"v4":"162.159.192.1:0","v6":"[2606:4700:d0::a29f:c001]:0"}}]}}')
[[ "$h4" == "162.159.192.1" && "$h6" == "2606:4700:d0::a29f:c001" ]]
IFS=$'\t' read -r h4 h6 < <(_warp_extract_peer_hosts <<< '{}')
[[ "$h4" == "162.159.192.8" && "$h6" == "2606:4700:d0::a29f:c008" ]]

# 2. 模拟共享 IPv4 注册失败但 -6 成功，且探测时只有 IPv6 对端连通
ip() { return 0; }
curl() {
    [[ "$*" == *api.cloudflareclient.com/v0a2158/reg* ]] || return 1
    [[ " $* " == *" -6 "* ]] || return 22
    printf '{"config":{"client_id":"1fbA","interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700::2"}},"peers":[{"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=","endpoint":{"v4":"162.159.192.1:0","v6":"[2606:4700:d0::a29f:c001]:0"}}]}}\n'
}
_warp_probe_endpoint_json() {
    jq -e '.peers[0].address == "2606:4700:d0::a29f:c001" and .peers[0].port == 2408' <<< "$1" >/dev/null
}
add_warp
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.endpoints[0].peers[0].address == "2606:4700:d0::a29f:c001" and .endpoints[0].peers[0].port == 2408' "$CONFIG_FILE" >/dev/null
[[ "$(get_warp_peer_summary)" == *"(IPv6)"* ]]

# 3. 手动切换对端：切 IPv4、自定义 IPv6 带方括号与端口、非法端口拒绝
switch_warp_peer <<< '1'
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.endpoints[0].peers[0].address == "162.159.192.8" and .endpoints[0].peers[0].port == 2408' "$CONFIG_FILE" >/dev/null

switch_warp_peer <<< $'4\n[2606:4700:d0::a29f:c008]\n500'
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.endpoints[0].peers[0].address == "2606:4700:d0::a29f:c008" and .endpoints[0].peers[0].port == 500' "$CONFIG_FILE" >/dev/null

cp "$CONFIG_FILE" "$D/before.json"
if switch_warp_peer <<< $'4\n162.159.192.8\n70000'; then exit 1; fi
cmp "$CONFIG_FILE" "$D/before.json"
''', 'test_warp_peer', folder, core],
                capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)

    def test_warp_stack_modes_rule_order_and_dns_cleanup(self):
        core = os.environ.get('SING_BOX_TEST_BIN') or shutil.which('sing-box')
        if not core:
            self.skipTest('sing-box binary is required')
        source = SCRIPT.read_text(encoding='utf-8')
        consts = '\n'.join(
            line for line in source.splitlines()
            if line.startswith(('GEOSITE_BASE=', 'WARP_AI_RULE_', 'WARP_MEDIA_RULE_', 'WARP_DEFAULT_', 'WARP_DNS_TAG=', 'WARP_LOCAL_DNS_TAG='))
        )
        funcs = extract_funcs(source, [
            'has_warp_endpoint',
            'has_socks5_outbound',
            'has_ss_outbound',
            'choose_split_outbound',
            'get_warp_stack_mode',
            'warp_stack_mode_label',
            'apply_warp_stack_mode',
            'add_warp_route',
            'split_ruleset_outbound',
            'toggle_warp_ruleset',
            'add_warp_ai',
            'count_split_rules',
            'view_warp_rules',
            'delete_warp_rule',
            'config_without_split_outbound',
            'delete_warp',
            'probe_split_outbound',
            'save_and_check_config',
            'apply_config_and_restart',
        ])
        with tempfile.TemporaryDirectory() as folder:
            res = subprocess.run(
                ['bash', '-c', '''
set -euo pipefail
D="$1"; BIN_FILE="$2"
CONFIG_FILE="$D/etc/config.json"; WARP_META="$D/etc/.meta/warp.json"
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; DIM=""; PLAIN=""
mkdir -p "$D/etc/.meta"
keys=$("$BIN_FILE" generate wg-keypair)
priv=$(awk '/^PrivateKey:/{print $2}' <<< "$keys")
jq -n --arg priv "$priv" '{
  endpoints: [{
    type: "wireguard", tag: "warp", mtu: 1280,
    address: ["172.16.0.2/32", "2606:4700:110::2/128"],
    private_key: $priv,
    peers: [{address: "2606:4700:d0::a29f:c008", port: 2408, public_key: "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", allowed_ips: ["0.0.0.0/0", "::/0"]}]
  }],
  outbounds: [{type: "direct", tag: "direct"}],
  route: {rules: [], final: "direct"}
}' > "$CONFIG_FILE"
ensure_config() { test -f "$CONFIG_FILE"; }
svc_active() { return 0; }
svc_restart() { :; }
sleep() { :; }
''' + consts + '\n' + funcs + r'''
[[ "$(get_warp_stack_mode)" == dual ]]

# 1. 仅 WARP IPv4 + 本机 IPv6（双栈优先本机 IPv6）
apply_warp_stack_mode v4_prefer_host_v6
"$BIN_FILE" check -c "$CONFIG_FILE"
[[ "$(get_warp_stack_mode)" == v4_prefer_host_v6 ]]
jq -e '.endpoints[0].peers[0].allowed_ips == ["0.0.0.0/0"]' "$CONFIG_FILE" >/dev/null
jq -e '.dns.servers | any(.tag == "sb-warp-dns" and .server == "1.1.1.1" and .detour == "warp")' "$CONFIG_FILE" >/dev/null
jq -e '.route.rules[-3].action == "resolve" and .route.rules[-3].strategy == "prefer_ipv6" and .route.rules[-2].ip_cidr == ["::/0"] and .route.rules[-2].outbound == "direct" and .route.rules[-1].ip_cidr == ["0.0.0.0/0"] and .route.rules[-1].outbound == "warp"' "$CONFIG_FILE" >/dev/null
[[ "$(count_split_rules)" == 0 ]]

# 2. 在单栈模式下添加自定义域名和 AI 规则集，必须插入到全局按栈块之前
add_warp_route <<< 'openai.com'
add_warp_ai
"$BIN_FILE" check -c "$CONFIG_FILE"
[[ "$(count_split_rules)" == 2 ]]
jq -e '.route.rules[0].domain_suffix == ["openai.com"] and .route.rules[1].rule_set == "geosite-ai" and .route.rules[2].action == "resolve"' "$CONFIG_FILE" >/dev/null
view_warp_rules | grep -q '全局分栈'

# 删除普通规则序号 1 不应破坏后面的全局栈块
delete_warp_rule <<< '1'
"$BIN_FILE" check -c "$CONFIG_FILE"
[[ "$(count_split_rules)" == 1 ]]
[[ "$(get_warp_stack_mode)" == v4_prefer_host_v6 ]]

# 3. 切换到仅 WARP IPv4（双栈优先 WARP IPv4）
apply_warp_stack_mode v4_prefer_warp_v4
"$BIN_FILE" check -c "$CONFIG_FILE"
[[ "$(get_warp_stack_mode)" == v4_prefer_warp_v4 ]]
jq -e '.route.rules[-2].outbound == "warp" and .route.rules[-1].outbound == "direct"' "$CONFIG_FILE" >/dev/null

# 4. 切换到仅 WARP IPv6 + 本机 IPv4（双栈优先本机 IPv4 & 双栈优先 WARP IPv6）
apply_warp_stack_mode v6_prefer_host_v4
"$BIN_FILE" check -c "$CONFIG_FILE"
[[ "$(get_warp_stack_mode)" == v6_prefer_host_v4 ]]
jq -e '.endpoints[0].peers[0].allowed_ips == ["::/0"]' "$CONFIG_FILE" >/dev/null
jq -e '.dns.servers | any(.tag == "sb-warp-dns" and .server == "2606:4700:4700::1111" and .detour == "warp")' "$CONFIG_FILE" >/dev/null

apply_warp_stack_mode v6_prefer_warp_v6
"$BIN_FILE" check -c "$CONFIG_FILE"
[[ "$(get_warp_stack_mode)" == v6_prefer_warp_v6 ]]
jq -e '.route.rules[-3].strategy == "prefer_ipv6" and .route.rules[-2].ip_cidr == ["::/0"] and .route.rules[-2].outbound == "warp"' "$CONFIG_FILE" >/dev/null

# 5. probe_split_outbound 在仅 IPv6 模式下只请求 api6.ipify.org
curl() {
    case "${@: -1}" in
      https://api6.ipify.org) echo 2a09:bac5::1 ;;
      https://api4.ipify.org) return 99 ;;
      *) return 70 ;;
    esac
}
out=$(probe_split_outbound warp WARP)
[[ "$out" == *"WARP IPV6: 2a09:bac5::1"* && "$out" != *" IP: "* ]]

# 6. 切回双栈模式应清理 sb-warp-dns / sb-local-dns 并恢复双栈 allowed_ips
apply_warp_stack_mode dual
"$BIN_FILE" check -c "$CONFIG_FILE"
[[ "$(get_warp_stack_mode)" == dual ]]
jq -e '.endpoints[0].peers[0].allowed_ips == ["0.0.0.0/0", "::/0"]' "$CONFIG_FILE" >/dev/null
jq -e 'has("dns") | not' "$CONFIG_FILE" >/dev/null
jq -e '.route | has("default_domain_resolver") | not' "$CONFIG_FILE" >/dev/null

# 7. 若已有用户自定义 DNS，启用单栈与删除 WARP 都必须保留用户 DNS
jq '.dns = {servers:[{tag:"user-dns", type:"udp", server:"9.9.9.9"}], final:"user-dns"} | .route.default_domain_resolver = "user-dns"' "$CONFIG_FILE" > "$D/custom.json"
mv "$D/custom.json" "$CONFIG_FILE"
apply_warp_stack_mode v4_prefer_host_v6
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.dns.final == "user-dns" and .route.default_domain_resolver == "user-dns" and (.dns.servers | map(.tag) == ["user-dns", "sb-warp-dns"])' "$CONFIG_FILE" >/dev/null
delete_warp
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.dns.final == "user-dns" and .route.default_domain_resolver == "user-dns" and (.dns.servers | map(.tag) == ["user-dns"])' "$CONFIG_FILE" >/dev/null
jq -e '.route.rules | length == 0' "$CONFIG_FILE" >/dev/null
''', 'test_warp_stack', folder, core],
                capture_output=True, text=True, timeout=25,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


if __name__ == '__main__':
    unittest.main()
