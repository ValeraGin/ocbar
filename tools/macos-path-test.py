#!/usr/bin/env python3
"""Opt-in direct / SSH-relayed / direct comparison using the same macOS helper.

Requires an authorized VPN account and SSH host. The SSH host only forwards TCP;
no software or routes are changed there. Authentication still validates the VPN
hostname with normal PKI. The helper uses the verified pin for the forwarded
endpoint. Temporarily adds only 1.1.1.1/32, 8.8.8.8/32 and example.com split DNS.
"""
import argparse
from contextlib import contextmanager
import getpass
import importlib.util
import os
from pathlib import Path
import re
import select
import socketserver
import threading
import shutil
import socket
import subprocess
import time
from urllib.parse import urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('native', ROOT / 'tools/macos-ocserv-test.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
live = native.live
LOCAL_CONTROL = object()


@contextmanager
def local_relay(host):
    # Same loopback endpoint/SNI behavior as SSH forwarding, but the upstream
    # socket leaves this Mac directly. This controls for the endpoint rewrite.
    stopped = threading.Event()

    class Forward(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                with socket.create_connection((host, 443), timeout=5) as upstream:
                    self.request.settimeout(5)
                    sockets = (self.request, upstream)
                    while not stopped.is_set():
                        readable, _, _ = select.select(sockets, [], [], .2)
                        for source in readable:
                            data = source.recv(65536)
                            if not data:
                                return
                            (upstream if source is self.request else self.request).sendall(data)
            except OSError:
                return

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = False
        block_on_close = True

    with Server(('127.0.0.1', 0), Forward) as server:
        port = server.server_address[1]
        worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .1})
        worker.start()
        try:
            yield port
        finally:
            stopped.set()
            server.shutdown()
            worker.join(timeout=2)
    with socket.socket() as check:
        check.settimeout(.5)
        assert check.connect_ex(('127.0.0.1', port)) != 0, 'local forwarding listener left open'


@contextmanager
def relay(via, host):
    if via is LOCAL_CONTROL:
        with local_relay(host) as port:
            yield port
        return
    if via is None:
        yield None
        return
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    command = ['ssh', '-N', '-S', 'none', '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes',
               '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2',
               '-L', '127.0.0.1:%d:%s:443' % (port, host), via]
    proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        for _ in range(120):
            if proc.poll() is not None:
                raise RuntimeError('SSH forwarding failed: ' + proc.stderr.read().decode(errors='replace')[-1000:])
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError('SSH listener did not start')
        yield port
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
        proc.stderr.close()
        with socket.socket() as check:
            check.settimeout(.5)
            assert check.connect_ex(('127.0.0.1', port)) != 0, 'SSH listener left open'


def authenticate(host, port, username, password, env):
    url = 'https://' + host + (':%d' % port if port else '')
    command = ['python3', str(ROOT / 'libexec/ocmac-pwauth.py'), shutil.which('openconnect'),
               '--authenticate', '--protocol=anyconnect', '--no-proxy', '--os=mac-intel', '--user=' + username]
    if port:
        command += ['--resolve', host + ':127.0.0.1']
    result = subprocess.run(command + [url], env=env, capture_output=True, text=True, timeout=40)
    if result.returncode:
        raise RuntimeError('authentication failed: ' + result.stderr.replace(username, '[user]').replace(password, '[password]')[-1000:])
    cookie, pin, endpoint = result.stdout.strip().rsplit(' ', 2)
    parsed = urlsplit(endpoint)
    assert parsed.hostname == host and parsed.scheme == 'https', 'unexpected authentication redirect'
    assert pin.startswith(('pin-sha256:', 'sha256:')), 'verified server pin missing'
    if port:
        # PKI was verified above using the real hostname/SNI on this same path.
        endpoint = urlunsplit(parsed._replace(netloc='127.0.0.1:%d' % port))
    return cookie, pin, endpoint


