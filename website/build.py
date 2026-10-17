#!/usr/bin/env python3
"""Build both static pages. Python standard library only."""
import argparse
import html
import json
import shutil
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
def metadata(page, base, canonical_suffix, alternatives):
    if not site_url:
        return page
    canonical = html.escape(site_url + canonical_suffix)
    tags = f'<link rel="canonical" href="{canonical}">\n<meta property="og:url" content="{canonical}">\n'
    for code, suffix in alternatives:
        tags += f'<link rel="alternate" hreflang="{code}" href="{html.escape(site_url + suffix)}">\n'
    page = page.replace('</head>', tags + '</head>')
    return page.replace('content="' + base + 'assets/social-card.jpg"', 'content="' + html.escape(site_url) + 'assets/social-card.jpg"')

# Язык: английская страница — по умолчанию; если в браузере русский стоит раньше
# английского, она сразу уводит на русскую. Выбор в переключателе EN/RU запоминается
# и важнее браузера. Русская страница не уводит никуда: ссылку на /ru/ дают нарочно.
# Скрипт в <head>, чтобы английская версия не мелькала перед переходом.
LANGUAGE_SCRIPT = '''<script>(function(){var k="ocbar-lang",d=document.documentElement,c=null;
try{c=localStorage.getItem(k)}catch(e){}
document.addEventListener("click",function(e){var a=e.target.closest&&e.target.closest(".languages a[lang]");
if(a)try{localStorage.setItem(k,a.lang)}catch(e){}});
if(d.lang!=="en")return;
var w=c;if(!w){var l=navigator.languages||[navigator.language||""];
for(var i=0;i<l.length;i++){var p=String(l[i]).toLowerCase().split("-")[0];if(p==="ru"||p==="en"){w=p;break}}}
if(w==="ru")location.replace("%s"+location.hash)})()</script>
'''

# Анимация меню — та же, что в README: tools/demo-gif.sh пишет её в assets/ репозитория.
for lang, source in (('en', 'assets/demo.gif'), ('ru', 'assets/ru/demo.gif')):
    shutil.copyfile(ROOT.parent / source, ROOT / f'dist/assets/demo-{lang}.gif')

for lang in ('en', 'ru'):
    content = json.loads((ROOT / f'src/{lang}.json').read_text())
    content = {k: html.escape(v, quote=True).replace('&lt;br&gt;', '<br>').replace('&lt;span&gt;', '<span>').replace('&lt;/span&gt;', '</span>') for k, v in content.items()}
    prefix = '' if lang == 'en' else 'ru/'
    for guide in (False, True):
        suffix = prefix + ('guide/' if guide else '')
        base = ('../' if lang == 'en' else '../../') if guide else ('' if lang == 'en' else '../')
        template = Template((ROOT / ('src/guide.html' if guide else 'src/page.html')).read_text())
        page = template.substitute(content, lang=lang, base=base, home='./',
            body=(ROOT / f'src/guide-{lang}.html').read_text() if guide else '',
            en_current='aria-current="page"' if lang == 'en' else '',
            ru_current='aria-current="page"' if lang == 'ru' else '')
        variants = [('en', 'guide/'), ('ru', 'ru/guide/'), ('x-default', 'guide/')] if guide else [('en', ''), ('ru', 'ru/'), ('x-default', '')]
        page = page.replace('</head>', LANGUAGE_SCRIPT % (base + 'ru/' + ('guide/' if guide else '')) + '</head>', 1)
        page = metadata(page, base, suffix, variants)
        dest = ROOT / 'dist' / suffix / 'index.html'
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(page)
        print(dest.relative_to(ROOT))
if site_url:
    (ROOT / 'dist/sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + ''.join(f'<url><loc>{html.escape(site_url + suffix)}</loc></url>' for suffix in ('', 'ru/', 'guide/', 'ru/guide/')) + '</urlset>\n')
    (ROOT / 'dist/robots.txt').write_text('User-agent: *\nAllow: /\nSitemap: ' + site_url + 'sitemap.xml\n')
else:
    for name in ('sitemap.xml', 'robots.txt'):
        (ROOT / 'dist' / name).unlink(missing_ok=True)
