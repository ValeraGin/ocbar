#!/bin/bash
# Карточки для ссылок: website/dist/assets/social-card-{en,ru}.{png,jpg} и
# social-card.{png,jpg} (английская — ей же пользуется GitHub social preview).
# Меню — настоящее, на демо-профиле, состояние «подключено», снятое с экрана
# (tools/menu-capture.sh): на время съёмки откроется демо-меню.
#   tools/social-card.sh         нужны app/make-app.sh и ImageMagick
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/app/.build/ocmac.app/Contents/MacOS/ocmac-app"
[ -x "$app" ] || { echo "social-card: соберите app/make-app.sh" >&2; exit 1; }
tmp=$(mktemp -d /private/tmp/ocmac-card.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
assets="$root/website/dist/assets"
cd "$root"
for lang in en ru; do
    "$root/tools/menu-capture.sh" "$lang" light "$tmp/$lang" connected
    swift tools/make-social-card.swift "$lang" "$tmp/$lang/connected.png" "$assets/social-card-$lang"
done
cp "$assets/social-card-en.png" "$assets/social-card.png"
cp "$assets/social-card-en.jpg" "$assets/social-card.jpg"
echo "social-card: $(du -h "$assets"/social-card-*.jpg | awk '{print $2 " " $1}' | xargs)"
