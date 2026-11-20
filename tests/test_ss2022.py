"""Regression tests: temporary config and stubbed service/firewall only."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'singbox.sh'


class SS2022Tests(unittest.TestCase):
    def run_shell(self, names, body, *, core=''):
        source = SCRIPT.read_text()
        funcs = [re.search(r'^' + n + r'\(\) \{\n.*?^\}', source, re.M | re.S).group()
                 for n in names.split()]
        funcs.append(next(x for x in source.splitlines() if x.startswith('validate_port()')))
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run(['bash', '-c', '''
set -eo pipefail
D="$1"; BIN_FILE="$2"
CONFIG_FILE="$D/etc/config.json"; META_DIR="$D/etc/.meta"
NODE_NAMES_META="$META_DIR/node-names.json"; REALITY_META="$META_DIR/reality.txt"
mkdir -p "$D/etc"
printf '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}\n' > "$CONFIG_FILE"
ensure_config() { test -f "$CONFIG_FILE"; }
get_public_ip() { printf '2001:db8::1\n'; }
sleep() { :; }
command() { if [[ "$1 $2" == '-v qrencode' ]]; then return 1; fi; builtin command "$@"; }
''' + '\n'.join(funcs) + '\n' + body, 'regression', folder, core],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_add_share_rename_delete_and_restart_rollback(self):
        core = os.environ.get('SING_BOX_TEST_BIN') or shutil.which('sing-box')
        if not core:
            self.skipTest('set SING_BOX_TEST_BIN to check with a real sing-box core')
        self.run_shell('add_ss2022_node ss2022_link ss2022_count port_in_use read_valid_port '
                       'format_url_host save_and_check_config apply_config_and_restart '
                       'read_node_name save_node_name node_display_name '
                       'node_link_fragment inbound_count inbound_field inbound_node_type count_by_type '
                       'view_node_links rename_node prompt_delete_index delete_node remove_reality_meta', r'''
ss() { return 1; }
netstat() { return 1; }
svc_active() { return 0; }
svc_restart() { :; }
open_firewall_port() { [[ "$1" == 8388 ]]; }
add_ss2022_node > "$D/add" <<<$'08388\n测试节点'
"$BIN_FILE" check -c "$CONFIG_FILE"
jq -e '.inbounds[0] | .type=="shadowsocks" and .method=="2022-blake3-aes-256-gcm" and .listen_port==8388 and (.password|length==44)' "$CONFIG_FILE" >/dev/null
[[ $(stat -c %a "$CONFIG_FILE") == 600 ]]
[[ $(ss2022_link m 'a+/=' '2001:db8::1' 8388 ss2022-8388) == 'ss://m:a%2B%2F%3D@[2001:db8::1]:8388#%E6%B5%8B%E8%AF%95%E8%8A%82%E7%82%B9' ]]
view_node_links > "$D/links"; grep -q '^      链接: ss://2022-blake3-aes-256-gcm:' "$D/links"
cp "$CONFIG_FILE" "$D/previous"
attempt=0
svc_restart() { attempt=$((attempt+1)); [[ "$attempt" -eq 2 ]]; }
open_firewall_port() { touch "$D/unexpected-firewall"; }
if add_ss2022_node > "$D/failed" <<<$'8388\n8389\n失败节点'; then exit 1; fi
cmp "$CONFIG_FILE" "$D/previous"
[[ "$attempt" == 2 && ! -e "$D/unexpected-firewall" && $(node_display_name ss2022-8389) == ss2022-8389 ]]
svc_restart() { :; }
rename_node <<<$'1\nnew'; [[ $(node_display_name ss2022-8388) == new ]]
delete_node <<<'1'; [[ $(ss2022_count) == 0 ]]
''', core=core)

    def test_uninstall_cancel_stop_failure_and_both_modes(self):
        self.run_shell('uninstall_singbox', r'''
PANEL_FILE="$D/sb"; PANEL_ALIAS="$D/SB"; SERVICE_FILE="$D/service"; OPENRC_FILE="$D/openrc"; BIN_FILE="$D/core"; INIT_SYS=systemd
touch "$PANEL_FILE" "$SERVICE_FILE" "$BIN_FILE" "$D/unrelated"
ln -s "$PANEL_FILE" "$PANEL_ALIAS"
svc_active() { return 1; }; svc_stop() { return 1; }
svc_disable() { :; }; svc_daemon_reload() { :; }
(uninstall_singbox full <<<'n'); [[ -f "$CONFIG_FILE" && -f "$PANEL_FILE" ]]
if (uninstall_singbox full <<<'y'); then exit 1; fi
[[ -f "$PANEL_FILE" && -f "$CONFIG_FILE" && -f "$BIN_FILE" ]]
svc_stop() { :; }
(uninstall_singbox <<<'y'); [[ ! -e "$D/etc" && ! -e "$BIN_FILE" && -f "$PANEL_FILE" && -L "$PANEL_ALIAS" ]]
(uninstall_singbox full <<<'y'); [[ ! -e "$PANEL_FILE" && ! -L "$PANEL_ALIAS" && -f "$D/unrelated" ]]
''')


if __name__ == '__main__':
    unittest.main()
