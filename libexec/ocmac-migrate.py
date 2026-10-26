#!/usr/bin/env python3
"""One-time migration from the former package. Originals are kept for recovery.

User mode copies configuration/preferences and default-service Keychain entries.
System modes are called only by `sudo ocmac install`, with a fixed system layout.
No profile commands or scripts are executed by migration.
"""
import argparse
import getpass
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import stat
import subprocess
import tempfile

OLD = 'ocbar'
NEW = 'ocmac'
OLD_SERVICE = 'ru.ocbar.client'
NEW_SERVICE = 'ru.ocmac.client'
OLD_APP = 'ru.ocbar.app'
NEW_APP = 'ru.ocmac.app'
MARKER = '.migration-v1.json'


def call(args, **kw):
    return subprocess.run(args, capture_output=True, check=False, **kw)


def checked(args, **kw):
    r = call(args, **kw)
    if r.returncode:
        raise RuntimeError('Migration step failed: ' + str(args[0]))
    return r


def settings(text):
    """First value wins, as in the CLI. Preserve unknown fields and raw commands."""
    result = {}; section = ''
    for line in text.lstrip('\ufeff').splitlines():
        if line.strip().startswith(('#', ';')): continue
        m = re.match(r'^\s*\[([^]]+)\]\s*$', line)
        if m: section = m[1].lower(); continue
        if '=' in line:
            k, v = line.split('=', 1)
            result.setdefault((section, k.strip().lower()), v.strip())
    return result


def transformed(text, home):
    section = ''; out = []
    for line in text.splitlines(keepends=True):
        m = re.match(r'^\s*\[([^]]+)\]', line)
        if m: section = m[1].lower()
        if '=' in line and not line.lstrip().startswith(('#', ';')):
            key, value = line.split('=', 1)
            field = key.strip().lower()
            if field in ('keychainservice', 'keychain_service') and value.strip() == OLD_SERVICE:
                line = key + '= ' + NEW_SERVICE + ('\n' if line.endswith('\n') else '')
            elif field in ('rules', 'csdwrapper', 'csd_wrapper'):
                # Only known file paths; never rewrite custom credential commands/URLs.
                for prefix in (str(home / '.config' / OLD), '~/.config/' + OLD):
                    if value.strip().startswith(prefix + '/'):
                        line = key + '=' + value.replace(prefix, prefix[:-len(OLD)] + NEW, 1)
                        break
        out.append(line)
    return ''.join(out)


class Keychain:
    @staticmethod
    def has(service, account):
        result = call(['/usr/bin/security', 'find-generic-password', '-s', service, '-a', account])
        if result.returncode not in (0, 44): raise RuntimeError('Keychain is unavailable; original entries are unchanged')
        return result.returncode == 0

    def copy(self, account):
        if self.has(NEW_SERVICE, account) or not self.has(OLD_SERVICE, account): return
        r = checked(['/usr/bin/security', 'find-generic-password', '-g', '-s', OLD_SERVICE, '-a', account])
        match = re.search(rb'^password: 0x([0-9a-fA-F]+)', r.stderr, re.M)
        if match:
            secret = bytes.fromhex(match[1].decode()).decode('utf-8')
        else:
            secret = checked(['/usr/bin/security', 'find-generic-password', '-w', '-s', OLD_SERVICE, '-a', account]).stdout.decode('utf-8').removesuffix('\n')
        def quote(s):
            if any(c in s for c in '\r\n\x00'):
                raise RuntimeError('A Keychain value requires manual migration; original entries are unchanged')
            return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
        command = 'add-generic-password -s ' + quote(NEW_SERVICE) + ' -a ' + quote(account) + ' -l ' + quote('OpenConnect for Mac') + ' -w ' + quote(secret) + '\n'
        checked(['/usr/bin/security', '-i'], input=command.encode())
        if not self.has(NEW_SERVICE, account): raise RuntimeError('Keychain copy could not be verified')


