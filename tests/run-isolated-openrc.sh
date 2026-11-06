#!/usr/bin/env bash
# An already prepared disposable Alpine root is required; NEVER accepts / or /etc.
set -e -o pipefail
root=$(readlink -f "${1:?Usage: $0 /var/tmp/sb-v4-isolated.XXXXXX/root}")
[[ "$root" =~ ^/var/tmp/sb-v4-isolated\.[a-zA-Z0-9]+/root$ ]] && [ -f "$root/work/release.json" ] && [ -f "$root/work/core.tar.gz" ] || exit 1
[ "$EUID" = 0 ] || exit 1
for fixture in core-musl.tar.gz official-core cloudflared; do
    [ -f "$root/work/$fixture" ] || { echo "Missing fixture: $fixture" >&2; exit 1; }
done
for namespace in uts ipc net mnt pid; do
    printf -v "SB_HOST_${namespace^^}" '%s' "$(readlink "/proc/self/ns/$namespace")"
    export "SB_HOST_${namespace^^}"
done
repo=$(cd "$(dirname "$0")/.." && pwd)
cp "$repo/singbox.sh" "$repo/tests/isolated-openrc.sh" "$repo/tests/isolated-argo.sh" "$root/work/"
# Private mount/PID/network/UTS/IPC; no host systemd socket or host /dev bind.
exec timeout --signal=TERM --kill-after=5 150 unshare --mount --pid --net --uts --ipc --fork --kill-child=KILL --mount-proc bash -c '
    set -e
    mount --make-rprivate /
    mount --bind /proc/sys /proc/sys
    mount -o remount,bind,ro /proc/sys
    mount --bind /proc "$1/proc"
    exec chroot "$1" /usr/bin/env SB_ISOLATED_OPENRC=yes /bin/bash /work/isolated-openrc.sh
' test "$root"
