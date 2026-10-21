#!/bin/bash
# Кадры README на двух языках: assets/*.png — английский интерфейс (README.md),
# assets/ru/*.png — русский (README.ru.md). Окна — витрина на демо-профилях,
# вне экрана. Меню — настоящее, снимается с экрана (tools/menu-capture.sh):
# на время съёмки на экране откроется демо-меню; сборка — app/make-app.sh.
#   tools/screenshots.sh            всё
#   tools/screenshots.sh --windows  только окна, без съёмки меню
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/app/.build/ocbar.app/Contents/MacOS/ocbar-app"
[ -x "$app" ] || { echo "screenshots: соберите app/make-app.sh" >&2; exit 1; }
mkdir -p "$root/assets/ru"
for lang in en ru; do
    dir="$root/assets"; [ "$lang" = ru ] && dir="$root/assets/ru"
    if [ "${1:-}" != --windows ]; then
        # Меню и оно же, открытое с ⌥ (сведения о соединении), рядом.
        shots=$(mktemp -d /private/tmp/ocbar-shots.XXXXXX)
        "$root/tools/menu-capture.sh" "$lang" dark "$shots" connected connected:option
        bg="#1E1F1C"
        magick "$shots/connected.png" \( -size 24x1 xc:"$bg" \) "$shots/connected-option.png" \
            -background "$bg" -gravity north +append -bordercolor "$bg" -border 24 "$dir/menu.png"
        rm -rf "$shots"
    fi
    "$app" --stage --screenshot settings --tab 0 --shot "$dir/profile.png" -AppleLanguages "($lang)" >/dev/null
    "$app" --stage --screenshot settings --tab 1 --shot "$dir/notifications.png" -AppleLanguages "($lang)" >/dev/null
    echo "screenshots: $lang → ${dir#"$root"/}"
done
