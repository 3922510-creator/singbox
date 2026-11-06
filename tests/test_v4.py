"""Isolated v4 tests. All mutators use a temporary filesystem and mocked services.

Sourcing the built script must have zero startup actions. Network access and host
service commands are forbidden in this harness; real core integration is separate.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest
import importlib.util

ROOT = Path(__file__).resolve().parents[1]


class Sandbox(unittest.TestCase):
    def shell(self, body, timeout=15):
        with tempfile.TemporaryDirectory(prefix="sb-v4-test-") as directory:
            prelude = r'''
set -e -o pipefail
source "$1"
ROOT="$2"
CONFIG_DIR="$ROOT/config"; CONFIG_FILE="$CONFIG_DIR/config.json"
META_DIR="$CONFIG_DIR/.meta"; STATE_FILE="$META_DIR/state.json"
ARGO_DIR="$META_DIR/tunnels"; BACKUP_DIR="$ROOT/backups"
SERVICE_FILE="$ROOT/sing-box.service"; OPENRC_FILE="$ROOT/sing-box-openrc"
SINGBOX_LOG="$ROOT/sing-box.log"; LOCK_FILE="$ROOT/lock"
BIN_FILE="$ROOT/core"; CF_BIN="$ROOT/cloudflared"
INIT_SYS=systemd; OS_FAMILY=debian
umask 077
mkdir -p "$META_DIR" "$ROOT/units"
printf '# sb-v4-managed\n' > "$SERVICE_FILE"
printf active > "$ROOT/active"
write_json "$CONFIG_FILE" '{"inbounds":[{"tag":"node1","type":"vless","listen":"::","listen_port":443,"users":[{"uuid":"uuid","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"example.com","reality":{"enabled":true,"short_id":["abcd"]}}}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}'
write_json "$STATE_FILE" '{"format":4,"nodes":{"node1":{"kind":"vless","name":"node1","public_key":"public"}}}'
cat > "$BIN_FILE" <<'CORE'
#!/usr/bin/env bash
case "$1" in
  check) ! grep -F 'reject_config' "$3" >/dev/null ;;
  version) printf 'sing-box version 1.14.4\n' ;;
  generate)
    case "$2" in
      reality-keypair) printf 'PrivateKey: private\nPublicKey: public\n' ;;
      uuid) printf '11111111-1111-4111-8111-111111111111' ;;
      rand) printf 'abcdef1234567890' ;;
    esac ;;
  *) exit 99 ;;
esac
CORE
chmod 755 "$BIN_FILE"
# Host-affecting commands are a hard failure. Tests override only narrow seams.
systemctl() { printf 'UNEXPECTED systemctl %s\n' "$*" >&2; return 99; }
rc-service() { printf 'UNEXPECTED rc-service\n' >&2; return 99; }
rc-update() { return 99; }
curl() { printf 'UNEXPECTED network\n' >&2; return 99; }
ufw() { printf '%s\n' "$*" >> "$ROOT/ufw"; }
get_public_ip() { printf '192.0.2.1'; }
svc_active() { [ -e "$ROOT/active" ]; }
svc_restart() {
    printf restart >> "$ROOT/restarted"
    [ ! -e "$ROOT/fail-always" ] || return 1
    if [ -e "$ROOT/fail-once" ]; then rm "$ROOT/fail-once"; return 1; fi
    touch "$ROOT/active"
}
svc_stop() { rm -f "$ROOT/active"; }
sleep() { :; }
argo_unit_path() { valid_tunnel_id "$1" && printf '%s/units/%s' "$ROOT" "$1"; }
argo_ctl() { argo_owned "$1" || return 1; printf '%s %s\n' "$1" "$2" >> "$ROOT/argo-actions"; }
argo_enable() { printf enable >> "$ROOT/argo-enable"; }
argo_disable() { printf disable >> "$ROOT/argo-disable"; }
argo_active() { [ -e "$ROOT/tunnel-active" ]; }
install_cloudflared() { :; }
probe_node() { [ ! -e "$ROOT/fail-probe" ]; }
show_node() { node_link "$1"; }
port_in_use() { return 1; }
# Fake system manager for the sole creation/reload seam.
create_tunnel() {
    systemctl() { [ "$1" = daemon-reload ]; }
    argo_create "$@"
}
ID=11111111-1111-4111-8111-111111111111
TOKEN=$(printf '{"a":"account","s":"secret","t":"%s"}' "$ID" | base64 -w0)
'''
            result = subprocess.run(
                ["bash", "-c", prelude + "\n" + body, "test", str(ROOT / "singbox.sh"), directory],
                text=True, capture_output=True, timeout=timeout,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout + result.stderr


class V4Tests(Sandbox):
    def test_build_matches_source(self):
        spec = importlib.util.spec_from_file_location("build", ROOT / "tools/build.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.build(), (ROOT / "singbox.sh").read_text())

    def test_confirm_exact_y_and_eof(self):
        self.shell(r'''
for answer in n Y yes 确认 ''; do if confirm testing <<< "$answer"; then exit 1; fi; done
if confirm testing < /dev/null; then exit 1; fi
confirm testing <<< y
''')

    def test_no_startup_mutation_and_no_compatibility(self):
        self.shell(r'''
before=$(sha256sum "$CONFIG_FILE" "$STATE_FILE")
source "$1"
# Re-source only defines constants/functions; no install or startup calls.
CONFIG_FILE="$ROOT/config/config.json"; STATE_FILE="$ROOT/config/.meta/state.json"
[ "$before" = "$(sha256sum "$CONFIG_FILE" "$STATE_FILE")" ]
[ ! -e "$ROOT/restarted" ]
''')

    def test_reject_corrupt_config_without_overwrite(self):
        self.shell(r'''
printf broken > "$CONFIG_FILE"
if require_owned; then exit 1; fi
[ "$(cat "$CONFIG_FILE")" = broken ]
''')

    def test_refuse_old_or_unknown_install(self):
        self.shell(r'''
rm "$STATE_FILE"
before=$(sha256sum "$CONFIG_FILE")
if install_singbox <<< y; then exit 1; fi
[ "$before" = "$(sha256sum "$CONFIG_FILE")" ]
[ ! -e "$ROOT/restarted" ]
''')

    def test_cancel_transaction_no_write_no_backup(self):
        self.shell(r'''
before=$(sha256sum "$CONFIG_FILE" "$STATE_FILE")
config=$(jq '.log={level:"debug"}' "$CONFIG_FILE")
if apply_config "$config" "$(cat "$STATE_FILE")" test <<< n; then exit 1; fi
[ "$before" = "$(sha256sum "$CONFIG_FILE" "$STATE_FILE")" ]
[ ! -e "$BACKUP_DIR" ]
''')

    def test_candidate_rejection_preserves_both_files(self):
        self.shell(r'''
before=$(sha256sum "$CONFIG_FILE" "$STATE_FILE")
config=$(jq '.reject_config=true' "$CONFIG_FILE")
if apply_config "$config" "$(cat "$STATE_FILE")" test <<< y; then exit 1; fi
[ "$before" = "$(sha256sum "$CONFIG_FILE" "$STATE_FILE")" ]
[ ! -e "$ROOT/restarted" ]
''')

    def test_success_transaction_private_backup(self):
        self.shell(r'''
config=$(jq '.log={level:"debug"}' "$CONFIG_FILE")
apply_config "$config" "$(cat "$STATE_FILE")" test <<< y
jq -e '.log.level=="debug"' "$CONFIG_FILE"
[ -f "$LAST_TX/config.json" ] && [ -f "$LAST_TX/state.json" ]
[ "$(stat -c %a "$LAST_TX")" = 700 ]
[ "$(stat -c %a "$CONFIG_FILE")" = 600 ]
''')

    def test_restart_failure_rolls_back_config_and_metadata(self):
        self.shell(r'''
before=$(sha256sum "$CONFIG_FILE" "$STATE_FILE")
config=$(jq '.log={level:"debug"}' "$CONFIG_FILE")
state=$(jq '.nodes.node1.name="changed"' "$STATE_FILE")
touch "$ROOT/fail-once"
if apply_config "$config" "$state" test <<< y; then exit 1; fi
[ "$before" = "$(sha256sum "$CONFIG_FILE" "$STATE_FILE")" ]
[ "$(cat "$ROOT/restarted")" = restartrestart ]
''')

    def test_failed_start_keeps_originally_stopped_service_stopped(self):
        self.shell(r'''
rm "$ROOT/active"; touch "$ROOT/fail-once"
if apply_config "$(cat "$CONFIG_FILE")" "$(cat "$STATE_FILE")" test <<< y; then exit 1; fi
[ ! -e "$ROOT/active" ]
''')

    def test_metadata_mismatch_and_public_argo_rejected(self):
        self.shell(r'''
if validate_managed_config "$(cat "$CONFIG_FILE")" '{"format":4,"nodes":{"missing":{"kind":"vless"}}}'; then exit 1; fi
state='{"format":4,"nodes":{"node1":{"kind":"argo"}}}'
if validate_managed_config "$(cat "$CONFIG_FILE")" "$state"; then exit 1; fi
''')

    def test_port_domain_path_validation(self):
        self.shell(r'''
for p in 0 65536 001 08 -1 abc; do if validate_port "$p"; then exit 1; fi; done
validate_port 1; validate_port 65535
for d in https://a.com a..com -a.com a.com. a/b a; do if valid_domain "$d"; then exit 1; fi; done
valid_domain argo.example.com
for path in bad '/a b' '/a?b' '/a#b' '/%2F'; do if valid_ws_path "$path"; then exit 1; fi; done
valid_ws_path /my/path-1
if read_valid_port test '' < /dev/null; then exit 1; fi
''')

    def test_port_checks_actual_tcp_and_udp_and_config(self):
        self.shell(r'''
# Restore the actual implementation, replacing only the ss command.
eval "$(sed -n '/^port_in_use() {/,/^}/p' "$1")"
ss() { printf 'tcp LISTEN 0 0 127.0.0.1:21871 0.0.0.0:*\nudp UNCONN 0 0 [::]:21872 [::]:*\n'; }
port_in_use 443; port_in_use 21871; port_in_use 21872
if port_in_use 21873; then exit 1; fi
''')

    def test_token_validation_no_secret_output(self):
        output = self.shell(r'''
[ "$(token_tunnel_id "$TOKEN")" = "$ID" ]
if token_tunnel_id 'cloudflared service install bad'; then exit 1; fi
if token_tunnel_id invalid; then exit 1; fi
if valid_tunnel_id ../../etc; then exit 1; fi
''')
        self.assertNotIn('secret', output)

    def test_tunnel_create_private_file_and_argv(self):
        output = self.shell(r'''
create_tunnel "$ID" "$TOKEN"
[ "$(stat -c %a "$ARGO_DIR/$ID/token")" = 600 ]
[ "$(stat -c %a "$ARGO_DIR/$ID")" = 700 ]
grep -F -- '--token-file' "$ROOT/units/$ID"
if grep -F "$TOKEN" "$ROOT/units/$ID"; then exit 1; fi
create_tunnel "$ID" "$TOKEN"
if create_tunnel "$ID" "${TOKEN}different"; then exit 1; fi
''')
        self.assertNotIn('eyJh', output)

    def test_unknown_tunnel_never_overwritten(self):
        self.shell(r'''
printf foreign > "$ROOT/units/$ID"
if create_tunnel "$ID" "$TOKEN"; then exit 1; fi
[ "$(cat "$ROOT/units/$ID")" = foreign ]
''')

    def test_openrc_service_definition_and_closed_lock(self):
        self.shell(r'''
INIT_SYS=openrc
argo_create "$ID" "$TOKEN"
grep -F 'supervisor="supervise-daemon"' "$ROOT/units/$ID"
grep -F 'respawn_max=0' "$ROOT/units/$ID"
install_service_file
sh -n "$OPENRC_FILE"
grep -F 'run -c ' "$OPENRC_FILE"
''')

    def test_argo_wizard_success_and_shared_tunnel_reuse(self):
        self.shell(r'''
systemctl() { [ "$1" = daemon-reload ]; }
add_argo_node <<< $'21871\n/ws\nargo.example.com\n'"$TOKEN"$'\n节点一\ny\ny\n'
jq -e '.nodes["argo-21871"].kind=="argo"' "$STATE_FILE"
add_argo_node <<< $'21872\n/ws2\nargo2.example.com\n'"$TOKEN"$'\n节点二\ny\ny\n'
[ "$(find "$ARGO_DIR" -name token | wc -l)" = 1 ]
''')

    def test_argo_probe_failure_rolls_back_and_removes_new_tunnel(self):
        self.shell(r'''
systemctl() { [ "$1" = daemon-reload ]; }
before=$(sha256sum "$CONFIG_FILE" "$STATE_FILE")
touch "$ROOT/fail-probe"
if add_argo_node <<< $'21871\n/ws\nargo.example.com\n'"$TOKEN"$'\n节点\ny\ny\n'; then exit 1; fi
[ "$before" = "$(sha256sum "$CONFIG_FILE" "$STATE_FILE")" ]
[ ! -e "$ARGO_DIR/$ID" ] && [ ! -e "$ROOT/units/$ID" ]
''')

    def test_argo_cancel_after_tunnel_creation_cleans_resources(self):
        self.shell(r'''
systemctl() { [ "$1" = daemon-reload ]; }
if add_argo_node <<< $'21871\n/ws\nargo.example.com\n'"$TOKEN"$'\n节点\ny\nn\n'; then exit 1; fi
[ ! -e "$ARGO_DIR/$ID" ] && [ ! -e "$ROOT/units/$ID" ]
''')

    def test_delete_shared_argo_preserves_tunnel_then_removes_last(self):
        self.shell(r'''
systemctl() { [ "$1" = daemon-reload ]; }
add_argo_node <<< $'21871\n/ws\nargo.example.com\n'"$TOKEN"$'\n一\ny\ny\n'
add_argo_node <<< $'21872\n/ws\nargo2.example.com\n'"$TOKEN"$'\n二\ny\ny\n'
delete_node argo-21871 <<< y
[ -f "$ARGO_DIR/$ID/token" ]
delete_node argo-21872 <<< y
[ ! -e "$ARGO_DIR/$ID" ]
[ -f "$LAST_TX/tunnel-$ID/token" ]
''')

    def test_ssh_actual_nonstandard_ports(self):
        self.shell(r'''
ss() { printf 'LISTEN 0 128 0.0.0.0:62900 0.0.0.0:* users:(("sshd",pid=12,fd=3))\nLISTEN 0 128 [::]:62900 [::]:* users:(("sshd",pid=12,fd=4))\n'; }
[ "$(ssh_ports)" = 62900 ]
ss() { :; }
if ssh_ports; then exit 1; fi
''')

    def test_menu_exit_and_all_features_reachable(self):
        output = self.shell(r'''
if show_menu <<< 0; then exit 1; else [ "$?" = 10 ]; fi
''')
        for text in ('搭建 / 添加节点', '我的节点', '转发与分流', '检查与维护', '系统与高级设置'):
            self.assertIn(text, output)

    def test_rollback_recovers_deleted_argo_credentials_from_backup(self):
        self.shell(r'''
systemctl() { [ "$1" = daemon-reload ]; }
: > "$CF_BIN"; chmod 755 "$CF_BIN"
add_argo_node <<< $'21871\n/ws\nargo.example.com\n'"$TOKEN"$'\n一\ny\ny\n'
delete_node argo-21871 <<< y
backup=${LAST_TX##*/}
rollback_config <<< "$backup"$'\ny\n'
jq -e '.nodes["argo-21871"].kind=="argo"' "$STATE_FILE"
[ -f "$ARGO_DIR/$ID/token" ]
[ "$(cat "$ARGO_DIR/$ID/token")" = "$TOKEN" ]
''')

    def test_failure_writing_metadata_restores_config(self):
        self.shell(r'''
before=$(sha256sum "$CONFIG_FILE" "$STATE_FILE")
eval "$(declare -f write_json | sed '1s/write_json/write_json_original/')"
write_json() { [ "$1" != "$STATE_FILE" ] || return 1; write_json_original "$@"; }
config=$(jq '.log={level:"debug"}' "$CONFIG_FILE")
if apply_config "$config" "$(cat "$STATE_FILE")" test <<< y; then exit 1; fi
[ "$before" = "$(sha256sum "$CONFIG_FILE" "$STATE_FILE")" ]
''')

    def test_argo_failure_does_not_stop_running_shared_tunnel(self):
        self.shell(r'''
systemctl() { [ "$1" = daemon-reload ]; }
add_argo_node <<< $'21871\n/ws\nargo.example.com\n'"$TOKEN"$'\n一\ny\ny\n'
touch "$ROOT/tunnel-active" "$ROOT/fail-probe"
: > "$ROOT/argo-actions"
if add_argo_node <<< $'21872\n/ws2\nargo2.example.com\n'"$TOKEN"$'\n二\ny\ny\n'; then exit 1; fi
if grep -F ' stop' "$ROOT/argo-actions"; then exit 1; fi
[ -f "$ARGO_DIR/$ID/token" ]
jq -e '(.nodes | has("argo-21871")) and (.nodes | has("argo-21872") | not)' "$STATE_FILE"
''')

    def test_warp_rules_deduplicate_and_preserve_existing_ruleset(self):
        self.shell(r'''
require_warp() { :; }
save_and_check_config() { write_json "$CONFIG_FILE" "$1"; }
config=$(jq '.route.rule_set=[{type:"local",tag:"geosite-openai",format:"binary",path:"/my/openai.srs"}]' "$CONFIG_FILE")
write_json "$CONFIG_FILE" "$config"
add_warp_ai
jq -e '(.route.rule_set|length)==3 and (.route.rule_set[] | select(.tag=="geosite-openai") | .path=="/my/openai.srs")' "$CONFIG_FILE"
if add_warp_ai; then exit 1; fi
jq -e '(.route.rules|length)==1' "$CONFIG_FILE"
''')

    def test_core_service_operations_close_lock_in_child(self):
        self.shell(r'''
eval "$(sed -n '/^svc_ctl() {/,/^}/p' "$1")"
exec 200>"$ROOT/test-lock"
systemctl() { [ ! -e "/proc/$BASHPID/fd/200" ]; }
svc_ctl start
[ -e "/proc/$BASHPID/fd/200" ]
''')

    def test_bbr_status_never_installs_or_mutates_queue(self):
        self.shell(r'''
modinfo() { return 1; }
tc() { case "$1 $2" in 'qdisc show') printf 'qdisc fq_codel 0: root\n' ;; *) error 'unexpected queue mutation'; return 99 ;; esac; }
apk() { error 'unexpected package install'; return 99; }
sysctl() { printf 'cubic\n'; }
bbr_status_short
''')

    def test_fresh_core_install_initializes_v4_only(self):
        self.shell(r'''
old_core="$BIN_FILE"
CONFIG_DIR="$ROOT/fresh"; CONFIG_FILE="$CONFIG_DIR/config.json"; META_DIR="$CONFIG_DIR/.meta"; STATE_FILE="$META_DIR/state.json"
BIN_FILE="$ROOT/fresh-bin"; SERVICE_FILE="$ROOT/fresh.service"
arch=$(release_arch)
mkdir -p "$ROOT/archive/sing-box-1.14.4-linux-$arch"
cp "$old_core" "$ROOT/archive/sing-box-1.14.4-linux-$arch/sing-box"
# Create an archive with the precise upstream layout, not a ./ prefix.
tar -czf "$ROOT/release.tgz" -C "$ROOT/archive" "sing-box-1.14.4-linux-$arch"
curl() {
    if [[ "$*" == *'/releases/latest'* ]]; then
        printf '{"assets":[{"name":"sing-box-1.14.4-linux-%s.tar.gz","browser_download_url":"https://example.com/core.tgz"}]}' "$arch"
    else
        local target
        while (( $# )); do if [ "$1" = -o ]; then target="$2"; shift; fi; shift; done
        cp "$ROOT/release.tgz" "$target"
    fi
}
systemctl() { [ "$1" != cat ]; }
install_singbox <<< y
jq -e '.format==4 and .nodes=={}' "$STATE_FILE"
jq -e '.inbounds==[]' "$CONFIG_FILE"
grep -F '# sb-v4-managed' "$SERVICE_FILE"
[ -x "$BIN_FILE" ]
''')

    def test_binary_replacement_is_atomic_and_executable(self):
        self.shell(r'''
printf old > "$ROOT/installed"
printf '#!/bin/sh\nprintf new' > "$ROOT/candidate"
install_binary "$ROOT/candidate" "$ROOT/installed"
[ "$("$ROOT/installed")" = new ]
[ "$(find "$ROOT" -name '*.new.*' | wc -l)" = 0 ]
''')

    def test_gcompat_loader_core_identity_requires_exact_arguments(self):
        self.shell(r'''
identity_script='source "$1"
BIN_FILE="$2"; CONFIG_FILE="$3"
readlink() {
  if [ "$1" = "/proc/$$/exe" ]; then printf /lib/ld-musl-x86_64.so.1
  elif [[ "$1" == /proc/*/exe ]]; then return 1
  else command readlink "$@"; fi
}
core_process_alive'
bash -c "$identity_script" test "$1" "$BIN_FILE" "$CONFIG_FILE" "$BIN_FILE" run -c "$CONFIG_FILE"
if bash -c "$identity_script" test "$1" "$BIN_FILE" "$CONFIG_FILE.bad" "$BIN_FILE" run -c "$CONFIG_FILE"; then exit 1; fi
''')

    def test_isolation_runner_guards_all_namespaces(self):
        launcher = (ROOT / 'tests/run-isolated-openrc.sh').read_text()
        for flag in ('--mount', '--pid', '--net', '--uts', '--ipc', '--kill-child=KILL'):
            self.assertIn(flag, launcher)
        result = __import__('subprocess').run(['bash', str(ROOT / 'tests/isolated-openrc.sh')], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Refusing non-isolated invocation', result.stderr)
