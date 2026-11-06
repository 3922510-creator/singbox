"""Old-install cleanup: real temporary files, fake init boundary; never host services."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class LegacyCleanup(unittest.TestCase):
    def run_shell(self, body):
        with tempfile.TemporaryDirectory(prefix='sb-legacy-') as root:
            prelude = r'''
set -e -o pipefail
source "$1"
ROOT="$2"
CONFIG_DIR="$ROOT/config"; CONFIG_FILE="$CONFIG_DIR/config.json"
META_DIR="$CONFIG_DIR/.meta"; STATE_FILE="$META_DIR/state.json"; ARGO_DIR="$META_DIR/tunnels"
BIN_FILE="$ROOT/sing-box"; SERVICE_FILE="$ROOT/sing-box.service"; OPENRC_FILE="$ROOT/openrc"
SINGBOX_LOG="$ROOT/log"; BACKUP_DIR="$ROOT/backups"
LEGACY_PANEL="$ROOT/sb"; LEGACY_ALIAS="$ROOT/SB"; LEGACY_COPY="$ROOT/old-copy"
LOCK_FILE="$ROOT/lock"; INIT_SYS=systemd
mkdir -p "$META_DIR" "$BACKUP_DIR"
printf '{"inbounds":[]}' > "$CONFIG_FILE"
printf secret > "$META_DIR/private-key"
printf core > "$BIN_FILE"
printf log > "$SINGBOX_LOG"
printf keep > "$BACKUP_DIR/existing"
printf 'Description=Sing-box Service\nExecStart=%s run -C %s\n' "$BIN_FILE" "$CONFIG_DIR" > "$SERVICE_FILE"
printf '# Sing-box 管理面板\nSCRIPT_VERSION="v3.7.0"\n' > "$LEGACY_PANEL"
cp "$LEGACY_PANEL" "$LEGACY_COPY"
ln -s "$LEGACY_PANEL" "$LEGACY_ALIAS"
systemctl() {
    case "$*" in
        'show sing-box -p FragmentPath --value') printf '%s\n' "$SERVICE_FILE" ;;
        'show sing-box -p DropInPaths --value') [ ! -e "$ROOT/dropin" ] || printf other ;;
        'stop sing-box') printf stop >> "$ROOT/actions"; [ ! -e "$ROOT/stop-fail" ] ;;
        'is-active --quiet sing-box') [ -e "$ROOT/still-running" ] ;;
        'disable sing-box') printf disable >> "$ROOT/actions" ;;
        daemon-reload) printf reload >> "$ROOT/actions" ;;
        *) echo "Unexpected systemctl $*" >&2; return 1 ;;
    esac
}
rc-service() {
    [ "$1" = sing-box ] || return 1
    case "$2" in stop) printf stop >> "$ROOT/actions" ;; status) return 1 ;; *) return 1 ;; esac
}
rc-update() { [ "$*" = 'del sing-box default' ]; printf disable >> "$ROOT/actions"; }
'''
            result = subprocess.run(['bash', '-c', prelude + '\n' + body,
                                     'test', str(REPO / 'singbox.sh'), root],
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_cancel_default_and_non_exact_y(self):
        self.run_shell(r'''
for answer in '' n Y yes; do
    if legacy_cleanup <<< "$answer"; then exit 1; fi
    [ -f "$CONFIG_FILE" ] && [ -f "$LEGACY_PANEL" ] && [ ! -e "$ROOT/actions" ]
done
[ "$(find "$BACKUP_DIR" -type f | wc -l)" = 1 ]
''')

    def test_real_file_cleanup_backup_and_symlink_alias(self):
        self.run_shell(r'''
legacy_cleanup <<< y
[ ! -e "$CONFIG_DIR" ] && [ ! -e "$BIN_FILE" ] && [ ! -e "$SERVICE_FILE" ]
[ ! -e "$LEGACY_PANEL" ] && [ ! -L "$LEGACY_ALIAS" ] && [ ! -e "$LEGACY_COPY" ]
[ ! -e "$SINGBOX_LOG" ] && [ -e "$BACKUP_DIR/existing" ]
backup=("$BACKUP_DIR"/legacy-*)
[ "$(cat "${backup[0]}/config/.meta/private-key")" = secret ]
[ "$(stat -c %a "${backup[0]}")" = 700 ]
[ -L "${backup[0]}/scripts/2" ]
[ "$(cat "$ROOT/actions")" = stopdisablereload ]
''')

    def test_keep_new_panel_and_unknown_copy(self):
        self.run_shell(r'''
printf '# Sing-box 管理面板 v4\nSCRIPT_VERSION="v4.0.1"\n' > "$LEGACY_PANEL"
printf unrelated > "$LEGACY_COPY"
legacy_cleanup <<< y
[ -f "$LEGACY_PANEL" ] && [ -L "$LEGACY_ALIAS" ]
[ "$(cat "$LEGACY_COPY")" = unrelated ]
''')

    def test_v4_state_and_unknown_services_block_all_changes(self):
        self.run_shell(r'''
printf broken > "$STATE_FILE"
if legacy_cleanup <<< y; then exit 1; fi
rm "$STATE_FILE"
printf '\nExecStop=/unexpected\n' >> "$SERVICE_FILE"
if legacy_cleanup <<< y; then exit 1; fi
[ -f "$CONFIG_FILE" ] && [ ! -e "$ROOT/actions" ]
''')

    def test_dropin_or_foreign_fragment_blocks(self):
        self.run_shell(r'''
touch "$ROOT/dropin"
if legacy_cleanup <<< y; then exit 1; fi
[ ! -e "$ROOT/actions" ] && [ -f "$CONFIG_FILE" ]
''')

    def test_symlink_and_tunnel_metadata_block(self):
        self.run_shell(r'''
mv "$CONFIG_DIR" "$ROOT/actual"
ln -s "$ROOT/actual" "$CONFIG_DIR"
if legacy_cleanup <<< y; then exit 1; fi
rm "$CONFIG_DIR"; mv "$ROOT/actual" "$CONFIG_DIR"
mkdir "$ARGO_DIR"
if legacy_cleanup <<< y; then exit 1; fi
[ ! -e "$ROOT/actions" ] && [ -f "$CONFIG_FILE" ]
''')

    def test_stop_failure_preserves_files_and_backup(self):
        self.run_shell(r'''
touch "$ROOT/stop-fail"
if legacy_cleanup <<< y; then exit 1; fi
[ -f "$CONFIG_FILE" ] && [ -f "$BIN_FILE" ] && [ -f "$LEGACY_PANEL" ]
backup=("$BACKUP_DIR"/legacy-*)
[ -f "${backup[0]}/config/config.json" ]
[ "$(cat "$ROOT/actions")" = stop ]
''')

    def test_still_running_preserves_files(self):
        self.run_shell(r'''
touch "$ROOT/still-running"
if legacy_cleanup <<< y; then exit 1; fi
[ -f "$CONFIG_FILE" ] && [ -f "$BIN_FILE" ]
[ "$(cat "$ROOT/actions")" = stop ]
''')

    def test_openrc_cleanup(self):
        self.run_shell(r'''
INIT_SYS=openrc
rm "$SERVICE_FILE"
printf '# sb-service-rev=2\n# 由 sb 管理面板生成；手动改完请 rc-service sing-box restart\ncommand="%s"\ncommand_args="run -C %s"\n' "$BIN_FILE" "$CONFIG_DIR" > "$OPENRC_FILE"
legacy_cleanup <<< y
[ ! -e "$OPENRC_FILE" ] && [ ! -e "$CONFIG_DIR" ]
[ "$(cat "$ROOT/actions")" = stopdisable ]
''')

    def test_backup_failure_never_stops_or_deletes(self):
        self.run_shell(r'''
cp() { return 1; }
if legacy_cleanup <<< y; then exit 1; fi
[ ! -e "$ROOT/actions" ] && [ -f "$CONFIG_FILE" ] && [ -f "$BIN_FILE" ]
''')

    def test_unknown_service_or_missing_init_blocks(self):
        self.run_shell(r'''
INIT_SYS=none
if legacy_cleanup <<< y; then exit 1; fi
INIT_SYS=systemd
printf 'Description=unrelated\\nExecStart=other\\n' > "$SERVICE_FILE"
if legacy_cleanup <<< y; then exit 1; fi
[ ! -e "$ROOT/actions" ] && [ -f "$CONFIG_FILE" ]
''')

    def test_orphan_legacy_argv_blocks_deletion(self):
        self.run_shell(r'''
# A child with the exact old argv suffix; only this test's PID is ever killed.
python3 -c 'import time; time.sleep(10)' "$BIN_FILE" run -C "$CONFIG_DIR" &
child=$!
trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true' EXIT
sleep 0.1
if legacy_cleanup <<< y; then exit 1; fi
[ -f "$CONFIG_FILE" ] && [ "$(cat "$ROOT/actions")" = stop ]
''')

    def test_cleanup_failure_never_installs(self):
        self.run_shell(r'''
install_singbox() { touch "$ROOT/installed"; }
if legacy_reinstall <<< n; then exit 1; fi
[ ! -e "$ROOT/installed" ]
''')

    def test_cleanup_then_install_separate_confirmation(self):
        self.run_shell(r'''
install_singbox() { confirm install && touch "$ROOT/installed"; }
if legacy_reinstall <<< $'y\nn'; then exit 1; fi
[ ! -e "$ROOT/installed" ] && [ ! -e "$CONFIG_DIR" ]
''')


if __name__ == '__main__':
    unittest.main()
