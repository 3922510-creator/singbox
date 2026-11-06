#!/usr/bin/env bash
# Run ONLY inside a disposable Alpine chroot with private mount/PID/network namespaces.
# /work/core.tar.gz and release.json must be a verified upstream release fixture.
set -e -o pipefail
[ "${SB_ISOLATED_OPENRC:-}" = yes ] && [ "$$" = 1 ] || { echo 'Refusing non-isolated invocation' >&2; exit 1; }
[ ! -e /run/systemd/private ] || exit 1
# PID isolation alone does not isolate hostname or IPC. Refuse before any service action.
for namespace in uts ipc net mnt pid; do
    variable="SB_HOST_${namespace^^}"
    expected="${!variable:-}"
    [ -n "$expected" ] && [ "$(readlink "/proc/self/ns/$namespace")" != "$expected" ] || {
        echo "Missing private $namespace namespace" >&2; exit 1;
    }
done
ip link set lo up
mkdir -p /run/openrc
printf default > /run/openrc/softlevel
printf 'auto lo\niface lo inet loopback\n' > /etc/network/interfaces
rc-service networking start
source /work/singbox.sh
platform_detect
[ "$INIT_SYS" = openrc ] && [ "$OS_FAMILY" = alpine ]
get_public_ip() { printf 127.0.0.1; }
# Download seam only; service manager, binary install, config and filesystem are real.
curl() {
    if [[ "$*" == *api.github.com/repos/SagerNet/sing-box/releases/latest* ]]; then cat /work/release.json
    elif [[ "$*" == *'/sing-box/releases/download/'* ]]; then
        local output asset=/work/core.tar.gz
        [[ "$*" != *-musl.tar.gz* ]] || asset=/work/core-musl.tar.gz
        while (( $# )); do if [ "$1" = -o ]; then output="$2"; shift; fi; shift; done
        cp "$asset" "$output"
    elif [[ "$*" == *cloudflare/cloudflared/releases/latest/download/* ]]; then
        local output
        while (( $# )); do if [ "$1" = -o ]; then output="$2"; shift; fi; shift; done
        cp /work/cloudflared "$output"
    else command curl "$@"; fi
}
if ! install_singbox <<< y; then
    rc-service sing-box status || true
    tail -30 "$SINGBOX_LOG" || true
    for proc in /proc/[0-9]*; do
        printf '%s exe=%s args=' "$proc" "$(readlink "$proc/exe" 2>/dev/null || true)"
        tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true
        printf '\n'
    done
    exit 1
fi
svc_active
rc-update show default | grep sing-box
add_direct_node vless <<< $'30001\nexample.com\nVLESS sandbox\ny\nn\n'
add_direct_node anytls <<< $'30002\nexample.com\nAnyTLS sandbox\ny\nn\n'
add_port_forward <<< $'30003\n127.0.0.1\n30004\ny\nn\n'
svc_active
jq -e '(.inbounds | length) == 3' "$CONFIG_FILE"
# Restart, stopped-service apply, then actual supervisor crash recovery.
service_action stop <<< y
! svc_active
service_action start <<< y
svc_active
old_pid=''
for proc in /proc/[0-9]*; do
    [ "$(readlink "$proc/exe" 2>/dev/null || true)" = "$BIN_FILE" ] || continue
    old_pid=${proc##*/}; break
done
[ -n "$old_pid" ] && [ "$old_pid" != 1 ]
kill -KILL "$old_pid"
recovered=0
for ((i=0; i<20; i++)); do if svc_active; then recovered=1; break; fi; sleep 1; done
[ "$recovered" = 1 ]
[ ! -e "/proc/$old_pid" ]
# A new panel must be able to lock while the service continues running.
if ( exec 200>&-; flock -n "$LOCK_FILE" true ); then echo 'parent lock unexpectedly absent' >&2; exit 1; fi
exec 200>&-
# Consumed by the sourced panel's lock implementation.
# shellcheck disable=SC2034
SB_LOCKED=0
acquire_lock
# Reserved port occupied by an unrelated process must be rejected.
port_in_use 30001
# Core runtime failure must restore the previous config/state and restart a good service.
before=$(sha256sum "$CONFIG_FILE" "$STATE_FILE")
config=$(jq '.outbounds += [{type:"direct",tag:"bad"}] | .inbounds += [{type:"direct",tag:"conflict",listen:"127.0.0.1",listen_port:30001,override_address:"127.0.0.1",override_port:30004}]' "$CONFIG_FILE")
if apply_config "$config" "$(cat "$STATE_FILE")" 'forced port conflict' <<< y; then echo 'port conflict falsely succeeded' >&2; exit 1; fi
[ "$before" = "$(sha256sum "$CONFIG_FILE" "$STATE_FILE")" ]
svc_active
source /work/isolated-argo.sh
# Actual script entry/menu navigation, no host tty inside this namespace.
printf '2\n0\n3\n0\n4\n0\n5\n0\n0\n' | bash /work/singbox.sh > /work/menu.log
svc_stop
# The glibc/gcompat path is still identified correctly if a user selects such an ELF.
install_binary /work/official-core "$BIN_FILE"
svc_start
sleep 1
svc_active
svc_stop
uninstall_singbox <<< y
[ ! -e "$BIN_FILE" ] && [ -f "$STATE_FILE" ] && [ -f "$CONFIG_FILE" ]
install_singbox <<< y
svc_active
svc_stop
printf '\nISOLATED OPENRC: PASS\n'
