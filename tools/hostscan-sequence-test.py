#!/usr/bin/env python3
"""Exercise the real auth client against a local TLS gateway fixture."""
import http.server
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
CLIENT = ROOT / 'auth/.build/release/ocbar-auth'


def check():
    with tempfile.TemporaryDirectory(prefix='ocbar-hostscan-') as tmp:
        tmp = Path(tmp)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(tmp / 'key.pem'), '-out', str(tmp / 'cert.pem'),
                        '-days', '1', '-subj', '/CN=localhost'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pin = subprocess.run(['openssl', 'x509', '-in', str(tmp / 'cert.pem'), '-pubkey', '-noout'],
                             check=True, capture_output=True).stdout
        key = subprocess.run(['openssl', 'pkey', '-pubin', '-outform', 'DER'], input=pin,
                             check=True, capture_output=True).stdout
        import base64, hashlib
        expected_pin = base64.b64encode(hashlib.sha256(key).digest()).decode()
        events = []
        state = {'scanned': False, 'waits': 0, 'inits': 0}

        class Gateway(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def respond(self, status, body=b'', headers=()):
                self.send_response(status)
                for key, value in headers:
                    self.send_header(key, value)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                path = urlparse(self.path).path
                if path == '/group':
                    events.append('resolve')
                    self.respond(200, b'gateway')
                elif path == '/+CSCOE+/sdesktop/token.xml':
                    events.append('token')
                    self.respond(200, b'<hostscan><token>SCAN_TOKEN</token></hostscan>')
                elif path == '/+CSCOE+/sdesktop/wait.html':
                    assert self.headers.get('Cookie') == 'sdesktop=HS_TOKEN'
                    assert state['scanned']
                    state['waits'] += 1
                    events.append('wait')
                    if state['waits'] == 1:
                        self.respond(200, b'<html><meta http-equiv="refresh" content="1"></html>')
                    else:
                        self.respond(302, headers=[('Location', '/group')])
                elif path == '/sso':
                    events.append('sso')
                    self.respond(302, headers=[('Set-Cookie', 'ssoToken=SSO_TOKEN; Path=/; Secure'),
                                               ('Location', '/final')])
                elif path == '/final':
                    events.append('final')
                    self.respond(200, b'<html>done</html>')
                else:
                    self.respond(404)

            def do_POST(self):
                path = urlparse(self.path).path
                data = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                if path == '/+CSCOE+/sdesktop/scan.xml':
                    assert b'endpoint.os.version=' in data
                    assert self.headers.get('Cookie') == 'sdesktop=SCAN_TOKEN'
                    state['scanned'] = True
                    events.append('scan')
                    self.respond(200, b'<hostscan><status>TOKEN_SUCCESS</status></hostscan>')
                elif path == '/group' and b'type="init"' in data:
                    state['inits'] += 1
                    if state['inits'] == 2:
                        assert self.headers.get('Cookie') == 'sdesktop=HS_TOKEN'
                        assert state['waits'] == 2
                    events.append('init')
                    base = f'https://localhost:{self.server.server_port}'
                    body = f'''<?xml version="1.0"?><config-auth type="auth-request">
                    <opaque is-for="sg"><tunnel-group>TEST</tunnel-group></opaque>
                    <auth id="main"><sso-v2-login>{base}/sso</sso-v2-login>
                    <sso-v2-login-final>{base}/final</sso-v2-login-final>
                    <sso-v2-token-cookie-name>ssoToken</sso-v2-token-cookie-name></auth>
                    <host-scan><host-scan-ticket>HS_TICKET</host-scan-ticket>
                    <host-scan-token>HS_TOKEN</host-scan-token>
                    <host-scan-base-uri>/+CSCOE+/sdesktop/</host-scan-base-uri>
                    <host-scan-wait-uri>/+CSCOE+/sdesktop/wait.html</host-scan-wait-uri></host-scan>
                    </config-auth>'''.encode()
                    self.respond(200, body)
                elif path == '/group' and b'type="auth-reply"' in data:
                    assert state['inits'] == 2 and b'SSO_TOKEN' in data
                    assert self.headers.get('Cookie') == 'sdesktop=HS_TOKEN'
                    events.append('reply')
                    self.respond(200, b'''<?xml version="1.0"?><config-auth type="complete">
                        <session-token>SESSION</session-token><server-cert-hash>HASH</server-cert-hash>
                        </config-auth>''')
                else:
                    self.respond(404)

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(tmp / 'cert.pem'), str(tmp / 'key.pem'))
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        wrapper = tmp / 'wrapper.sh'
        wrapper.write_text('''#!/bin/bash
[ "$1" = "" ] || exit 13
shift
while [ "$1" ]; do
  if [ "$1" = -ticket ]; then shift; [ "$1" = HS_TICKET ] || exit 8; fi
  shift
done
[ "$CSD_TOKEN" = HS_TOKEN ] || exit 9
[ "$CSD_HOSTNAME" = localhost ] || exit 10
[ "$CSD_SHA256" = "$OCBAR_EXPECTED_PIN" ] || exit 12
base="https://$CSD_HOSTNAME:${OCBAR_FIXTURE_PORT}/+CSCOE+/sdesktop"
token=$(curl -ks "$base/token.xml?ticket=HS_TICKET&stub=0" | sed -n 's/.*<token>\\(.*\\)<\\/token>.*/\\1/p')
[ "$token" = SCAN_TOKEN ] || exit 11
printf 'endpoint.os.version="test";\\n' | curl -ks -H "Cookie: sdesktop=$token" --data-binary @- "$base/scan.xml?reusebrowser=1"
''')
        wrapper.chmod(0o755)
        env = dict(os.environ, OCBAR_FIXTURE_PORT=str(server.server_port), OCBAR_EXPECTED_PIN=expected_pin)
        try:
            result = subprocess.run([str(CLIENT), '--url', f'https://localhost:{server.server_port}/group',
                                     '--csd-wrapper', str(wrapper), '--insecure', '--no-window',
                                     '--timeout', '15', '--show-after', '30'],
                                    env=env, capture_output=True, text=True, timeout=35)
        finally:
            server.shutdown()
            thread.join(timeout=2)
        expected = ['resolve', 'init', 'token', 'scan', 'wait', 'wait', 'resolve', 'init', 'sso', 'final', 'reply']
        assert events == expected, f'events: {events}; stderr: {result.stderr}'
        assert result.returncode == 0, result.stderr
        assert '"session_token":"SESSION"' in result.stdout, result.stdout
        print('hostscan-sequence-test: OK')


if __name__ == '__main__':
    check()
