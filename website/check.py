#!/usr/bin/env python3
"""Check generated site links, assets, translations and metadata before publishing."""
from html.parser import HTMLParser
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent
DIST = ROOT / 'dist'

class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.ids = set()
        self.links = []
        self.lang = None
        self.h1_count = 0
        self.meta = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            assert attrs['id'] not in self.ids, f'{self.path}: duplicate id {attrs["id"]}'
            self.ids.add(attrs['id'])
        if tag == 'html':
            self.lang = attrs.get('lang')
        if tag == 'h1':
            self.h1_count += 1
        if tag == 'meta':
            self.meta[attrs.get('name', attrs.get('property', ''))] = attrs.get('content')
        for key in ('src', 'href'):
            if key in attrs:
                self.links.append(attrs[key])
        if tag == 'img':
            assert 'alt' in attrs, f'{self.path}: image missing alt'

pages = {}
for path in DIST.rglob('*.html'):
    page = Page(path)
    page.feed(path.read_text())
    pages[path.resolve()] = page
    assert page.lang in ('en', 'ru'), f'{path}: missing language'
    assert page.h1_count == 1, f'{path}: expected one h1'
    assert page.meta.get('description'), f'{path}: missing description'
    assert page.meta.get('og:image'), f'{path}: missing share card'
    assert page.meta.get('twitter:card') == 'summary_large_image'
    assert '"ocmac-lang"' in path.read_text(), f'{path}: missing language detection'

for path in (DIST / 'assets').glob('*.svg'):
    ET.parse(path)
    if path.name.endswith('-en.svg'):
        assert not re.search('[А-Яа-яЁё]', path.read_text()), f'{path}: untranslated illustration'
assert not re.search('[А-Яа-яЁё]', (DIST / 'index.html').read_text()), 'Untranslated English landing'

checked = 0
for path, page in pages.items():
    for target in page.links + [page.meta['og:image']]:
        url = urlsplit(target)
        if url.scheme or url.netloc:
            continue
        dest = (path.parent / unquote(url.path)).resolve() if url.path else path
        assert dest.is_relative_to(DIST.resolve()), f'{path}: link outside site {target}'
        if dest.is_dir():
            dest /= 'index.html'
        assert dest.is_file(), f'{path}: broken link {target}'
        if url.fragment and dest in pages:
            assert unquote(url.fragment) in pages[dest].ids, f'{path}: broken anchor {target}'
        checked += 1
for lang in ('en', 'ru'):
    for screen in ('profile',):
        assert (DIST / f'assets/{screen}-{lang}.png').is_file()
keys = [set(json.loads((ROOT / f'src/{lang}.json').read_text())) for lang in ('en', 'ru')]
assert keys[0] == keys[1], f'Translation keys differ: {keys[0] ^ keys[1]}'
assert (DIST / 'assets/social-card.jpg').is_file()
print(f'OK: {len(pages)} pages, {checked} local references, matching translation keys')
