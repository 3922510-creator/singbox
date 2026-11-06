#!/usr/bin/env python3
"""Boot a disposable systemd manager, NEVER the host bus or host service units.

Requires root, Linux namespaces/cgroup v2 and a prepared release fixture directory
under /var/tmp/sb-v4-isolated.*. All source binaries are read-only bind mounts;
only the unique test cgroup is writable inside the cgroup namespace. No host units
are registered. The unshare wrapper kills only its own PID-namespace child on exit.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import time
import uuid

REPO = Path(__file__).resolve().parents[1]


def main():
    fixtures = Path(sys.argv[1]).resolve()
    if os.geteuid() != 0 or fixtures.parent != Path('/var/tmp') or not fixtures.name.startswith('sb-v4-isolated.'):
        raise SystemExit('Refusing non-disposable path / non-root invocation')
    for name in ('core.tar.gz', 'release.json', 'cloudflared'):
        if not (fixtures / name).is_file():
            raise SystemExit('Missing verified upstream release fixture: ' + name)
    root = fixtures / ('systemd-' + uuid.uuid4().hex[:8])
    group = Path('/sys/fs/cgroup') / ('sb-v4-isolated-' + uuid.uuid4().hex)
    namespaces = {f'SB_HOST_{name.upper()}': os.readlink(f'/proc/self/ns/{name}') for name in ('uts', 'ipc', 'net', 'mnt', 'pid')}
    root.mkdir(mode=0o700)
    group.mkdir()  # Unique empty test group; never change any parent controller settings.
    process = None
    try:
        for directory in ('usr', 'usr-local/bin', 'etc/systemd/system', 'var/log', 'run', 'tmp', 'proc', 'sys/fs/cgroup', 'dev', 'work', 'root', 'home'):
            (root / directory).mkdir(parents=True, exist_ok=True)
        for name in ('bin', 'sbin', 'lib', 'lib64'):
            source = Path('/') / name
            if not source.is_symlink():
                raise RuntimeError('This harness expects a merged-/usr host')
            (root / name).symlink_to(os.readlink(source))
        for name, minor in (('null', 3), ('zero', 5), ('random', 8), ('urandom', 9)):
            os.mknod(root / 'dev' / name, 0o020666, os.makedev(1, minor))
        shutil.copyfile('/etc/os-release', root / 'etc/os-release')
        (root / 'etc/alternatives').mkdir()
        (root / 'etc/alternatives/awk').symlink_to(os.readlink('/etc/alternatives/awk'))
        (root / 'etc/passwd').write_text('root:x:0:0:root:/root:/bin/bash\n')
        (root / 'etc/group').write_text('root:x:0:\n')
        (root / 'etc/machine-id').write_text(uuid.uuid4().hex + '\n')
        (root / 'etc/hostname').write_text('sb-v4-isolated\n')
        (root / 'etc/hosts').write_text('127.0.0.1 localhost\n')
        (root / 'etc/nsswitch.conf').write_text('hosts: files dns\n')
        for name in ('core.tar.gz', 'release.json'):
            shutil.copyfile(fixtures / name, root / 'work' / name)
        shutil.copyfile(REPO / 'singbox.sh', root / 'work/singbox.sh')
        shutil.copyfile(REPO / 'tests/isolated-systemd.sh', root / 'work/test.sh')
        shutil.copyfile(REPO / 'tests/isolated-argo.sh', root / 'work/isolated-argo.sh')
        shutil.copyfile(fixtures / 'cloudflared', root / 'work/cloudflared')
        (root / 'work/cloudflared').chmod(0o755)
        units = root / 'etc/systemd/system'
        # Never boot host sysinit services (sysctl, modules, mounts, SSH, etc.).
        for name in ('sysinit', 'basic', 'network-online', 'network', 'multi-user', 'sockets'):
            (units / f'{name}.target').write_text('[Unit]\nDescription=Empty isolated test target\nDefaultDependencies=no\n')
        (units / 'sb-test.target').write_text('[Unit]\nDefaultDependencies=no\nWants=sb-test.service\n')
        environment = '\n'.join(f'Environment="{key}={value}"' for key, value in namespaces.items())
        (units / 'sb-test.service').write_text('[Unit]\nDefaultDependencies=no\n[Service]\nType=oneshot\nExecStart=/bin/bash /work/test.sh\nEnvironment=SB_ISOLATED_SYSTEMD=yes\n' + environment + '\nStandardOutput=append:/work/test.log\nStandardError=append:/work/test.log\n')
        dropin = units / 'sing-box.service.d'
        dropin.mkdir()
        (dropin / 'test-logging.conf').write_text('[Service]\nStandardOutput=append:/work/core.log\nStandardError=append:/work/core.log\n')
        cf_dropin = units / 'sb-argo-11111111-1111-4111-8111-111111111111.service.d'
        cf_dropin.mkdir()
        (cf_dropin / 'test-logging.conf').write_text('[Service]\nStandardOutput=append:/work/cloudflared.log\nStandardError=append:/work/cloudflared.log\n')
        script = r'''
set -e
[ "$$" = 1 ] || exit 1
[ "$(readlink /proc/self/ns/uts)" != "$SB_HOST_UTS" ] || exit 1
mount --make-rprivate /
# "1" is resolved in this private PID namespace: only this just-created child moves.
printf '1\n' > "$2/cgroup.procs"
exec unshare --cgroup bash -c '
    set -e
    root="$1"
    mount --bind "$root" "$root"
    mount --bind /usr "$root/usr"
    mount -o remount,bind,ro "$root/usr"
    mount --bind "$root/usr-local" "$root/usr/local"
    mount --bind /proc/sys /proc/sys
    mount -o remount,bind,ro /proc/sys
    mount --bind /proc "$root/proc"
    mount -t sysfs -o ro,nosuid,nodev,noexec sysfs "$root/sys"
    mount -t cgroup2 none "$root/sys/fs/cgroup"
    mount -t tmpfs -o mode=755,nosuid tmpfs "$root/dev"
    for spec in "null 1 3" "zero 1 5" "random 1 8" "urandom 1 9"; do
        read -r name major minor <<< "$spec"
        mknod -m 666 "$root/dev/$name" c "$major" "$minor"
    done
    touch "$root/work/console-device.log"
    ln -s /work/console-device.log "$root/dev/console"
    ip link set lo up
    exec chroot "$root" /usr/bin/env container=systemd-nspawn SYSTEMD_GENERATOR_PATH=/dev/null SYSTEMD_LOG_LEVEL=warning /lib/systemd/systemd --system --unit=sb-test.target --log-target=console
' test "$1"
'''
        with (root / 'console.log').open('w') as console:
            process = subprocess.Popen(['unshare', '--mount', '--pid', '--net', '--uts', '--ipc', '--fork', '--kill-child=KILL', '--mount-proc', 'bash', '-c', script, 'test', str(root), str(group)], stdout=console, stderr=subprocess.STDOUT, env={**os.environ, **namespaces}, start_new_session=True)
            deadline = time.monotonic() + 150
            while time.monotonic() < deadline and process.poll() is None and not (root / 'work/result').exists():
                time.sleep(0.25)
            result = (root / 'work/result').read_text().strip() if (root / 'work/result').exists() else 'missing'
            print('ISOLATED SYSTEMD ROOT:', root, 'wrapper status:', process.poll())
            for name in ('console.log', 'work/console-device.log', 'work/test.log', 'work/core.log', 'work/cloudflared.log'):
                path = root / name
                if path.exists():
                    print('\n---', name, '---\n', '\n'.join(path.read_text(errors='replace').splitlines()[-45:]))
            if result != '0':
                raise RuntimeError('Isolated systemd tests failed: ' + result)
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()  # Only the Popen unshare wrapper; --kill-child kills its namespace child.
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        # Kernel cgroup files cannot be unlinked; remove only empty directories in OUR unique group.
        for attempt in range(40):
            try:
                for path in sorted(group.rglob('*'), key=lambda p: len(p.parts), reverse=True):
                    if path.is_dir():
                        path.rmdir()
                group.rmdir()
                break
            except OSError:
                if attempt == 39:
                    raise
                time.sleep(0.1)
    print('ISOLATED SYSTEMD: PASS')


if __name__ == '__main__':
    main()
