#!/usr/bin/env bash
# Only the private systemd container launched by run-isolated-systemd.py may run this.
set -e -o pipefail
[ "${SB_ISOLATED_SYSTEMD:-}" = yes ] && [ "$(cat /proc/1/comm)" = systemd ] || exit 1
for namespace in uts ipc net mnt pid; do
    variable="SB_HOST_${namespace^^}"; expected="${!variable:-}"
    [ -n "$expected" ] && [ "$(readlink "/proc/self/ns/$namespace")" != "$expected" ] || exit 1
done
write_result() { printf '%s\n' "$?" > /work/result; }
trap write_result EXIT
source /work/singbox.sh
platform_detect
[ "$INIT_SYS" = systemd ]
get_public_ip() { printf 127.0.0.1; }
curl() {
    if [[ "$*" == *api.github.com/repos/SagerNet/sing-box/releases/latest* ]]; then cat /work/release.json
    elif [[ "$*" == *'/sing-box/releases/download/'* ]]; then
        local output
        while (( $# )); do if [ "$1" = -o ]; then output="$2"; shift; fi; shift; done
        cp /work/core.tar.gz "$output"
    elif [[ "$*" == *cloudflare/cloudflared/releases/latest/download/* ]]; then
        local output
        while (( $# )); do if [ "$1" = -o ]; then output="$2"; shift; fi; shift; done
        cp /work/cloudflared "$output"
    else command curl "$@"; fi
}
install_singbox <<< y
systemctl is-enabled sing-box
svc_active
add_direct_node vless <<< $'31001\nexample.com\nVLESS systemd\ny\nn\n'
add_direct_node anytls <<< $'31002\nexample.com\nAnyTLS systemd\ny\nn\n'
add_port_forward <<< $'31003\n127.0.0.1\n31004\ny\nn\n'
# Exercise the actual enabled target dependency, not only the is-enabled flag.
service_action stop <<< y
systemctl start multi-user.target
sleep 1
svc_active
old_pid=$(systemctl show sing-box -p MainPID --value)
[ "$old_pid" -gt 1 ] && [ "$(readlink "/proc/$old_pid/exe")" = "$BIN_FILE" ]
kill -KILL "$old_pid"
recovered=0
for ((i=0; i<20; i++)); do
    new_pid=$(systemctl show sing-box -p MainPID --value)
    if [ "$new_pid" -gt 1 ] && [ "$new_pid" != "$old_pid" ] && svc_active; then recovered=1; break; fi
    sleep 1
done
[ "$recovered" = 1 ]
before=$(sha256sum "$CONFIG_FILE" "$STATE_FILE")
config=$(jq '.inbounds += [{type:"direct",tag:"conflict",listen:"127.0.0.1",listen_port:31001,override_address:"127.0.0.1",override_port:31004}]' "$CONFIG_FILE")
if apply_config "$config" "$(cat "$STATE_FILE")" 'forced port conflict' <<< y; then exit 1; fi
[ "$before" = "$(sha256sum "$CONFIG_FILE" "$STATE_FILE")" ]
svc_active
# Shared lock must not be retained by core service after panel descriptor closes.
exec 200>&-
# Consumed by the sourced panel's lock implementation.
# shellcheck disable=SC2034
SB_LOCKED=0
acquire_lock
source /work/isolated-argo.sh
printf '1\n0\n2\n0\n4\n0\n5\n0\n6\n0\n7\n0\n0\n' | bash /work/singbox.sh > /work/menu.log
uninstall_singbox <<< y
[ ! -e "$BIN_FILE" ] && [ -f "$STATE_FILE" ] && [ -f "$CONFIG_FILE" ]
install_singbox <<< y
svc_active
svc_stop
printf '\nISOLATED SYSTEMD: PASS\n'
