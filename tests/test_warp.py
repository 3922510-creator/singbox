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


if __name__ == '__main__':
    unittest.main()
