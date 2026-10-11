#!/usr/bin/env python3
"""Opt-in live macOS profile/helper test. Requires an initially disconnected VPN.

Temporarily stops the supervisor, uses disposable config/user-state, and adds
only routes to 1.1.1.1 and 8.8.8.8 plus the example.com split-DNS zone. Restores
the supervisor and checks cleanup. Credentials are entered without echo and
remain in memory. Tunnel mode requires the installed NOPASSWD ocbar-helper.
Proxy mode tests SOCKS HTTPS/remote DNS without changing system routes or DNS.
Proxy environment variables are removed unless explicitly opted in: otherwise
user-mode OpenConnect and the sudo helper can use different upstream paths.
"""
import argparse
import getpass
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
CLI = str(ROOT / 'bin/ocbar')
HELPER = '/usr/local/libexec/ocbar-helper'
ZONE = Path('/etc/resolver/example.com')
STATE = Path('/var/db/ocbar')
FAILURES = []


def test_environment(source, inherit_proxy=False):
    return {k: v for k, v in source.items()
            if not k.startswith('OCBAR_') and
            (inherit_proxy or k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'))}


def run(command, env=None, timeout=60, check=True):
    r = subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError('%s failed (%d): %s' % (command[0], r.returncode, (r.stdout + r.stderr)[-2000:]))
    return r


def status(env=None):
    return json.loads(run([CLI, 'status', '--json'], env).stdout)


def route(target):
    text = run(['/sbin/route', '-n', 'get', target]).stdout
    return dict(re.findall(r'^\s*(gateway|interface):\s*(\S+)', text, re.M))


def tunnel_env():
    return dict(line.split('=', 1) for line in (STATE / 'tunnel.env').read_text().splitlines() if '=' in line)


def proxy_traffic(env, port):
    s = status(env)
    assert s['state'] == 'connected' and s['mode'] == 'proxy', 'proxy did not connect'
    base = ['curl', '--socks5-hostname', '127.0.0.1:%d' % port, '--noproxy', '',
            '--fail', '--silent', '--show-error', '--max-time', '20']
    r = run(base + ['https://1.1.1.1/cdn-cgi/trace'])
    trace = dict(line.split('=', 1) for line in r.stdout.splitlines() if '=' in line)
    assert trace.get('ip'), 'proxy trace did not report an exit address'
    run(base + ['https://example.com/'])
    print('  SOCKS HTTPS exit=%s; remote DNS + HTTPS OK' % trace['ip'], flush=True)


def traffic(env, phase):
    s = status(env)
    dev = s['tundev']
    assert s['state'] == 'connected' and dev.startswith('utun'), s['state']
    for target in ('1.1.1.1', '8.8.8.8'):
        assert route(target)['interface'] == dev, 'test route does not use VPN'
    assert ZONE.exists(), 'split-DNS resolver not installed'
    resolver = ZONE.read_text()
    dns = re.search(r'^nameserver\s+(\S+)', resolver, re.M).group(1)
    assert dns in ('8.8.8.8', '1.1.1.1'), 'unexpected DNS; no route authorized for it'
    resolved = run(['/usr/bin/dscacheutil', '-q', 'host', '-a', 'name', 'example.com'], timeout=15).stdout
    assert 'ip_address:' in resolved, 'macOS resolver returned no address'
    direct = run(['/usr/bin/dig', '@' + dns, 'example.com', '+short', '+time=3', '+tries=1']).stdout
    assert re.search(r'^\d+\.\d+\.\d+\.\d+$', direct, re.M), 'VPN DNS did not answer'
    mtu = re.search(r'\bmtu (\d+)', run(['/sbin/ifconfig', dev]).stdout).group(1)
    wanted_mtu = re.search(r'^MTU=(\d+)', (STATE / 'tunnel.env').read_text(), re.M).group(1)
    assert mtu == wanted_mtu, 'interface MTU differs from helper state'
    print('  macOS DNS + direct VPN DNS OK; %s MTU=%s' % (dev, mtu), flush=True)
    r = run(['curl', '--noproxy', '*', '--fail', '--silent', '--show-error',
             '--max-time', '12', 'https://1.1.1.1/cdn-cgi/trace'], check=False)
    if r.returncode:
        failure = '%s [%s]: HTTPS failed (curl %s)' % (s.get('url', ''), phase, r.returncode)
        FAILURES.append(failure)
        print('  FAIL: ' + failure, flush=True)
    else:
        trace = dict(line.split('=', 1) for line in r.stdout.splitlines() if '=' in line)
        assert trace.get('ip'), 'trace did not report an exit address'
        print('  HTTPS exit=' + trace['ip'], flush=True)



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', required=True, help='Explicitly allow live host routes/DNS changes')
    parser.add_argument('hosts', nargs='+')
    parser.add_argument('--dtls', choices=('on', 'off'), default='on')
    parser.add_argument('--mtu', type=int, help='Profile base MTU (576–9000)')
    parser.add_argument('--upstream-proxy', help='Explicit profile proxy, independent of proxy environment')
    parser.add_argument('--mode', choices=('tunnel', 'proxy'), default='tunnel')
    parser.add_argument('--inherit-proxy-env', action='store_true',
                        help='Proxy mode only: allow inherited upstream proxy variables (different network path)')
    parser.add_argument('--preserve-route', action='append', default=['9.9.9.9'],
                        help='Additional IPv4 address whose route must remain unchanged')
    args = parser.parse_args()
    if args.inherit_proxy_env and args.mode != 'proxy':
        parser.error('--inherit-proxy-env only applies to proxy mode; sudo does not preserve that environment')
    if args.mtu is not None and not 576 <= args.mtu <= 9000:
        parser.error('MTU must be 576–9000')
    if any(not re.fullmatch(r'[A-Za-z0-9.-]+', host) for host in args.hosts):
        parser.error('hosts must be DNS hostnames')
    before = status()
    assert before['state'] == 'down' and not before['foreign'], 'disconnect ocbar before this test'
    assert not ZONE.exists(), 'example.com already has a resolver; refusing to overwrite it'
    for target in args.preserve_route:
        ipaddress.IPv4Address(target)
    if args.mode == 'tunnel':
        run(['sudo', '-n', HELPER, 'version'])
    baseline = {target: route(target) for target in ['default', '1.1.1.1', '8.8.8.8'] + args.preserve_route}
    # Determine the actual installed label from the CLI rather than assuming it.
    source = Path(CLI).read_text()
    label = 'gui/%d/%s' % (os.getuid(), re.search(r'^AGENT_LABEL="([^"]+)"', source, re.M).group(1))
    supervisor_loaded = run(['launchctl', 'print', label], check=False).returncode == 0
    username = getpass.getpass('VPN username (hidden): ')
    password = getpass.getpass('VPN password (hidden): ')
    assert username and password and not any(c in username for c in '\r\n'), 'invalid credentials'
    stopped = False
    started = False
    with tempfile.TemporaryDirectory(prefix='ocbar-macos-live-') as directory:
        tmp = Path(directory)
        (tmp / 'profiles').mkdir()
        env = test_environment(os.environ, args.inherit_proxy_env)
        env.update(OCBAR_CONFIG_DIR=str(tmp), OCBAR_USER_STATE=str(tmp / 'user-state'),
                   OCBAR_LOG_DIR=str(tmp / 'logs'), OCBAR_NOTIFY='0',
                   OCBAR_TEST_PASSWORD=password, OCBAR_AUTH=str(ROOT / 'auth/.build/release/ocbar-auth'))
        try:
            if supervisor_loaded:
                run([CLI, 'supervisor', 'stop'])
                stopped = True
            assert status()['state'] == 'down', 'VPN changed during preparation'
            for host in args.hosts:
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    port = sock.getsockname()[1]
                profile = tmp / 'profiles/live-test.ocbar'
                profile.write_text('[Connection]\nName = External live test\nUrl = https://' + host +
                                   '\nUser = ' + username + '\nAuth = password\n' +
                                   'Mode = ' + args.mode + '\n' +
                                   'Dtls = ' + args.dtls + '\n' +
                                   ('UpstreamProxy = ' + args.upstream_proxy + '\n' if args.upstream_proxy else '') +
                                   ('Mtu = %d\n' % args.mtu if args.mtu else '') +
                                   '[Routes]\n1.1.1.1/32\n8.8.8.8/32\n' +
                                   '[DNS]\nexample.com = vpn\n' +
                                   '[Auth]\nPassword = command\nPasswordCommand = printf %s "$OCBAR_TEST_PASSWORD"\nTotp = off\n' +
                                   '[Proxy]\nSystemProxy = off\nPort = %d\n' % port +
                                   '[Health]\nCheck = https://1.1.1.1/cdn-cgi/trace\n')
                run([CLI, 'profile-check', str(profile)], env)
                path = ('explicit profile upstream ' + args.upstream_proxy if args.upstream_proxy else
                        'inherited upstream proxy environment' if args.inherit_proxy_env else 'proxy environment removed')
                print(host + ': connecting through profile (%s; %s)' % (args.mode, path), flush=True)
                started = True
                run([CLI, 'connect', 'live-test'], env, timeout=90)
                if args.mode == 'proxy':
                    proxy_traffic(env, port)
                    assert not ZONE.exists(), 'proxy changed system DNS'
                    for target in baseline:
                        assert route(target) == baseline[target], 'proxy changed host route'
                    run([CLI, 'disconnect'], env)
                    assert status(env)['state'] == 'down', 'proxy still connected'
                    with socket.socket() as sock:
                        sock.settimeout(1)
                        assert sock.connect_ex(('127.0.0.1', port)) != 0, 'SOCKS still listening'
                    print(host + ': proxy disconnect cleanup OK', flush=True)
                    continue
                traffic(env, 'connect')
                assert route('default') == baseline['default'], 'default route changed'
                for target in args.preserve_route:
                    assert route(target) == baseline[target], 'unrelated route changed'
                run([CLI, 'pause'], env)
                assert status(env)['state'] == 'paused', 'pause state missing'
                assert not ZONE.exists(), 'pause left split DNS installed'
                for target in ('1.1.1.1', '8.8.8.8'):
                    assert route(target) == baseline[target], 'pause did not restore route'
                print('  pause: routes and split DNS removed', flush=True)
                run([CLI, 'resume'], env)
                traffic(env, 'resume')
                print('  resume: routes and DNS restored', flush=True)
                connected_at = tunnel_env().get('CONNECTED')
                run(['sudo', '-n', HELPER, 'reconnect-now'])
                for _ in range(30):
                    now = tunnel_env()
                    if (now.get('STATE') == 'connected' and now.get('REASON') == 'reconnect'
                            and now.get('CONNECTED') != connected_at):
                        break
                    time.sleep(1)
                else:
                    raise AssertionError('helper did not finish reconnect within 30 seconds')
                traffic(env, 'reconnect')
                print('  reconnect: session, routes and DNS restored', flush=True)
                run(['sudo', '-n', HELPER, 'stats'])
                time.sleep(.5)
                lines = (STATE / 'openconnect.log').read_text().splitlines()[-40:]
                for line in lines:
                    if any(word in line for word in ('Configured as', 'No DTLS address', 'Established DTLS', 'Transport:', 'CSTP connected')):
                        print('  transport: ' + line.replace(username, '[user]').replace(password, '[password]'), flush=True)
                run([CLI, 'disconnect'], env)
                assert status(env)['state'] == 'down' and not ZONE.exists(), 'disconnect cleanup failed'
                for target in baseline:
                    assert route(target) == baseline[target], 'disconnect did not restore ' + target
                print(host + ': disconnect cleanup OK', flush=True)
        finally:
            try:
                if started:
                    run([CLI, 'disconnect'], env)
                assert not ZONE.exists(), 'resolver left after cleanup'
                for target in baseline:
                    assert route(target) == baseline[target], 'route left after cleanup: ' + target
            finally:
                if stopped:
                    run([CLI, 'supervisor', 'start'])
                    assert run(['launchctl', 'print', label], check=False).returncode == 0
                    print('Original supervisor restored', flush=True)
    print('Original host routes restored', flush=True)
    if FAILURES:
        raise SystemExit('%d HTTPS check(s) failed; control/DNS checks completed' % len(FAILURES))
    print('Live macOS checks passed', flush=True)


if __name__ == '__main__':
    main()
