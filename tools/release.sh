#!/bin/bash
# Выпуск: tools/release.sh 0.4.1 "что нового одной строкой"
# VERSION в bin/ocbar → коммит и тег → revision в формуле → push ocbar →
# формула в tap → push tap → brew upgrade, brew test, перезапуск приложения.
set -euo pipefail
ver="${1:?версия, например 0.4.1}"; note="${2:?что нового одной строкой}"
root="$(cd "$(dirname "$0")/.." && pwd)"
tap="${OCBAR_TAP_DIR:-$(brew --repository)/Library/Taps/valeragin/homebrew-ocbar}"
cd "$root"
[ -z "$(git status --porcelain -- . ':!.claude')" ] || { echo "release: в дереве незакоммиченные правки" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$ver" >/dev/null && { echo "release: тег v$ver уже есть" >&2; exit 1; }

# Проверки — до отправки: выпуск не должен зависеть от того, заметит ли
# кто-то красный CI уже после push.
echo "release: проверки перед выпуском"
swift build -c release --package-path auth >/dev/null
auth/.build/release/ocbar-auth --selftest >/dev/null
auth/.build/release/ocbar-auth --learn-selftest >/dev/null
tools/helper-selftest.sh >/dev/null
OCBAR_AUTH="$root/auth/.build/release/ocbar-auth" bin/ocbar selftest >/dev/null
app/make-app.sh >/dev/null
app/.build/ocbar.app/Contents/MacOS/ocbar-app --selftest >/dev/null
grep -q "^## $ver " CHANGELOG.md || { echo "release: в CHANGELOG.md нет раздела $ver" >&2; exit 1; }

sed -i '' -E "s/^VERSION=\"[^\"]*\"/VERSION=\"$ver\"/" bin/ocbar
bin/ocbar version | grep -qx "ocbar $ver"
git add bin/ocbar && git commit -q -m "release: $ver"
git tag -a "v$ver" -m "ocbar $ver: $note"
sha=$(git rev-parse "v$ver^{commit}")

/usr/bin/python3 - "$ver" "$sha" Formula/ocbar.rb <<'PY'
import re, sys
ver, sha, path = sys.argv[1:]
s = open(path).read()
s2, n1 = re.subn(r'(tag:\s*)"v[^"]+"', r'\g<1>"v%s"' % ver, s, count=1)
s2, n2 = re.subn(r'(revision:\s*)"[0-9a-f]{40}"', r'\g<1>"%s"' % sha, s2, count=1)
assert n1 == 1 and n2 == 1, "в формуле не нашлись tag или revision"
open(path, "w").write(s2)
PY
ruby -c Formula/ocbar.rb >/dev/null
git add Formula/ocbar.rb && git commit -q -m "chore: формула — revision тега v$ver"
git push -q origin main "v$ver"

cp Formula/ocbar.rb "$tap/Formula/ocbar.rb"
git -C "$tap" add Formula/ocbar.rb
git -C "$tap" commit -q -m "ocbar $ver"
git -C "$tap" push -q origin main

# Заметки к релизу — из CHANGELOG, раздел этой версии.
notes=$(awk -v v="## $ver " 'index($0, v) == 1 {f = 1; next} f && /^## / {exit} f' CHANGELOG.md)
if command -v gh >/dev/null; then
    printf '%s\n' "$notes" | gh release create "v$ver" --title "ocbar $ver" --notes-file - >/dev/null \
        && echo "release: GitHub Release v$ver создан" \
        || echo "release: GitHub Release не создан (проверьте gh auth)" >&2
fi

brew update >/dev/null
brew upgrade ocbar
brew test ocbar
ocbar app stop >/dev/null 2>&1 || true
ocbar app start
echo "release: ocbar $ver выпущен"
