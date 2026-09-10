#!/bin/bash
#
# Собрать ocbar.app — бандл для меню-бара. SwiftPM даёт обычный исполняемый
# файл; меню-бару нужен бандл с Info.plist, где LSUIElement выключает Dock.
#
#   ./make-app.sh                 → app/.build/ocbar.app
#   ./make-app.sh /Applications   → /Applications/ocbar.app
#
# Подписи Developer ID нет и не предполагается: приложение собирается у себя,
# карантин ему не ставится (docs/06-distribution.md).

set -euo pipefail
# Каталог скрипта — абсолютным путём и до cd: после cd относительный
# "$(dirname "$0")" удваивается (app/app/make-icon.swift), и иконка молча
# уходила в запасную.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

DEST="${1:-.build}"
APP="$DEST/ocbar.app"
# Версия одна — VERSION в bin/ocbar (D47). Не прочиталась — это поломка
# сборки, а не повод выпустить бандл с чужой версией.
VERSION=$(sed -n 's/^VERSION="\(.*\)"/\1/p' ../bin/ocbar | head -1)
if [ -z "$VERSION" ]; then
    echo "make-app.sh: не прочитал VERSION из $HERE/../bin/ocbar — бандл не собираю" >&2
    exit 1
fi

swift build -c release --disable-sandbox
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ocbar-app" "$APP/Contents/MacOS/ocbar-app"

# Иконка рисуется кодом (make-icon.swift) и собирается в .icns. Интерпретатор
# swift внутри песочницы brew может не собрать её (кэш модулей), поэтому
# готовая копия лежит в Resources/ и идёт в бандл, когда генерация не
# удалась: у установленного через brew приложения иконка должна быть всегда.
ICON_OK=0
ICONSET="$(mktemp -d)/AppIcon.iconset"
if swift "$HERE/make-icon.swift" "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    ICON_OK=1
elif [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; ICON_OK=1
    echo "иконка не собралась — взята готовая из Resources/"
else
    echo "иконка не собралась — приложение будет с системной"
fi
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ocbar</string>
    <key>CFBundleDisplayName</key><string>ocbar</string>
    <key>CFBundleIdentifier</key><string>ru.ocbar.app</string>
    <key>CFBundleExecutable</key><string>ocbar-app</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCameraUsageDescription</key><string>ocbar читает QR второго фактора с экрана телефона, чтобы сохранить секрет одноразового кода. Кадры никуда не сохраняются.</string>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>ru.ocbar.app.notify</string>
        <key>CFBundleURLSchemes</key><array><string>ocbar</string></array>
    </dict></array>
$([ "$ICON_OK" = 1 ] && printf '    <key>CFBundleIconFile</key><string>AppIcon</string>\n    <key>CFBundleIconName</key><string>AppIcon</string>')
    <key>NSHumanReadableCopyright</key><string>© 2026 ValeraGin (Ignatkovich Valery). MIT</string>
</dict>
</plist>
PLIST

# Подпись «для себя» (ad-hoc): без неё macOS каждый раз считает бандл новым
# и заново спрашивает про доступ, а Keychain видит другое приложение.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "codesign не сработал — приложение всё равно запустится"

echo "готово: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
