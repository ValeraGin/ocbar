#!/usr/bin/env python3
"""Opt-in installed macOS helper test against disposable local ocserv servers.

Changes only the route to 192.0.2.1 and the native.lab.test split-DNS resolver.
Uses synthetic credentials and an explicit temporary CA for authentication,
then passes the verified session/pin to the installed helper. This does not
claim profile support for private CAs. Requires Docker and a disconnected VPN.
"""
import argparse
import hashlib
import importlib.util
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


lab = module('ocserv_lab', 'ocserv-integration-test.py')
live = module('macos_live', 'macos-vpn-test.py')
ZONE = Path('/etc/resolver/native.lab.test')
ADDRESS = '192.0.2.1'
PAYLOAD = bytes(range(256)) * 4096
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()


def run(command, timeout=40, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, check=True, timeout=timeout, **kwargs)


def helper(*args, **kwargs):
    return run(['sudo', '-n', live.HELPER, *args], **kwargs)


def wait_connected(previous=None):
    for _ in range(100):
        state = live.tunnel_env()
        if state.get('STATE') == 'connected' and (previous is None or
                (state.get('REASON') == 'reconnect' and state.get('CONNECTED') != previous)):
            return state
        time.sleep(.2)
    raise AssertionError('helper did not complete connection/reconnection')


