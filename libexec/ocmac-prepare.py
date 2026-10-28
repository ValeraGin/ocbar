#!/usr/bin/env python3
"""Copy referenced CSD scripts to private app storage before administrator setup."""
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile


def atomic(path, data, mode):
    fd, name = tempfile.mkstemp(prefix='.prepare-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream: stream.write(data)
        os.chmod(name, mode); os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def prepare(config):
    files = list((config / 'profiles').glob('*.ocmac'))
    if (config / 'profiles.conf').is_file(): files.append(config / 'profiles.conf')
    edits = []; scripts = {}
    for path in files:
        text = path.read_text(encoding='utf-8-sig'); section = ''; lines = []
        for line in text.splitlines(keepends=True):
            match = re.match(r'^\s*\[([^]]+)\]', line)
            if match: section = match[1].lower()
            match = re.match(r'^(\s*(?:CsdWrapper|csd_wrapper)\s*=\s*)([^\r\n]*)(\r?\n)?$', line, re.I)
            if match and (section == 'connection' or path.name == 'profiles.conf') and match[2].strip():
                source = Path(match[2].strip()).expanduser()
                if not source.is_absolute(): raise ValueError('CSD script path must be absolute')
                if not source.is_file(): raise ValueError("CSD source must be a regular file")
                with source.open("rb") as stream: data = stream.read(1024 * 1024 + 1)
                if not data or len(data) > 1024 * 1024: raise ValueError('CSD script is empty or too large')
                target = config / 'csd' / ('external-' + hashlib.sha256(data).hexdigest() + '.sh')
                if target.exists() and (target.is_symlink() or target.read_bytes() != data):
                    raise ValueError('Existing private CSD copy does not match its digest')
                scripts[target] = data
                line = match[1] + str(target) + (match[3] or '')
            lines.append(line)
        updated = ''.join(lines)
        if updated != text: edits.append((path, updated.encode()))
    # Read and validate every input before changing any profile.
    if scripts:
        directory = config / 'csd'
        if directory.is_symlink(): raise ValueError('Private CSD directory must not be a symbolic link')
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        for path, data in scripts.items(): atomic(path, data, 0o700)
    for path, data in edits: atomic(path, data, 0o600)
    return len(edits)

if __name__ == '__main__':
    try:
        if os.geteuid() == 0: raise ValueError('Run ocmac prepare without sudo')
        print('Prepared profiles:', prepare(Path(sys.argv[1]).expanduser()))
    except (OSError, ValueError) as error:
        print('Preparation: ' + str(error), file=sys.stderr); raise SystemExit(1)
