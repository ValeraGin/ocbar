#!/bin/bash
# Хелпер изменился — его VERSION тоже должен смениться:
#   tools/helper-version-check.sh <база> [<версия>]
# <база> и <версия> — ссылки git (тег, коммит); без <версия> — рабочее дерево.
#
# По VERSION `ocbar version` и doctor отличают установленную копию хелпера
# от той, что лежит в пакете. 0.17.2 изменил хелпер, а VERSION остался
# 0.8.1: старая копия выглядела как новая, и исправление лишних сессий не
# действовало, пока его не нашли сравнением файлов (2026-09-23).
set -euo pipefail
base="${1:?база: тег или коммит, например v0.17.2}"; head="${2:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
f=libexec/ocbar-helper
ver() { sed -n 's/^VERSION="\([^"]*\)".*/\1/p' | head -1; }

old=$(git -C "$root" show "$base:$f") || { echo "helper-version-check: нет $f в $base" >&2; exit 2; }
if [ -n "$head" ]; then
    new=$(git -C "$root" show "$head:$f") || { echo "helper-version-check: нет $f в $head" >&2; exit 2; }
else
    new=$(cat "$root/$f")
fi
[ "$old" != "$new" ] || exit 0
v_old=$(printf '%s\n' "$old" | ver); v_new=$(printf '%s\n' "$new" | ver)
if [ "$v_old" = "$v_new" ]; then
    echo "helper-version-check: $f изменился с $base, а VERSION тот же ($v_new) — поднимите его:" >&2
    echo "  иначе установленная копия выглядит свежей, и никто не узнает, что нужен sudo ocbar install" >&2
    exit 1
fi
echo "helper-version-check: хелпер $v_old → $v_new"
