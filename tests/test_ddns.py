"""Offline tests for the sh implementation; never touch host services or real DNS."""
import json
import os
import pty
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'ddns.sh'


class DDNSTests(unittest.TestCase):
    def shell(self, body, expected=0):
        env = dict(os.environ, DDNS_TEST_SOURCE='1')
        if 'menu' in body:
            body = "show_status() { printf '  首页模拟状态\\n'; }; " + body
        result = subprocess.run(['sh', '-c', '. "$1"; ' + body, 'test', str(SCRIPT)],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout

    def test_public_ip(self):
        self.assertEqual(self.shell('public_ip 8.8.8.8').strip(), '8.8.8.8')
        for ip in ['127.0.0.1', '10.0.0.1', '100.64.0.1', '192.168.1.1',
                   '172.16.0.1', '169.254.1.1', '192.0.2.1', '198.51.100.1',
                   '203.0.113.1', '224.0.0.1', '0.0.0.0', '256.1.1.1', '::1', 'html']:
            with self.subTest(ip=ip):
                self.shell('public_ip ' + ip, expected=1)

    def test_domain(self):
        self.shell('valid_domain nat.example.com')
        for value in ['https://example.com', '*.example.com', '-a.example.com', 'example.com:22']:
            self.shell('valid_domain ' + "'" + value + "'", expected=1)

    def test_three_interfaces_agree(self):
        output = self.shell('''ip() { exit 9; }
fetch() {
  case "$*" in '-4 --noproxy * -A curl/ddns https://api.ip.sb/ip'|'-4 --noproxy * -A curl/ddns https://api4.ipify.org'|'-4 --noproxy * -A curl/ddns https://ipv4.icanhazip.com') echo 8.8.8.8 ;; *) exit 9 ;; esac
}
get_ip''')
        self.assertEqual(output.strip(), '8.8.8.8')
        self.assertEqual(len(self.shell('ip_endpoints').splitlines()), 3)

    def test_each_interface_failure_and_mismatch_preserves_dns(self):
        for url in ['https://api.ip.sb/ip', 'https://api4.ipify.org', 'https://ipv4.icanhazip.com']:
            for result in ['return 1', 'echo 1.1.1.1', 'echo 10.0.0.1', 'echo html']:
                with self.subTest(url=url, result=result):
                    self.shell('''fetch() { case "$*" in *"%s") %s ;; *) echo 8.8.8.8 ;; esac; }
api() { exit 9; }
update''' % (url, result), expected=1)

    def test_menu_continues_after_error(self):
        output = self.shell('''id() { echo 0; }
get_ip() { fail 'mock query failed'; }
printf '2\\n\\n0\\n' | menu''')
        self.assertEqual(output.count('Cloudflare DDNS'), 2)
        self.assertIn('接口校验失败', output)

    def test_menu_rejects_manual_update(self):
        self.shell('''id() { echo 0; }
update() { exit 9; }
printf '3\\nn\\n\\n0\\n' | menu''')

    def test_menu_compact_order_and_no_escapes_in_pipe(self):
        output = self.shell("id() { echo 0; }; printf '0\\n' | menu")
        self.assertNotIn('\x1b', output)
        self.assertIn('    1) 刷新首页状态\n    2) 公网 IP 交叉校验\n    3) 立即更新 DNS\n    4) 查看查询接口', output)
        self.assertLess(output.index('首页模拟状态'), output.index('1) 刷新首页状态'))
        self.assertLessEqual(len(output.splitlines()), 24)
        self.assertEqual(output.count('Cloudflare DDNS'), 1)

    def test_status_translated(self):
        output = self.shell('''load_config() { record=nat.example.com; source_mode=egress; zone_id=abc; }
detect_init() { init=systemd; }
systemctl() { case "$*" in *--quiet*) return 0 ;; *) exit 9 ;; esac; }
api() { echo '{"result":[{"type":"A","content":"8.8.8.8","proxied":false}]}'; }
show_status''')
        for label in ['三接口全部一致', '已开启', '运行中', '仅 DNS（灰云）', '8.8.8.8']:
            self.assertIn(label, output)
        for raw in ['egress', 'false', 'active', 'enabled']:
            self.assertNotIn(raw, output)

    def test_confirm_y_and_default_no(self):
        for value in ['y', 'Y']:
            self.shell("printf '%s\\n' '" + value + "' | confirm '测试'")
        for value in ['', 'n', 'N', 'yes', '确认', '1']:
            self.shell("printf '%s\\n' '" + value + "' | confirm '测试'", expected=1)

    def test_terminal_clear_and_compact_menu(self):
        master, slave = pty.openpty()
        try:
            env = dict(os.environ, DDNS_TEST_SOURCE='1', TERM='xterm', COLUMNS='40')
            process = subprocess.Popen(['sh', '-c', '. "$1"; id() { echo 0; }; show_status() { echo "  首页状态"; }; printf "0\\n" | menu',
                                        'test', str(SCRIPT)], env=env, stdout=slave, stderr=slave)
            os.close(slave)
            slave = None
            process.wait(timeout=5)
            chunks = []
            while True:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                chunks.append(chunk)
            output = b''.join(chunks).decode()
            self.assertEqual(process.returncode, 0, output)
            self.assertIn('\x1b[H\x1b[2J', output)
            self.assertIn('1) 刷新首页状态\r\n    2)', output)
        finally:
            if slave is not None:
                os.close(slave)
            os.close(master)

    def test_menu_rule_fits_phone(self):
        output = self.shell('COLUMNS=36; ui_rule')
        self.assertEqual(len(output.rstrip('\n')), 36)

    def update(self, records, expected=0):
        fixture = json.dumps({'success': True, 'result': records})
        return self.shell('''record=nat.example.com; zone_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
get_ip() { echo 8.8.8.8; }
api() {
  case "$1" in
    --get) printf '%%s' '%s' ;;
    *) printf 'WRITE:%%s\\n' "$*" >&2; printf '%%s\\n' "$*"; ;;
  esac
}
update
''' % fixture, expected=expected)

    def test_create(self):
        # Capture write arguments separately because update suppresses API output.
        output = self.shell('''record=nat.example.com; zone_id=abc
get_ip() { echo 8.8.8.8; }
api() {
  if [ "$1" = --get ]; then echo '{"result":[]}'; else
    [ "$2" = POST ] || exit 5
    printf '%s' "$4" | jq -e '.content == "8.8.8.8" and .proxied == false and .ttl == 60' >/dev/null || exit 6
  fi
}
update''')
        self.assertIn('已更新', output)

    def test_no_change(self):
        self.assertIn('无变化', self.update([dict(type='A', content='8.8.8.8', proxied=False, id='id')]))

    def test_change_and_disable_proxy(self):
        for ip, proxied in [('1.1.1.1', False), ('8.8.8.8', True)]:
            self.assertIn('已更新', self.update([dict(type='A', content=ip, proxied=proxied, id='id')]))

    def test_conflicting_records(self):
        for records in [[dict(type='CNAME')], [dict(type='A'), dict(type='A')]]:
            self.update(records, expected=1)

    def test_failed_source_never_writes(self):
        self.shell('get_ip() { return 1; }; api() { exit 9; }; update', expected=1)

    def test_failed_api_stops(self):
        self.shell('get_ip() { echo 8.8.8.8; }; zone_id=abc; record=nat.example.com; api() { return 1; }; update', expected=1)

    def test_invalid_config(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'config.json'
            config.write_text('{}')
            self.shell('CONFIG=' + str(config) + '; load_config', expected=1)

    def test_api_token_not_in_arguments(self):
        self.shell('''token=test-token
fetch() {
  case "$*" in *test-token*) exit 9 ;; esac
  line=$(cat)
  [ "$line" = 'header = "Authorization: Bearer test-token"' ] || exit 8
  echo '{"success":true,"result":[]}'
}
api https://example.com >/dev/null''')

    def test_install_sandbox(self):
        for init in ['systemd', 'openrc']:
            with self.subTest(init=init), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source = SCRIPT.read_text()
                for prefix in ['/etc/', '/usr/local/', '/run/systemd/']:
                    source = source.replace(prefix, str(root) + prefix)
                script = root / 'ddns.sh'
                script.write_text(source)
                (root / 'etc/systemd/system').mkdir(parents=True)
                (root / 'etc/init.d').mkdir(parents=True)
                if init == 'systemd':
                    (root / 'run/systemd/system').mkdir(parents=True)
                bin_dir = root / 'bin'
                bin_dir.mkdir()
                for name in ['id', 'stty', 'systemctl', 'rc-service', 'rc-update']:
                    stub = bin_dir / name
                    stub.write_text('#!/bin/sh\n' + ('echo 0\n' if name == 'id' else 'exit 0\n'))
                    stub.chmod(0o755)
                env = dict(os.environ, DDNS_TEST_SOURCE='1', PATH=str(bin_dir) + ':' + os.environ.get('PATH', os.defpath))
                body = '''. "$0"
api() { case "$*" in *--get*) echo '{"result":[]}' ;; *zones/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) echo '{"result":{"name":"example.com"}}' ;; *) echo '{"success":true}' ;; esac; }
get_ip() { echo 8.8.8.8; }
install_ddns'''
                result = subprocess.run(['sh', '-c', body, str(script)], env=env, text=True,
                                        input='test-token\n' + 'a' * 32 + '\nnat.example.com\ny\n', capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                config = root / 'etc/cloudflare-ddns/config.json'
                self.assertEqual(config.stat().st_mode & 0o777, 0o600)
                self.assertEqual(config.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual(json.loads(config.read_text())['token'], 'test-token')
                self.assertNotIn('test-token', result.stdout + result.stderr)
                installed = root / 'usr/local/lib/cloudflare-ddns.sh'
                self.assertTrue(installed.is_file())
                self.assertEqual((root / 'usr/local/bin/ddns').resolve(), installed)
                before = config.read_bytes()
                # Existing shell installations upgrade without re-entering the token.
                result = subprocess.run(['sh', '-c', body, str(script)], env=env, text=True,
                                        input='y\n', capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(config.read_bytes(), before)
                self.assertEqual(len(list(installed.parent.glob('*.bak.*'))), 1)
                self.assertNotIn('test-token', result.stdout + result.stderr)
                # Rejecting an upgrade must not create a backup or modify files.
                result = subprocess.run(['sh', '-c', body, str(script)], env=env, text=True,
                                        input='n\n', capture_output=True)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(len(list(installed.parent.glob('*.bak.*'))), 1)
                if init == 'systemd':
                    self.assertTrue((root / 'etc/systemd/system/cloudflare-ddns.timer').is_file())
                else:
                    service = root / 'etc/init.d/cloudflare-ddns'
                    self.assertTrue(service.stat().st_mode & 0o111)
                    subprocess.run(['sh', '-n', str(service)], check=True)

    def test_legacy_sources_ignored(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'config.json'
            for mode in ['hostname', 'url', 'egress']:
                config.write_text(json.dumps(dict(token='test-token', zone_id='a' * 32,
                    record='nat.example.com', source_mode=mode, source='https://old.example.com')))
                self.assertEqual(self.shell('CONFIG=' + str(config) + '''; load_config
ip() { exit 9; }
fetch() { case "$*" in *old.example.com*) exit 9 ;; *) echo 8.8.8.8 ;; esac; }
get_ip''').strip(), '8.8.8.8')

    def test_homepage_refresh_does_not_require_pause(self):
        output = self.shell("id() { echo 0; }; printf '1\\n0\\n' | menu")
        self.assertEqual(output.count('首页模拟状态'), 2)
        self.assertNotIn('按回车返回', output)

    def test_service_syntax(self):
        text = SCRIPT.read_text()
        self.assertIn('ExecStart=/bin/sh /usr/local/lib/cloudflare-ddns.sh --once', text)
        self.assertIn('command_args="/usr/local/lib/cloudflare-ddns.sh --daemon"', text)
        self.assertNotIn('ExecStart=/usr/bin/env python', text)
        subprocess.run(['sh', '-n', str(SCRIPT)], check=True)
        subprocess.run(['sh', '-n', str(SCRIPT.parent / 'install-ddns.sh')], check=True)


if __name__ == '__main__':
    unittest.main()
