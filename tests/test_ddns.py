"""Offline tests: never access Cloudflare or modify host services."""
import importlib.util
from pathlib import Path
import unittest
import tempfile
import stat
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('ddns', Path(__file__).resolve().parents[1] / 'cloudflare-ddns.py')
ddns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ddns)


class DDNSTests(unittest.TestCase):
    def setUp(self):
        self.config = dict(token='test-token', zone_id='a' * 32,
                           record='nat.example.com', source_mode='url', source='https://example.com/ip')

    def test_public_ipv4(self):
        self.assertEqual(ddns.public_ipv4(' 8.8.8.8\n'), '8.8.8.8')
        for value in ['127.0.0.1', '10.0.0.1', '100.64.0.1', '192.168.1.1',
                      '0.0.0.0', '224.0.0.1', '::1', 'html', '8.8.8.8:22']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                ddns.public_ipv4(value)

    def test_domain(self):
        self.assertEqual(ddns.domain('NAT.Example.COM.'), 'nat.example.com')
        for value in ['https://example.com', 'example.com:22', '*.example.com', '-a.example.com']:
            with self.assertRaises(ValueError):
                ddns.domain(value)

    def test_https_required(self):
        with self.assertRaises(ValueError):
            ddns.https_get('http://example.com')

    def test_source_url(self):
        with patch.object(ddns, 'https_get', return_value='8.8.8.8'):
            self.assertEqual(ddns.source_ip(self.config), '8.8.8.8')

    def test_source_hostname(self):
        self.config.update(source_mode='hostname', source='provider.example.com')
        with patch.object(ddns.socket, 'getaddrinfo', return_value=[(2, 1, 6, '', ('8.8.8.8', 0))]):
            self.assertEqual(ddns.source_ip(self.config), '8.8.8.8')
        with patch.object(ddns.socket, 'getaddrinfo', return_value=[
                (2, 1, 6, '', ('8.8.8.8', 0)), (2, 1, 6, '', ('1.1.1.1', 0))]):
            with self.assertRaises(ValueError):
                ddns.source_ip(self.config)

    def test_egress_agreement(self):
        self.config.update(source_mode='egress')
        with patch.object(ddns, 'https_get', side_effect=['8.8.8.8', '1.1.1.1']):
            with self.assertRaises(ValueError):
                ddns.source_ip(self.config)
        with patch.object(ddns, 'https_get', side_effect=['8.8.8.8', '8.8.8.8']):
            self.assertEqual(ddns.source_ip(self.config), '8.8.8.8')

    def check_update(self, records):
        api = Mock()
        api.request.return_value = {'result': records}
        with patch.object(ddns, 'Cloudflare', return_value=api), patch.object(
                ddns, 'source_ip', return_value='8.8.8.8'):
            ddns.update(self.config)
        return api.request.call_args_list

    def test_create(self):
        calls = self.check_update([])
        self.assertEqual(calls[-1].args[0], 'POST')
        self.assertEqual(calls[-1].args[2]['content'], '8.8.8.8')
        self.assertIs(calls[-1].args[2]['proxied'], False)

    def test_no_change(self):
        calls = self.check_update([dict(type='A', content='8.8.8.8', proxied=False, id='id')])
        self.assertEqual(len(calls), 1)

    def test_change_and_disable_proxy(self):
        for ip, proxy in [('1.1.1.1', False), ('8.8.8.8', True)]:
            calls = self.check_update([dict(type='A', content=ip, proxied=proxy, id='id')])
            self.assertEqual(calls[-1].args[0], 'PATCH')
            self.assertTrue(calls[-1].args[1].endswith('/id'))

    def test_conflicting_records(self):
        for records in [[dict(type='CNAME')], [dict(type='A'), dict(type='A')]]:
            with self.assertRaises(ValueError):
                self.check_update(records)

    def test_failed_source_never_writes_dns(self):
        with patch.object(ddns, 'source_ip', side_effect=ValueError('bad IP')), patch.object(ddns, 'Cloudflare') as api:
            with self.assertRaises(ValueError):
                ddns.update(self.config)
            api.assert_not_called()

    def test_install_service_generation(self):
        for init in ['systemd', 'openrc']:
            with self.subTest(init=init), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                def sandbox_path(value):
                    value = str(value)
                    if value.startswith(('/etc/', '/run/', '/usr/local/')):
                        return root / value.lstrip('/')
                    return Path(value)
                if init == 'systemd':
                    (root / 'run/systemd/system').mkdir(parents=True)
                    (root / 'etc/systemd/system').mkdir(parents=True)
                else:
                    (root / 'etc/init.d').mkdir(parents=True)
                (root / 'etc/cloudflare-ddns').parent.mkdir(parents=True, exist_ok=True)
                config_path = root / 'etc/cloudflare-ddns/config.json'
                script_path = root / 'usr/local/lib/cloudflare-ddns.py'
                answers = ['a' * 32, 'nat.example.com', '1', 'provider.example.com', 'YES']
                old_umask = ddns.os.umask(0o077)
                try:
                    with patch.object(ddns, 'Path', side_effect=sandbox_path), patch.object(
                            ddns, 'CONFIG', config_path), patch.object(ddns, 'SCRIPT', script_path), patch.object(
                            ddns.os, 'geteuid', return_value=0), patch.object(ddns.shutil, 'which', return_value='/bin/mock'), patch.object(
                            ddns, 'getpass', return_value='test-token'), patch('builtins.input', side_effect=answers), patch.object(
                            ddns, 'Cloudflare') as api, patch.object(ddns, 'source_ip', return_value='8.8.8.8'), patch.object(
                            ddns, 'update') as update, patch.object(ddns, 'run') as run:
                        api.return_value.request.return_value = {'result': {'name': 'example.com'}}
                        ddns.install()
                        update.assert_called_once()
                        self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)
                        self.assertEqual(stat.S_IMODE(config_path.parent.stat().st_mode), 0o700)
                        self.assertTrue(script_path.is_file())
                        if init == 'systemd':
                            service = root / 'etc/systemd/system/cloudflare-ddns.service'
                            self.assertIn('--once', service.read_text())
                            run.assert_any_call('systemctl', 'enable', '--now', 'cloudflare-ddns.timer')
                        else:
                            service = root / 'etc/init.d/cloudflare-ddns'
                            self.assertIn('--daemon', service.read_text())
                            run.assert_any_call('rc-service', 'cloudflare-ddns', 'start')
                finally:
                    ddns.os.umask(old_umask)

    def test_api_error_does_not_leak_token(self):
        error = ddns.HTTPError(ddns.API, 403, 'denied', {}, None)
        with patch.object(ddns, 'urlopen', side_effect=error):
            with self.assertRaises(RuntimeError) as caught:
                ddns.Cloudflare('secret-token').request('GET', '/zones')
            self.assertNotIn('secret-token', str(caught.exception))


if __name__ == '__main__':
    unittest.main()
