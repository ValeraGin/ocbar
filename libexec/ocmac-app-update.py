#!/usr/bin/env python3
"""Refresh the user-facing app and its login item independently of root setup."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import time

LABEL = 'ru.ocmac.app'
EXECUTABLE = 'ocmac-app'


def run(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=30)


def info(bundle):
    try: return plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException): return {}


def validate(bundle):
    data = info(bundle)
    if data.get('CFBundleIdentifier') != LABEL or data.get('CFBundleExecutable') != EXECUTABLE:
        raise RuntimeError('The replacement app has an unexpected identity')
    if not os.access(bundle / 'Contents/MacOS' / EXECUTABLE, os.X_OK):
        raise RuntimeError('The replacement app executable is missing')
    return data


def installation_check(bundle, expected):
    result = run([str(bundle / 'Contents/MacOS' / EXECUTABLE), '--installation-check'])
    try: report = json.loads(result.stdout)
    except ValueError: raise RuntimeError('The installed app did not return its client check')
    version = expected.get('CFBundleShortVersionString', '')
    if result.returncode or not report.get('clientAvailable') or report.get('clientVersion') != 'ocmac ' + version:
        raise RuntimeError('The installed app cannot find the matching client version')


def matching_agents(home, old_binary):
    found = []
    for path in (home / 'Library/LaunchAgents').glob('*.plist'):
        try: data = plistlib.loads(path.read_bytes())
        except (OSError, ValueError, plistlib.InvalidFileException): continue
        args = data.get('ProgramArguments', [])
        label = data.get('Label', '')
        if (args and isinstance(args[0], str) and Path(args[0]).resolve() == old_binary.resolve()
                and label == path.stem and re.fullmatch(r'[A-Za-z0-9_.-]+', label)):
            found.append((path, label))
    return found


def pids(binary):
    result = run(['/usr/bin/pgrep', '-u', str(os.getuid()), '-f', '^' + re.escape(str(binary)) + r'( |$)'])
    return [int(x) for x in result.stdout.split() if x.isdigit()]


def update(source, home, start=False):
    expected = validate(source)
    dest = home / 'Applications/OpenConnect for Mac.app'
    old = info(dest)
    old_name = old.get('CFBundleExecutable', EXECUTABLE)
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', old_name): raise RuntimeError('Invalid app executable name')
    old_binary = dest / 'Contents/MacOS' / old_name
    agents = matching_agents(home, old_binary)
    original_plists = {path: path.read_bytes() for path, _ in agents}
    new_plist = home / "Library/LaunchAgents" / (LABEL + ".plist")
    prior_new_plist = new_plist.read_bytes() if new_plist.exists() else None
    aliases = [p for p in dest.parent.glob('*.app') if p.is_symlink() and p.resolve() == dest.resolve()]
    running = set(pids(old_binary))
    for alias in aliases: running.update(pids(alias / 'Contents/MacOS' / old_name))
    uid = os.getuid()
    new_binary = dest / 'Contents/MacOS' / EXECUTABLE
    # Compare actual contents, not just version numbers: a repaired build may share a version.
    same = dest.is_dir() and run(['/usr/bin/diff', '-qr', str(source / 'Contents'), str(dest / 'Contents')]).returncode == 0
    if same and all(label == LABEL for _, label in agents) and not aliases:
        installation_check(dest, expected)
        if start and not running:
            result = run(['/usr/bin/open', str(dest)])
            if result.returncode: raise RuntimeError('Could not open the installed app')
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='.openconnect-update-', dir=dest.parent))
    staged, backup = work / 'next.app', work / 'previous.app'
    replaced = False
    changed_agents = False
    finished = False
    try:
        shutil.copytree(source, staged, symlinks=True)
        validate(staged)
        for _, label in agents:
            target = f'gui/{uid}/{label}'
            if run(['/bin/launchctl', 'print', target]).returncode == 0:
                if run(['/bin/launchctl', 'bootout', target]).returncode:
                    raise RuntimeError('Could not stop the previous login item')
                changed_agents = True
        for pid in running:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        deadline = time.monotonic() + 5
        while any(pids(p) for p in [old_binary, *(a / 'Contents/MacOS' / old_name for a in aliases)]):
            if time.monotonic() >= deadline: raise RuntimeError('The previous app did not exit')
            time.sleep(0.1)
        if dest.exists(): dest.rename(backup)
        staged.rename(dest); replaced = True
        installation_check(dest, expected)
        if agents:
            plist = home / 'Library/LaunchAgents' / (LABEL + '.plist')
            plist.parent.mkdir(parents=True, exist_ok=True)
            plist.write_bytes(plistlib.dumps({'Label': LABEL, 'ProgramArguments': [str(new_binary)],
                                             'RunAtLoad': True, 'LimitLoadToSessionType': 'Aqua'}))
            if run(['/bin/launchctl', 'bootstrap', f'gui/{uid}', str(plist)]).returncode:
                raise RuntimeError('Could not restore launch at login')
        elif start or running:
            if run(['/usr/bin/open', str(dest)]).returncode: raise RuntimeError('Could not open the updated app')
        for path, label in agents:
            if label != LABEL: path.unlink(missing_ok=True)
        for alias in aliases: alias.unlink()
        run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(dest)])
        finished = True
        return dest
    except Exception:
        if replaced:
            shutil.rmtree(dest)
        if backup.exists(): backup.rename(dest)
        if replaced or changed_agents:
            run(['/bin/launchctl', 'bootout', f'gui/{uid}/{LABEL}'])
            if prior_new_plist is None: new_plist.unlink(missing_ok=True)
            else: new_plist.write_bytes(prior_new_plist)
            for path, data in original_plists.items(): path.write_bytes(data)
            for path, _ in agents: run(['/bin/launchctl', 'bootstrap', f'gui/{uid}', str(path)])
            if running and not agents: run(['/usr/bin/open', str(dest)])
        raise
    finally:
        if finished or not backup.exists(): shutil.rmtree(work, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--start', action='store_true')
    args = parser.parse_args()
    try:
        print(update(args.source.resolve(), Path.home(), args.start))
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, 'App update: ' + str(error) + '\n')

if __name__ == '__main__': main()
