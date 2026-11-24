"""双栈 BestTrace：模拟跳点/安装器，不运行远程代码或安装软件。"""
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
            for name in ("besttrace_analyze_route", "besttrace_print_summary",
                         "besttrace_install", "besttrace_check", "menu_tools")
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
nexttrace() {
    [[ ! -e /proc/$BASHPID/fd/200 ]] || return 91
    printf '%s\n' "$*" >> "$ROOT/traces"
    printf '%s\n' "${TRACE:-1  2001:db8::1 AS4837 China}"
    return "${TRACE_RC:-0}"
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

    def test_cancel_invalid_and_eof(self):
        self.run_shell(r'''
for input in 0 '' 9 $'2\n0' $'1\n0' $'2\n6\n--help' $'2\n6\n1.1.1.1' $'1\n6\n2001:db8::1'; do
    besttrace_check <<< "$input" || :
done
besttrace_check < /dev/null
[[ ! -e "$ROOT/traces" && ! -e "$ROOT/curl-args" ]]
assert_clean
''')

    def test_both_families_summary_and_lock_isolation(self):
        output = self.run_shell(r'''
exec 200>"$ROOT/lock"
besttrace_check <<< $'1\n1'
[[ $(wc -l < "$ROOT/traces") == 13 ]]
grep -Fxq -- '-4 219.141.147.210 -q 1 -M' "$ROOT/traces"
besttrace_check <<< $'2\n1'
[[ $(wc -l < "$ROOT/traces") == 17 ]]
grep -Fxq -- '-6 240e:4c:4008::1 -q 1 -M' "$ROOT/traces"
grep -Fxq -- '-6 2408:8899::8 -q 1 -M' "$ROOT/traces"
grep -Fxq -- '-6 2409:8088::a -q 1 -M' "$ROOT/traces"
grep -Fxq -- '-6 2001:da8::666 -q 1 -M' "$ROOT/traces"
[[ -e /proc/$$/fd/200 && ! -e "$ROOT/curl-args" ]]
assert_clean
''')
        self.assertIn("IPv4 线路汇总", output)
        self.assertIn("IPv6 线路汇总", output)
        self.assertIn("电信 / 240e:4c:4008::1 / 联通 4837", output)

    def test_operator_filters_and_custom(self):
        self.run_shell(r'''
for family in 1 2; do
    for selection in 2 3 4 5; do
        : > "$ROOT/traces"
        besttrace_check <<< "$family"$'\n'"$selection"
        count=$(wc -l < "$ROOT/traces")
        if [[ "$family" == 1 && "$selection" != 5 ]]; then
            [[ "$count" == 4 ]]
        else
            [[ "$count" == 1 ]]
        fi
    done
done
besttrace_check <<< $'2\n6\n2001:db8::1'
besttrace_check <<< $'1\n6\n192.0.2.1'
grep -Fxq -- '-6 2001:db8::1 -q 1 -M' "$ROOT/traces"
grep -Fxq -- '-4 192.0.2.1 -q 1 -M' "$ROOT/traces"
assert_clean
''')

    def test_asn_classification_and_boundaries(self):
        self.run_shell(r'''
for pair in '4809:CN2' '9929:9929' '10099:A 网' '58807:CMIN2' '4837:4837' '58453:CMI' '9808:移动骨干' '4134:163 骨干' '4538:CERNET' '23910:CERNET'; do
    asn=${pair%%:*}; expected=${pair#*:}
    result=$(besttrace_analyze_route "1  2001:db8::1 AS$asn China" 6 0)
    [[ "$result" == *"$expected"* ]]
done
result=$(besttrace_analyze_route '1  2001:db8::1 AS48090 China' 6 0)
[[ "$result" == '未识别（ASN 信息不足）' ]]
result=$(besttrace_analyze_route $'API AS4809\n1  *\n2  *' 6 0)
[[ "$result" == '未识别（ASN 信息不足）' ]]
result=$(besttrace_analyze_route $'\e[32m1  2001:db8::1 AS58807 China\e[0m' 6 0)
[[ "$result" == *CMIN2* ]]
''')

    def test_no_false_gia_gt_or_default_carrier(self):
        self.run_shell(r'''
result=$(besttrace_analyze_route '1  240e::1 AS4809 China' 6 0)
[[ "$result" == '电信 CN2（AS4809；GIA/GT 未判定）' ]]
result=$(besttrace_analyze_route '1  59.43.1.1 AS4809 China Shanghai' 4 0)
[[ "$result" == *'CN2 GIA 特征'* ]]
result=$(besttrace_analyze_route '1  59.43.1.1 AS4809 China Hong Kong' 4 0)
[[ "$result" == *'GIA/GT 未判定'* ]]
result=$(besttrace_analyze_route '1  *' 4 0)
[[ "$result" == '未识别（ASN 信息不足）' ]]
''')

    def test_failure_retains_summary_and_continues(self):
        output = self.run_shell(r'''
TRACE_RC=9
rc=0
besttrace_check <<< $'2\n1' || rc=$?
[[ "$rc" == 1 && $(wc -l < "$ROOT/traces") == 4 ]]
assert_clean
''')
        self.assertIn("IPv6 线路汇总", output)
        self.assertIn("探测失败（退出码 9）", output)

    def test_interrupt_stops_remaining_targets(self):
        self.run_shell(r'''
TRACE_RC=130
rc=0
besttrace_check <<< $'2\n1' || rc=$?
[[ "$rc" == 130 && $(wc -l < "$ROOT/traces") == 1 ]]
assert_clean
''')

    def test_install_cancel_failure_and_cleanup(self):
        self.run_shell(r'''
command() {
    if [[ "$*" == '-v nexttrace' ]]; then
        [[ -e "$MARKER" ]]
    else
        builtin command "$@"
    fi
}
for answer in n N yes ''; do
    rc=0
    besttrace_install <<< "$answer" || rc=$?
    [[ "$rc" == 2 ]]
done
[[ ! -e "$ROOT/curl-args" ]]
DOWNLOAD_RC=22
rc=0
besttrace_install <<< y || rc=$?
[[ "$rc" == 1 && ! -e "$MARKER" ]]
DOWNLOAD_RC=0
for PAYLOAD in '' '<html>error</html>' 'if then'; do
    rc=0
    besttrace_install <<< y || rc=$?
    [[ "$rc" == 1 && ! -e "$MARKER" ]]
done
PAYLOAD='[[ ! -e /proc/$$/fd/200 ]] || exit 91; printf "ran\n" > "$MARKER"'
exec 200>"$ROOT/lock"
besttrace_install <<< Y
[[ $(cat "$MARKER") == ran && -e /proc/$$/fd/200 ]]
grep -Fxq -- '--proto' "$ROOT/curl-args"
grep -Fxq -- '=https' "$ROOT/curl-args"
assert_clean
''')

    def test_menu_entry_returns_after_failure(self):
        self.run_shell(r'''
menu_header() { :; }
menu_section() { :; }
menu_option() { :; }
menu_back() { :; }
read_menu_choice() { read -r REPLY; }
besttrace_check() { return 17; }
pause() { :; }
set +e
menu_tools <<'INPUT'
3
0
INPUT
[[ "$REPLY" == 0 ]]
''')


if __name__ == "__main__":
    unittest.main()
