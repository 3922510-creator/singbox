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
            'add_warp',
        ])
        with tempfile.TemporaryDirectory() as folder:
            res = subprocess.run(
                ['bash', '-c', '''
set -euo pipefail
D="$1"; BIN_FILE="$2"
CONFIG_FILE="$D/etc/config.json"; WARP_META="$D/etc/.meta/warp.json"
RED=""; GREEN=""; YELLOW=""; BLUE=""; PLAIN=""
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
svc_restart() { :; }
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


if __name__ == '__main__':
    unittest.main()
