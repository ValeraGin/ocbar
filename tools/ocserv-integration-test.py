#!/usr/bin/env python3
"""Real ocserv + OpenConnect: authentication and isolated container tunnel.

Build tools/server-lab first. All accounts/certificates are disposable. The
production password driver is exercised directly; host VPN routes are untouched.
"""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
LAB = ROOT / 'tools/server-lab'
CONFIG = '''auth = "plain[passwd=/tmp/ocpasswd]"
tcp-port = 443
udp-port = 443
run-as-user = nobody
run-as-group = nogroup
socket-file = /tmp/ocserv-socket
server-cert = /lab/cert.pem
server-key = /lab/key.pem
isolate-workers = false
max-clients = 32
max-same-clients = 32
try-mtu-discovery = false
device = vpns
ipv4-network = 192.0.2.0
ipv4-netmask = 255.255.255.0
dns = 192.0.2.1
route = 192.0.2.0/255.255.255.0
cisco-client-compat = true
'''


def run(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=60, **kw)


@contextmanager
def server(image, tmp, mode, debug=False):
    name = 'ocbar-lab-' + uuid.uuid4().hex[:12]
    network = name + '-net'
    config = CONFIG
    if mode == 'groups':
        config += 'select-group = employees\nselect-group = contractors\n'
    elif mode == 'otp':
        config = config.replace('passwd=/tmp/ocpasswd]', 'passwd=/tmp/ocpasswd,otp=/tmp/otp.db]')
    elif mode == 'certificate':
        config = config.replace('auth = "plain[passwd=/tmp/ocpasswd]"', 'auth = "certificate"')
        config += 'ca-cert = /lab/cert.pem\ncert-user-oid = 2.5.4.3\n'
    (tmp / 'ocserv.conf').write_text(config)
    if debug:
        (tmp / 'debug-start.sh').write_text((LAB / 'start.sh').read_text().replace(
            'exec ocserv -f', 'exec ocserv -d 1 -f'))
    run('docker', 'network', 'create', network)
    try:
        run('docker', 'run', '-d', '--rm', '--name', name,
            '--network', network, '--network-alias=gateway',
            '--cap-add=NET_ADMIN', '--device=/dev/net/tun', '-e', 'LAB_TRAFFIC=1',
            '-p', '127.0.0.1::443', '-v', f'{tmp}:/lab:ro',
            *(['--entrypoint', '/bin/sh'] if debug else []), image,
            *(['/lab/debug-start.sh'] if debug else []))
        port = int(run('docker', 'port', name, '443/tcp').stdout.strip().rsplit(':', 1)[1])
        for _ in range(60):
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.5):
                    break
            except OSError:
                time.sleep(.2)
        else:
            raise AssertionError('ocserv did not start: ' + run('docker', 'logs', name).stderr)
        yield name, port, network
    finally:
        subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=20)
        subprocess.run(['docker', 'network', 'rm', network], capture_output=True, timeout=20)