def copy_tree(source, dest):
    if not source.exists(): return
    if source.is_symlink(): raise RuntimeError('Migration source is a symbolic link; original left unchanged')
    for item in source.rglob('*'):
        if item.is_symlink(): raise RuntimeError('Migration source contains symbolic links; original left unchanged')
    shutil.copytree(source, dest, dirs_exist_ok=True)


def migrate_user(home, keychain=None, preferences=True):
    old = home / '.config' / OLD; new = home / '.config' / NEW
    if (new / MARKER).is_file(): return 'already migrated'
    if not old.is_dir(): return 'no previous configuration'
    if old.is_symlink(): raise RuntimeError('Previous configuration is a symbolic link')
    if new.is_symlink(): raise RuntimeError('Destination configuration is a symbolic link')
    if new.exists() and any(new.iterdir()):
        raise RuntimeError('Destination configuration already exists. Keep both directories and resolve the conflict before migration.')
    new.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.ocmac-migration-', dir=new.parent))
    try:
        copy_tree(old, staging)
        accounts = set()
        for p in staging.rglob('*'):
            if not p.is_file(): continue
            if p.suffix == '.' + OLD or p.name == 'profiles.conf':
                text = p.read_text(encoding='utf-8-sig'); data = settings(text)
                sections = {s for s, k in data if k == 'url'}
                if p.suffix == '.' + OLD: sections = {'connection'}
                for section in sections:
                    user = data.get((section, 'user')) or getpass.getuser()
                    service = data.get(('auth', 'keychainservice'), OLD_SERVICE) if section == 'connection' else data.get((section, 'keychain_service'), OLD_SERVICE)
                    if service == OLD_SERVICE:
                        accounts.update([user, 'totp/' + user])
                p.write_text(transformed(text, home))
                if p.suffix == '.' + OLD:
                    target = p.with_suffix('.' + NEW)
                    if target.exists(): raise RuntimeError('Profile filename collision; source files are unchanged')
                    p.rename(target)
        for account in sorted(accounts):
            (keychain or Keychain()).copy(account)
        # User preferences are copied through cfprefsd, not from its stale disk cache.
        if preferences:
            previous = call(['/usr/bin/defaults', 'export', OLD_APP, '-'])
            current = call(['/usr/bin/defaults', 'export', NEW_APP, '-'])
            if previous.returncode == 0:
                old_prefs = plistlib.loads(previous.stdout)
                new_prefs = plistlib.loads(current.stdout) if current.returncode == 0 else {}
                old_prefs.update(new_prefs)
                pref_file = staging / '.preferences.plist'
                pref_file.write_bytes(plistlib.dumps(old_prefs))
                checked(['/usr/bin/defaults', 'import', NEW_APP, str(pref_file)])
                pref_file.unlink()
        # Copy policy and selected profile, never PID/session files or notification tokens.
        state = home / 'Library/Application Support'
        old_state = state / OLD; new_state = state / NEW
        for name in ('desired', 'autoconnect', 'skip-networks', 'routes.disabled', 'zones.disabled'):
            src, dst = old_state / name, new_state / name
            if src.is_file() and not src.is_symlink() and not dst.exists():
                dst.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(src, dst)
        log_source = home / 'Library/Logs' / OLD; log_dest = home / 'Library/Logs' / NEW
        if log_source.is_dir() and not log_dest.exists(): copy_tree(log_source, log_dest)
        (staging / MARKER).write_text(json.dumps({'version': 1, 'profiles_migrated': True, 'autostart': (home / 'Library/LaunchAgents/ru.ocbar.app.plist').is_file()}) + '\n')
        os.chmod(staging, 0o700)
        for p in staging.rglob('*'):
            if p.is_file(): os.chmod(p, 0o700 if os.access(p, os.X_OK) else 0o600)
        if new.exists(): new.rmdir()
        staging.rename(new)
        return 'profiles, preferences and credential references migrated; originals preserved'
    finally:
        if staging.exists(): shutil.rmtree(staging)


