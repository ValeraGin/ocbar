#!/bin/zsh
# Снимки настоящего меню (NSHostingMenu) на демо-профилях. На каждый кадр —
# своя демо-копия приложения со своим значком (--stage --demo-menu): она сразу
# в нужном состоянии и сама открывает меню (OCMAC_DEMO_OPEN) там, где нет
# указателя; снимается только окно меню (screencapture -l), под ним — ровный
# фон своего окна. Переключать кадры в открытом меню нельзя: при смене высоты
# NSMenu на миг рисует пункты внахлёст.
#
#   tools/menu-capture.sh <en|ru> <light|dark> <каталог> <кадр[:option]>...
#   кадры: down connecting connected network-busy network-off pausing paused
#          lost login proxy woke; «:option» — сведения о соединении, как с ⌥
#
# На экране на время съёмки: второй значок ocmac, светлый или тёмный
# прямоугольник и открытое меню. Клавиши и щелчки в это время закрывают
# меню — кадр тогда снимается заново.
# Нужны: собранное приложение (app/make-app.sh) и Swift.
set -euo pipefail
root=${0:A:h:h}
app="$root/app/.build/ocmac.app/Contents/MacOS/ocmac-app"
[ -x "$app" ] || { echo "menu-capture: соберите app/make-app.sh" >&2; exit 1; }
lang=$1 theme=$2 out=$3; shift 3
mkdir -p "$out"
work=$(mktemp -d /private/tmp/ocmac-capture.XXXXXX)
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$work"' EXIT
# Номер окна меню у процесса: окно шириной 150–500 точек на экране.
cat > "$work/winid.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (b["Width"] as? NSNumber)?.doubleValue ?? 0, height = (b["Height"] as? NSNumber)?.doubleValue ?? 0
    if width > 150, width < 500, height > 100 {
        print(w[kCGWindowNumber as String] as? Int ?? 0); break
    }
}
SWIFT
swiftc -O "$work/winid.swift" -o "$work/winid" 2>/dev/null
bg="#EEF0EA"; [ "$theme" = dark ] && bg="#1E1F1C"
state="$work/state"
for frame in "$@"; do
    ok=0
    for try in 1 2 3 4; do
        print -r -- "$frame" > "$state"
        OCMAC_DEMO_STATE="$state" OCMAC_DEMO_OPEN=1 "$app" --stage --demo-menu "--$theme" --backdrop "$bg" \
            -AppleLanguages "($lang)" -InterfaceLanguage "$lang" >/dev/null 2>&1 &
        pid=$!
        id=""
        for _ in {1..40}; do id=$("$work/winid" "$pid"); [ -n "$id" ] && break; sleep 0.25; done
        sleep 0.6
        if [ -n "$id" ] && screencapture -x -o -l "$id" "$out/${frame//:/-}.png" 2>/dev/null; then ok=1; fi
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pid=""
        [ "$ok" = 1 ] && break
    done
    [ "$ok" = 1 ] || { echo "menu-capture: кадр $frame не снялся за четыре попытки" >&2; exit 1; }
done
echo "menu-capture: $lang $theme → $out ($#)"