def traffic(tmp, phase):
    state = wait_connected()
    assert live.route(ADDRESS)['interface'] == state['TUNDEV'], 'test route bypasses VPN'
    assert ZONE.exists() and 'nameserver ' + ADDRESS in ZONE.read_text(), 'split DNS missing'
    answer = run(['dig', '@' + ADDRESS, 'app.native.lab.test', '+short', '+time=3', '+tries=1']).stdout
    assert ADDRESS in answer.splitlines(), 'direct VPN DNS failed'
    # macOS watches resolver files asynchronously after resume/reconnect.
    began = time.monotonic()
    for attempt in range(10):
        remaining = 5 - (time.monotonic() - began)
        if remaining <= 0:
            raise AssertionError('macOS split DNS did not become ready within 5 seconds')
        try:
            answer = run(['dscacheutil', '-q', 'host', '-a', 'name',
                          '%s-%d-%d.native.lab.test' % (phase, time.time_ns(), attempt)],
                         timeout=min(2, remaining)).stdout
        except subprocess.TimeoutExpired:
            answer = ''
        if 'ip_address: ' + ADDRESS in answer:
            break
        time.sleep(min(.5, max(0, 5 - (time.monotonic() - began))))
    else:
        raise AssertionError('macOS split DNS did not become ready within 5 seconds')
    print('  macOS resolver ready after %.1fs' % (time.monotonic() - began), flush=True)
    for scheme, port in [('http', 8080), ('https', 8443)]:
        result = subprocess.run(['curl', '--noproxy', '*', '--fail', '--silent', '--show-error',
                                 '--max-time', '15', '--cacert', str(tmp / 'cert.pem'),
                                 '%s://%s:%d/payload.bin' % (scheme, ADDRESS, port)],
                                capture_output=True, timeout=20)
        assert result.returncode == 0, '%s: %s' % (scheme, result.stderr.decode(errors='replace'))
        assert hashlib.sha256(result.stdout).hexdigest() == DIGEST, 'payload corrupted or truncated'
    print('  %s: %s MTU=%s; VPN/macOS DNS + HTTP/HTTPS 1 MiB hashes OK' %
          (phase, state['TUNDEV'], state['MTU']), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', required=True)
    parser.add_argument('--image', action='append', help='Repeat to test multiple ocserv images')
    parser.add_argument('--compression', action='append', choices=('none', 'lzs'))
    parser.add_argument('--tls', choices=('1.2', '1.3'), help='Require this outer VPN TLS version')
    parser.add_argument('--preserve-route', action='append', default=[])
    args = parser.parse_args()
    before = live.status()
    assert before['state'] == 'down' and not before['foreign'], 'VPN must be disconnected'
    assert not ZONE.exists(), 'test resolver already exists'
    helper('version')
    baseline = {ip: live.route(ip) for ip in ['default', ADDRESS, '127.0.0.1', '1.1.1.1'] + args.preserve_route}
    assert baseline[ADDRESS] == baseline['default'], 'test resource already has a specific route'
    label = 'gui/%d/ru.ocmac.supervisor' % os.getuid()
    loaded = subprocess.run(['launchctl', 'print', label], capture_output=True).returncode == 0
    stopped = False
    started = False
    env = live.test_environment(os.environ)
    env.update(OCMAC_USERNAME='lab-user', OCMAC_PASSWORD='lab-password',
               OCMAC_PROMPT_CMD='exit 3', OCMAC_PROMPT_TTY='0', OCMAC_PW_TIMEOUT='25')
    original_config = lab.CONFIG
    try:
        if loaded:
            run([live.CLI, 'supervisor', 'stop'])
            stopped = True
        assert live.status()['state'] == 'down', 'VPN state changed during setup'
        for image in args.image or ['ocmac-test-ocserv:bookworm', 'ocmac-test-ocserv:trixie']:
            for compression in args.compression or ['none', 'lzs']:
                with tempfile.TemporaryDirectory(prefix='ocmac-native-lab-') as directory:
                    tmp = Path(directory)
                    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                         '-keyout', str(tmp / 'key.pem'), '-out', str(tmp / 'cert.pem'),
                         '-days', '1', '-subj', '/CN=localhost',
                         '-addext', 'basicConstraints=critical,CA:TRUE',
                         '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:192.0.2.1'])
                    (tmp / 'otp.db').write_text('')
                    (tmp / 'payload.bin').write_bytes(PAYLOAD)
                    (tmp / 'https.py').write_text('''import http.server,ssl
server=http.server.ThreadingHTTPServer(('0.0.0.0',8443),http.server.SimpleHTTPRequestHandler)
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('/lab/cert.pem','/lab/key.pem')
server.socket=ctx.wrap_socket(server.socket,server_side=True)
server.serve_forever()
''')
                    lab.CONFIG = original_config + '\ncompression = %s\n' % ('true' if compression == 'lzs' else 'false')
                    if args.tls:
                        lab.CONFIG += 'tls-priorities = "NORMAL:%SERVER_PRECEDENCE:-VERS-ALL:+VERS-TLS' + args.tls + '"\n'
                    with lab.server(image, tmp, 'password', debug=True) as (name, port, _):
                        version = run(['docker', 'exec', name, 'ocserv', '--version'])
                        print('%s; compression=%s' % ((version.stdout + version.stderr).splitlines()[0], compression), flush=True)
                        run(['docker', 'exec', name, 'cp', '/lab/payload.bin', '/tmp/web/payload.bin'])
                        run(['docker', 'exec', '-d', '-w', '/lab', name, 'python3', '/lab/https.py'])
                        url = 'https://127.0.0.1:%d' % port
                        auth = run(['python3', str(ROOT / 'libexec/ocmac-pwauth.py'), shutil.which('openconnect'),
                                    '--authenticate', '--protocol=anyconnect', '--no-proxy', '--os=mac-intel',
                                    '--user=lab-user', '--cafile', str(tmp / 'cert.pem'), url], env=env)
                        cookie, pin, endpoint = auth.stdout.strip().rsplit(' ', 2)
                        assert pin.startswith(('pin-sha256:', 'sha256:')) and endpoint.startswith(url)
                        log_path = live.STATE / 'openconnect.log'
                        log_offset = log_path.stat().st_size if log_path.exists() else 0
                        try:
                            started = True
                            helper('tunnel-start', endpoint, pin, 'split', 'lab-user',
                                   input='cookie=%s\nnet %s/32\nzone native.lab.test vpn 53\nnodtls\n' % (cookie, ADDRESS))
                            del cookie
                            wait_connected()
                            for _ in range(30):
                                data = log_path.read_bytes()
                                diagnostics = data[log_offset if len(data) >= log_offset else 0:].decode(errors='replace')
                                if 'Configured as' in diagnostics:
                                    break
                                time.sleep(.1)
                            negotiated = re.search(r'with ciphersuite \(TLS([0-9.]+)\)', diagnostics)
                            assert negotiated, 'VPN TLS version missing from current connection log'
                            if args.tls:
                                assert negotiated.group(1) == args.tls, 'unexpected VPN TLS version'
                            print('  outer VPN TLS ' + negotiated.group(1), flush=True)
                            if compression == 'lzs':
                                assert 'SSL + LZS connected' in diagnostics, 'LZS not negotiated'
                            else:
                                assert 'SSL connected' in diagnostics, 'uncompressed TLS not negotiated'
                            traffic(tmp, 'connect')
                            helper('suspend')
                            assert not ZONE.exists() and live.route(ADDRESS) == baseline[ADDRESS], 'pause cleanup failed'
                            helper('resume')
                            traffic(tmp, 'resume')
                            connected = live.tunnel_env()['CONNECTED']
                            time.sleep(1)
                            helper('reconnect-now')
                            wait_connected(connected)
                            traffic(tmp, 'reconnect')
                            access = run(['docker', 'exec', name, 'cat', '/tmp/http.log']).stdout
                            assert access.count('GET /payload.bin HTTP/1.1" 200') == 3, 'server did not observe all HTTP probes'
                            print('  server HTTP log: all 3 requests returned 200', flush=True)
                        finally:
                            if started:
                                helper('tunnel-stop')
                                started = False
                            logs = run(['docker', 'logs', name])
                            for line in (logs.stdout + logs.stderr).splitlines()[-20:]:
                                print('  server: ' + line, flush=True)
                            assert not ZONE.exists(), 'test resolver left behind'
                            for target, expected in baseline.items():
                                assert live.route(target) == expected, 'route changed: ' + target
                        print('  disconnect: routes/resolver restored', flush=True)
    finally:
        lab.CONFIG = original_config
        try:
            if started:
                helper('tunnel-stop')
            assert not ZONE.exists(), 'resolver left after test'
            for target, expected in baseline.items():
                assert live.route(target) == expected, 'route left after test: ' + target
        finally:
            if stopped:
                run([live.CLI, 'supervisor', 'start'])
                run(['launchctl', 'print', label])
                print('Original supervisor restored', flush=True)
    print('Native helper lab passed; original routes restored', flush=True)


if __name__ == '__main__':
    main()
