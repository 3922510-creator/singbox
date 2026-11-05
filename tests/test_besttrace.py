"""BestTrace entry tests: mock downloads, never execute remote code or install tools."""
import pathlib
import re
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "singbox.sh"


class BestTraceTests(unittest.TestCase):
    def run_shell(self, body):
        source = SCRIPT.read_text()
        functions = "\n".join(
            re.search(r"^" + name + r"\(\) \{\n.*?^\}", source, re.M | re.S).group()
            for name in ("besttrace_check", "menu_tools")
        )
        with tempfile.TemporaryDirectory(prefix="sb-besttrace-test-") as directory:
            prelude = r'''
set -e -o pipefail
ROOT="$1"
export TMPDIR="$ROOT"
export MARKER="$ROOT/executed"
PAYLOAD='printf "ran\n" > "$MARKER"'
curl() {
    printf '%s\n' "$@" > "$ROOT/curl-args"
    local target
    while (( $# )); do
        if [[ "$1" == -o ]]; then target="$2"; shift; fi
        shift
    done
    printf '%s' "$PAYLOAD" > "$target"
    return "${DOWNLOAD_RC:-0}"
}
assert_clean() {
    [[ -z "$(find "$ROOT" -maxdepth 1 -type d -name 'tmp.*' -print)" ]]
}
'''
            result = subprocess.run(
                ["bash", "-c", prelude + functions + "\n" + body, "test", directory],
                text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_cancel_and_eof_do_not_download(self):
        self.run_shell(r'''
for answer in n N 确认 yes ''; do
    besttrace_check <<< "$answer"
done
besttrace_check < /dev/null
[[ ! -e "$ROOT/curl-args" && ! -e "$MARKER" ]]
assert_clean
''')

    def test_success_and_child_isolation(self):
        self.run_shell(r'''
exec 200>"$ROOT/lock"
PAYLOAD='[[ ! -e /proc/$$/fd/200 ]] || exit 91
printf "ran\n" > "$MARKER"
exit 0'
besttrace_check <<< Y
[[ $(cat "$MARKER") == ran ]]
[[ -e /proc/$$/fd/200 ]]
grep -Fxq -- '--proto' "$ROOT/curl-args"
grep -Fxq -- '=https' "$ROOT/curl-args"
grep -Fxq -- '--max-time' "$ROOT/curl-args"
assert_clean
''')

    def test_failed_or_partial_download_not_executed(self):
        self.run_shell(r'''
DOWNLOAD_RC=22
rc=0
besttrace_check <<< y || rc=$?
[[ "$rc" == 1 && ! -e "$MARKER" ]]
assert_clean
''')

    def test_empty_or_invalid_payload_not_executed(self):
        self.run_shell(r'''
for PAYLOAD in '' '<html>error</html>' 'if then'; do
    rc=0
    besttrace_check <<< y || rc=$?
    [[ "$rc" == 1 && ! -e "$MARKER" ]]
    assert_clean
done
''')

    def test_upstream_exit_preserved_and_cleanup(self):
        output = self.run_shell(r'''
PAYLOAD='exit 17'
rc=0
besttrace_check <<< y || rc=$?
[[ "$rc" == 17 ]]
assert_clean
printf 'parent-alive\n'
''')
        self.assertIn("退出码 17", output)
        self.assertIn("parent-alive", output)

    def test_menu_entry_returns_after_failure(self):
        self.run_shell(r'''
menu_header() { :; }
menu_section() { :; }
menu_option() { printf '%s %s\n' "$@"; }
menu_back() { :; }
read_menu_choice() { read -r REPLY; }
besttrace_check() { printf 'route-called\n'; return 17; }
pause() { :; }
# 面板本身没有 errexit；第三方失败不应退出菜单。
set +e
menu_tools <<'INPUT'
7
0
INPUT
[[ "$REPLY" == 0 ]]
''')


if __name__ == "__main__":
    unittest.main()
