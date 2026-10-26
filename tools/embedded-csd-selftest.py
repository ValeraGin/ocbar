#!/usr/bin/env python3
"""Embedded CSD: real CLI import/export/auth argv and helper installation plans.

All profiles, scripts and state are temporary. No VPN, root writes or secret stores.
"""
import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location('ocmac_csd', ROOT / 'libexec/ocmac-csd.py')
csd = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(csd)


def main():
    with tempfile.TemporaryDirectory(prefix='ocmac embedded CSD ') as tmp:
        base = Path(tmp)
        home = base / 'home'
        home.mkdir()
        config = home / '.config/ocmac'
        profile = base / 'portable.ocmac'
        script = b'#!/bin/bash\nprintf "[Connection]\\n# keep comments\\n"\ntouch marker\n'
        encoded = base64.b64encode(script).decode()
        digest = base64.b32encode(hashlib.sha256(script).digest()).decode().rstrip('=').lower()
        name = 'inline-' + digest + '.sh'
        assert len(name) <= 64, 'script name exceeds the privileged helper limit'
        body = '[Connection]\nName = Portable\nUrl = vpn.example.test/group\nCsdScriptBase64 = ' + encoded + '\n[Auth]\nPassword = command\nPasswordCommand = printf test-password\nTotp = off\n'
        profile.write_text(body)
        env = {k: v for k, v in os.environ.items() if not k.startswith('OCMAC_')}
        env.update(HOME=str(home), OCMAC_CONFIG_DIR=str(config), OCMAC_USER_STATE=str(base / 'state'),
                   OCMAC_STATE_DIR=str(base / 'var'), OCMAC_LOG_DIR=str(base / 'logs'), OCMAC_LANG='ru',
                   OCMAC_SELFTEST_HELPER='/dev/null', OCMAC_NOTIFY='0')

        def cli(*args, ok=True, extra=None):
            result = subprocess.run([str(ROOT / 'bin/ocmac'), *map(str, args)], env=dict(env, **(extra or {})),
                                    cwd=base, text=True, capture_output=True)
            if ok:
                assert result.returncode == 0, (args, result.stderr, result.stdout)
            else:
                assert result.returncode != 0, (args, result.stdout)
            return result

        cli('profile-check', profile)
        assert not config.exists(), 'profile-check wrote to the config directory'
        assert csd.decode(profile) == script
        print('OK: validation is read-only; shell syntax, section headers and comments survive')
        cli('import', profile)
        extracted = config / 'csd' / name
        assert extracted.read_bytes() == script
        assert extracted.stat().st_mode & 0o777 == 0o700
        assert not (base / 'marker').exists(), 'import executed the embedded script'
        cli('import', profile, ok=False)
        assert (config / 'profiles/portable.ocmac').read_text() == body
        print('OK: import extracts executable data once without running it; existing profile is preserved')

        exported = base / 'exported.ocmac'
        cli('export', 'portable', exported)
        assert 'CsdScriptBase64 = ' + encoded in exported.read_text()
        assert 'CsdWrapper' not in exported.read_text()
        assert csd.decode(exported) == script
        print('OK: export remains portable, contains no generated local path')

        auth = base / 'auth-stub'
        argv = base / 'auth-args'
        auth.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$OCMAC_CSD_ARGS"\nprintf \'%s\\n\' \'{"session_token":"test-token","server_cert_hash":"test-hash","post_url":"https://vpn.example.test/group"}\'\n')
        auth.chmod(0o700)
        extracted.unlink()
        cli('_selftest-fn', 'sso_auth', 'portable', extra={'OCMAC_AUTH': str(auth), 'OCMAC_CSD_ARGS': str(argv)})
        args = argv.read_text().splitlines()
        assert args[args.index('--csd-wrapper') + 1] == str(extracted)
        assert extracted.read_bytes() == script
        changed_script = script + b'# changed\n'
        changed = base64.b64encode(changed_script).decode()
        (config / 'profiles/portable.ocmac').write_text(body.replace(encoded, changed))
        cli('_selftest-fn', 'sso_auth', 'portable', extra={'OCMAC_AUTH': str(auth), 'OCMAC_CSD_ARGS': str(argv)})
        args = argv.read_text().splitlines()
        assert Path(args[args.index('--csd-wrapper') + 1]).read_bytes() == changed_script
        assert args[args.index('--csd-wrapper') + 1] != str(extracted)
        print('OK: authentication recreates a missing script and picks up profile edits by content hash')

        plan = cli('_selftest-fn', 'install_csd_steps', home).stdout.strip()
        assert ' materialize ' in plan
        root_copy = base / 'system CSD'
        plan = plan.replace('/usr/local/libexec/ocmac/csd', shlex.quote(str(root_copy)))
        subprocess.run(['/bin/bash', '-c', plan], cwd=base, env=env, text=True, capture_output=True, check=True)
        copies = list(root_copy.glob('inline-*.sh'))
        assert len(copies) == 1 and copies[0].read_bytes() == changed_script
        assert copies[0].stat().st_mode & 0o777 == 0o755
        assert not (base / 'marker').exists()
        print('OK: helper plan extracts directly to its destination with mode 755, without executing data')

        for label, payload in [
            ('bad Base64', '!'), ('no shebang', base64.b64encode(b'echo test\n').decode()),
            ('NUL byte', base64.b64encode(b'#!/bin/bash\n\0').decode()),
            ('invalid UTF-8', base64.b64encode(b'#!/bin/bash\n\xff').decode()),
            ('oversized script', base64.b64encode(b'#!/bin/bash\n' + b'#' * (256 * 1024)).decode()),
        ]:
            invalid = base / 'invalid.ocmac'
            invalid.write_text(body.replace(encoded, payload))
            cli('profile-check', invalid, ok=False)
            cli('import', invalid, 'rejected', ok=False)
            assert not (config / 'profiles/rejected.ocmac').exists()
            print('OK: rejected', label)

        invalid.write_text(body.replace('[Connection]', '[Connection]\nCsdWrapper = /external.sh'))
        cli('profile-check', invalid, ok=False)
        cli('import', invalid, 'rejected', ok=False)
        print('OK: external and embedded script conflict is rejected')
        profile.write_text(body)
        target_dir = base / 'symlink test'
        target_dir.mkdir()
        victim = base / 'victim'
        victim.write_text('do not change')
        (target_dir / name).symlink_to(victim)
        try:
            csd.materialize(profile, target_dir)
            raise AssertionError('symlink was accepted')
        except ValueError:
            pass
        assert victim.read_text() == 'do not change'
        print('OK: script extraction refuses symlinks')

        # UTF-8 BOM, Windows line endings and mixed-case keys follow the CLI parser.
        profile.write_bytes(('\ufeff' + body.replace('CsdScriptBase64', 'csdscriptbase64').replace('\n', '\r\n')).encode())
        cli('profile-check', profile)
        assert csd.decode(profile) == script
        print('OK: BOM, CRLF and case-insensitive key')


if __name__ == '__main__':
    main()
