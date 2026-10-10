#!/usr/bin/env python3
"""Opt-in external AnyConnect test: native auth and isolated Linux VPN traffic.

Requires tools/server-lab image, Docker and OpenConnect. Prompts without echo;
credentials are kept in memory and passed to the disposable container on stdin.
Only the container routes change. HTTPS probes use Cloudflare's public trace
endpoint; DNS probes query example.com via the servers supplied by the VPN.
"""
import argparse
import shutil
import getpass
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('hosts', nargs='+', help='Authorized VPN gateway hostnames')
parser.add_argument('--image', default='ocbar-test-ocserv:trixie')
parser.add_argument('--openconnect', default=shutil.which('openconnect'))
parser.add_argument('--credentials-stdin', action='store_true', help='Read username/password JSON from stdin instead of prompting')
parser.add_argument('--container', action='store_true', help=argparse.SUPPRESS)
args = parser.parse_args()
if any(not host or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-' for c in host) for host in args.hosts):
    parser.error('hosts must be DNS hostnames, without URL paths or credentials')
if not args.container and not args.openconnect:
    parser.error('openconnect is required')

def auth(host, credentials, container=False):
    env = {k: v for k, v in os.environ.items() if not k.startswith('OCBAR_')}
    env.update(OCBAR_USERNAME=credentials['username'], OCBAR_PASSWORD=credentials['password'],
               OCBAR_PROMPT_CMD='exit 3', OCBAR_PROMPT_TTY='0', OCBAR_PW_TIMEOUT='25')
    driver = '/test/ocbar-pwauth.py' if container else str(ROOT / 'libexec/ocbar-pwauth.py')
    client = 'openconnect' if container else args.openconnect
    r = subprocess.run(['python3', driver, client, '--authenticate', '--protocol=anyconnect',
                        '--os=mac-intel', '--user=' + credentials['username'], '--no-proxy',
                        'https://' + host], env=env, capture_output=True, text=True, timeout=35)
    if r.returncode:
        message = r.stderr.replace(credentials['username'], '[user]').replace(credentials['password'], '[password]')
        raise RuntimeError('auth exit %d: %s' % (r.returncode, message[-1200:]))
    cookie, pin, url = r.stdout.strip().rsplit(' ', 2)
    assert cookie and pin.startswith(('sha256:', 'pin-sha256:'))
    print(host + ': authentication OK (trusted TLS, ocbar password driver)', flush=True)
    return cookie, pin, url

def client(host, credentials):
    cookie, pin, url = auth(host, credentials, True)
    script = Path('/tmp/tunnel-script.py')
    script.write_text('''#!/usr/bin/python3
import ipaddress,json,os,subprocess
from pathlib import Path
if os.environ['reason'] == 'connect':
 e=os.environ
 dev=e['TUNDEV']
 addr=str(ipaddress.IPv4Interface(e['INTERNAL_IP4_ADDRESS']+'/'+e.get('INTERNAL_IP4_NETMASK','255.255.255.255')))
 subprocess.run(['ip','addr','add',addr,'dev',dev],check=True)
 subprocess.run(['ip','link','set',dev,'up','mtu',e.get('INTERNAL_IP4_MTU') or '1412'],check=True)
 dns=e.get('INTERNAL_IP4_DNS','').split()
 for target in set(['1.1.1.1']+dns):
  subprocess.run(['ip','route','replace',target+'/32','dev',dev],check=True)
 Path('/tmp/tunnel-state').write_text(json.dumps({'interface':dev,'dns':dns,'mtu':e.get('INTERNAL_IP4_MTU')}))
''')
    script.chmod(0o700)
    with open('/tmp/openconnect.log', 'w+') as log:
        proc = subprocess.Popen(['openconnect', '--protocol=anyconnect', '--cookie-on-stdin',
                                 '--servercert', pin, '--no-proxy', '--interface=ocbartest',
                                 '--script=' + str(script), url],
                                stdin=subprocess.PIPE, stdout=log, stderr=log, text=True)
        proc.stdin.write(cookie + '\n')
        proc.stdin.close()
        try:
            for _ in range(150):
                if Path('/tmp/tunnel-state').exists(): break
                if proc.poll() is not None: raise RuntimeError('tunnel process exited before connection')
                time.sleep(.1)
            else: raise RuntimeError('tunnel connection timed out')
            state = json.loads(Path('/tmp/tunnel-state').read_text())
            print(host + ': tunnel ready; MTU=' + str(state['mtu']), flush=True)
            route = json.loads(subprocess.check_output(['ip','-j','route','get','1.1.1.1'],text=True))
            assert route[0]['dev'] == 'ocbartest'
            http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with http.open('https://1.1.1.1/cdn-cgi/trace', timeout=15) as response:
                payload = response.read(4096).decode()
                assert response.status == 200 and '\nip=' in payload
            result = dict(line.split('=',1) for line in payload.splitlines() if '=' in line)
            print(host + ': routed HTTPS OK; VPN exit=' + result.get('ip','?'), flush=True)
            successes = []
            for dns in state['dns']:
                try:
                    question = b'\x07example\x03com\x00' + struct.pack('!HH',1,1)
                    packet = struct.pack('!HHHHHH',5432,0x100,1,0,0,0) + question
                    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as udp:
                        udp.settimeout(4)
                        udp.sendto(packet,(dns,53))
                        answer,_ = udp.recvfrom(4096)
                    ident,flags,_,count,_,_ = struct.unpack('!HHHHHH',answer[:12])
                    assert ident==5432 and flags & 0x8000 and flags & 15 == 0 and count > 0
                    successes.append(dns)
                except (OSError, AssertionError): pass
            assert successes, 'no VPN-supplied DNS answered successfully'
            print(host + ': VPN DNS OK (' + ', '.join(successes) + ')', flush=True)
            time.sleep(2)
            log.flush(); log.seek(0); diagnostics = log.read()
            print(host + ': DTLS observed=' + str('Established DTLS connection' in diagnostics), flush=True)
        finally:
            proc.terminate()
            try: proc.wait(timeout=8)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=3)

