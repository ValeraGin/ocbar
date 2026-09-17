#!/usr/bin/env python3
"""Ссылки в markdown: файлы на месте, якоря существуют. Запускается в CI."""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LINK = re.compile(r'\[[^\]]*\]\(([^)]+)\)')
HEAD = re.compile(r'^#{1,6}\s+(.*?)\s*$', re.M)


def anchors(path):
    out = set()
    for h in HEAD.findall(open(path, encoding='utf-8').read()):
        a = re.sub(r'[^\w\s-]', '', h.lower()).strip().replace(' ', '-')
        out.add(a)
    return out


def main():
    bad, checked = [], 0
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if not d.startswith('.') and d not in {'.build', 'node_modules'}]
        for name in files:
            if not name.endswith('.md'):
                continue
            path = os.path.join(base, name)
            for target in LINK.findall(open(path, encoding='utf-8').read()):
                if target.startswith(('http://', 'https://', 'mailto:')):
                    continue
                checked += 1
                file_part, _, anchor = target.partition('#')
                dest = os.path.normpath(os.path.join(base, file_part)) if file_part else path
                if not os.path.exists(dest):
                    bad.append(f'{os.path.relpath(path, ROOT)} → {target} (нет файла)')
                elif anchor and dest.endswith('.md') and anchor not in anchors(dest):
                    bad.append(f'{os.path.relpath(path, ROOT)} → {target} (нет якоря)')
    print(f'ссылок проверено: {checked}, битых: {len(bad)}')
    for b in bad:
        print('  ' + b)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
