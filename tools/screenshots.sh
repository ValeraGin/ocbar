#!/bin/bash
# Кадры README на двух языках: assets/*.png — английский интерфейс (README.md),
# assets/ru/*.png — русский (README.ru.md). Витрина на демо-профилях, вне
# экрана, без окон поверх работы; сборка — app/make-app.sh.
#   tools/screenshots.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/app/.build/ocbar.app/Contents/MacOS/ocbar-app"
[ -x "$app" ] || { echo "screenshots: соберите app/make-app.sh" >&2; exit 1; }
mkdir -p "$root/assets/ru"
for lang in en ru; do
    dir="$root/assets"; [ "$lang" = ru ] && dir="$root/assets/ru"
    "$app" --stage --screenshot menu --shot "$dir/menu.png" -AppleLanguages "($lang)" >/dev/null
    "$app" --stage --screenshot settings --tab 0 --shot "$dir/profile.png" -AppleLanguages "($lang)" >/dev/null
    "$app" --stage --screenshot settings --tab 1 --shot "$dir/notifications.png" -AppleLanguages "($lang)" >/dev/null
    echo "screenshots: $lang → ${dir#"$root"/}"
done
