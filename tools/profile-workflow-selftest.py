#!/usr/bin/env python3
"""Profile import and CSD setup workflows. Temporary files only; no VPN or sudo."""
import base64
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('csd', ROOT / 'libexec/ocbar-csd.py')
csd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(csd)


def main():
    with tempfile.TemporaryDirectory(prefix='ocbar profile workflow ') as directory:
        base = Path(directory)
        home = base / 'home'
        home.mkdir()
        config = home / '.config/ocbar'
        system = base / 'system'
        env = {k: v for k, v in os.environ.items() if not k.startswith('OCBAR_')}
        env.update(HOME=str(home), OCBAR_CONFIG_DIR=str(config), OCBAR_LANG='ru',
                   OCBAR_SELFTEST_HELPER='/dev/null', OCBAR_NOTIFY='0')

        def cli(*args):
            result = subprocess.run([str(ROOT / 'bin/ocbar'), *map(str, args)], env=env,
                                    text=True, capture_output=True, check=True, timeout=25)
            return result.stdout

        xml = base / 'company.xml'
        xml.write_text('<AnyConnectProfile><ServerList>' + ''.join(
            f'<HostEntry><HostName>{name}</HostName><HostAddress>{url}</HostAddress></HostEntry>'
            for name, url in [('Office VPN', 'vpn.example.test'), ('Backup', 'backup.example.test')]
        ) + '</ServerList></AnyConnectProfile>')
        ids = json.loads(cli('import', '--json', xml))['profiles']
        assert ids == ['office-vpn', 'backup']
        assert all((config / f'profiles/{name}.ocbar').is_file() for name in ids)
        assert json.loads(cli('csd-status', ids[0])) == {'required': False, 'ready': True, 'name': ''}
        assert json.loads(cli('check-access', ids[0])) == {'reachable': None}
        class Resource(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(401)  # Login required still means the service responds.
                self.end_headers()
            def log_message(self, *args):
                pass
        print('Checking HTTP resource…', flush=True)
        with ThreadingHTTPServer(('127.0.0.1', 0), Resource) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            target = f'http://127.0.0.1:{server.server_port}/'
            assert json.loads(cli('check-access', ids[0], target)) == {'reachable': True}
            server.shutdown()
        assert json.loads(cli('check-access', ids[0], target)) == {'reachable': False}
        assert not list(home.rglob('access')), 'one-shot checks must not change supervisor access state'
        print('OK: resource checks distinguish unset, responding and unavailable without changing connection state')
        print('OK: machine import returns actual ids for every XML server, not the filename')

        script = b'#!/bin/bash\nexit 0\n'
        profile = base / 'team.ocbar'

        def body(data):
            return '[Connection]\nUrl = vpn.example.test\nCsdScriptBase64 = ' + base64.b64encode(data).decode() + '\n'

        profile.write_text(body(script))
        assert json.loads(cli('import', '--json', profile))['profiles'] == ['team']

        def status(name):
            return json.loads(cli('_selftest-fn', 'csd_system_status', name, system))

        assert not status('team')['ready'] and not system.exists(), 'readiness check must be read-only'
        assert status('team')['reason'] == 'missing', 'first setup must not be described as an edit'
        plan = cli('_selftest-fn', 'install_csd_steps', home)
        # Run only the embedded materialization command against a temporary system directory.
        command = next(line for line in plan.splitlines() if ' materialize ' in line)
        subprocess.run(['/bin/bash', '-c', command.replace('/usr/local/libexec/ocbar/csd', shlex.quote(str(system)))],
                       env=env, check=True, capture_output=True)
        assert status('team')['ready']
        changed = script + b'# changed in editor\n'
        (config / 'profiles/team.ocbar').write_text(body(changed))
        assert not status('team')['ready'], 'editing embedded data must invalidate the system copy'
        csd.materialize(config / 'profiles/team.ocbar', system, 0o755)
        assert status('team')['ready']
        installed = system / status('team')['name']
        installed.write_bytes(b'#!/bin/bash\n# replaced on disk\n')
        assert status('team')['reason'] == 'changed'
        csd.materialize(config / 'profiles/team.ocbar', system, 0o755)
        print('OK: import/edit needs setup; installing the exact new CSD enables connection')

        wrappers = []
        for name in ('first', 'second'):
            path = base / name / 'wrapper.sh'
            path.parent.mkdir()
            path.write_text('#!/bin/bash\n# ' + name + '\n')
            path.chmod(0o700)
            wrappers.append(path)
            (config / f'profiles/{name}.ocbar').write_text('[Connection]\nUrl = vpn.example.test\nCsdWrapper = ' + str(path) + '\n')
        plans = [shlex.split(line) for line in cli('_selftest-fn', 'install_csd_steps', home).splitlines() if line.startswith('install ')]
        assert len({row[-1] for row in plans}) == 2, 'equal basenames must not share a destination'
        assert all(len(Path(row[-1]).name) <= 64 for row in plans)
        legacy = system / 'wrapper.sh'
        legacy.write_bytes(wrappers[0].read_bytes())
        legacy.chmod(0o755)
        assert status('first')['ready'] and status('first')['name'] == 'wrapper.sh'
        assert not status('second')['ready'], 'legacy fallback must compare contents'
        for path in wrappers:
            dest = system / csd.external_name(path.read_bytes())
            dest.write_bytes(path.read_bytes())
            dest.chmod(0o755)
        assert status('first')['ready'] and status('second')['ready']
        assert status('first')['name'] != status('second')['name']
        print('OK: equal external basenames are isolated; matching legacy copies remain usable')


if __name__ == '__main__':
    main()