if args.container:
    credentials = json.load(sys.stdin)
    try: client(args.hosts[0], credentials)
    except Exception as e:
        print(type(e).__name__ + ': ' + str(e).replace(credentials['password'],'[password]').replace(credentials['username'],'[user]'), flush=True)
        if Path('/tmp/openconnect.log').exists():
            for line in Path('/tmp/openconnect.log').read_text().splitlines():
                if any(label in line for label in ['Established', 'Connected as', 'MTU', 'DTLS', 'CSTP']):
                    print(line.replace(credentials['password'],'[password]').replace(credentials['username'],'[user]'))
        sys.exit(1)
else:
    credentials = json.load(sys.stdin) if args.credentials_stdin else {
        'username': getpass.getpass('VPN username (hidden): '),
        'password': getpass.getpass('VPN password (hidden): ')}
    failed = False
    for host in args.hosts:
        try:
            auth(host, credentials)
            name = 'ocbar-external-' + os.urandom(6).hex()
            try:
                r = subprocess.run(['docker','run','--rm','-i','--name',name,
                                    '--cap-add=NET_ADMIN','--device=/dev/net/tun',
                                    '--entrypoint=python3','-v',str(Path(__file__).resolve())+':/test/probe.py:ro',
                                    '-v',str(ROOT/'libexec/ocbar-pwauth.py')+':/test/ocbar-pwauth.py:ro',
                                    args.image,'/test/probe.py','--container',host],
                                   input=json.dumps(credentials),capture_output=True,text=True,timeout=90)
                print(r.stdout, end='', flush=True)
                print(host + ': container exit=' + str(r.returncode), flush=True)
                failed = failed or r.returncode != 0
                if r.returncode and r.stderr:
                    print(r.stderr.replace(credentials['password'],'[password]').replace(credentials['username'],'[user]')[-1200:])
            finally: subprocess.run(['docker','rm','-f',name],capture_output=True,timeout=20)
        except Exception as e:
            failed = True
            print(host + ': ' + type(e).__name__ + ': ' + str(e).replace(credentials['password'], '[password]').replace(credentials['username'], '[user]'), flush=True)
    sys.exit(1 if failed else 0)
