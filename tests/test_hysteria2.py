"""Hysteria 2 panel regression; no production service or firewall changes."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'singbox.sh'


class Hysteria2Tests(unittest.TestCase):
    def test_add_and_share_with_udp_only(self):
        core = os.environ.get('SING_BOX_TEST_BIN') or shutil.which('sing-box')
        if not core or not shutil.which('openssl'):
            self.skipTest('requires sing-box and openssl')
        names = '''add_hysteria2_node hysteria2_link view_node_links open_firewall_port
                   count_by_type ss2022_count nodes_total_count prompt_delete_index
                   inbound_count inbound_field inbound_node_type format_url_host singbox_version_ge
                   node_link_fragment read_node_name save_node_name node_display_name'''
        source = SCRIPT.read_text()
        funcs = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S).group()
                          for name in names.split())
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['bash', '-c', funcs + r'''
set -eo pipefail
D=$1; BIN_FILE=$2
CONFIG_FILE="$D/config.json"; META_DIR="$D/meta"; NODE_NAMES_META="$META_DIR/names.json"
printf '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}\n' > "$CONFIG_FILE"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 1 \
    -subj /CN=hy.example.com -addext subjectAltName=DNS:hy.example.com \
    -keyout "$D/key.pem" -out "$D/cert.pem" >/dev/null 2>&1
ensure_config() { test -f "$CONFIG_FILE"; }
read_valid_port() { test "$2" = 8444 && printf '%s\n' "${TEST_PORT:-$2}"; }
port_in_use() { [[ "$1" == 80 && "${HTTP_BUSY:-no}" == yes ]]; }
get_public_ip() { printf '127.0.0.1\n'; }
command() { if [[ "$1 $2" == '-v qrencode' ]]; then return 1; fi; builtin command "$@"; }
ufw() {
    if [[ "$1" == status ]]; then printf 'Status: active\n'; else printf '%s\n' "$*" >> "$D/firewall"; fi
}
apply_config_and_restart() {
    printf '%s\n' "$1" > "$D/candidate.json"
    "$BIN_FILE" check -c "$D/candidate.json" && mv "$D/candidate.json" "$CONFIG_FILE"
}
if add_hysteria2_node <<<'bad/path'; then exit 1; fi
[[ $(nodes_total_count) == 0 && ! -e "$D/firewall" ]]
add_hysteria2_node > "$D/add" <<EOF
hy.example.com
3
$D/cert.pem
$D/key.pem
测试 Hy2
n
EOF
jq -e '.inbounds[0] | .type == "hysteria2" and .listen_port == 8444 and .tls.enabled and .tls.server_name == "hy.example.com" and (.users[0].password | length > 0)' "$CONFIG_FILE" >/dev/null
[[ $(nodes_total_count) == 1 && $(cat "$D/firewall") == 'allow 8444/udp' ]]
[[ $(prompt_delete_index 节点 node <<<'1') == 0 ]]
[[ $(hysteria2_link 'a@b' hy.example.com 8444 hysteria2-8444) == 'hysteria2://a%40b@hy.example.com:8444/?sni=hy.example.com#%E6%B5%8B%E8%AF%95%20Hy2' ]]
view_node_links > "$D/view"
link=$(grep -o 'hysteria2://[^[:space:]]*' "$D/add")
grep -Fq "$link" "$D/view"

# Older cores still verify the PEM mode above. Run both ACME modes on compatible cores.
if singbox_version_ge 1.14.0 && "$BIN_FILE" version | grep -Eq '^Tags:.*[ ,]with_acme([ ,]|$)'; then
    HTTP_BUSY=yes
    if add_hysteria2_node <<< $'hy.example.com\n1'; then exit 1; fi
    [[ $(nodes_total_count) == 1 ]]
    if add_hysteria2_node <<< $'hy.example.com\n2\n\n'; then exit 1; fi
    [[ $(nodes_total_count) == 1 ]]
    HTTP_BUSY=no TEST_PORT=8445
    add_hysteria2_node > "$D/http" <<< $'http.example.com\n\nadmin@example.com\nHTTP\n'
    jq -e --arg dir "$META_DIR/acme" '.inbounds[1].tls.certificate_provider == {
        type:"acme", provider:"letsencrypt", domain:["http.example.com"], data_directory:$dir,
        disable_tls_alpn_challenge:true, email:"admin@example.com"}' "$CONFIG_FILE" >/dev/null
    HTTP_BUSY=yes TEST_PORT=8446
    add_hysteria2_node > "$D/dns" <<< $'dns.example.com\n2\n\nnot-a-real-token\nDNS\n'
    jq -e '.inbounds[2].tls.certificate_provider | .domain == ["dns.example.com"] and
        .dns01_challenge == {provider:"cloudflare", api_token:"not-a-real-token"}' "$CONFIG_FILE" >/dev/null
    ! grep -Fq 'not-a-real-token' "$D/dns"
    [[ $(cat "$D/firewall") == $'allow 8444/udp\nallow 8445/udp\nallow 8446/udp' ]]
fi
''', 'hy2-regression', tmp, core], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
