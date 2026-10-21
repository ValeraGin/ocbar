#!/usr/bin/env python3
"""Installer scenarios in a fake macOS environment. No downloads, sudo or live settings."""
import os
import base64
from pathlib import Path
import pty
import select
import shlex
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def executable(path, body):
    path.write_text('#!/bin/bash\nset -eu\n' + body)
    path.chmod(0o755)


def scenario(*args, brew=True, tools=True, answer='y', system='Darwin', uid='501', version='15.0', embedded=False, old_ocbar=''):
    tmp = tempfile.TemporaryDirectory(prefix='ocbar installer test ')
    base = Path(tmp.name)
    fake = base / 'bin'
    fake.mkdir()
    (base / 'home').mkdir()
    (base / 'prefix/bin').mkdir(parents=True)
    log = base / 'calls'
    log.touch()
    clean_env = {k: v for k, v in os.environ.items() if not k.startswith('OCBAR_')}
    env = dict(clean_env, HOME=str(base / 'home'), PATH=f'{fake}:/usr/bin:/bin:/usr/sbin:/sbin',
               TEST_BASE=str(base), TEST_LOG=str(log), TEST_OLD=old_ocbar)
    # Only replace the fallback Homebrew locations so a real local brew cannot be used.
    script = (ROOT / 'install.sh').read_text().replace('/opt/homebrew/bin/brew', shlex.quote(str(fake / 'brew')))
    script = script.replace('/usr/local/bin/brew', shlex.quote(str(fake / 'brew')))
    (base / 'install.sh').write_text(script)
    executable(fake / 'uname', f'echo {shlex.quote(system)}\n')
    executable(fake / 'id', f'if [ "${{1:-}}" = -u ]; then echo {uid}; else /usr/bin/id "$@"; fi\n')
    executable(fake / 'sw_vers', f'echo {shlex.quote(version)}\n')
    executable(fake / 'git', 'echo git-test\n')
    executable(fake / 'xcrun', '[ -f "$TEST_BASE/tools-ready" ]\n')
    if tools:
        (base / 'tools-ready').touch()
    executable(fake / 'xcode-select', 'echo apple-tools >> "$TEST_LOG"; touch "$TEST_BASE/tools-ready"\n')
    executable(fake / 'defaults', 'echo "defaults $*" >> "$TEST_LOG"\n')
    executable(fake / 'sudo', 'echo "sudo $*" >> "$TEST_LOG"; [ "$1" != -- ] || shift; exec "$@"\n')
    brew_body = '''echo "brew $*" >> "$TEST_LOG"
case "$1" in
    --prefix) if [ "$#" = 1 ]; then echo "$TEST_BASE/prefix"; else echo "$TEST_BASE/prefix"; fi ;;
    list) [ -f "$TEST_BASE/installed" ] ;;
    install|reinstall) touch "$TEST_BASE/installed" ;;
    upgrade) if [ "$TEST_OLD" = upgradable ]; then touch "$TEST_BASE/inline-supported"; fi ;;
    help) exit 0 ;;
esac
'''
    executable(base / 'brew-template', brew_body)
    if brew:
        shutil.copy(base / 'brew-template', fake / 'brew')
    executable(fake / 'curl', '''echo download-homebrew >> "$TEST_LOG"
while [ "$1" != -o ]; do shift; done
cat > "$2" <<'EOF'
cp "$TEST_BASE/brew-template" "$TEST_BASE/bin/brew"
EOF
''')
    executable(base / 'prefix/bin/ocbar', '''echo "ocbar $*" >> "$TEST_LOG"
if [ -n "$TEST_OLD" ] && [ ! -f "$TEST_BASE/inline-supported" ] && [ "$1" = profile-check ]; then exit 0; fi
case "$1" in
    profile-check|import) exec /bin/bash ''' + shlex.quote(str(ROOT / 'bin/ocbar')) + ''' "$@" ;;
esac
''')
    profile = base / 'office.ocbar'
    profile.write_text('[Connection]\nName = Office\nUrl = vpn.example.test/employees\nCsdWrapper = /old/path\n\n[Routes]\n10.0.0.0/8\n\n[DNS]\nexample.test = vpn\n')
    if embedded:
        encoded = base64.b64encode(b'#!/bin/bash\nexit 0\n').decode()
        profile.write_text(profile.read_text().replace('CsdWrapper = /old/path', 'CsdScriptBase64 = ' + encoded))
    csd = base / 'wrapper with spaces.sh'
    csd.write_text('#!/bin/bash\nexit 0\n')

    def run(options):
        pid, fd = pty.fork()
        if pid == 0:
            os.execve('/bin/bash', ['bash', str(base / 'install.sh'), *options], env)
        output = b''
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
                if b'[y/N]' in chunk:
                    os.write(fd, (answer + '\n').encode())
        else:
            os.kill(pid, 9)
            raise AssertionError('installer timed out')
        _, status = os.waitpid(pid, 0)
        os.close(fd)
        return os.waitstatus_to_exitcode(status), output.decode(errors='replace')

    options = [str(profile) if x == 'PROFILE' else str(csd) if x == 'CSD' else x for x in args]
    code, output = run(options)
    return tmp, base, code, output, lambda: run(options)



