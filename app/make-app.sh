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
cd "$(dirname "$0")"

DEST="${1:-.build}"
APP="$DEST/ocbar.app"
VERSION=$(sed -n 's/^VERSION="\(.*\)"/\1/p' ../bin/ocbar | head -1)
VERSION="${VERSION:-0.1.0}"

swift build -c release --disable-sandbox
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ocbar-app" "$APP/Contents/MacOS/ocbar-app"

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
    <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
PLIST

# Подпись «для себя» (ad-hoc): без неё macOS каждый раз считает бандл новым
# и заново спрашивает про доступ, а Keychain видит другое приложение.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "codesign не сработал — приложение всё равно запустится"

echo "готово: $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
