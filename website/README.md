# ocbar website

English and Russian landing pages and installation guides, published on GitHub Pages.
The landing is one short page: what ocbar is, the menu animation, five advantages,
the install commands and links. No runtime dependencies or tracking; the only
scripts are language detection and the copy button.

## Build and check

```sh
python3 website/build.py --url https://valeragin.github.io/ocbar/
python3 website/check.py
python3 -m http.server 8767 --bind 127.0.0.1 --directory website
```

Preview `/dist/` and `/dist/ru/`. The main page template is `src/page.html`;
translations are in `src/en.json` and `src/ru.json`. Installation guides keep their
own templates and their existing URLs. `dist/landing.css` styles the landing,
`dist/style.css` the installation guides. The build copies the README animation
`assets/demo.gif` and `assets/ru/demo.gif` to `dist/assets/demo-{en,ru}.gif`; the page
background matches the animation background `#EEF0EA`. Generated HTML is tracked.

## Publish

Main site — GitHub Pages: [English](https://valeragin.github.io/ocbar/) ·
[Русский](https://valeragin.github.io/ocbar/ru/). The **Website** workflow builds
and publishes it on every push to `main` that changes `website/`, and can be run
by hand. `configure-pages` supplies the address, so canonical URLs follow it.

GitHub Pages, not Cloudflare Pages: `*.pages.dev` does not resolve from Russian
mobile networks without a VPN, while `github.io` does (both checked 2026-10-16).
The former Cloudflare project `ocbar.pages.dev` was deleted on 2026-10-17.
After a push, check both languages, installation links and the animation.

Always build with the stable project URL. The build generates canonical URLs,
language alternates, social-card URLs, sitemap and robots.txt. A deployment
preview URL must not become the canonical URL. Without `--url`, the build makes
a portable local preview and removes sitemap/robots files.

## Screenshots and assets

`tools/screenshots.sh` refreshes README screenshots in `assets/` and `assets/ru/`.
`tools/demo-gif.sh` rebuilds the README animation `assets/demo.gif` and `assets/ru/demo.gif`
from the real menu on the demo profile.
For the website, render `--stage --light --screenshot menu` and
`--stage --light --screenshot settings --tab 0` into
`dist/assets/menu-LANG.png` and `profile-LANG.png`, with `-AppleLanguages '(LANG)'`.
Use only demonstration profiles, never `--live` for public images.

SVG route, DNS, comparison and open-source illustrations are localized for both
languages. `mark.svg`/`icon.svg` match the native app switch. The social card uses
this identity too. See [ASSETS.md](ASSETS.md) for provenance.
