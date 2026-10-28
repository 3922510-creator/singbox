"""Isolated shell regression tests: never source the production entry point."""
import pathlib
import re
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "singbox.sh"


class NodeNamesTests(unittest.TestCase):
    def run_shell(self, body):
        source = SCRIPT.read_text()
        names = ["node_display_name", "read_node_name", "save_node_name",
                 "node_link_fragment", "rename_node", "prompt_delete_index",
                 "inbound_count", "inbound_field", "count_by_type", "view_node_links",
                 "add_reality_node", "add_anytls_node", "menu_nodes", "delete_node"]
        functions = []
        for name in names:
            match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", source, re.M | re.S)
            self.assertIsNotNone(match, name)
            functions.append(match.group())
        with tempfile.TemporaryDirectory(prefix="sb-names-test-") as directory:
            prelude = r'''
set -e -o pipefail
META_DIR="$1"
NODE_NAMES_META="$META_DIR/names.json"
CONFIG_FILE="$META_DIR/config.json"
REALITY_META="$META_DIR/reality.txt"
# Explicit isolation: no network, service operations, or real config initialization.
ensure_config() { :; }
get_public_ip() { printf '192.0.2.1'; }
get_reality_pubkey() { printf 'public-key'; }
svc_restart() { echo unexpected-restart >&2; return 99; }
command() { if [ "$1" = -v ] && [ "$2" = qrencode ]; then return 1; else builtin command "$@"; fi; }
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[{"type":"vless","tag":"vless-reality-443","listen_port":443,"users":[{"uuid":"test-uuid"}],"tls":{"server_name":"example.com","reality":{"short_id":["abc"]}}},{"type":"anytls","tag":"anytls-reality-8444","listen_port":8444,"users":[{"password":"test-password"}],"tls":{"server_name":"example.com","reality":{"short_id":["def"]}}}],"route":{"rules":[{"inbound":["vless-reality-443"],"outbound":"direct"}]}}
JSON
'''
            result = subprocess.run(["bash", "-c", prelude + "\n" + "\n".join(functions) + "\n" + body,
                                     "test", directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_roundtrip_encoding_clear_and_corruption(self):
        self.run_shell(r'''
tag=vless-reality-443
[ "$(node_display_name "$tag")" = "$tag" ]
name='香港 01 #A & B / "专线" \\n'
save_node_name "$tag" "$name"
[ "$(node_display_name "$tag")" = "$name" ]
[ "$(stat -c %a "$NODE_NAMES_META")" = 600 ]
[ "$(node_link_fragment "$tag")" = "$(printf %s "$name" | jq -sRr @uri)" ]
save_node_name anytls-reality-8444 '日本'
save_node_name "$tag" ''
[ "$(node_display_name "$tag")" = "$tag" ]
[ "$(node_display_name anytls-reality-8444)" = 日本 ]
printf broken > "$NODE_NAMES_META"
if save_node_name "$tag" changed; then exit 1; fi
[ "$(cat "$NODE_NAMES_META")" = broken ]
[ "$(find "$META_DIR" -name '*.tmp.*' | wc -l)" = 0 ]
''')

    def test_rename_actual_selection_without_config_change(self):
        self.run_shell(r'''
before=$(sha256sum "$CONFIG_FILE")
rename_node <<< $'2\n日本 东京 #2\n'
[ "$(node_display_name anytls-reality-8444)" = '日本 东京 #2' ]
[ "$(sha256sum "$CONFIG_FILE")" = "$before" ]
rename_node <<< $'2\n\n'
[ "$(node_display_name anytls-reality-8444)" = anytls-reality-8444 ]
rename_node <<< '0'
[ "$(sha256sum "$CONFIG_FILE")" = "$before" ]
''')

    def test_list_and_share_links_for_both_protocols(self):
        self.run_shell(r'''
save_node_name vless-reality-443 '香港 #1'
save_node_name anytls-reality-8444 '日本 & 2'
output=$(view_node_links)
[[ "$output" = *'VLESS-Reality | 香港 #1'* ]]
[[ "$output" = *'AnyTLS-Reality | 日本 & 2'* ]]
[[ "$output" = *"#$(node_link_fragment vless-reality-443)"* ]]
[[ "$output" = *"#$(node_link_fragment anytls-reality-8444)"* ]]
''')

    def test_validation_and_eof(self):
        self.run_shell(r'''
long=$(printf '%081d' 0)
name=$(read_node_name <<< "$long
合法中文")
[ "$name" = 合法中文 ]
name=$(read_node_name <<< $'bad\tname\n正常\n')
[ "$name" = 正常 ]
if read_node_name < /dev/null; then exit 1; fi
''')

    def test_create_both_protocols_and_qr_payload(self):
        self.run_shell(r'''
BIN_FILE="$META_DIR/mock-core"
cat > "$BIN_FILE" <<'MOCK'
#!/bin/bash
case "$2" in
reality-keypair) printf 'PrivateKey: private\nPublicKey: public\n' ;;
uuid) printf uuid ;;
rand) printf abc123 ;;
esac
MOCK
chmod +x "$BIN_FILE"
read_valid_port() { printf '%s' "$2"; }
singbox_version_ge() { return 0; }
save_and_check_config() { printf '%s' "$1" > "$CONFIG_FILE"; }
save_reality_meta() { :; }
open_firewall_port() { :; }
svc_restart() { :; }
command() { if [ "$1" = -v ] && [ "$2" = qrencode ]; then return 0; else builtin command "$@"; fi; }
qrencode() { printf '%s' "$3" > "$META_DIR/qr-link"; }
add_reality_node <<< $'example.com\n香港 #1\ny\n'
[ "$(node_display_name vless-reality-443)" = '香港 #1' ]
[[ "$(cat "$META_DIR/qr-link")" = vless://*"#$(node_link_fragment vless-reality-443)" ]]
add_anytls_node <<< $'example.com\n日本 & 2\ny\n'
[ "$(node_display_name anytls-reality-8444)" = '日本 & 2' ]
[[ "$(cat "$META_DIR/qr-link")" = anytls://*"#$(node_link_fragment anytls-reality-8444)" ]]
jq -e '.inbounds | length == 4' "$CONFIG_FILE"
''')


if __name__ == "__main__":
    unittest.main()
