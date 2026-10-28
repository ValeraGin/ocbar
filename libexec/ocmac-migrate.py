#!/usr/bin/env python3
"""Run the separately pinned transition tool only during an explicit upgrade.

Normal app launch never downloads code. Downloaded bytes must match a fixed SHA256;
system phases execute those verified bytes through stdin, not a mutable script path.
The transition cache is removed after successful system setup.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import urllib.request

REVISION = 'd459888acab51dd3d40a904696a9dfb9c5254b6d'
BASE = 'https://raw.githubusercontent.com/ValeraGin/openconnect-for-mac/' + REVISION + '/'
SCRIPT = ('libexec/ocmac-migrate.py', '7d5206faa6e7dde2e4f370b0b90a5b82a3654e3979dd6e0f6b9bd195fe0df1c5')
MANIFEST = ('Formula/tap_migrations.json', '03341ec76581277ca62f64ffcb998a72605e990a4f0f7f491e401b491de8e478')


def verify(data, digest):
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError('Transition tool checksum mismatch; no code was executed')
    return data


def download(resource):
    with urllib.request.urlopen(BASE + resource[0], timeout=30) as response:
        data = response.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024: raise ValueError('Transition download exceeds its size limit')
    return verify(data, resource[1])


def cache_path(home): return home / '.cache/openconnect-for-mac/transition-v1.py'
def completion(home): return home / 'Library/Application Support/ocmac/transition-complete'


def completed(home):
    if completion(home).is_file(): return True
    marker = home / '.config/ocmac/.migration-v1.json'
    try: return bool(json.loads(marker.read_text()).get('app_restored'))
    except (OSError, ValueError): return False


def load_script(home, fetch=False):
    cache = cache_path(home)
    if cache.is_symlink(): raise ValueError('Transition cache must not be a symbolic link')
    if cache.exists(): return verify(cache.read_bytes(), SCRIPT[1])
    if not fetch: return None
    data = download(SCRIPT)
    cache.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Root never trusts this path: load_script verifies bytes again in every phase.
    fd = os.open(cache, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as stream: stream.write(data)
    return data


def run_transition(data, phase, cli=None):
    args = ['/usr/bin/python3', '-', phase]
    if cli: args.append(cli)
    return subprocess.run(args, input=data, check=False).returncode


def cleanup_package():
    brew = next((str(p) for p in [Path('/opt/homebrew/bin/brew'), Path('/usr/local/bin/brew')] if p.is_file()), None)
    if not brew: return
    def output(*args):
        result = subprocess.run([brew, *args], capture_output=True, text=True, check=True)
        return result.stdout.splitlines()
    taps = output('tap')
    # The old package identity is data in the pinned transition manifest, not an app alias.
    for previous, target in json.loads(download(MANIFEST)).items():
        owner, _, _ = target.split('/')
        tap = owner + '/' + previous
        package = tap + '/' + previous
        installed = subprocess.run([brew, 'list', '--versions', package], capture_output=True)
        if installed.returncode == 0:
            subprocess.run([brew, 'uninstall', package], check=True)
        if tap.lower() in [t.lower() for t in taps]:
            subprocess.run([brew, 'untap', tap], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['user', 'prepare', 'finish', 'restore-app'])
    parser.add_argument('cli', nargs='?')
    args = parser.parse_args()
    root = os.geteuid() == 0
    if root:
        username = os.environ.get('SUDO_USER', '')
        if not username or username == 'root': parser.error('Run system setup using sudo from your regular account')
        home = Path(pwd.getpwnam(username).pw_dir)
    else: home = Path.home()
    if args.phase in ('user', 'restore-app') and root: parser.error('This phase must run without sudo')
    if args.phase in ('prepare', 'finish') and not root: parser.error('This phase requires administrator setup')
    if args.phase == 'user' and completed(home):
        if not completion(home).exists():
            cleanup_package()
            completion(home).parent.mkdir(parents=True, exist_ok=True)
            completion(home).write_text('complete\n')
            cache_path(home).unlink(missing_ok=True)
        print('Previous installation already migrated'); return 0
    data = load_script(home, fetch=args.phase == 'user')
    if data is None:
        if args.phase == 'prepare' and not completed(home):
            raise ValueError('Run ocmac prepare without sudo before administrator setup')
        return 0
    result = run_transition(data, args.phase, args.cli)
    if result == 0 and args.phase == 'restore-app':
        cleanup_package()
        completion(home).parent.mkdir(parents=True, exist_ok=True)
        completion(home).write_text('complete\n')
        cache_path(home).unlink(missing_ok=True)
    return result

if __name__ == '__main__':
    try: raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('Migration: ' + str(error), file=sys.stderr); raise SystemExit(1)
