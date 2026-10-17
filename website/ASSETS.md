# Visual assets

## Current identity — 2026-10-16

The approved graphite-and-lime switch is drawn in code. `dist/assets/mark.svg`
and `icon.svg` match the app's `app/make-icon.swift` and SwiftUI `AppMark`.
Brand accent: #C3F36B. The image represents one input and two separate routes.

The landing shows the real menu as an animation (`tools/demo-gif.sh`, demo profile).
The earlier route atlas, split-DNS, Cisco comparison and open-source illustrations
remain only in `next/` and `concepts/`. No third-party stock images or remote fonts.

`social-card.png` and its JPEG delivery copy use the new switch, typography and
three route lines. Regenerate them from the repository root with
`swift tools/make-social-card.swift`. They are programmatically drawn marketing artwork, not a
screenshot. PNG is the master; JPEG is the web/Open Graph delivery asset.

The menu and profile PNGs are actual native app renders from the rebranded
build in `--stage` mode, with synthetic profiles. Website images use light
appearance and each page's language. README images use the default appearance.
Menu dimensions: 1560×1221. Profile dimensions: 2096×1416.

Earlier generated blue tunnel artwork is historical and is not used by the
current production pages. Earlier concept directories preserve the design work.
