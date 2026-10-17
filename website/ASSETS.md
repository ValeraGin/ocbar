# Visual assets

## Current identity — 2026-10-16

The approved graphite-and-lime switch is drawn in code. `dist/assets/mark.svg`
and `icon.svg` match the app's `app/make-icon.swift` and SwiftUI `AppMark`.
Brand accent: #C3F36B. The image represents one input and two separate routes.

The landing shows the real menu as an animation (`tools/demo-gif.sh`, demo profile).
The earlier route atlas, split-DNS, Cisco comparison and open-source illustrations
remain only in `next/` and `concepts/`. No third-party stock images or remote fonts.

`social-card-en` and `social-card-ru` (PNG master, JPEG for Open Graph) show the
landing headline and the real menu on the demo profile, connected. `social-card.*`
is the English copy, also used as the GitHub social preview. Regenerate all of them
from the repository root with `tools/social-card.sh` (draws with
`tools/make-social-card.swift`), then upload the English PNG to GitHub settings.

The menu and profile PNGs are actual native app renders from the rebranded
build in `--stage` mode, with synthetic profiles. Website images use light
appearance and each page's language. README images use the default appearance.
Menu dimensions: 1560×1221. Profile dimensions: 2096×1416.

Earlier generated blue tunnel artwork is historical and is not used by the
current production pages. Earlier concept directories preserve the design work.
