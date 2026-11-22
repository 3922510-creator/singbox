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