def check_csd_plan():
    with tempfile.TemporaryDirectory(prefix='ocbar CSD plan ') as tmp:
        base = Path(tmp)
        home = base / 'home'
        profiles = home / '.config/ocbar/profiles'
        profiles.mkdir(parents=True)
        script = home / 'scripts $(touch marker); dir/csd.sh'
        script.parent.mkdir()
        script.write_text('#!/bin/bash\nexit 0\n')
        legacy = home / 'legacy.sh'
        legacy.write_text('#!/bin/bash\nexit 0\n')
        (profiles / 'office.ocbar').write_text('[Connection]\nUrl = vpn.example.test\nCsdWrapper = ' + str(script) + '\n')
        (profiles.parent / 'profiles.conf').write_text('[legacy]\ncsd_wrapper = ~/legacy.sh\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith('OCBAR_')}
        env.update(OCBAR_CONFIG_DIR=str(base / 'wrong-config'), OCBAR_SELFTEST_HELPER='/dev/null')
        result = subprocess.run([str(ROOT / 'bin/ocbar'), '_selftest-fn', 'install_csd_steps', str(home)],
                                env=env, text=True, capture_output=True, check=True)
        commands = result.stdout.strip().splitlines()
        assert len(commands) == 2, result.stdout
        args = [shlex.split(command) for command in commands]
        assert {row[-2] for row in args} == {str(script), str(legacy)}, args
        assert {row[-1] for row in args} == {'/usr/local/libexec/ocbar/csd/csd.sh', '/usr/local/libexec/ocbar/csd/legacy.sh'}
        fake = base / 'fake'
        fake.mkdir()
        executable(fake / 'install', "printf '%s\\n' \"$@\" >> \"$TEST_ARGS\"\n")
        env.update(PATH=str(fake) + ':/usr/bin:/bin', TEST_ARGS=str(base / 'args'))
        for command in commands:
            subprocess.run(['/bin/bash', '-c', command], env=env, cwd=base, check=True)
        assert not (base / 'marker').exists(), 'CSD path executed as shell syntax'
        assert str(script) in (base / 'args').read_text().splitlines()
    print('OK: helper CSD plan reads user .ocbar and legacy profiles; paths are shell-quoted')


def main():
    for name, kwargs, args, expected in [
        ('macOS required', {'system': 'Linux'}, [], 'macOS is required'),
        ('minimum macOS', {'version': '14.3'}, [], '14.4'),
        ('root refused', {'uid': '0'}, [], 'without sudo'),
        ('invalid language', {}, ['--language', 'zz'], 'Language must'),
        ('missing option value', {}, ['--profile'], 'Missing value'),
        ('missing profile', {}, ['--profile', '/does-not-exist'], 'No profile'),
        ('CSD requires profile', {}, ['--csd', 'CSD'], '--csd needs'),
        ('decline tools', {'tools': False, 'answer': 'n'}, [], 'Tools are required'),
        ('decline brew', {'brew': False, 'answer': 'n'}, [], 'Homebrew is required'),
    ]:
        tmp, base, code, output, _ = scenario(*args, **kwargs)
        with tmp:
            assert code != 0 and expected in output, (name, code, output)
            assert 'sudo' not in (base / 'calls').read_text(), name
        print('OK:', name)

    tmp, base, code, output, rerun = scenario('--profile', 'PROFILE', '--csd', 'CSD', '--language', 'ru', tools=False, brew=False)
    with tmp:
        assert code == 0, output
        calls = (base / 'calls').read_text()
        assert 'apple-tools' in calls and 'download-homebrew' in calls
        assert 'brew install ValeraGin/ocbar/ocbar' in calls
        assert 'defaults write ru.ocbar.app InterfaceLanguage -string ru' in calls
        dst = base / 'home/.config/ocbar/profiles/office.ocbar'
        content = dst.read_text()
        target = base / 'home/.config/ocbar/csd/office.sh'
        assert f'CsdWrapper = {target}' in content and '/old/path' not in content
        assert '10.0.0.0/8' in content and 'example.test = vpn' in content
        assert target.stat().st_mode & 0o777 == 0o700
        assert dst.stat().st_mode & 0o777 == 0o600
        assert calls.index('ocbar import') < calls.index('sudo ')
        dst.write_text(content + '# local edit\n')
        code, output = rerun()
        assert code == 0 and 'Keeping existing profile' in output, output
        assert dst.read_text().endswith('# local edit\n')
        assert (base / 'calls').read_text().count('ocbar import') == 1
    print('OK: fresh install, dependency prompts, CSD, helper order and safe retry')

    tmp, base, code, output, _ = scenario('--profile', 'PROFILE', '--language', 'ru', embedded=True)
    with tmp:
        assert code == 0, output
        profile = base / 'home/.config/ocbar/profiles/office.ocbar'
        assert 'CsdScriptBase64 =' in profile.read_text() and 'CsdWrapper' not in profile.read_text()
        extracted = list((base / 'home/.config/ocbar/csd').glob('inline-*.sh'))
        assert len(extracted) == 1 and extracted[0].read_bytes() == b'#!/bin/bash\nexit 0\n'
    print('OK: one-file profile installation needs no --csd argument')

    tmp, base, code, output, _ = scenario('--profile', 'PROFILE', '--csd', 'CSD', embedded=True)
    with tmp:
        assert code == 0, output
        profile = base / 'home/.config/ocbar/profiles/office.ocbar'
        assert 'CsdWrapper =' in profile.read_text() and 'CsdScriptBase64' not in profile.read_text()
    print('OK: an explicit external script replaces the embedded source')

    tmp, base, code, output, _ = scenario('--profile', 'PROFILE', embedded=True, old_ocbar='upgradable')
    with tmp:
        assert code == 0, output
        assert 'brew upgrade ValeraGin/ocbar/ocbar' in (base / 'calls').read_text()
        assert (base / 'home/.config/ocbar/profiles/office.ocbar').exists()
    print('OK: older ocbar is upgraded before importing an embedded script')

    tmp, base, code, output, _ = scenario('--profile', 'PROFILE', embedded=True, old_ocbar='unavailable')
    with tmp:
        assert code != 0 and 'cannot read CsdScriptBase64' in output, output
        assert 'ocbar import' not in (base / 'calls').read_text()
        assert 'sudo ' not in (base / 'calls').read_text()
    print('OK: unsupported releases cannot silently skip embedded CSD')

    tmp, base, code, output, _ = scenario('--no-start', '--no-autostart')
    with tmp:
        assert code == 0, output
        assert 'ocbar app' not in (base / 'calls').read_text()
    print('OK: optional app start and login launch')

    tmp, base, code, output, rerun = scenario('--head')
    with tmp:
        assert code == 0, output
        assert 'brew install --HEAD' in (base / 'calls').read_text()
        code, output = rerun()
        assert code == 0, output
        assert 'brew reinstall --HEAD' in (base / 'calls').read_text()
    print('OK: explicit HEAD install and reinstall')
    check_csd_plan()


if __name__ == '__main__':
    main()