def trusted(path):
    for p in (path, *path.parents):
        st = p.lstat()
        if stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
            raise RuntimeError('Unsafe legacy system path; migration refused: ' + str(path))


def system(phase):
    if os.geteuid() != 0: raise RuntimeError('System migration requires sudo ocmac install')
    username = os.environ.get('SUDO_USER')
    if not username or username == 'root': raise RuntimeError('Run sudo from your regular account')
    user = pwd.getpwnam(username); home = Path(user.pw_dir)
    old_helper = Path('/usr/local/libexec/ocbar-helper')
    if phase == 'prepare':
        if (home / '.config' / OLD).exists() and not (home / '.config' / NEW / MARKER).is_file():
            raise RuntimeError('Run ocmac migrate as your regular user before sudo ocmac install')
        if old_helper.exists():
            trusted(old_helper)
            # No two supervisors may manage the same connection during the transition.
            label = f'gui/{user.pw_uid}/ru.ocbar.supervisor'
            if call(['/bin/launchctl', 'print', label]).returncode == 0:
                checked(['/bin/launchctl', 'bootout', label])
            checked([str(old_helper), 'tunnel-stop'])
        label = f'gui/{user.pw_uid}/ru.ocbar.app'
        if call(['/bin/launchctl', 'print', label]).returncode == 0:
            checked(['/bin/launchctl', 'bootout', label])
        call(['/usr/bin/pkill', '-u', str(user.pw_uid), '-f', r'/(ocbar|OpenConnect for Mac)\.app/Contents/MacOS/ocbar-app( |$)'])
        return
    # Called only after the new helper, trust manifest and supervisor are installed.
    backup = Path('/private/var/db/ocmac/migration-backup')
    trusted(backup.parent)
    backup.mkdir(mode=0o700, exist_ok=True); trusted(backup)
    for source, name in [(old_helper, 'helper'), (Path('/private/etc/sudoers.d/ocbar'), 'sudoers'),
                         (Path('/usr/local/libexec/ocbar'), 'libexec'), (Path('/private/var/db/ocbar'), 'state')]:
        if source.exists():
            trusted(source)
            dest = backup / name
            if dest.exists(): raise RuntimeError('Migration backup already exists: ' + str(dest))
            source.rename(dest)
    for label in ('ru.ocbar.supervisor', 'ru.ocbar.app'):
        checked(['/usr/bin/sudo', '-u', username, '/bin/rm', '-f', str(home / 'Library/LaunchAgents' / (label + '.plist'))])


def restore_app(home, cli):
    marker = home / '.config' / NEW / MARKER
    if not marker.is_file(): return
    data = json.loads(marker.read_text())
    if data.get('app_restored'): return
    if data.get('autostart') and not (home / 'Library/LaunchAgents/ru.ocmac.app.plist').exists():
        checked([cli, 'app', 'autostart', 'on'])
    alias = home / 'Applications/ocbar.app'
    if alias.is_symlink() and alias.resolve() == (home / 'Applications/OpenConnect for Mac.app').resolve():
        alias.unlink()
    data['app_restored'] = True
    marker.write_text(json.dumps(data) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['user', 'prepare', 'finish', 'restore-app'])
    parser.add_argument('cli', nargs='?')
    args = parser.parse_args()
    try:
        if args.phase == 'user':
            if os.geteuid() == 0: raise RuntimeError('Run ocmac migrate without sudo first')
            print(migrate_user(Path.home()))
        elif args.phase == 'restore-app':
            if os.geteuid() == 0 or not args.cli: raise RuntimeError('Restore the app as the regular user with a CLI path')
            restore_app(Path.home(), args.cli)
        else: system(args.phase)
    except (OSError, ValueError, RuntimeError) as e:
        print('Migration: ' + str(e), file=__import__('sys').stderr); raise SystemExit(1)

if __name__ == '__main__': main()
