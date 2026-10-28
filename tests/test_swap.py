"""Swap management regression tests with fake kernel commands and temp-only paths.

No swapon/swapoff/mkswap command reaches the host.
"""
import pathlib
import re
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "singbox.sh"


class SwapTests(unittest.TestCase):
    def run_shell(self, body):
        source = SCRIPT.read_text()
        functions = re.findall(r"^(?:swap_\w+|menu_swap)\(\) \{\n.*?^\}", source, re.M | re.S)
        self.assertEqual(len(functions), 9)
        functions.append(re.search(r"^menu_tools\(\) \{\n.*?^\}", source, re.M | re.S).group())
        with tempfile.TemporaryDirectory(prefix="sb-swap-test-") as directory:
            prelude = r'''
set -e -o pipefail
ROOT="$1"
SB_SWAP_DIR="$ROOT/sb-swap"
SB_SWAP_FILE="$SB_SWAP_DIR/swapfile"
SB_SWAP_MARKER="$SB_SWAP_DIR/managed"
SB_SWAP_FSTAB="$ROOT/fstab"
SB_SWAP_PROC="$ROOT/swaps"
SB_SWAP_MEMINFO="$ROOT/meminfo"
CALLS="$ROOT/calls"
: > "$CALLS"
printf '/dev/root / ext4 defaults 0 1\n/swapfile none swap sw 0 0\n' > "$SB_SWAP_FSTAB"
printf 'Filename Type Size Used Priority\n/swapfile file 1024 0 -2\n' > "$SB_SWAP_PROC"
printf 'MemTotal: 1048576 kB\nMemAvailable: 524288 kB\nSwapTotal: 1024 kB\nSwapFree: 1024 kB\n' > "$SB_SWAP_MEMINFO"
stat() {
    if [ "$1" = -f ]; then printf '%s\n' "${FS:-ext2/ext3}"; else command stat "$@"; fi
}
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/test 99999999 1 %s 1%% /\n' "${DISK_FREE:-99999998}"; }
dd() {
    printf 'dd\n' >> "$CALLS"
    local arg target=''
    for arg in "$@"; do case "$arg" in of=*) target=${arg#of=} ;; esac; done
    [ "$target" = "$SB_SWAP_FILE" ] || return 99
    [ "${DD_FAIL:-0}" = 0 ] || return 1
    printf 'fake swap data' > "$target"
}
mkswap() { printf 'mkswap\n' >> "$CALLS"; [ "$1" = "$SB_SWAP_FILE" ] && [ "${MKSWAP_FAIL:-0}" = 0 ]; }
swapon() {
    printf 'swapon\n' >> "$CALLS"
    [ "$1" = "$SB_SWAP_FILE" ] && [ "${SWAPON_FAIL:-0}" = 0 ] || return 1
    printf '%s file 131072 %s -3\n' "$1" "${USED:-0}" >> "$SB_SWAP_PROC"
}
swapoff() {
    printf 'swapoff\n' >> "$CALLS"
    [ "$1" = "$SB_SWAP_FILE" ] && [ "${SWAPOFF_FAIL:-0}" = 0 ] || return 1
    awk -v path="$1" '$1 != path' "$SB_SWAP_PROC" > "$ROOT/swaps.tmp"
    command mv "$ROOT/swaps.tmp" "$SB_SWAP_PROC"
}
'''
            result = subprocess.run(["bash", "-c", prelude + "\n" + "\n".join(functions) + "\n" + body,
                                     "test", directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_create_delete_preserves_other_swap_and_fstab(self):
        self.run_shell(r'''
cp "$SB_SWAP_FSTAB" "$ROOT/original"
swap_create <<< $'128\n确认\n'
swap_owned && swap_active
[ "$(stat -c %a "$SB_SWAP_FILE")" = 600 ]
[ "$(stat -c %a "$SB_SWAP_DIR")" = 700 ]
[ "$(grep -Fc "$(swap_entry)" "$SB_SWAP_FSTAB")" = 1 ]
swap_status > "$ROOT/status"
grep -q '/swapfile' "$ROOT/status"
swap_delete <<< '确认'
[ ! -e "$SB_SWAP_DIR" ]
cmp "$SB_SWAP_FSTAB" "$ROOT/original"
grep -q '^/swapfile ' "$SB_SWAP_PROC"
[ "$(find "$ROOT" -name 'fstab.sb-swap.bak.*' | wc -l)" = 2 ]
''')

    def test_cancel_and_invalid_sizes_do_nothing(self):
        self.run_shell(r'''
for size in 0 127 65537 999999999999999999 0128 -1 '1;touch nope' abc; do
    if swap_create <<< "$size"; then exit 1; fi
done
swap_create <<< $'128\n否决\n'
[ ! -e "$SB_SWAP_DIR" ]
[ ! -s "$CALLS" ]
''')

    def test_no_takeover_or_symlinks(self):
        self.run_shell(r'''
mkdir "$SB_SWAP_DIR"
printf important > "$SB_SWAP_FILE"
if swap_create <<< $'128\n确认\n'; then exit 1; fi
if swap_delete <<< 确认; then exit 1; fi
[ "$(cat "$SB_SWAP_FILE")" = important ]
rm "$SB_SWAP_FILE"; rmdir "$SB_SWAP_DIR"
ln -s "$ROOT/missing" "$SB_SWAP_DIR"
if swap_create <<< $'128\n确认\n'; then exit 1; fi
[ ! -s "$CALLS" ]
''')

    def test_unsupported_filesystem_and_disk_space(self):
        self.run_shell(r'''
for FS in btrfs zfs tmpfs ramfs nfs overlayfs; do
    if swap_create <<< $'128\n确认\n'; then exit 1; fi
done
FS=ext2/ext3
DISK_FREE=100
if swap_create <<< $'128\n确认\n'; then exit 1; fi
[ ! -s "$CALLS" ]
''')

    def test_creation_failures_leave_fstab_untouched(self):
        self.run_shell(r'''
cp "$SB_SWAP_FSTAB" "$ROOT/original"
for failure in DD_FAIL MKSWAP_FAIL SWAPON_FAIL; do
    printf -v "$failure" 1
    if swap_create <<< $'128\n确认\n'; then exit 1; fi
    [ ! -e "$SB_SWAP_DIR" ]
    cmp "$SB_SWAP_FSTAB" "$ROOT/original"
    printf -v "$failure" 0
done
''')

    def test_swapoff_failure_never_deletes(self):
        self.run_shell(r'''
swap_create <<< $'128\n确认\n'
cp "$SB_SWAP_FSTAB" "$ROOT/before"
SWAPOFF_FAIL=1
if swap_delete <<< 确认; then exit 1; fi
swap_owned && swap_active
cmp "$SB_SWAP_FSTAB" "$ROOT/before"
''')

    def test_memory_precheck_and_cancel_preserve_active_swap(self):
        self.run_shell(r'''
USED=65536
swap_create <<< $'128\n确认\n'
printf 'MemAvailable: 65536 kB\n' > "$SB_SWAP_MEMINFO"
if swap_delete <<< 确认; then exit 1; fi
swap_owned && swap_active
! grep -q '^swapoff$' "$CALLS"
printf 'MemAvailable: 524288 kB\n' > "$SB_SWAP_MEMINFO"
swap_delete <<< 否决
swap_owned && swap_active
! grep -q '^swapoff$' "$CALLS"
''')

    def test_fstab_failure_rolls_back_creation(self):
        self.run_shell(r'''
cp "$SB_SWAP_FSTAB" "$ROOT/original"
mv() { return 1; }
if swap_create <<< $'128\n确认\n'; then exit 1; fi
[ ! -e "$SB_SWAP_DIR" ]
! swap_active
cmp "$SB_SWAP_FSTAB" "$ROOT/original"
''')

    def test_fstab_failure_and_swapoff_failure_keep_active_file(self):
        self.run_shell(r'''
mv() { return 1; }
SWAPOFF_FAIL=1
if swap_create <<< $'128\n确认\n'; then exit 1; fi
swap_owned && swap_active
! grep -q 'sb-managed-swap' "$SB_SWAP_FSTAB"
''')

    def test_fstab_failure_restores_swap_after_delete_attempt(self):
        self.run_shell(r'''
swap_create <<< $'128\n确认\n'
cp "$SB_SWAP_FSTAB" "$ROOT/before"
mv() { return 1; }
if swap_delete <<< 确认; then exit 1; fi
swap_owned && swap_active
cmp "$SB_SWAP_FSTAB" "$ROOT/before"
''')

    def test_foreign_or_symlink_fstab_refused(self):
        self.run_shell(r'''
printf '%s none swap defaults 0 0\n' "$SB_SWAP_FILE" >> "$SB_SWAP_FSTAB"
if swap_create <<< $'128\n确认\n'; then exit 1; fi
rm "$SB_SWAP_FSTAB"
ln -s "$ROOT/target" "$SB_SWAP_FSTAB"
printf data > "$ROOT/target"
if swap_create <<< $'128\n确认\n'; then exit 1; fi
[ "$(cat "$ROOT/target")" = data ]
[ ! -s "$CALLS" ]
''')

    def test_menu_route_and_missing_kernel_state(self):
        self.run_shell(r'''
menu_header() { printf '%s\n' "$1"; }
menu_option() { printf '%s %s\n' "$1" "$2"; }
menu_section() { :; }
menu_back() { :; }
read_menu_choice() { read -r REPLY; }
menu_tools <<< $'6\n0\n0\n' > "$ROOT/menu"
grep -q 'Swap 管理' "$ROOT/menu"
grep -q '添加 Swap' "$ROOT/menu"
[ ! -s "$CALLS" ]
rm "$SB_SWAP_PROC"
if swap_create <<< $'128\n确认\n'; then exit 1; fi
if swap_delete <<< 确认; then exit 1; fi
[ ! -s "$CALLS" ]
''')

    def test_swapoff_false_success_does_not_remove_file(self):
        self.run_shell(r'''
swap_create <<< $'128\n确认\n'
cp "$SB_SWAP_FSTAB" "$ROOT/before"
swapoff() { return 0; }
if swap_delete <<< 确认; then exit 1; fi
swap_owned && swap_active
cmp "$SB_SWAP_FSTAB" "$ROOT/before"
''')

    def test_delete_inactive_owned_swap(self):
        self.run_shell(r'''
swap_create <<< $'128\n确认\n'
swapoff "$SB_SWAP_FILE"
: > "$CALLS"
swap_delete <<< 确认
[ ! -e "$SB_SWAP_FILE" ]
[ ! -s "$CALLS" ]
''')


if __name__ == "__main__":
    unittest.main()
