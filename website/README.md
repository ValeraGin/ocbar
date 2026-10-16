# ocbar website

English and Russian landing pages and installation guides for Cloudflare Pages.
The production design uses the lime switch, editorial hero and interactive route
atlas selected in `next/`. The site has no runtime dependencies or tracking.

## Build and check

```sh
python3 website/build.py --url https://ocbar.pages.dev/
python3 website/check.py
python3 -m http.server 8767 --bind 127.0.0.1 --directory website
```

Preview `/dist/` and `/dist/ru/`. The main page template is `src/page.html`;
translations are in `src/en.json` and `src/ru.json`. Landing strings use `site_`
keys. Installation guides keep their own templates and their existing URLs.
`dist/landing.css` and `dist/landing.js` implement the approved design;
`dist/style.css` styles the installation guides. Generated HTML is tracked.

`next/` preserves the selected design preview; `concepts/` preserves earlier
explorations. Neither directory is included in a production upload.

## Publish

Cloudflare Pages project: `ocbar`. Public addresses:
[English](https://ocbar.pages.dev/) · [Русский](https://ocbar.pages.dev/ru/).
The rebranded EN/RU landing and guides were published on 2026-10-16.
The project uses free `pages.dev` hosting, with Direct Upload rather than Git
integration. Upload only `dist/` through Workers & Pages → ocbar → Create
deployment → Production: either the `dist` folder, or a ZIP with the contents of
`dist/` at the archive root (`cd website/dist && zip -qr -X ../ocbar-site.zip .`).
Check both languages, installation links and diagrams.

`pages.dev` does not resolve from Russian mobile networks without a VPN
(checked 2026-10-16), so Russian visitors need a mirror on another host.

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

The manual GitHub Pages workflow remains available as an alternative; a normal
push does not deploy the Cloudflare site.
