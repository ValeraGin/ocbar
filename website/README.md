# ocbar website

English and Russian product pages with real app screenshots, an illustrative route
switcher, installation instructions and a compatibility FAQ. No runtime packages,
external fonts, trackers or network integrations.

## Edit and preview

Copy lives in `src/en.json` and `src/ru.json`; the shared page is `src/page.html`.
Styles, browser behavior and assets live in `dist/`. The generated HTML is tracked,
so the site can also be opened without a build environment.

```sh
python3 website/build.py
python3 website/check.py
python3 -m http.server 8765 --bind 127.0.0.1 --directory website/dist
```

Open `http://127.0.0.1:8765/` or `http://127.0.0.1:8765/ru/`.
The route switches only change the illustration. The installation button copies
commands; it never runs them. Browser clipboard permission failure selects the
commands for manual copying.

The original screenshots remain in the repository's `assets/` directory. When
refreshing them, copy the English and Russian menu/profile files to `dist/assets/`
and check the hero crop against the new dimensions. Do not use live customer data.

## Publish with GitHub Pages

The prepared workflow is manual; a push alone does not publish the site.

1. Enable GitHub Pages with **GitHub Actions** as the source in repository settings.
2. Push the reviewed website changes.
3. Run the **Website** workflow on the intended revision of `main`.
4. Verify its returned URL and both languages, then add that URL to the repository
   About field and README. Upload `dist/assets/social-card.jpg` as the repository
   social preview if desired.

The build takes the actual Pages URL from `configure-pages`, including the
repository subpath. It generates absolute canonical/social URLs, language alternates,
`sitemap.xml` and `robots.txt`. A custom domain can be attached later without
rewriting the templates. The expected default address for this repository is
`https://valeragin.github.io/ocbar/`; it is not live merely because this file exists.

For another static host, build with its final address and upload only `dist/`:

```sh
python3 website/build.py --url https://your-site.example/
python3 website/check.py
```

`build.py` without `--url` returns to a portable local preview and removes generated
sitemap/robots files. Do not publish source templates or private planning material.

[GitHub Pages workflow documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)

## Visual assets

- `dist/assets/mark.svg`: vector adaptation of the app's existing linked-ring mark.
- `dist/assets/routing-art.jpg`: optimized hero illustration; PNG master kept alongside it.
- `dist/assets/social-card.jpg`: optimized launch/share card, under 1 MB; PNG master kept alongside it.
- `dist/assets/menu-*.png`, `profile-*.png`: actual app UI, synthetic demonstration profiles.

Image generation prompts and provenance are in [ASSETS.md](ASSETS.md).
The illustration and share card are marketing assets, not product screenshots.
