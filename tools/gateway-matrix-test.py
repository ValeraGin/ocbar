#!/usr/bin/env python3
"""Synthetic AnyConnect SSO gateways over real local TLS + WebKit.

These are protocol variants, not emulations certified against vendor firmware.
No VPN tunnel, user profiles, credentials or external servers are used.
"""
import argparse
from contextlib import contextmanager
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
CASES = ('sso', 'custom-cookie', 'nested-hash', 'get-redirect', 'post-redirect',
         'reply-redirect', 'reply-host-redirect', 'client-cert-fallback', 'init-error', 'reply-error',
         'password-form', 'missing-cookie-name', 'malformed-xml', 'http-503',
         'redirect-loop', 'https-downgrade', 'untrusted-tls')
FAILURES = {
    'init-error': 'POLICY_DENIED', 'reply-error': 'ACCESS_DENIED',
    'password-form': 'username/password', 'missing-cookie-name': 'sso-v2-token-cookie-name',
    'malformed-xml': 'XML', 'http-503': 'HTTP 503',
    'redirect-loop': 'редирект', 'https-downgrade': 'незащищённый',
    'untrusted-tls': None,
}


@contextmanager
def gateway(case, context, connections=None, hostname="localhost"):
    events, errors = [], []
    nonce = uuid.uuid4().hex
    cookie = ('enterpriseTicket' if case == 'custom-cookie' else 'ssoToken') + nonce
    token = 'SSO_' + nonce
    opaque = '<opaque is-for="sg"><tunnel-group>LAB</tunnel-group><nonce>keep&amp;return</nonce></opaque>'

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, code, body=b'', headers=()):
            if isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            for key, value in headers:
                self.send_header(key, value)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if connections is not None:
                connections.append(self.client_address[1])
            events.append(('GET', self.path))
            if self.path == '/group' and case == 'get-redirect':
                return self.send(302, headers=[('Location', '/node')])
            if case == 'redirect-loop':
                return self.send(302, headers=[('Location', '/group')])
            if case == 'https-downgrade':
                return self.send(302, headers=[('Location', f'http://localhost:{self.server.server_port}/plain')])
            if self.path == '/sso':
                return self.send(302, headers=[('Set-Cookie', f'{cookie}={token}; Path=/; Secure'),
                                               ('Location', '/final')])
            self.send(200, '<html>local gateway</html>')

        def do_POST(self):
            if connections is not None:
                connections.append(self.client_address[1])
            try:
                self.post()
            except Exception as error:
                errors.append(repr(error))
                self.send(500, 'fixture assertion failed')

        def post(self):
            data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            xml = ET.fromstring(data)
            kind = xml.get('type')
            events.append((kind, self.path))
            base = f'https://{hostname}:{self.server.server_port}'
            if kind == 'init':
                assert xml.findtext('group-access') == base + '/group'
                if case == 'http-503':
                    return self.send(503, 'unavailable')
                if case == 'malformed-xml':
                    return self.send(200, 'not XML')
                if case == 'init-error':
                    return self.send(200, '<config-auth><auth><error>POLICY_DENIED</error></auth></config-auth>')
                if case == 'password-form':
                    return self.send(200, '<config-auth><auth><form><input name="username"/><input name="password"/></form></auth></config-auth>')
                if case == 'client-cert-fallback' and xml.find('client-cert-fail') is None:
                    return self.send(200, '<config-auth><client-cert-request/></config-auth>')
                if case == 'post-redirect' and self.path == '/group':
                    return self.send(307, headers=[('Location', '/node')])
                field = '' if case == 'missing-cookie-name' else f'<sso-v2-token-cookie-name>{cookie}</sso-v2-token-cookie-name>'
                # Deliberately place a different opaque first to detect taking the wrong one.
                return self.send(200, f'''<?xml version="1.0"?><config-auth type="auth-request">
<opaque is-for="other"><nonce>wrong</nonce></opaque>{opaque}
<auth><sso-v2-login>{base}/sso</sso-v2-login>
<sso-v2-login-final>{base}/final</sso-v2-login-final>{field}</auth></config-auth>''')
            assert kind == 'auth-reply'
            assert xml.findtext('auth/sso-token') == token
            assert xml.findtext('opaque/nonce') == 'keep&return'
            assert xml.find('opaque').get('is-for') == 'sg'
            assert xml.find('host-scan-token') is None
            if case == 'reply-error':
                return self.send(200, '<config-auth><error>ACCESS_DENIED</error></config-auth>')
            if case in ('reply-redirect', 'reply-host-redirect') and self.path != '/session-node':
                destination = '/session-node' if case == 'reply-redirect' else f'https://127.0.0.1:{self.server.server_port}/session-node'
                return self.send(302, headers=[('Location', destination)])
            hash_xml = '<server-cert-hash>HASH</server-cert-hash>'
            if case == 'nested-hash':
                hash_xml = '<config><vpn-base-config>' + hash_xml + '</vpn-base-config></config>'
            self.send(200, '<config-auth type="complete"><session-token>SESSION</session-token>' + hash_xml + '</config-auth>')

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port, events, errors
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def check(case, client, context):
    with gateway(case, context) as (port, events, errors):
        env = {k: v for k, v in os.environ.items() if not k.startswith('OCBAR_')}
        env['OCBAR_LANG'] = 'ru'
        command = [str(client), '--url', f'https://localhost:{port}/group',
                   '--no-autofill', '--no-window', '--timeout', '12', '--show-after', '30']
        if case != 'untrusted-tls':
            command.append('--insecure')
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=25)
        assert not errors, errors
        if case in FAILURES:
            assert result.returncode != 0, f'{case}: unexpectedly succeeded'
            assert not result.stdout.strip(), f'{case}: unexpected session'
            reason = FAILURES[case]
            assert reason is None or reason in result.stderr, result.stderr
            assert not any(kind == 'auth-reply' for kind, _ in events) or case == 'reply-error'
            if case == 'untrusted-tls':
                assert not events, 'untrusted TLS must fail before HTTP'
        else:
            assert result.returncode == 0, result.stderr
            reply = json.loads(result.stdout)
            assert reply['session_token'] == 'SESSION'
            assert reply['server_cert_hash'] == 'HASH'
            path = '/session-node' if case in ('reply-redirect', 'reply-host-redirect') else '/node' if case in ('get-redirect', 'post-redirect') else '/group'
            host = '127.0.0.1' if case == 'reply-host-redirect' else 'localhost'
            assert reply['post_url'] == f'https://{host}:{port}{path}', reply
            assert reply['host'] == host, reply
            assert ('GET', '/sso') in events, 'must complete this fixture SSO, not reuse an old token'
            if case == 'client-cert-fallback':
                assert sum(kind == 'init' for kind, _ in events) == 2, events
        print(f'gateway-matrix ({case}): OK', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', type=Path, default=ROOT / 'auth/.build/release/ocbar-auth')
    parser.add_argument('--case', action='append', choices=CASES)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ocbar-gateways-') as directory:
        tmp = Path(directory)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(tmp / 'key.pem'), '-out', str(tmp / 'cert.pem'),
                        '-days', '1', '-subj', '/CN=localhost'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(tmp / 'cert.pem'), str(tmp / 'key.pem'))
        failed = []
        for case in args.case or CASES:
            try:
                check(case, args.client, context)
            except (AssertionError, subprocess.TimeoutExpired) as error:
                failed.append(case)
                print(f'gateway-matrix ({case}): FAIL: {error}', flush=True)
        if failed:
            raise SystemExit('Failed: ' + ', '.join(failed))


if __name__ == '__main__':
    main()
