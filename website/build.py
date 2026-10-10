#!/usr/bin/env python3
"""Build both static pages. Python standard library only."""
import argparse
import html
import json
from pathlib import Path
from string import Template
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--url', help='Public site root, including repository path, for social and canonical URLs')
args = parser.parse_args()
site_url = (args.url or '').rstrip('/') + '/' if args.url else None
if site_url and urlparse(site_url).scheme != 'https':
    parser.error('--url must be an https URL')
template = Template((ROOT / 'src/page.html').read_text())
for lang in ('en', 'ru'):
    content = json.loads((ROOT / f'src/{lang}.json').read_text())
    # Only intentional line breaks and the hero accent are markup in translations.
    content = {k: html.escape(v, quote=True).replace('&lt;br&gt;', '<br>').replace('&lt;span&gt;', '<span>').replace('&lt;/span&gt;', '</span>') for k, v in content.items()}
    page = template.substitute(content, lang=lang, base='' if lang == 'en' else '../', home='./',
                               en_current='aria-current="page"' if lang == 'en' else '',
                               ru_current='aria-current="page"' if lang == 'ru' else '')
    if site_url:
        canonical = site_url + ('' if lang == 'en' else 'ru/')
        metadata = f'<link rel="canonical" href="{html.escape(canonical)}">\n'
        metadata += f'<meta property="og:url" content="{html.escape(canonical)}">\n'
        for code, suffix in [('en', ''), ('ru', 'ru/'), ('x-default', '')]:
            metadata += f'<link rel="alternate" hreflang="{code}" href="{html.escape(site_url + suffix)}">\n'
        page = page.replace('</head>', metadata + '</head>')
        page = page.replace('content="' + ('' if lang == 'en' else '../') + 'assets/social-card.jpg"', 'content="' + html.escape(site_url) + 'assets/social-card.jpg"')
    dest = ROOT / 'dist' / ('' if lang == 'en' else 'ru') / 'index.html'
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(page)
    print(dest.relative_to(ROOT))
if site_url:
    (ROOT / 'dist/sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + ''.join(f'<url><loc>{html.escape(site_url + suffix)}</loc></url>' for suffix in ('', 'ru/')) + '</urlset>\n')
    (ROOT / 'dist/robots.txt').write_text('User-agent: *\nAllow: /\nSitemap: ' + site_url + 'sitemap.xml\n')
else:
    for name in ('sitemap.xml', 'robots.txt'):
        (ROOT / 'dist' / name).unlink(missing_ok=True)
