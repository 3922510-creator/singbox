"""Installer extraction tests: no package install, no writes outside the sandbox."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def shell(self, body):
        source = (ROOT / 'install.sh').read_text()
        functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S).group()
                              for name in ('install_deps', 'download_script', 'register_shortcut'))
        with tempfile.TemporaryDirectory(prefix='sb-installer-') as directory:
            script = r'''
set -e
ROOT="$1"; export TMPDIR="$ROOT"
INSTALL_PATH="$ROOT/sb"; ALIAS_PATH="$ROOT/SB"; REPO_RAW=https://example.com/singbox.sh
msg() { :; }; ok() { :; }; err() { printf '%s\n' "$*" >&2; }
detect_family() { printf debian; }
PAYLOAD=$'#!/usr/bin/env bash\nprintf ready\n'
curl() {
    local target
    while (( $# )); do if [ "$1" = -o ]; then target="$2"; shift; fi; shift; done
    printf '%s' "$PAYLOAD" > "$target"
    return "${CURL_RC:-0}"
}
'''
            result = subprocess.run(['bash', '-c', script + functions + '\n' + body, 'test', directory], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_valid_download_backs_up_old_panel_and_registers(self):
        self.shell(r'''
printf old > "$INSTALL_PATH"
download_script
register_shortcut
[ "$(readlink "$ALIAS_PATH")" = "$INSTALL_PATH" ]
[ "$(cat "$INSTALL_PATH".bak-*)" = old ]
bash -n "$INSTALL_PATH"
[ "$(stat -c %a "$INSTALL_PATH")" = 755 ]
''')

    def test_partial_and_invalid_download_never_overwrite(self):
        self.shell(r'''
printf old > "$INSTALL_PATH"
CURL_RC=22
if download_script; then exit 1; fi
CURL_RC=0; PAYLOAD=$'#!/bin/bash\nif then\n'
if download_script; then exit 1; fi
[ "$(cat "$INSTALL_PATH")" = old ]
[ "$(find "$ROOT" -name 'tmp.*' | wc -l)" = 0 ]
''')

    def test_missing_dependency_installs_no_firewall_or_optional_tools(self):
        self.shell(r'''
command() {
    if [ "$1 $2" = '-v jq' ] && [ ! -e "$ROOT/deps-ready" ]; then return 1; fi
    builtin command "$@"
}
apt-get() { printf '%s\n' "$*" >> "$ROOT/apt"; touch "$ROOT/deps-ready"; }
install_deps
if grep -E 'ufw|firewalld|qrencode' "$ROOT/apt"; then exit 1; fi
grep -F 'iproute2' "$ROOT/apt"
''')
