"""Offline tests for the sh implementation; never touch host services or real DNS."""
import json
import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
import os
import pty
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'ddns.sh'


class DDNSTests(unittest.TestCase):
    def shell(self, body, expected=0):
        if 'menu' in body:
            body = "show_status() { printf '  首页模拟状态\\n'; }; " + body
        with tempfile.TemporaryDirectory() as state:
            env = dict(os.environ, DDNS_TEST_SOURCE='1', DDNS_STATE=state)
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
        self.assertLessEqual(len(output.splitlines()), 26)
        self.assertEqual(output.count('Cloudflare DDNS'), 1)

    def test_status_translated(self):
        output = self.shell('''load_config() { record=nat.example.com; source_mode=egress; zone_id=abc; bark_url=''; }
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
                env = dict(os.environ, DDNS_TEST_SOURCE='1', DDNS_STATE=str(root / 'state'), PATH=str(bin_dir) + ':' + os.environ.get('PATH', os.defpath))
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
                if init == 'systemd':
                    unit = root / 'etc/systemd/system/cloudflare-ddns.service'
                    old_unit = unit.read_text().replace('--scheduled', '--once').replace('StateDirectory=cloudflare-ddns\n', '').replace('StateDirectoryMode=0700\n', '')
                    unit.write_text(old_unit)
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
                    self.assertIn('--scheduled', unit.read_text())
                    self.assertEqual(unit.read_text().count('StateDirectory=cloudflare-ddns'), 1)
                    self.assertEqual(len(list(unit.parent.glob('*.service.bak.*'))), 1)
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

    def test_log_retains_only_last_ten(self):
        output = self.shell('''init_state
record=nat.example.com
i=1
while [ "$i" -le 15 ]; do record_change "8.8.8.$i" "1.1.1.$i"; i=$((i+1)); done
show_changes
[ "$(stat -c %a "$STATE/changes.log")" = 600 ]''')
        lines = output.splitlines()
        self.assertEqual(len(lines), 10)
        self.assertTrue(lines[0].endswith('8.8.8.6 -> 1.1.1.6'))
        self.assertTrue(lines[-1].endswith('8.8.8.15 -> 1.1.1.15'))

    def test_only_successful_ip_changes_log_and_notify(self):
        body = '''record=nat.example.com; zone_id=abc; bark_url=http://localhost:8080/test-key
get_ip() { echo 8.8.8.8; }
api() { if [ "$1" = --get ]; then printf '%s' 'FIXTURE'; else return 0; fi; }
send_bark() { echo "PUSH:$*"; }
update
show_changes'''
        for records in [[], [dict(type='A', content='8.8.8.8', proxied=False, id='id')],
                        [dict(type='A', content='8.8.8.8', proxied=True, id='id')]]:
            output = self.shell(body.replace('FIXTURE', json.dumps({'result': records})))
            self.assertNotIn('PUSH:', output)
            self.assertNotIn(' -> ', output)
        output = self.shell(body.replace('FIXTURE', json.dumps({'result': [dict(type='A', content='1.1.1.1', proxied=False, id='id')]})))
        self.assertIn('1.1.1.1 -> 8.8.8.8', output)
        self.assertEqual(output.count('PUSH:'), 1)

    def test_dns_failure_never_logs_or_notifies(self):
        self.shell('''record=nat.example.com; zone_id=abc
get_ip() { echo 8.8.8.8; }
api() { if [ "$1" = --get ]; then echo '{"result":[{"type":"A","content":"1.1.1.1","proxied":false,"id":"id"}]}'; else return 1; fi; }
record_change() { exit 9; }
send_bark() { exit 9; }
update''', expected=1)

    def test_bark_url_and_response(self):
        for url in ['https://api.day.app/key-123/', 'http://192.168.1.3:8080/key', 'https://bark.example.com/prefix/key',
                    'https://test-user:test-pass@bark.example.com/key',
                    'http://test-user:p%40ss%3Aword@localhost:8080/prefix/key']:
            self.shell("validate_bark '" + url + "'")
        for url in ['file:///etc/passwd', 'http://example.com', 'https://example.com/key?x=1',
                    'https://user@example.com/key', 'https://user:p@ss@example.com/key',
                    'https://user:pa"ss@example.com/key', r'https://user:pa\\ss@example.com/key',
                    'https://example.com/key\n']:
            self.shell("validate_bark '" + url + "'", expected=1)
        body = '''bark_url=http://localhost:8080/test-secret
curl() {
  case "$*" in *test-secret*) exit 9 ;; esac
  line=$(cat)
  [ "$line" = 'url = "http://localhost:8080/test-secret"' ] || exit 8
  echo '{"code":200}'
}
send_bark 'DDNS test' 'old -> new'
'''
        self.shell(body)
        self.shell(body.replace('"code":200', '"code":400'), expected=1)
        self.shell(body.replace("echo '{\"code\":200}'", 'return 1'), expected=1)

    def test_save_bark_preserves_existing_config(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'config.json'
            original = dict(token='test-token', zone_id='a' * 32, record='nat.example.com')
            config.write_text(json.dumps(original))
            config.chmod(0o600)
            output = self.shell('CONFIG=' + str(config) + '; bark_url=http://localhost:8080/secret-key; save_bark')
            self.assertNotIn('secret-key', output)
            self.assertEqual(json.loads(config.read_text()), dict(original, bark_url='http://localhost:8080/secret-key'))
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(list(config.parent.glob('*.bak.*'))), 1)

    def test_self_hosted_bark_http_roundtrip(self):
        received = []
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append((self.path, json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"code":200,"message":"success"}')
            def log_message(self, *_):
                pass
        # Port 0 allocates a free listener atomically; no production port or PID is touched.
        server = HTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            self.shell('bark_url=http://127.0.0.1:' + str(server.server_port) + '/prefix/device-key; send_bark "DDNS 测试" "1.1.1.1 -> 8.8.8.8"')
            self.assertEqual(received, [('/prefix/device-key', dict(title='DDNS 测试', body='1.1.1.1 -> 8.8.8.8', group='DDNS'))])
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)

    def test_basic_auth_self_hosted_roundtrip(self):
        received = []
        expected = 'Basic ' + base64.b64encode(b'test-user:p@ss:word').decode()
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                auth = self.headers.get('Authorization')
                received.append((self.path, auth))
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                ok = auth == expected
                self.send_response(200 if ok else 401)
                self.end_headers()
                self.wfile.write(b'{"code":200}' if ok else b'{"code":401}')
            def log_message(self, *_):
                pass
        server = HTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            url = 'http://test-user:p%40ss%3Aword@127.0.0.1:' + str(server.server_port) + '/prefix/device-key'
            self.shell('bark_url=' + url + '; send_bark "DDNS test" "test body"')
            self.assertEqual(received[0], ('/prefix/device-key', expected))
            self.shell('bark_url=' + url.replace('p%40ss%3Aword', 'wrong-pass') + '; send_bark "test" "test"', expected=1)
            self.assertEqual(len(received), 2)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)

    def test_basic_auth_credentials_stay_out_of_argv(self):
        self.shell('''bark_url=https://test-user:test-password@example.com/device-key
