"""Exit-IP display uses an isolated real core and never falls back to direct."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_warp import extract_funcs, SCRIPT


CORE = shutil.which('sing-box') or ('/usr/local/bin/sing-box' if Path('/usr/local/bin/sing-box').is_file() else None)


@unittest.skipUnless(CORE and shutil.which('jq'), 'core/jq required')
class ExitIPTests(unittest.TestCase):
    def test_v4_v6_display_and_cleanup(self):
        funcs = extract_funcs(SCRIPT.read_text(), ['probe_split_outbound'])
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            curl = root / 'curl'
            curl.write_text('''#!/bin/bash
[[ "$*" == *"--proxy socks5h://127.0.0.1:"* ]] || exit 70
[[ "$*" == *"--noproxy "* ]] || exit 71
case "${@: -1}" in
 https://api4.ipify.org) [[ "$MODE" != fail ]] || exit 22; echo 203.0.113.4 ;;
 https://api6.ipify.org) [[ "$MODE" == dual ]] || exit 22; echo 2001:db8::6 ;;
 *) exit 72 ;;
esac
''')
            curl.chmod(0o700)
            config = root / 'source.json'
            config.write_text('{"outbounds":[{"type":"socks","tag":"socks5","version":"5","server":"proxy.example","server_port":1080}]}')
            original = config.read_bytes()
            for mode in ('v4', 'dual', 'fail'):
                env = dict(os.environ, MODE=mode, TMPDIR=folder,
                           PATH=folder + ':' + os.environ['PATH'])
                result = subprocess.run(['bash', '-c', '''set -euo pipefail
CONFIG_FILE="$1"; BIN_FILE="$2"
''' + funcs + '\nprobe_split_outbound socks5 S5\n',
                                         'test', str(config), CORE],
                                        env=env, text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if mode == 'fail':
                    self.assertEqual(result.stdout, '')
                else:
                    self.assertIn('S5 IP: 203.0.113.4', result.stdout)
                    self.assertEqual(len(result.stdout.splitlines()), 1)
                if mode == 'dual':
                    self.assertIn('IPV6: 2001:db8::6', result.stdout)
                else:
                    self.assertNotIn('IPV6', result.stdout)
                self.assertEqual(config.read_bytes(), original)
                self.assertEqual(sorted(p.name for p in root.iterdir()), ['curl', 'source.json'])
