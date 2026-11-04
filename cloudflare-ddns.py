#!/usr/bin/env python3
"""Cloudflare IPv4 DDNS for NAT hosts; Python standard library only."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import time
from getpass import getpass
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

CONFIG = Path('/etc/cloudflare-ddns/config.json')
SCRIPT = Path('/usr/local/lib/cloudflare-ddns.py')
API = 'https://api.cloudflare.com/client/v4'


def public_ipv4(value):
    ip = ipaddress.IPv4Address(value.strip())
    if not ip.is_global or ip.is_multicast:
        raise ValueError('IP 来源没有返回可用的公网 IPv4')
    return str(ip)


def https_get(url, headers=None):
    if urlsplit(url).scheme != 'https':
        raise ValueError('接口必须使用 HTTPS')
    request = Request(url, headers=headers or {})
    with urlopen(request, timeout=20) as response:
        if urlsplit(response.url).scheme != 'https':
            raise ValueError('拒绝非 HTTPS 重定向')
        body = response.read(1048577)
        if len(body) > 1048576:
            raise ValueError('接口响应过大')
        return body.decode('utf-8').strip()


def source_ip(config):
    mode, source = config['source_mode'], config['source']
    if mode == 'hostname':
        ips = {public_ipv4(item[4][0]) for item in socket.getaddrinfo(
            source, None, socket.AF_INET, socket.SOCK_STREAM)}
        if len(ips) != 1:
            raise ValueError('商家域名必须只解析到一个公网 IPv4')
        return ips.pop()
    if mode == 'url':
        return public_ipv4(https_get(source))
    if mode == 'egress':
        # Do not trust one IP-check service or silently guess an ingress address.
        ips = {public_ipv4(https_get(url)) for url in (
            'https://api4.ipify.org', 'https://ipv4.icanhazip.com')}
        if len(ips) != 1:
            raise ValueError('两个出口查询结果不一致，保留原 DNS')
        return ips.pop()
    raise ValueError('未知 IP 来源模式')


class Cloudflare:
    def __init__(self, token):
        self.token = token

    def request(self, method, path, data=None):
        request = Request(API + path, method=method, headers={
            'Authorization': 'Bearer ' + self.token,
            'Content-Type': 'application/json',
        }, data=None if data is None else json.dumps(data).encode())
        try:
            with urlopen(request, timeout=25) as response:
                result = json.load(response)
        except HTTPError as exc:
            # Never log requests, tokens or an uncontrolled remote response body.
            raise RuntimeError('Cloudflare HTTP %s；检查 Token 权限和 Zone ID' % exc.code) from None
        if result.get('success') is not True:
            codes = [str(e.get('code', '?')) for e in result.get('errors', [])]
            raise RuntimeError('Cloudflare API 失败，错误码：' + ','.join(codes))
        return result


def update(config):
    ip = source_ip(config)
    cf = Cloudflare(config['token'])
    base = '/zones/' + config['zone_id'] + '/dns_records'
    records = cf.request('GET', base + '?' + urlencode({
        'name': config['record'], 'per_page': 100}))['result']
    # An existing CNAME or multiple A records must not be destroyed implicitly.
    if any(r['type'] == 'CNAME' for r in records):
        raise ValueError('同名 CNAME 已存在，请先手动处理')
    records = [r for r in records if r['type'] == 'A']
    if len(records) > 1:
        raise ValueError('存在多条同名 A 记录，请先手动处理')
    if records and records[0]['content'] == ip and records[0].get('proxied') is False:
        print('%s 无变化：%s' % (config['record'], ip), flush=True)
        return
    data = {'type': 'A', 'name': config['record'], 'content': ip,
            'ttl': 60, 'proxied': False}
    if records:
        cf.request('PATCH', base + '/' + records[0]['id'], data)
    else:
        cf.request('POST', base, data)
    print('%s 已更新为 %s（仅 DNS）' % (config['record'], ip), flush=True)


def domain(value):
    value = value.strip().rstrip('.').lower().encode('idna').decode('ascii')
    if len(value) > 253 or '.' not in value or any(
            not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', part)
            for part in value.split('.')):
        raise ValueError('请输入完整域名，不要带协议、路径或端口')
    return value


def run(*args):
    subprocess.run(args, check=True)


def install():
    if os.geteuid() != 0:
        raise ValueError('请使用 root 运行安装')
    systemd = Path('/run/systemd/system').is_dir() and shutil.which('systemctl')
    openrc = shutil.which('rc-service') and shutil.which('rc-update')
    if not systemd and not openrc:
        raise ValueError('只支持 systemd 或 OpenRC')
    paths = [CONFIG.parent, SCRIPT, Path('/etc/systemd/system/cloudflare-ddns.service'),
             Path('/etc/systemd/system/cloudflare-ddns.timer'), Path('/etc/init.d/cloudflare-ddns')]
    if any(p.exists() or p.is_symlink() for p in paths):
        raise ValueError('检测到已有安装/同名文件，拒绝覆盖。配置在 ' + str(CONFIG))
    print('Cloudflare Token：区域 DNS 编辑 + 区域读取，资源仅限你的域名。')
    print('Token 仅在本机输入，不要发到聊天里。')
    token = getpass('API Token（隐藏输入）：').strip()
    if not token or any(c.isspace() for c in token):
        raise ValueError('Token 不能为空或包含空白')
    zone = input('Cloudflare Zone ID（域名概述页面）：').strip()
    if not re.fullmatch(r'[a-fA-F0-9]{32}', zone):
        raise ValueError('Zone ID 应是 32 位十六进制字符')
    record = domain(input('要更新的完整子域名（如 nat.example.com）：'))
    print('IP 来源：1 商家提供的动态域名；2 HTTPS 纯文本 IPv4 接口；3 本机出口 IP')
    mode = input('选择 [1/2/3]：').strip()
    if mode == '1':
        source_mode, source = 'hostname', domain(input('商家动态域名（不能是上面的目标域名）：'))
        if source == record:
            raise ValueError('来源域名不能等于待更新域名')
    elif mode == '2':
        source_mode, source = 'url', input('查询接口 URL（返回纯文本 IPv4）：').strip()
        parsed = urlsplit(source)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError('请输入有效 HTTPS URL，不要在 URL 中放账号密码')
    elif mode == '3':
        if input('必须确认入站映射 IP 等于本机出口 IP。确认请输入 YES：').strip() != 'YES':
            raise ValueError('未确认，不使用出口 IP')
        source_mode, source = 'egress', ''
    else:
        raise ValueError('无效选择')
    config = dict(token=token, zone_id=zone, record=record,
                  source_mode=source_mode, source=source)
    zone_info = Cloudflare(token).request('GET', '/zones/' + zone)['result']
    zone_name = zone_info['name'].lower()
    if record != zone_name and not record.endswith('.' + zone_name):
        raise ValueError('目标记录不属于此 Zone')
    ip = source_ip(config)
    print('将把 %s 的 A 记录设为 %s，关闭此记录橙云，每 60 秒检查一次。' % (record, ip))
    print('不会修改 NAT 端口，不会修改 AAAA；已有 AAAA 可能影响客户端连接，请自行核对。')
    if input('确认安装并更新 DNS？请输入 YES：').strip() != 'YES':
        raise ValueError('已取消')
    # Verify API/DNS before leaving a persistent service on the host.
    update(config)
    os.umask(0o077)
    CONFIG.parent.mkdir(mode=0o700)
    CONFIG.write_text(json.dumps(config, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    CONFIG.chmod(0o600)
    SCRIPT.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(__file__).resolve(), SCRIPT)
    SCRIPT.chmod(0o700)
    if systemd:
        Path('/etc/systemd/system/cloudflare-ddns.service').write_text(
            '[Unit]\nDescription=Cloudflare NAT DDNS\nWants=network-online.target\n'
            'After=network-online.target\n\n[Service]\nType=oneshot\n'
            'ExecStart=/usr/bin/env python3 /usr/local/lib/cloudflare-ddns.py --once\n'
            'TimeoutStartSec=180\nUMask=0077\nNoNewPrivileges=true\n'
            'PrivateTmp=true\nProtectSystem=strict\nProtectHome=true\n', encoding='utf-8')
        Path('/etc/systemd/system/cloudflare-ddns.timer').write_text(
            '[Unit]\nDescription=Check Cloudflare DDNS every minute\n\n[Timer]\n'
            'OnBootSec=30s\nOnUnitInactiveSec=60s\nAccuracySec=5s\n'
            '\n[Install]\nWantedBy=timers.target\n', encoding='utf-8')
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', '--now', 'cloudflare-ddns.timer')
    else:
        service = Path('/etc/init.d/cloudflare-ddns')
        service.write_text('#!/sbin/openrc-run\n'
                           'description="Cloudflare NAT DDNS"\n'
                           'supervisor="supervise-daemon"\ncommand="/usr/bin/env"\n'
                           'command_args="python3 /usr/local/lib/cloudflare-ddns.py --daemon"\n'
                           'respawn_delay=5\nrespawn_max=0\n'
                           'output_log="/var/log/cloudflare-ddns.log"\n'
                           'error_log="/var/log/cloudflare-ddns.log"\n'
                           'depend() { need net; after firewall; }\n', encoding='utf-8')
        service.chmod(0o755)
        run('rc-update', 'add', 'cloudflare-ddns', 'default')
        run('rc-service', 'cloudflare-ddns', 'start')
    print('安装成功。配置：%s；手动检查：python3 %s --once' % (CONFIG, SCRIPT))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--install', action='store_true')
    modes.add_argument('--once', action='store_true')
    modes.add_argument('--daemon', action='store_true')
    args = parser.parse_args()
    if args.install:
        install()
        return
    config = json.loads(CONFIG.read_text(encoding='utf-8'))
    while True:
        try:
            update(config)
        except (ValueError, OSError, RuntimeError, URLError) as exc:
            if not args.daemon:
                raise
            print('更新失败：%s；60 秒后重试' % exc, file=sys.stderr, flush=True)
        if not args.daemon:
            return
        time.sleep(60)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, RuntimeError, URLError) as error:
        print('错误：' + str(error), file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print('\n已取消', file=sys.stderr)
        sys.exit(1)
