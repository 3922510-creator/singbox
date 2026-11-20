"""Regression tests for v3.8.0 menu layout, navigation, pause, and EOF handling."""
import pathlib
import re
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "singbox.sh"


def extract_funcs(source, names):
    blocks = []
    for name in names:
        m = re.search(r"^" + re.escape(name) + r"\(\) [\{\(]\n.*?^[\}\)]", source, re.M | re.S)
        if not m:
            line = next((l for l in source.splitlines() if l.startswith(name + "()")), None)
            if not line:
                raise AssertionError(f"function {name} not found")
            blocks.append(line)
        else:
            blocks.append(m.group())
    return "\n\n".join(blocks)


class MenuUXTests(unittest.TestCase):
    def run_ui(self, names, body):
        source = SCRIPT.read_text(encoding="utf-8")
        funcs = extract_funcs(source, names)
        with tempfile.TemporaryDirectory(prefix="sb-ui-") as root:
            prelude = r'''
set -eo pipefail
ROOT="$1"
COLUMNS=44
SCRIPT_VERSION="v3.8.0"
BBR3_REPO="XDflight/bbr3-debs"
WARP_AI_RULE_TAG="geosite-ai"
WARP_MEDIA_RULE_TAG="geosite-stream"
RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; PLAIN=""; BOLD=""; DIM=""
CONFIG_FILE="$ROOT/config.json"
META_DIR="$ROOT/.meta"
REALITY_META="$META_DIR/reality.txt"
NODE_NAMES_META="$META_DIR/node-names.json"
BIN_FILE="$ROOT/sing-box"
mkdir -p "$META_DIR"
printf '{"inbounds":[{"type":"vless","tag":"vless-reality-443","listen_port":443},{"type":"direct","tag":"forward-80-to-80","listen_port":80,"override_address":"1.1.1.1","override_port":80}],"endpoints":[],"route":{"rules":[]}}\n' > "$CONFIG_FILE"
clear() { :; }
sleep() { :; }
get_singbox_status() { printf '运行中 [v1.14.3]'; }
'''
            res = subprocess.run(
                ["bash", "-c", prelude + "\n" + funcs + "\n" + body, "test", root],
                capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            return res.stdout

    def test_main_menu_structure_summary_and_eof_exit(self):
        out = self.run_ui(
            [
                "ui_width", "ui_rule", "menu_header", "menu_section", "menu_option",
                "menu_exit", "read_menu_choice", "menu_invalid",
                "inbound_count", "inbound_field", "count_by_type", "ss2022_count",
                "has_warp_endpoint", "nodes_total_count", "home_status_line", "show_menu",
            ],
            r'''
# 空回车直接刷新（不报无效选项），0 正常退出，EOF 不死循环
show_menu <<< ''
show_menu <<< '0'
show_menu < /dev/null
''',
        )
        self.assertIn("运行中 [v1.14.3] · 节点 1 · 转发 1 · WARP关", out)
        self.assertIn("代理与分流", out)
        self.assertIn("核心与配置", out)
        self.assertIn("网络与系统", out)
        self.assertIn("网络加速", out)
        self.assertIn("防火墙管理", out)
        self.assertNotIn("无效选项", out)

    def test_bbr_submenu_back_has_no_extra_pause_and_eof_exits(self):
        out = self.run_ui(
            [
                "ui_width", "ui_rule", "menu_header", "menu_section", "menu_option",
                "menu_back", "read_menu_choice", "menu_invalid",
                "menu_bbr", "menu_tcp_buf",
            ],
            r'''
PAUSE_COUNT=0
pause() { PAUSE_COUNT=$((PAUSE_COUNT + 1)); }
sysctl() { echo bbr; }
bbr_kernel_desc() { echo BBRv3; }
bbr_status_short() { :; }
tcp_buf_status() { :; }
tcp_buf_recommend_mb() { echo 8; }
# 进 TCP 调优(6) -> 空回车刷新 -> 0 返回 BBR -> 0 返回上级：全程 0 次 pause
menu_bbr <<< $'6\n\n0\n0\n'
[[ "$PAUSE_COUNT" -eq 0 ]]
# EOF 直接返回，不死循环
menu_bbr < /dev/null
printf 'OK pause=%s\n' "$PAUSE_COUNT"
''',
        )
        self.assertIn("OK pause=0", out)

    def test_nodes_and_warp_layouts_and_confirm_cancel(self):
        out = self.run_ui(
            [
                "ui_width", "ui_rule", "menu_header", "menu_section", "menu_option",
                "menu_back", "read_menu_choice", "menu_invalid",
                "inbound_count", "inbound_field", "count_by_type", "ss2022_count",
                "nodes_summary_line", "menu_nodes",
                "has_warp_endpoint", "has_warp_ruleset", "warp_summary_short", "menu_warp",
            ],
            r'''
PAUSE_COUNT=0
pause() { PAUSE_COUNT=$((PAUSE_COUNT + 1)); }
# 节点管理顶栏含摘要，日常操作在添加节点前；空回车不触发 pause
menu_nodes <<< $'\n0\n'
[[ "$PAUSE_COUNT" -eq 0 ]]
# WARP 删除无出口时提示并 pause 一次；空回车不 pause；EOF 正常退出
menu_warp <<< $'\n0\n'
[[ "$PAUSE_COUNT" -eq 0 ]]
menu_warp < /dev/null
''',
        )
        self.assertIn("共 1 个（VLESS 1 · AnyTLS 0 · SS2022 0）", out)
        self.assertLess(out.index("日常操作"), out.index("添加节点"))
        self.assertLess(out.index("分流规则"), out.index("出口管理"))
        self.assertIn("添加 WARP 出口（免费自动注册）", out)

    def test_narrow_terminal_no_overwide_fixed_dashes(self):
        source = SCRIPT.read_text(encoding="utf-8")
        code_lines = [l for l in source.splitlines() if not l.lstrip().startswith("#")]
        code = "\n".join(code_lines)
        self.assertNotIn("====================================================", code)
        self.assertNotIn("--------------------------------------------------", code)


if __name__ == "__main__":
    unittest.main()
