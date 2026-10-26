#!/bin/bash
# Выпуск: tools/release.sh 0.4.1 "что нового одной строкой"
# VERSION в bin/ocbar → коммит и тег → revision в формуле → push ocbar →
# формула в tap → push tap → brew upgrade, brew test, перезапуск приложения.
# Тег уже есть, а push не прошёл — доделать: tools/release.sh --publish 0.4.1
# OCBAR_RELEASE_LOCAL_UPDATE=0 — опубликовать без обновления и перезапуска
# установленной копии, например пока её отдельно диагностируют.
set -euo pipefail
publish_only=
if [ "${1:-}" = --publish ]; then
    publish_only=1; ver="${2:?версия, например 0.4.1}"
else
    ver="${1:?версия, например 0.4.1}"; note="${2:?что нового одной строкой}"
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
tap="${OCBAR_TAP_DIR:-$(brew --repository)/Library/Taps/valeragin/homebrew-ocbar}"
cd "$root"
[ -z "$(git status --porcelain -- . ':!.claude')" ] || { echo "release: в дереве незакоммиченные правки" >&2; exit 1; }
# Хук worktime (knowledge-base/tools/worktime) не пускает push в будни
# 10–19 МСК. Проверяем до сборки: 0.18.0 собрался, получил тег и встал на push.
if [ -z "${WORKTIME_PUSH_OK:-}" ] && [ -e .git/hooks/pre-push ] \
    && TZ=Europe/Moscow date '+%u %H' | awk '{exit !($1 <= 5 && $2 >= 10 && $2 < 19)}'; then
    echo "release: рабочее время (будни 10–19 МСК), хук worktime не пустит push — выпуск после 19:00" >&2
    exit 1
fi

publish() {
    git push -q origin main "v$ver"

    cp Formula/ocbar.rb "$tap/Formula/ocbar.rb"
    git -C "$tap" add Formula/ocbar.rb
    git -C "$tap" commit -q -m "ocbar $ver"
    git -C "$tap" push -q origin main

    # Заметки к релизу — из CHANGELOG, раздел этой версии.
    notes=$(awk -v v="## $ver " 'index($0, v) == 1 {f = 1; next} f && /^## / {exit} f' CHANGELOG.md)
    if command -v gh >/dev/null; then
        printf '%s\n' "$notes" | gh release create "v$ver" --title "OpenConnect for Mac $ver" --notes-file - >/dev/null \
            && echo "release: GitHub Release v$ver создан" \
            || echo "release: GitHub Release не создан (проверьте gh auth)" >&2
    fi

    if [ "${OCBAR_RELEASE_LOCAL_UPDATE:-1}" = 0 ]; then
        echo "release: OpenConnect for Mac $ver опубликован; локальное обновление и проверка меню отложены"
        return 0
    fi

    brew update >/dev/null
    # Обновляем кеш исходников до сборки в песочнице Homebrew, чтобы нужный
    # тег уже был локально и сборка не зависела от помощников учётной записи.
    cache="$(brew --cache)/ocbar--git"
    [ -d "$cache" ] && git -C "$cache" fetch -q origin --tags '+refs/heads/*:refs/remotes/origin/*'
    brew upgrade ocbar
    brew test ocbar
    ocbar app stop >/dev/null 2>&1 || true
    ocbar app start
    echo "release: OpenConnect for Mac $ver выпущен"
    menu_check
}

# Keep failed check output in the release log instead of silently stopping.
run_checked() {
    local output status
    output=$(mktemp "${TMPDIR:-/tmp}/ocbar-release-check.XXXXXX")
    if "$@" >"$output" 2>&1; then
        rm -f "$output"
    else
        status=$?
        cat "$output" >&2
        rm -f "$output"
        return "$status"
    fi
}

# Живое меню после выпуска: приложение само открывает меню, меняет его высоту
# и пишет итог в app.log (MenuProbe). В 0.19.0 окно перестало сжиматься, а
# вердикт «ИТОГ ПЛОХО» лежал в журнале, и его никто не видел.
menu_check() {
    local log="$HOME/Library/Logs/ocbar/app.log" tok n v
    sleep 5
    tok=$(tr -d '[:space:]' < "$HOME/Library/Application Support/ocbar/notify.token" 2>/dev/null || true)
    [ -n "$tok" ] || { echo "release: проверка меню пропущена — нет токена приложения" >&2; return 0; }
    n=$(wc -l < "$log" 2>/dev/null || echo 0)
    open -g "ocbar://debug-menu?token=$tok"
    sleep 10
    v=$(tail -n +"$((n + 1))" "$log" 2>/dev/null | grep 'проверка меню: ИТОГ' | tail -1 | sed 's/^.*проверка меню: //')
    case "$v" in
        "ИТОГ ОК"*) echo "release: меню — $v" ;;
        *) echo "release: меню — ${v:-итога нет} (подробности: grep 'проверка меню' $log)" >&2 ;;
    esac
}

