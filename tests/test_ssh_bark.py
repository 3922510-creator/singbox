import base64
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock

PANEL = Path(__file__).resolve().parents[1] / 'singbox.sh'
WORKER = PANEL.read_text().split("python3 -c \"$(cat <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]


def line(message, second):
    return json.dumps({'MESSAGE': message,
                       '__REALTIME_TIMESTAMP': str((1760000000 + second) * 1000000),
                       '__MONOTONIC_TIMESTAMP': str(second * 1000000)})


class SSHBarkTest(unittest.TestCase):
    def setUp(self):
        self.worker = {'__name__': 'ssh_bark_test'}
        exec(compile(WORKER, str(PANEL), 'exec'), self.worker)

    def test_success_and_failure_window_per_ip(self):
        failed = 'Failed password for invalid user scanner from 192.0.2.2 port 123 ssh2'
        lines = [line(failed, t) for t in (0, 301, 302, 303, 304)]
        lines += [line('Invalid user scanner from 192.0.2.2 port 123', 304),
                  line(failed.replace('192.0.2.2', '192.0.2.3'), 304),
                  line('Accepted publickey for root from 2001:db8::1 port 2222 ssh2: test-key', 305),
                  line(failed, 306), line(failed, 307), 'corrupt-json']
        lines += [line(failed, t) for t in (2102, 2103, 2104, 2105, 2106)]
        results = list(self.worker['events'](lines))
        self.assertEqual([title for title, _ in results], ['SSH 登录成功', 'SSH 疑似暴力破解', 'SSH 疑似暴力破解'])
        self.assertIn('2001:db8::1', results[0][1])
        self.assertNotIn('test-key', results[0][1])
        self.assertIn('192.0.2.2', results[1][1])

    def test_https_post_and_no_redirect(self):
        config = self.worker['config']('https://example.com:8443/bark/', 'test_key_123')
        for bad in ('http://example.com', 'https://user@example.com', 'https://example.com/?bad', 'https://example.com\\foo'):
            with self.assertRaises(ValueError):
                self.worker['config'](bad, 'test_key_123')
        opener = MagicMock()
        self.worker['opener'] = opener
        opener.open.return_value.__enter__.return_value.read.return_value = b'{"code":200}'
        self.worker['notify'](config, '登录', '测试')
        req = opener.open.call_args.args[0]
        self.assertEqual(req.get_method(), 'POST')
        self.assertEqual(req.full_url, 'https://example.com:8443/bark/push')
        self.assertNotIn('test_key_123', req.full_url)
        self.assertEqual(json.loads(req.data)['device_key'], 'test_key_123')
        self.assertIsNone(self.worker['NoRedirect']().redirect_request(None, None, 307, '', {}, 'https://other.example'))
        opener.open.return_value.__enter__.return_value.read.return_value = b'{"code":400}'
        with self.assertRaises(ValueError):
            self.worker['notify'](config, '登录', '测试')

    def test_webhook_with_basic_auth(self):
        parse = self.worker['webhook_config']
        cfg = parse('https://demo:p%40ss%3Aword@example.com:8443/bark/test_key_123')
        self.assertEqual(cfg['endpoint'], 'https://example.com:8443/bark/push')
        opener = MagicMock()
        self.worker['opener'] = opener
        opener.open.return_value.__enter__.return_value.read.return_value = b'{"code":200}'
        self.worker['notify'](cfg, '登录', '测试')
        req = opener.open.call_args.args[0]
        self.assertEqual(base64.b64decode(req.get_header('Authorization').split()[1]), b'demo:p@ss:word')
        self.assertEqual(json.loads(req.data)['device_key'], 'test_key_123')
        self.assertNotIn('basic_auth', parse('https://example.com/test_key_123'))
        for bad in ('http://demo:pw@example.com/test_key_123', 'https://demo@example.com/test_key_123',
                    'https://demo:p%0Ass@example.com/test_key_123', 'https://example.com/test_key_123?x=y'):
            with self.assertRaises(ValueError):
                parse(bad)

    @unittest.skipUnless(os.geteuid() == 0, 'the full sb entry point requires root')
    def test_worker_entrypoint_skips_panel_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lock = root / 'panel.lock'
            config = root / 'config.json'
            marker = root / 'journal.started'
            panel = root / 'sb'
            panel.write_text(PANEL.read_text().replace('/var/run/sing-box-manager.lock', str(lock))
                             .replace('/etc/sb-ssh-bark.json', str(config)))
            config.write_text('{"endpoint":"https://example.test/push","key":"test_key_123"}')
            for name, script in {'flock': 'exit 1\n', 'journalctl': f'touch "{marker}"\n'}.items():
                stub = root / name
                stub.write_text('#!/bin/sh\n' + script)
                stub.chmod(0o755)
            env = dict(os.environ, PATH=f'{root}:' + os.defpath)
            subprocess.run(['bash', panel, '--ssh-bark-worker'], env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=5)
            self.assertTrue(marker.exists(), 'worker did not reach journalctl')
            self.assertFalse(lock.exists(), 'worker must not open the panel lock')

    def test_machine_label_changes_title_and_group_without_touching_credentials(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.json'
            credentials = b'{"key":"test_key_123","endpoint":"https://example.test/push"}'
            path.write_bytes(credentials)
            self.assertEqual(self.worker['host_label'](str(path), 'fallback'), 'fallback')
            cmd = ['python3', '-c', WORKER, 'label', str(path)]
            subprocess.run(cmd, input='西海岸线路机\n', text=True, check=True)
            self.assertEqual(path.read_bytes(), credentials)
            label = self.worker['host_label'](str(path), 'fallback')
            opener = MagicMock()
            self.worker['opener'] = opener
            opener.open.return_value.__enter__.return_value.read.return_value = b'{"code":200}'
            self.worker['notify'](json.loads(credentials), 'SSH 登录成功', '测试', label)
            payload = json.loads(opener.open.call_args.args[0].data)
            self.assertEqual(payload['title'], '[西海岸线路机] SSH 登录成功')
            self.assertEqual(payload['group'], 'SSH · 西海岸线路机')
            for invalid in ('x' * 41, 'bad\x1bname'):
                attempt = subprocess.run(cmd, input=invalid + '\n', text=True, capture_output=True)
                self.assertNotEqual(attempt.returncode, 0)
                self.assertEqual(self.worker['host_label'](str(path), 'fallback'), label)
            subprocess.run(cmd, input='\n', text=True, check=True)
            self.assertEqual(self.worker['host_label'](str(path), 'fallback'), 'fallback')
            self.assertEqual(path.read_bytes(), credentials)

    def test_config_privacy_and_invalid_input_does_not_replace(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.json'
            cmd = ['python3', '-c', WORKER, 'configure', str(path)]
            subprocess.run(cmd, input='https://example.com\ntest_key_123\n', text=True, check=True)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            old = path.read_bytes()
            bad = subprocess.run(cmd, input='http://example.com\nother_key_123\n', text=True, capture_output=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertNotIn('other_key_123', bad.stderr)
            self.assertEqual(path.read_bytes(), old)


if __name__ == '__main__':
    unittest.main()
