#!/usr/bin/env python3
"""Decode embedded CSD data. Reading/validating a profile never runs its script."""
import base64
import binascii
import hashlib
import os
from pathlib import Path
import sys
import tempfile

MAX_SCRIPT = 256 * 1024


def connection_value(path, key):
    section = ''
    for raw in Path(path).read_text(encoding='utf-8-sig').splitlines():
        line = raw.strip(' \t\r')
        if line.startswith('['):
            section = line.strip('[]').lower()
        elif section == 'connection' and line and not line.startswith(('#', ';')) and '=' in line:
            name, value = line.split('=', 1)
            if name.strip(' \t').lower() == key.lower():
                return value.strip(' \t\r')
    return ''


def decode(path):
    encoded = connection_value(path, 'CsdScriptBase64')
    if not encoded:
        raise ValueError('no embedded script')
    if connection_value(path, 'CsdWrapper'):
        raise ValueError('choose CsdWrapper or CsdScriptBase64, not both')
    if len(encoded) > ((MAX_SCRIPT + 2) // 3) * 4:
        raise ValueError('script exceeds 256 KiB')
    try:
        data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError('invalid Base64') from None
    if base64.b64encode(data).decode('ascii') != encoded:
        raise ValueError('non-canonical Base64')
    if len(data) > MAX_SCRIPT:
        raise ValueError('script exceeds 256 KiB')
    data.decode('utf-8')
    if b'\0' in data or not data.startswith(b'#!'):
        raise ValueError('expected a UTF-8 script starting with #!, without NUL bytes')
    return data


def script_name(data):
    # The helper accepts at most 64 characters. Base32 keeps all SHA-256 bits.
    digest = base64.b32encode(hashlib.sha256(data).digest()).decode('ascii').rstrip('=').lower()
    return 'inline-' + digest + '.sh'


def materialize(path, directory, mode=0o700):
    data = decode(path)
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    target = directory / script_name(data)
    if target.is_symlink():
        raise ValueError('refusing a symbolic link at the script destination')
    fd, temporary = tempfile.mkstemp(prefix='.csd-', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return str(target)


def main():
    try:
        command, path = sys.argv[1:3]
        if command == 'name' and len(sys.argv) == 3:
            print(script_name(decode(path)))
        elif command == 'materialize' and len(sys.argv) in (4, 5):
            mode = sys.argv[4] if len(sys.argv) == 5 else '700'
            if mode not in ('700', '755'):
                raise ValueError('mode must be 700 or 755')
            print(materialize(path, sys.argv[3], int(mode, 8)))
        else:
            raise ValueError('usage: ocbar-csd.py name PROFILE | materialize PROFILE DIRECTORY [700|755]')
        return 0
    except (ValueError, OSError) as error:
        print('CsdScriptBase64: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