curl() {
  case "$*" in *test-user*|*test-password*|*device-key*) exit 9 ;; esac
  line=$(cat)
  [ "$line" = 'url = "https://test-user:test-password@example.com/device-key"' ] || exit 8
  echo '{"code":200}'
}
send_bark 'test' 'test' ''')

    def test_notification_failure_does_not_undo_dns(self):
        output = self.shell('''record=nat.example.com; zone_id=abc; bark_url=http://localhost:8080/key
get_ip() { echo 8.8.8.8; }
api() { if [ "$1" = --get ]; then echo '{"result":[{"type":"A","content":"1.1.1.1","proxied":false,"id":"id"}]}'; else return 0; fi; }
send_bark() { return 1; }
update
show_changes''')
        self.assertEqual(output.count('1.1.1.1 -> 8.8.8.8'), 1)

    def test_test_notification_never_updates_dns(self):
        output = self.shell('''load_config() { record=nat.example.com; bark_url=http://localhost:8080/key; }
curl() { cat >/dev/null; echo '{"code":200}'; }
api() { exit 9; }
printf 'y\\n' | test_bark''')
        self.assertIn('Bark 服务端已确认接收', output)
        self.assertIn('请检查手机', output)

    def test_active_lock_rejects_second_writer(self):
        self.shell('''init_state
mkdir "$STATE/update.lock"
printf '%s\\n' "$$" > "$STATE/update.lock/pid"
get_ip() { exit 9; }
update''', expected=1)

    def test_service_syntax(self):
        text = SCRIPT.read_text()
        self.assertIn('ExecStart=/bin/sh /usr/local/lib/cloudflare-ddns.sh --scheduled', text)
        self.assertIn('StateDirectory=cloudflare-ddns', text)
        self.assertIn('command_args="/usr/local/lib/cloudflare-ddns.sh --daemon"', text)
        self.assertNotIn('ExecStart=/usr/bin/env python', text)
        subprocess.run(['sh', '-n', str(SCRIPT)], check=True)
        subprocess.run(['sh', '-n', str(SCRIPT.parent / 'install-ddns.sh')], check=True)


if __name__ == '__main__':
    unittest.main()