def auth_case(name, command, password='lab-password', answer='exit 3', expected=0, reason=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith('OCBAR_')}
    env.update(OCBAR_PASSWORD=password, OCBAR_USERNAME='lab-user',
               OCBAR_PROMPT_CMD=answer, OCBAR_PROMPT_TTY='0', OCBAR_PW_TIMEOUT='25')
    result = subprocess.run(['python3', str(ROOT / 'libexec/ocbar-pwauth.py'), *command],
                            env=env, capture_output=True, text=True, timeout=35)
    assert result.returncode == expected, f'{name}: exit {result.returncode}: {result.stderr}'
    assert 'lab-password' not in result.stderr, f'{name}: password in log'
    assert reason is None or reason in result.stderr, f'{name}: missing expected reason: {result.stderr}'
    if expected == 0:
        cookie, fingerprint, url = result.stdout.strip().rsplit(' ', 2)
        assert cookie and fingerprint.startswith(('sha256:', 'pin-sha256:', 'sha1:'))
        assert url.startswith(command[-1]), url
    else:
        assert not result.stdout.strip(), f'{name}: unexpected session on failure'
    print(f'ocserv ({name}): OK', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', default='ocbar-test-ocserv:bookworm')
    parser.add_argument('--openconnect', default=shutil.which('openconnect'))
    parser.add_argument('--mode', action='append', choices=['password', 'groups', 'otp', 'certificate'])
    args = parser.parse_args()
    if not args.openconnect:
        parser.error('openconnect is required')
    with tempfile.TemporaryDirectory(prefix='ocbar-ocserv-') as directory:
        tmp = Path(directory)
        run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(tmp / 'key.pem'), '-out', str(tmp / 'cert.pem'),
            '-days', '1', '-subj', '/CN=localhost',
            '-addext', 'basicConstraints=critical,CA:TRUE',
            '-addext', 'subjectAltName=DNS:localhost,DNS:gateway,IP:127.0.0.1')
        run('openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=lab-user',
            '-keyout', str(tmp / 'client-key.pem'), '-out', str(tmp / 'client.csr'))
        (tmp / 'client.ext').write_text('basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\n')
        run('openssl', 'x509', '-req', '-in', str(tmp / 'client.csr'),
            '-CA', str(tmp / 'cert.pem'), '-CAkey', str(tmp / 'key.pem'), '-CAcreateserial',
            '-out', str(tmp / 'client.pem'), '-days', '1', '-extfile', str(tmp / 'client.ext'))
        # Public RFC 6238 test secret, never a personal OTP seed.
        (tmp / 'otp.db').write_text('HOTP/T30/6 lab-user - 3132333435363738393031323334353637383930\n')
        (tmp / 'otp.py').write_text('''import hashlib,hmac,struct,time,os
from pathlib import Path
Path(__file__).with_suffix('.called').touch()
assert os.environ['OCBAR_PROMPT_SECRET'] == '1'
b = hmac.new(b'12345678901234567890', struct.pack('!Q', int(time.time())//30), hashlib.sha1).digest()
p = b[-1] & 15
print('%06d' % ((struct.unpack('!I',b[p:p+4])[0] & 0x7fffffff) % 1000000))
''')
        shutil.copy2(LAB / 'tunnel-script.sh', tmp / 'tunnel-script.sh')
        for mode in args.mode or ['password', 'groups', 'otp', 'certificate']:
            with server(args.image, tmp, mode) as (name, port, network):
                if mode == 'password':
                    v = run('docker', 'exec', name, 'ocserv', '--version')
                    print((v.stdout + v.stderr).splitlines()[0], flush=True)
                command = [args.openconnect, '--authenticate', '--protocol=anyconnect',
                           '--os=mac-intel', '--user=lab-user', '--no-proxy',
                           '--cafile', str(tmp / 'cert.pem'), f'https://localhost:{port}']
                if mode == 'password':
                    auth_case('stored-password', command)
                    auth_case('manual-password', command, password='', answer='printf %s lab-password')
                    auth_case('wrong-password-then-cancel', command, password='wrong-lab-password', expected=3)
                    auth_case('cancel-password', command, password='', expected=3)
                    auth_case('untrusted-certificate', command[:-3] + command[-1:], expected=1)
                    for transport in ('cstp', 'dtls'):
                        client = name + '-client'
                        try:
                            r = run('docker', 'run', '--rm', '--name', client, '--network', network,
                                    '--cap-add=NET_ADMIN', '--device=/dev/net/tun', '--entrypoint=python3',
                                    '-v', f'{tmp}:/lab:ro', '-v', f'{LAB}:/test-lab:ro',
                                    '-v', f'{ROOT / "libexec/ocbar-pwauth.py"}:/test/ocbar-pwauth.py:ro',
                                    args.image, '/test-lab/tunnel-client.py', transport)
                            print(r.stdout.strip(), flush=True)
                        except subprocess.CalledProcessError as error:
                            raise AssertionError('container tunnel: ' + error.stderr) from error
                        finally:
                            subprocess.run(['docker', 'rm', '-f', client], capture_output=True, timeout=20)
                elif mode == 'groups':
                    auth_case('group-choice-refused-without-selection', command, expected=1, reason='шлюз просит выбрать группу')
                    auth_case('explicit-group', command[:-1] + ['--authgroup=employees', command[-1]])
                elif mode == 'otp':
                    auth_case('password-and-TOTP', command, answer='python3 ' + shlex.quote(str(tmp / 'otp.py')))
                    assert (tmp / 'otp.called').exists(), 'server must ask for OTP'
                    auth_case('cancel-TOTP', command, expected=3)
                else:
                    auth_case('client-certificate', command[:-1] + ['-c', str(tmp / 'client.pem'), '-k', str(tmp / 'client-key.pem'), command[-1]])
                    auth_case('missing-client-certificate', command, expected=1)


if __name__ == '__main__':
    main()
