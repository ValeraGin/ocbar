#!/bin/bash
# Карточки для ссылок: website/dist/assets/social-card-{en,ru}.{png,jpg} и
# social-card.{png,jpg} (английская — ей же пользуется GitHub social preview).
# Меню — настоящее, из витрины на демо-профиле, состояние «подключено».
#   tools/social-card.sh         нужны app/make-app.sh и ImageMagick
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/app/.build/ocbar.app/Contents/MacOS/ocbar-app"
[ -x "$app" ] || { echo "social-card: соберите app/make-app.sh" >&2; exit 1; }
tmp=$(mktemp -d /private/tmp/ocbar-card.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
assets="$root/website/dist/assets"
cd "$root"
for lang in en ru; do
    "$app" --stage --light --screenshot menu --frame connected --shot "$tmp/$lang.raw.png" \
        -AppleLanguages "($lang)" >/dev/null 2>&1
    # Серый фон витрины — в фон карточки, затем срезаем до меню (как в demo-gif.sh).
    magick "$tmp/$lang.raw.png" -fuzz 6% -fill "#EEF0EA" -draw "color 0,0 floodfill" \
        -trim +repage "$tmp/$lang.png"
    swift tools/make-social-card.swift "$lang" "$tmp/$lang.png" "$assets/social-card-$lang"
done
cp "$assets/social-card-en.png" "$assets/social-card.png"
cp "$assets/social-card-en.jpg" "$assets/social-card.jpg"
echo "social-card: $(du -h "$assets"/social-card-*.jpg | awk '{print $2 " " $1}' | xargs)"
