#!/usr/bin/env python3
"""Real ocserv + real OpenConnect, isolated password auth (no host tunnel).

Build tools/server-lab first. All accounts and certificates are disposable.
"""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kw):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=60, **kw)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', default='ocbar-test-ocserv:bookworm')
    parser.add_argument('--openconnect', default=shutil.which('openconnect'))
    args = parser.parse_args()
    if not args.openconnect:
        parser.error('openconnect is required')
    container = 'ocbar-lab-' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix='ocbar-ocserv-') as directory:
        tmp = Path(directory)
        run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(tmp / 'key.pem'), '-out', str(tmp / 'cert.pem'),
            '-days', '1', '-subj', '/CN=localhost',
            '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1')
        (tmp / 'ocserv.conf').write_text('''auth = "plain[passwd=/tmp/ocpasswd]"
tcp-port = 443
udp-port = 443
run-as-user = nobody
run-as-group = nogroup
socket-file = /tmp/ocserv-socket
server-cert = /lab/cert.pem
server-key = /lab/key.pem
isolate-workers = false
max-clients = 8
max-same-clients = 8
try-mtu-discovery = false
device = vpns
ipv4-network = 192.0.2.0
ipv4-netmask = 255.255.255.0
dns = 192.0.2.1
route = 192.0.2.0/255.255.255.0
cisco-client-compat = true
''')
        try:
            run('docker', 'run', '-d', '--rm', '--name', container,
                '--cap-add=NET_ADMIN', '--device=/dev/net/tun',
                '-p', '127.0.0.1::443', '-v', f'{tmp}:/lab:ro', args.image)
            port = int(run('docker', 'port', container, '443/tcp').stdout.strip().rsplit(':', 1)[1])
            for _ in range(60):
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.5):
                        break
                except OSError:
                    time.sleep(.2)
            else:
                raise AssertionError('ocserv did not start: ' + run('docker', 'logs', container).stderr)
            v = run('docker', 'exec', container, 'ocserv', '--version')
            version = (v.stdout + v.stderr).splitlines()[0]
            print(version, flush=True)
            command = [args.openconnect, '--authenticate', '--protocol=anyconnect',
                       '--os=mac-intel', '--user=lab-user', '--no-proxy',
                       '--cafile', str(tmp / 'cert.pem'), f'https://localhost:{port}']
            for name, password, answer, expected, trust in [
                ('stored-password', 'lab-password', 'exit 3', 0, True),
                ('manual-password', '', 'printf %s lab-password', 0, True),
                ('wrong-password-then-cancel', 'wrong-lab-password', 'exit 3', 3, True),
                ('cancel-password', '', 'exit 3', 3, True),
                ('untrusted-certificate', 'lab-password', 'exit 3', 1, False),
            ]:
                env = {k: v for k, v in os.environ.items() if not k.startswith('OCBAR_')}
                env.update(OCBAR_PASSWORD=password, OCBAR_USERNAME='lab-user',
                           OCBAR_PROMPT_CMD=answer, OCBAR_PROMPT_TTY='0', OCBAR_PW_TIMEOUT='25')
                cmd = command[:] if trust else command[:-3] + command[-1:]
                result = subprocess.run(['python3', str(ROOT / 'libexec/ocbar-pwauth.py'), *cmd],
                                        env=env, capture_output=True, text=True, timeout=35)
                assert result.returncode == expected, f'{name}: exit {result.returncode}: {result.stderr}'
                assert 'lab-password' not in result.stderr, f'{name}: password in log'
                if expected == 0:
                    cookie, fingerprint, url = result.stdout.strip().rsplit(' ', 2)
                    assert cookie and fingerprint.startswith(('sha256:', 'pin-sha256:', 'sha1:'))
                    assert url.startswith(f'https://localhost:{port}'), url
                else:
                    assert not result.stdout.strip(), f'{name}: unexpected session on failure'
                print(f'ocserv ({name}): OK', flush=True)
        finally:
            subprocess.run(['docker', 'rm', '-f', container], capture_output=True, timeout=20)


if __name__ == '__main__':
    main()
