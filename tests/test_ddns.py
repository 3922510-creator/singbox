"""Offline tests for the sh implementation; never touch host services or real DNS."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'ddns.sh'


class DDNSTests(unittest.TestCase):
    def shell(self, body, expected=0):
        env = dict(os.environ, DDNS_TEST_SOURCE='1')
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

    def test_source_url(self):
        self.assertEqual(self.shell('source_mode=url; source=https://example.com; fetch() { echo 8.8.8.8; }; get_ip').strip(), '8.8.8.8')

    def test_source_hostname(self):
        body = '''source_mode=hostname; source=provider.example.com
fetch() { printf '%s' '{"Status":0,"Answer":[{"type":5,"data":"alias.example.com"},{"type":1,"data":"8.8.8.8"}]}'; }
get_ip'''
        self.assertEqual(self.shell(body).strip(), '8.8.8.8')
        self.shell(body.replace('"type":5,"data":"alias.example.com"', '"type":1,"data":"1.1.1.1"'), expected=1)

    def test_egress_agreement(self):
        body = '''source_mode=egress
fetch() { case "$1" in *ipify*) echo 8.8.8.8 ;; *) echo 1.1.1.1 ;; esac; }
get_ip'''
        self.shell(body, expected=1)
        self.assertEqual(self.shell(body.replace('echo 1.1.1.1', 'echo 8.8.8.8')).strip(), '8.8.8.8')

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
                                        input='test-token\n' + 'a' * 32 + '\nnat.example.com\n1\nprovider.example.com\nYES\n', capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                config = root / 'etc/cloudflare-ddns/config.json'
                self.assertEqual(config.stat().st_mode & 0o777, 0o600)
                self.assertEqual(config.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual(json.loads(config.read_text())['token'], 'test-token')
                self.assertNotIn('test-token', result.stdout + result.stderr)
                self.assertTrue((root / 'usr/local/lib/cloudflare-ddns.sh').is_file())
                if init == 'systemd':
                    self.assertTrue((root / 'etc/systemd/system/cloudflare-ddns.timer').is_file())
                else:
                    service = root / 'etc/init.d/cloudflare-ddns'
                    self.assertTrue(service.stat().st_mode & 0o111)
                    subprocess.run(['sh', '-n', str(service)], check=True)

    def test_service_syntax(self):
        text = SCRIPT.read_text()
        self.assertIn('ExecStart=/bin/sh /usr/local/lib/cloudflare-ddns.sh --once', text)
        self.assertIn('command_args="/usr/local/lib/cloudflare-ddns.sh --daemon"', text)
        self.assertNotIn('ExecStart=/usr/bin/env python', text)
        subprocess.run(['sh', '-n', str(SCRIPT)], check=True)
        subprocess.run(['sh', '-n', str(SCRIPT.parent / 'install-ddns.sh')], check=True)


if __name__ == '__main__':
    unittest.main()