if [ -n "$publish_only" ]; then
    git rev-parse -q --verify "refs/tags/v$ver" >/dev/null || { echo "release: тега v$ver нет — сначала обычный выпуск" >&2; exit 1; }
    grep -q "tag: *\"v$ver\"" Formula/ocbar.rb || { echo "release: формула не на v$ver" >&2; exit 1; }
    publish
    exit 0
fi
git rev-parse -q --verify "refs/tags/v$ver" >/dev/null && { echo "release: тег v$ver уже есть" >&2; exit 1; }

# Проверки — до отправки: выпуск не должен зависеть от того, заметит ли
# кто-то красный CI уже после push.
echo "release: проверки перед выпуском"
# Хелпер изменился с прошлого выпуска — его VERSION тоже: по ней doctor и
# `ocbar version` видят, что установленная копия отстала (0.17.2 — не видели).
prev=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
[ -z "$prev" ] || tools/helper-version-check.sh "$prev" || { echo "release: хелпер изменился, а его версия нет" >&2; exit 1; }
python3 tools/i18n-scan.py --check >/dev/null || { python3 tools/i18n-scan.py --check; echo "release: интерфейс переведён не весь" >&2; exit 1; }
echo "release: installer and embedded CSD checks"
python3 tools/installer-selftest.py
python3 tools/embedded-csd-selftest.py
python3 tools/profile-workflow-selftest.py
echo "release: build auth"
swift build -c release --package-path auth >/dev/null
echo "release: auth self-test"
run_checked auth/.build/release/ocbar-auth --selftest
echo "release: HostScan gateway sequence"
run_checked python3 tools/hostscan-sequence-test.py
echo "release: WebKit learn self-test"
run_checked auth/.build/release/ocbar-auth --learn-selftest
echo "release: helper self-test"
run_checked tools/helper-selftest.sh
echo "release: CLI self-test"
OCBAR_AUTH="$root/auth/.build/release/ocbar-auth" run_checked bin/ocbar selftest
# И в песочнице brew test (tools/brew-sandbox.sb): там нет прав машины —
# записи экрана, камеры, служб системы. Проверка, которая на них молча
# опирается, падает здесь, до push, а не в brew test после выпуска (0.15.2).
echo "release: Homebrew sandbox self-tests"
sbtmp=$(mktemp -d /private/tmp/ocbar-brewsb.XXXXXX)
TMPDIR="$sbtmp" OCBAR_AUTH="$root/auth/.build/release/ocbar-auth" \
    sandbox-exec -f tools/brew-sandbox.sb bin/ocbar selftest > "$sbtmp.log" 2>&1 \
    || { grep -E 'FAIL|selftest:' "$sbtmp.log" >&2; echo "release: самопроверка не проходит в песочнице brew — полный вывод: $sbtmp.log" >&2; exit 1; }
TMPDIR="$sbtmp" sandbox-exec -f tools/brew-sandbox.sb auth/.build/release/ocbar-auth --selftest > "$sbtmp.log" 2>&1 \
    || { grep -E 'FAIL|selftest:' "$sbtmp.log" >&2; echo "release: ocbar-auth --selftest не проходит в песочнице brew — $sbtmp.log" >&2; exit 1; }
rm -rf "$sbtmp" "$sbtmp.log"
echo "release: build app"
app/make-app.sh >/dev/null
echo "release: app self-test"
run_checked app/.build/ocbar.app/Contents/MacOS/ocbar-app --selftest
grep -q "^## $ver " CHANGELOG.md || { echo "release: в CHANGELOG.md нет раздела $ver" >&2; exit 1; }

sed -i '' -E "s/^VERSION=\"[^\"]*\"/VERSION=\"$ver\"/" bin/ocbar
bin/ocbar version | grep -qx "ocbar $ver"
git add bin/ocbar && git commit -q -m "release: $ver"
# Согласуем дату тега с выпускным коммитом, включая нормализацию локальными хуками.
GIT_COMMITTER_DATE="$(git log -1 --format=%cI)" git tag -a "v$ver" -m "ocbar $ver: $note"
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
publish
