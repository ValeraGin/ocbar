#!/usr/bin/env python3
"""Inside a disposable client container: auth, CSTP tunnel, HTTP and DNS."""
import os
import socket
import struct
import subprocess
import time
import urllib.request
from pathlib import Path

env = dict(os.environ, OCBAR_PASSWORD='lab-password', OCBAR_USERNAME='lab-user',
           OCBAR_PROMPT_CMD='exit 3', OCBAR_PROMPT_TTY='0', OCBAR_PW_TIMEOUT='20')
url = 'https://gateway:443'
auth = subprocess.run(['python3', '/test/ocbar-pwauth.py', 'openconnect',
                       '--authenticate', '--protocol=anyconnect', '--user=lab-user',
                       '--cafile=/lab/cert.pem', '--no-proxy', url],
                      env=env, capture_output=True, text=True, timeout=30)
assert auth.returncode == 0, auth.stderr
cookie, fingerprint, _ = auth.stdout.strip().rsplit(' ', 2)
with open('/tmp/openconnect.log', 'w+') as log:
    proc = subprocess.Popen(['openconnect', '--protocol=anyconnect', '--cookie-on-stdin',
                             '--servercert', fingerprint, '--no-proxy', '--no-dtls',
                             '--interface=labtun', '--script=/lab/tunnel-script.sh', url],
                            stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
    proc.stdin.write(cookie + '\n'); proc.stdin.close()
    try:
        for _ in range(100):
            if Path('/tmp/tunnel-ready').exists():
                break
            assert proc.poll() is None, 'tunnel exited before ready'
            time.sleep(.1)
        else:
            raise AssertionError('tunnel not ready')
        route = subprocess.check_output(['ip', '-j', 'route', 'get', '192.0.2.1'], text=True)
        assert 'labtun' in route, route
        # Ignore any inherited proxy: the request must traverse the VPN.
        http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        assert http.open('http://192.0.2.1:8080/proof.txt', timeout=5).read() == b'ocbar-tunnel-proof\n'
        # Query the DNS address supplied by ocserv, inside the VPN.
        dns = Path('/tmp/tunnel-dns').read_text().strip()
        assert dns == '192.0.2.1', dns
        question = b'\x03app\x03lab\x04test\x00' + struct.pack('!HH', 1, 1)
        packet = struct.pack('!HHHHHH', 1234, 0x100, 1, 0, 0, 0) + question
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.settimeout(5); udp.sendto(packet, (dns, 53)); answer, _ = udp.recvfrom(4096)
        ident, flags, _, count, _, _ = struct.unpack('!HHHHHH', answer[:12])
        assert ident == 1234 and flags & 0x8000 and flags & 0xF == 0 and count >= 1
        assert socket.inet_aton('192.0.2.1') in answer
        print('ocserv (CSTP + route + HTTP + VPN DNS): OK', flush=True)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.wait(timeout=3)
