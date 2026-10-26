#!/usr/bin/env python3
"""Local HTTP CONNECT/SOCKS5 relay tests for real URLSession and WebKit.

Only synthetic gateways and loopback sockets; no VPN routes or personal data.
Every TLS connection reaching the gateway must have come from the relay.
"""
import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('gateways', Path(__file__).with_name('gateway-matrix-test.py'))
gateways = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateways)


@contextmanager
def relay(scheme, target_port, deny=lambda: False):
    ports, requests, errors = set(), [], []

    class Handler(socketserver.StreamRequestHandler):
        def exact(self, size):
            data = self.rfile.read(size)
            if len(data) != size:
                raise EOFError()
            return data

        def handle(self):
            try:
                self.connection.settimeout(15)
                if scheme == 'http':
                    method, authority, _ = self.rfile.readline().decode().split()
                    while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                        pass
                    assert method == 'CONNECT', method
                    host, port = authority.rsplit(':', 1)
                    port = int(port)
                else:
                    version, count = self.exact(2)
                    assert version == 5 and 0 in self.exact(count)
                    self.wfile.write(b'\x05\x00'); self.wfile.flush()
                    version, command, reserved, kind = self.exact(4)
                    assert (version, command, reserved) == (5, 1, 0)
                    if kind == 1:
                        host = socket.inet_ntoa(self.exact(4))
                    elif kind == 3:
                        host = self.exact(self.exact(1)[0]).decode()
                    elif kind == 4:
                        host = socket.inet_ntop(socket.AF_INET6, self.exact(16))
                    else:
                        raise AssertionError(kind)
                    port = struct.unpack('!H', self.exact(2))[0]
                # Never turn this test into an open proxy for arbitrary addresses.
                assert host in ('upstream-gateway.invalid',) and port == target_port, (host, port)
                requests.append((host, port))
                if deny():
                    self.wfile.write(b'HTTP/1.1 502 Unavailable\r\nContent-Length: 0\r\n\r\n' if scheme == 'http'
                                     else b'\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00')
                    self.wfile.flush()
                    return
                with socket.create_connection(('127.0.0.1', target_port), timeout=10) as upstream:
                    ports.add(upstream.getsockname()[1])
                    self.wfile.write(b'HTTP/1.1 200 Connection Established\r\n\r\n' if scheme == 'http'
                                     else b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
                    self.wfile.flush()
                    while True:
                        ready, _, _ = select.select([self.connection, upstream], [], [], 15)
                        if not ready:
                            return
                        for source in ready:
                            data = source.recv(65536)
                            if not data:
                                return
                            (upstream if source is self.connection else self.connection).sendall(data)
            except (EOFError, ConnectionError, TimeoutError):
                pass
            except Exception as error:
                errors.append(repr(error))

    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True
    server = Server(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'{scheme}://127.0.0.1:{server.server_address[1]}', ports, requests, errors
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)


def check(client, context, scheme, stage):
    connections = []
    with gateways.gateway('sso', context, connections=connections, hostname='upstream-gateway.invalid') as (port, events, errors):
        def deny():
            return stage == 'http-failure' or (stage == 'web-failure' and any(k == 'init' for k, _ in events))
        with relay(scheme, port, deny) as (proxy, relayed, requests, proxy_errors):
            env = {k: v for k, v in os.environ.items() if not k.startswith('OCMAC_') and not k.lower().endswith('_proxy')}
            # Explicit profile proxy must win even over NO_PROXY=*.
            env.update(OCMAC_LANG='ru', NO_PROXY='*', no_proxy='*')
            result = subprocess.run([str(client), '--url', f'https://upstream-gateway.invalid:{port}/group',
                                     '--upstream-proxy', proxy, '--insecure', '--no-autofill', '--no-window',
                                     '--timeout', '8', '--show-after', '30'],
                                    env=env, capture_output=True, text=True, timeout=30)
            assert not errors and not proxy_errors, (errors, proxy_errors)
            assert requests, 'proxy was never contacted: ' + result.stderr
            assert set(connections) <= relayed, 'direct connection bypassed the explicit proxy'
            if stage == 'success':
                assert result.returncode == 0, result.stderr
                assert json.loads(result.stdout)['session_token'] == 'SESSION'
                assert ('GET', '/sso') in events and ('auth-reply', '/group') in events, events
            else:
                assert result.returncode != 0 and not result.stdout.strip(), result.stderr
                assert not any(k == 'auth-reply' for k, _ in events), events
                if stage == 'http-failure':
                    assert not events, events
                else:
                    assert any(k == 'init' for k, _ in events) and ('GET', '/sso') not in events, events
            print(f'upstream ({scheme}, {stage}): OK; proxied TLS connections={len(relayed)}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', type=Path, default=ROOT / 'auth/.build/release/ocmac-auth')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ocmac-upstream-') as directory:
        tmp = Path(directory)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(tmp/'key.pem'), '-out', str(tmp/'cert.pem'),
                        '-days', '1', '-subj', '/CN=localhost'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(tmp/'cert.pem'), str(tmp/'key.pem'))
        for scheme in ('http', 'socks5'):
            for stage in ('success', 'http-failure', 'web-failure'):
                check(args.client, context, scheme, stage)


if __name__ == '__main__':
    main()