def traffic():
    state = native.wait_connected()
    for address in ('1.1.1.1', '8.8.8.8'):
        assert live.route(address)['interface'] == state['TUNDEV'], 'probe bypasses VPN'
    dns = re.search(r'^nameserver\s+(\S+)', live.ZONE.read_text(), re.M).group(1)
    assert dns in ('1.1.1.1', '8.8.8.8'), 'VPN DNS is outside scoped routes'
    print('  %s MTU=%s; DNS=%s' % (state['TUNDEV'], state['MTU'], dns), flush=True)
    result = live.run(['dig', '@' + dns, 'example.com', '+short', '+time=3', '+tries=1'], check=False)
    direct_dns = bool(re.search(r'^\d+\.\d+\.\d+\.\d+$', result.stdout, re.M))
    try:
        result = live.run(['dscacheutil', '-q', 'host', '-a', 'name', 'example.com'], timeout=5)
        system_dns = 'ip_address:' in result.stdout
    except (subprocess.TimeoutExpired, RuntimeError):
        system_dns = False
    print('  DNS direct=%s; macOS=%s' % (direct_dns, system_dns), flush=True)
    https = True
    for attempt in range(2):
        result = live.run(['curl', '--noproxy', '*', '--fail', '--silent', '--show-error',
                           '--max-time', '12', 'https://1.1.1.1/cdn-cgi/trace'], check=False)
        trace = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        success = result.returncode == 0 and bool(trace.get('ip'))
        https = https and success
        print('  HTTPS %d: %s' % (attempt + 1, 'exit=' + trace['ip'] if success else 'FAIL curl=%d' % result.returncode), flush=True)
    return direct_dns and system_dns and https


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', required=True)
    parser.add_argument('--ssh-via', required=True, help='Authorized SSH alias/user@host; TCP forwarding must be allowed')
    parser.add_argument('--preserve-route', action='append', default=[])
    parser.add_argument('--local-control-only', action='store_true',
                        help='Only direct local TCP forwarding, to control for loopback/SNI rewriting')
    parser.add_argument('hosts', nargs='+')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@-]*', args.ssh_via):
        parser.error('invalid SSH destination')
    if any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', host) for host in args.hosts):
        parser.error('hosts must be DNS hostnames')
    before = live.status()
    assert before['state'] == 'down' and not before['foreign'], 'VPN must be disconnected'
    assert not live.ZONE.exists(), 'example.com resolver already exists'
    native.helper('version')
    baseline = {target: live.route(target) for target in
                ['default', '127.0.0.1', '1.1.1.1', '8.8.8.8'] + args.preserve_route}
    label = 'gui/%d/ru.ocmac.supervisor' % os.getuid()
    loaded = subprocess.run(['launchctl', 'print', label], capture_output=True).returncode == 0
    username = getpass.getpass('VPN username (hidden): ')
    password = getpass.getpass('VPN password (hidden): ')
    env = live.test_environment(os.environ)
    env.update(OCMAC_USERNAME=username, OCMAC_PASSWORD=password, OCMAC_PROMPT_CMD='exit 3',
               OCMAC_PROMPT_TTY='0', OCMAC_PW_TIMEOUT='25')
    stopped = started = False
    results = []
    try:
        if loaded:
            native.run([live.CLI, 'supervisor', 'stop'])
            stopped = True
        assert live.status()['state'] == 'down', 'VPN changed during setup'
        for host in args.hosts:
            paths = [('direct-before', None), ('ssh-relay', args.ssh_via), ('direct-after', None),
                     ('direct-loopback-control', LOCAL_CONTROL)]
            if args.local_control_only:
                paths = paths[-1:]
            for path, via in paths:
                print('%s [%s]' % (host, path), flush=True)
                with relay(via, host) as port:
                    cookie, pin, endpoint = authenticate(host, port, username, password, env)
                    print('  authentication: normal PKI verified', flush=True)
                    log = live.STATE / 'openconnect.log'
                    offset = log.stat().st_size if log.exists() else 0
                    try:
                        started = True
                        native.helper('tunnel-start', endpoint, pin, 'split', username,
                                      input='cookie=%s\nnet 1.1.1.1/32\nnet 8.8.8.8/32\nzone example.com vpn 53\nnodtls\n' % cookie)
                        del cookie
                        results.append((host, path, traffic()))
                    finally:
                        if started:
                            native.helper('tunnel-stop')
                            started = False
                        data = log.read_bytes()
                        for line in data[offset if len(data) >= offset else 0:].decode(errors='replace').splitlines():
                            if 'Configured as' in line or 'with ciphersuite' in line:
                                print('  transport: ' + line.replace(username, '[user]').replace(password, '[password]'), flush=True)
                        assert not live.ZONE.exists(), 'test resolver left behind'
                        for target, expected in baseline.items():
                            assert live.route(target) == expected, 'route changed: ' + target
                print('  tunnel/forwarding cleanup OK', flush=True)
    finally:
        try:
            if started:
                native.helper('tunnel-stop')
            assert not live.ZONE.exists()
            for target, expected in baseline.items():
                assert live.route(target) == expected, 'route left after test: ' + target
        finally:
            if stopped:
                native.run([live.CLI, 'supervisor', 'start'])
                native.run(['launchctl', 'print', label])
                print('Original supervisor restored', flush=True)
    for host, path, passed in results:
        print('%s [%s]: %s' % (host, path, 'PASS' if passed else 'FAIL'), flush=True)
    raise SystemExit(0 if all(passed for _, _, passed in results) else 1)


if __name__ == '__main__':
    main()
