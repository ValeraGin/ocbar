#!/bin/bash
# Самопроверка клиента: 200+ проверок на временном состоянии, с заглушкой
# хелпера вместо настоящего. Файл подгружается (source) самим `ocbar
# selftest` — ему нужны внутренние функции клиента, а держать тысячу строк
# проверок в самом клиенте незачем: правится он чаще, чем читается целиком.
#
# Отдельно не запускается: без окружения bin/ocbar здесь нет ни путей, ни
# функций.
# на рабочей машине с живой сессией.
cmd_selftest() {
    local tmp fails=0 total=0 skipped=0 out rc port bad qa tok oc ours foreign lp
    local -a pids=()
    # Окна и причины отказа ocbar-auth — на языке системы; проверки сверяют
    # русский текст, поэтому язык закреплён.
    export OCBAR_LANG=ru
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ocbar-selftest.XXXXXX") || die "нет временного каталога"
    mkdir -p "$tmp/profiles" "$tmp/state" "$tmp/var" "$tmp/logs" "$tmp/other/profiles" "$tmp/fake" "$tmp/foreign"
    # Заглушка хелпера: пишет вызов в журнал и ведёт socks.state, как настоящий.
    cat > "$tmp/helper" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$OCBAR_STATE_DIR/helper.log"
[ "${1:-}" = --dry-run ] && shift
m="$OCBAR_STATE_DIR/socks.state"
case "${1:-}" in
    version)     echo "ocbar-helper selftest" ;;
    socks-set)   printf '%s %s\n' "$2" "$3" >> "$m" ;;
    socks-clear) if [ "${OCBAR_STUB_KEEP_SOCKS:-0}" != 1 ] && [ -f "$m" ]; then grep -Fv "$2 " "$m" > "$m.tmp" || true; mv "$m.tmp" "$m"; fi ;;
esac
exit 0
STUB
    chmod +x "$tmp/helper"

    run() { OCBAR_CONFIG_DIR="$tmp" OCBAR_USER_STATE="$tmp/state" OCBAR_STATE_DIR="$tmp/var" OCBAR_LOG_DIR="$tmp/logs" \
            OCBAR_CONFIG="$tmp/zones.conf" OCBAR_NETWORKS="$tmp/networks.conf" \
            OCBAR_SELFTEST_HELPER="$tmp/helper" OCBAR_OPENCONNECT="${OCBAR_OPENCONNECT:-/usr/bin/true}" OCBAR_NOTIFY=0 "$SELF" "$@" 2>&1; }
    has()  { # имя, что искать, где
        total=$((total+1))
        if printf '%s' "$3" | grep -Fq -- "$2"; then ok "$1"; else fails=$((fails+1)); bad "$1" "нет «${2}»"; fi
    }
    hasnt() {
        total=$((total+1))
        if printf '%s' "$3" | grep -Fq -- "$2"; then fails=$((fails+1)); bad "$1" "нашлось «${2}», а не должно"; else ok "$1"; fi
    }
    # Через регулярное выражение: интерфейс в строке маршрута зависит от
    # таблицы маршрутизации машины, и сравнивать её целиком нельзя.
    matches() {
        total=$((total+1))
        if printf '%s' "$3" | grep -Eq -- "$2"; then ok "$1"; else fails=$((fails+1)); bad "$1" "не подошло /${2}/"; fi
    }
    is() { # имя, ожидаемое, фактическое — точно
        total=$((total+1))
        if [ "$2" = "$3" ]; then ok "$1"; else fails=$((fails+1)); bad "$1" "ждали «${2}», получили «${3}»"; fi
    }
    same() { # имя, файл, эталон — побайтно
        total=$((total+1))
        if cmp -s "$2" "$3"; then ok "$1"; else
            fails=$((fails+1)); bad "$1" "не совпало с эталоном:"
            # «|| true»: diff при расхождении даёт 1, и под pipefail провал
            # одной проверки обрывал бы всю самопроверку.
            diff "$3" "$2" 2>&1 | head -20 | sed 's/^/        /' || true
        fi
    }
    check() { local name="$1"; shift; total=$((total+1)); if "$@"; then ok "$name"; else fails=$((fails+1)); bad "$name"; fi; }
    omit() { skipped=$((skipped+1)); skip "$1" "пропущено: $2"; }
    # Жив ли процесс (зомби — не жив). Поддельные процессы — сироты, их
    # подбирает launchd, поэтому зомби не задерживаются.
    alive() { case "$(ps -p "$1" -o stat= 2>/dev/null)" in ''|Z*) return 1 ;; *) return 0 ;; esac; }
    gone_now() { ! alive "$1"; }
    gone()  { local i=0; while alive "$1" && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done; ! alive "$1"; }
    # Фоновый процесс-сирота; печатает свой номер. Каждый живёт не дольше
    # двух минут, даже если проверка оборвётся.
    spawn() { ( "$@" </dev/null >/dev/null 2>&1 & printf '%s' "$!" ); }
    # Поддельный процесс с нужным именем: ps -o comm= показывает argv[0].
    # SIGINT возвращён по умолчанию — фоновым процессам скрипта его ставят в
    # «игнорировать», а openconnect гасится именно им.
    fake() { spawn /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec { $ARGV[0] } @ARGV[1 .. $#ARGV]' /bin/sleep "$1" 120; }
    # Поддельный openconnect туннеля: имя и --pid-file — как у запущенного
    # хелпером, по ним клиент и находит лишние сессии.
    fake_tun() { spawn /usr/bin/perl -e 'exec { "/usr/bin/perl" } "openconnect", "-e", q($SIG{INT} = "DEFAULT"; sleep 120), "--", "--pid-file", $ARGV[0]' "$1"; }
    listen() { spawn /usr/bin/python3 -c 'import signal, socket, sys
signal.alarm(120)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
while True:
    c, _ = s.accept(); c.close()' "$1"; }
    # «Чужой» ocproxy: командная строка «…/ocproxy -D <порт>» — ровно то,
    # что прежняя уборка искала pgrep -f и гасила.
    printf '#!/bin/bash\n# пустышка чужого ocproxy для проверки уборки\nfor i in $(seq 1 120); do sleep 1; done\n' > "$tmp/foreign/ocproxy"
    chmod +x "$tmp/foreign/ocproxy"
    # Свой порт для прокси-профилей: 11080 может держать живая сессия.
    port=$((21000 + RANDOM % 20000)); while port_open "$port"; do port=$((port + 1)); done

    cat > "$tmp/profiles/t.ocbar" <<'PROFILE'
[Connection]
Name = Проба
Url  = vpn.example.test/group
User = tester

[Routes]
10.11.12.0/24
не-сеть
0.0.0.0/1

[DNS]
example.test = 192.0.2.10
bad.test     = не-адрес

[Auth]
Totp = off

[Health]
Check = wiki.example.test:443
PROFILE

    info "ocbar selftest ($VERSION)"
    out=$(run status --short || true)
    has "состояние без туннеля" "state=down" "$out"
    has "профиль в списке" "profile_list=t|Проба||" "$out"
    has "адрес профиля отдельной строкой" "profile_url=t|vpn.example.test/group" "$out"

    # Файлы состояния заводятся объявлением наверху скрипта: иначе флаг
    # появляется где-то в середине, и о нём не знают ни уборка, ни `ocbar
    # state`, ни документация. Здесь — список тех, что объявлены иначе
    # (их пишут не мы или пишут рядом с использованием).
    local stray
    stray=$(grep -v '^[A-Z_][A-Z_0-9]*="\$USER_STATE' "$SELF" \
            | grep -o '"\$USER_STATE/[a-zA-Z._-]*"' \
            | tr -d '"' | sed 's|\$USER_STATE/||' | sort -u \
            | grep -v -x -e rules -e notify.token -e notify.allowed -e notify.last \
                        -e proxy.env -e proxy.pid -e supervisor.logins || true)
    is "состояние: файлы заводятся только объявлением наверху" "" "$stray"

    # Примет ли клиент файл профиля: этим редактор проверяет форму перед
    # сохранением.
    printf '[Connection]\nName = Проба\nUrl = vpn.example.test/g\nUser = t\n' > "$tmp/chk-ok.ocbar"
    printf '[Connection]\nName = Плохой\nUrl = vpn.example.test/g\nUser = t\nMtu = 99\n' > "$tmp/chk-bad.ocbar"
    local chk
    chk=$(run profile-check "$tmp/chk-ok.ocbar"; echo "rc=$?")
    has "profile-check: годный профиль принят" "rc=0" "$chk"
    chk=$(run profile-check "$tmp/chk-bad.ocbar"; echo "rc=$?")
    has "profile-check: негодный профиль отвергнут" "rc=1" "$chk"
    has "profile-check: сказана причина" "Mtu вне 576–9000" "$chk"
    hasnt "profile-check: в причине нет пути к файлу" "$tmp" "$chk"
    rm -f "$tmp/chk-ok.ocbar" "$tmp/chk-bad.ocbar"

    # Машинное состояние: приложение читает его целиком, поэтому проверяем
    # не текст, а разобранный JSON.
    # run() подмешивает поток ошибок — берём только строку JSON.
    local js; js=$(run status --json | grep '^{' | tail -1)
    is "status --json: состояние" "down" \
       "$(printf '%s' "$js" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' 2>/dev/null || echo "не JSON")"
    is "status --json: сеть профиля списком объектов" "10.11.12.0/24 on" \
       "$(printf '%s' "$js" | /usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin); r=d["routes"][0]; print(r["net"], "on" if r["on"] else "off")' 2>/dev/null || echo "не JSON")"
    is "status --json: профиль с адресом" "t vpn.example.test/group" \
       "$(printf '%s' "$js" | /usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin); p=d["profiles"][0]; print(p["name"], p["url"])' 2>/dev/null || echo "не JSON")"
    is "status --json: название профиля" "Проба" \
       "$(printf '%s' "$js" | /usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin); print(d["profiles"][0]["title"])' 2>/dev/null || echo "не JSON")"

    # Общий журнал: строки разных файлов — одной лентой по времени; строка
    # без времени — сразу за предыдущей своего файла.
    mkdir -p "$tmp/logs"
    printf '2026-01-02 10:00:05 супервизор-пять\n2026-01-02 10:00:01 супервизор-один\n' > "$tmp/logs/supervisor.log"
    printf '2026-01-02 10:00:03 ocbar-auth: вход-три\nпродолжение-без-времени\n' > "$tmp/logs/auth.log"
    local merged; merged=$(run logs -n 10 supervisor auth | tr -s ' ')
    is "общий журнал: по времени, продолжение за своей строкой" \
       "10:00:01 супервизор супервизор-один|10:00:03 вход вход-три|10:00:03 вход продолжение-без-времени|10:00:05 супервизор супервизор-пять" \
       "$(printf '%s\n' "$merged" | grep -v '──' | paste -sd'|' -)"
    rm -f "$tmp/logs/supervisor.log" "$tmp/logs/auth.log"
    status_out=$out
    # Парольная группа: подставной openconnect спрашивает пароль и код, как
    # шлюз; пароль ocbar берёт из профиля, код — у «человека» (команда).
    cat > "$tmp/profiles/pw.ocbar" <<'PROFILE'
[Connection]
Name = Пароль и SMS
Url  = vpn.example.test/pw
User = tester
Auth = password

[Auth]
Password        = command
PasswordCommand = echo secret-pw
PROFILE
    cat > "$tmp/ocpw" <<'STUB'
#!/bin/bash
echo "POST https://vpn.example.test/pw"
printf 'Password:'; IFS= read -r p
printf 'Response:'; IFS= read -r c
printf '%s %s %s\n' "$p" "$c" "$*" > "$OCBAR_PWSTUB_LOG"
[ "$p" = secret-pw ] && [ "$c" = 424242 ] || { echo "Login failed."; exit 1; }
echo "COOKIE='tok123'"
echo "HOST='192.0.2.5'"
echo "CONNECT_URL='https://node.example.test/pw'"
echo "FINGERPRINT='pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='"
STUB
    chmod +x "$tmp/ocpw"
    out=$(OCBAR_OPENCONNECT="$tmp/ocpw" OCBAR_PWSTUB_LOG="$tmp/pwstub.log" \
          OCBAR_PROMPT_CMD='printf "%s" "$OCBAR_PROMPT_LABEL" > '"$tmp"'/pwlabel; echo 424242' \
          run _selftest-fn pw_auth pw </dev/null || true)
    has "парольная группа: сессия от openconnect --authenticate" "tok123 pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= https://node.example.test/pw" "$out"
    is "парольная группа: пароль и код дошли до шлюза" "secret-pw 424242" "$(cut -d' ' -f1-2 "$tmp/pwstub.log" 2>/dev/null)"
    has "парольная группа: openconnect только аутентифицирует" "--authenticate" "$(cat "$tmp/pwstub.log" 2>/dev/null)"
    is "парольная группа: человеку показана подпись шлюза" "Response:" "$(cat "$tmp/pwlabel" 2>/dev/null)"
    hasnt "парольная группа: пароль и код не в выводе" "secret-pw" "$out"
    out=$(OCBAR_OPENCONNECT="$tmp/ocpw" OCBAR_PWSTUB_LOG="$tmp/pwstub.log" OCBAR_PROMPT_CMD='echo 111111' \
          run _selftest-fn pw_auth pw </dev/null; echo "rc=$?")
    has "парольная группа: неверный код — отказ с причиной" "Login failed" "$out"
    has "парольная группа: неверный код — ненулевой код" "rc=1" "$out"
    out=$(OCBAR_OPENCONNECT="$tmp/ocpw" OCBAR_PWSTUB_LOG="$tmp/pwstub.log" OCBAR_PROMPT_CMD='exit 3' \
          run _selftest-fn pw_auth pw </dev/null; echo "rc=$?")
    has "парольная группа: отмена окна кода — вход отменён" "вход отменён" "$out"
    out=$(OCBAR_SILENT=1 OCBAR_OPENCONNECT="$tmp/ocpw" run _selftest-fn pw_auth pw </dev/null; echo "rc=$?")
    has "парольная группа: автоподключение не зовёт человека — код 5" "rc=5" "$out"
    # Пароля нет в источнике — его тоже спрашивают у человека, со звёздочками.
    sed -i '' 's/^PasswordCommand = echo secret-pw/PasswordCommand = true/' "$tmp/profiles/pw.ocbar"
    out=$(OCBAR_OPENCONNECT="$tmp/ocpw" OCBAR_PWSTUB_LOG="$tmp/pwstub.log" \
          OCBAR_PROMPT_CMD='if [ -n "$OCBAR_PROMPT_SECRET" ]; then echo secret-pw; else echo 424242; fi' \
          run _selftest-fn pw_auth pw </dev/null || true)
    has "парольная группа: пароля нет — спрошен у человека, вход прошёл" "tok123" "$out"
    # Дальше проверки рассчитаны на единственный профиль t.
    rm -f "$tmp/profiles/pw.ocbar"
    out=$status_out
    has "профиль по умолчанию" "default=t" "$out"
    has "режим профиля" "profile_mode=tunnel" "$out"
    has "порт SOCKS по умолчанию" "proxy_port=11080" "$out"
    has "сеть профиля" "route=10.11.12.0/24 " "$out"
    hasnt "некорректная сеть отброшена" "route=не-сеть" "$out"
    has "предупреждение о широкой сети" "уводит в туннель почти весь трафик" "$out"
    has "зона профиля" "zone=example.test 192.0.2.10 - on" "$out"
    hasnt "зона с нечисловым адресом отброшена" "zone=bad.test" "$out"
    # Код выхода: connect, pause и resume зовут status в конце, и приложение
    # судит об успехе по коду.
    rc=0; run status >/dev/null || rc=$?
    is "status: код 0" 0 "$rc"
    : > "$tmp/state/needs-login"; rc=0; run status >/dev/null || rc=$?; rm -f "$tmp/state/needs-login"
    is "status: код 0 и при флаге «нужен вход»" 0 "$rc"
    rc=0; run profiles >/dev/null || rc=$?
    is "profiles: код 0, когда у последнего профиля нет описания" 0 "$rc"

    # profiles.conf с BOM и CRLF, секция с именем профиля-файла, «|» в названии.
    printf '\357\273\277[old]\r\nurl = vpn.example.test/o\r\nname = Старый|формат\r\n\r\n[t]\r\nurl = vpn.example.test/dup\r\n' > "$tmp/profiles.conf"
    out=$(run status --short || true)
    is "profile_list: профиль-файл и одноимённая секция — одна строка" 1 "$(printf '%s\n' "$out" | grep -c '^profile_list=t|' || true)"
    has "profile_list: «|» в названии заменён на «¦»" "profile_list=old|Старый¦формат||" "$out"
    # Порядок профилей: как расставил человек, неизвестное имя — отказ.
    printf '[Connection]\nName = Второй\nUrl = vpn.example.test/b\n' > "$tmp/profiles/b2.ocbar"
    run profiles order b2 >/dev/null 2>&1 || true
    is "profiles order: указанный профиль первым в меню" "b2" "$(run status --short | sed -n 's/^profile_list=\([^|]*\)|.*/\1/p' | head -1 || true)"
    is "profiles order: в ocbar profiles тот же порядок" "b2" "$(run profiles order | head -1 || true)"
    is "profiles order: неизвестный профиль — отказ" fail "$( (run profiles order nope >/dev/null 2>&1) && echo ok || echo fail)"
    rm -f "$tmp/profiles/b2.ocbar" "$tmp/profiles.order"
    matches "profiles.conf с BOM и CRLF: адрес без мусора" '^Url += vpn\.example\.test/o$' "$(run export old)"
    rm -f "$tmp/profiles.conf"
    printf '\357\273\277[Connection]\r\nName = БОМ\r\nUrl = vpn.example.test/bom\r\n\r\n[Routes]\r\n10.20.0.0/16\r\n' > "$tmp/profiles/bom.ocbar"
    out=$(run export bom || true)
    matches "профиль-файл с BOM и CRLF: Url из первой секции" '^Url += vpn\.example\.test/bom$' "$out"
    has "профиль-файл с BOM и CRLF: сеть на месте" "10.20.0.0/16" "$out"
    rm -f "$tmp/profiles/bom.ocbar"
    # Хвостовой комментарий в строке DNS — не порт; [Proxy] с нестандартным портом
    # не теряется при выгрузке туннельного профиля (так же пишет приложение).
    printf '[Connection]\nName = Хвост\nUrl = vpn.example.test/tail\n\n[DNS]\nint.example.test = 192.0.2.53 # офис\n\n[Proxy]\nPort = 11999\n' > "$tmp/profiles/tail.ocbar"
    out=$(run export tail || true)
    matches "DNS: комментарий в конце строки — не порт" '^int\.example\.test +\= 192\.0\.2\.53$' "$out"
    matches "export: [Proxy] с портом 11999 в туннельном профиле сохранён" '^Port += 11999$' "$out"
    rm -f "$tmp/profiles/tail.ocbar"

    # Переключатели без туннеля меняют только состояние — привилегий не надо.
    run routes del 10.11.12.0/24 >/dev/null || true
    matches "сеть выключается" "route=10\.11\.12\.0/24 .* off" "$(run status --short)"
    run routes add 10.11.12.0/24 >/dev/null || true
    matches "сеть возвращается" "route=10\.11\.12\.0/24 .* on" "$(run status --short)"
    run dns off example.test >/dev/null || true
    has "зона выключается" "zone=example.test 192.0.2.10 - off" "$(run status --short)"
    run dns on example.test >/dev/null || true
    has "зона возвращается" "zone=example.test 192.0.2.10 - on" "$(run status --short)"
    # Снять маршруты и зоны без туннеля — нечего: хелпер от root не зовётся.
    : > "$tmp/var/helper.log"
    run routes clear >/dev/null || true
    run dns clear >/dev/null || true
    is "routes clear и dns clear без туннеля хелпер не зовут" "" "$(cat "$tmp/var/helper.log")"
    printf 'example.test\n' > "$tmp/var/zones.state"
    run dns clear >/dev/null || true
    has "dns clear при наших зонах зовёт хелпер" "dns-clear" "$(cat "$tmp/var/helper.log")"
    rm -f "$tmp/var/zones.state"; : > "$tmp/var/helper.log"

    has "пути в version --all" "config_dir=$tmp" "$(run version --all)"
    has "профиль в списке profiles" "Проба" "$(run profiles)"

    # Экспорт и импорт: файл, выданный наружу, должен читаться обратно.
    run export t "$tmp/out.ocbar" >/dev/null || true
    out=$(cat "$tmp/out.ocbar" 2>/dev/null || true)
    has "экспорт: секция сетей" "[Routes]" "$out"
    has "экспорт: сеть на месте" "10.11.12.0/24" "$out"
    has "экспорт: проверка доступа" "wiki.example.test:443" "$out"
    cp "$tmp/out.ocbar" "$tmp/other/profiles/copy.ocbar" 2>/dev/null || true
    has "экспортированный профиль читается" "Проба" \
        "$(OCBAR_CONFIG_DIR="$tmp/other" OCBAR_USER_STATE="$tmp/state" OCBAR_STATE_DIR="$tmp/var" OCBAR_LOG_DIR="$tmp/logs" \
           OCBAR_SELFTEST_HELPER="$tmp/helper" OCBAR_NOTIFY=0 "$SELF" profiles 2>&1)"

    # Неверные значения должны отвергаться, а не молча менять поведение.
    # Только загрузкой профиля: через connect поломка валидации дошла бы до входа.
    make_bad() { printf '[Connection]\nName = Плохой\nUrl = vpn.example.test/g\n%s\n' "$1" > "$tmp/profiles/bad.ocbar"; }
    make_bad "Mode = никак"
    has "неизвестный режим отвергнут" "Mode = tunnel или proxy" "$(run _check-profile bad)"
    make_bad "$(printf '\n[Proxy]\nPort = 80')"
    has "порт вне диапазона отвергнут" "вне диапазона" "$(run _check-profile bad)"
    make_bad "$(printf '\n[Auth]\nPassword = ниоткуда')"
    has "неизвестный источник пароля отвергнут" "password = auto" "$(run _check-profile bad)"
    # Точная строка: при Totp = off «вводит человек» есть и в строке кода, и
    # общий шаблон не заметил бы потерю строки пароля.
    make_bad "$(printf '\n[Auth]\nPassword = ask\nTotp = keychain\nKeychainService = ocbar.selftest.invalid')"
    matches "secret status: «пароль — вводит человек» (Totp = keychain)" '\[ !! \] пароль +вводит человек \(password = ask\)$' "$(run secret status bad)"
    rm -f "$tmp/profiles/bad.ocbar"

    # Прокси-режим: без сети и без ocproxy проверяется всё, кроме самого
    # openconnect — команда запуска, программа туннеля, состояние, уборка,
    # системный SOCKS, переключение. Порт — свой.
    printf '[Connection]\nName = Прокси\nUrl = vpn.example.test/g\nUser = tester\nMode = proxy\n\n[Proxy]\nPort = %s\nSystemProxy = on\n\n[Auth]\nTotp = off\n' "$port" > "$tmp/profiles/px.ocbar"
    printf 'px\n' > "$tmp/state/desired"      # выбранный профиль — как после connect
    out=$(run status --short || true)
    has "режим прокси в status" "profile_mode=proxy" "$out"
    has "галочка системного SOCKS в status" "system_proxy=on" "$out"
    has "порт профиля в status" "proxy_port=$port" "$out"
    out=$(OCBAR_OCPROXY=/usr/bin/true run connect --dry-run px || true)
    has "прокси: openconnect со --script-tun" "--script-tun" "$out"
    has "прокси: программа туннеля — ocbar" "_proxy-tun" "$out"
    hasnt "прокси: хелпер не зовётся" "tunnel-start" "$out"
    has "прокси: порт профиля доходит до ocproxy" "ocproxy -D $port " "$out"
    printf 'PORT=%s\n' "$port" > "$tmp/state/proxy.env"
    out=$(VPNFD=3 INTERNAL_IP4_ADDRESS=10.9.8.7 INTERNAL_IP4_DNS=10.0.0.1 OCBAR_OCPROXY=/usr/bin/true \
          OCBAR_PROXY_PORT="$port" run _proxy-tun || true; cat "$tmp/state/proxy.env" 2>/dev/null || true)
    has "программа туннеля пишет адрес" "IP4=10.9.8.7" "$out"
    has "программа туннеля пишет DNS шлюза" "DNS=10.0.0.1" "$out"
    has "программа туннеля отмечает connected" "STATE=connected" "$out"
    matches "программа туннеля пишет номер ocproxy" '^OCPROXY_PID=[0-9]+$' "$out"
    has "программа туннеля без openconnect отказывает" "нет VPNFD" "$(run _proxy-tun)"
    # Уборка: состояние без процесса, чужой ocproxy на том же порту.
    foreign=$(spawn "$tmp/foreign/ocproxy" -D "$port"); pids+=("$foreign")
    run cleanup --dry-run >/dev/null || true
    check "уборка --dry-run: чужой «ocproxy -D ${port}» жив" alive "$foreign"
    has "уборка --dry-run: состояние не тронуто" "STATE=connected" "$(cat "$tmp/state/proxy.env")"
    run cleanup >/dev/null || true
    check "уборка: чужой «ocproxy -D ${port}» жив" alive "$foreign"
    has "уборка: состояние без процесса помечено отключённым" "STATE=disconnected" "$(cat "$tmp/state/proxy.env")"
    ours=$(fake "$tmp/fake/ocproxy"); pids+=("$ours")
    printf 'STATE=disconnected\nPORT=%s\nOCPROXY_PID=%s\n' "$port" "$ours" > "$tmp/state/proxy.env"
    run cleanup --dry-run >/dev/null || true
    check "уборка --dry-run: свой осиротевший ocproxy не гасится" alive "$ours"
    run cleanup >/dev/null || true
    check "уборка: свой осиротевший ocproxy гасится" gone "$ours"
    # Живая прокси-сессия (поддельная): openconnect, свой ocproxy, порт занят.
    lp=$(listen "$port"); pids+=("$lp")
    rc=0; while ! port_open "$port" && [ $rc -lt 30 ]; do sleep 0.1; rc=$((rc+1)); done
    oc=$(fake "$tmp/fake/openconnect"); pids+=("$oc")
    ours=$(fake "$tmp/fake/ocproxy"); pids+=("$ours")
    printf '%s\n' "$oc" > "$tmp/state/proxy.pid"
    printf 'STATE=connected\nPORT=%s\nPROFILE=px\nSYS_PROXY=on\nOCPROXY_PID=%s\n' "$port" "$ours" > "$tmp/state/proxy.env"
    printf '[Connection]\nName = Прокси 2\nUrl = vpn.example.test/g2\nUser = tester\nMode = proxy\n\n[Proxy]\nPort = %s\n\n[Auth]\nTotp = off\n' "$port" > "$tmp/profiles/px2.ocbar"
    out=$(OCBAR_OCPROXY=/usr/bin/true run connect --dry-run px2 || true)
    hasnt "переключение прокси-профилей: порт своей сессии не помеха" "уже занят" "$out"
    has "переключение прокси-профилей: сначала отключение старого" "сначала отключение профиля [px]" "$out"
    : > "$tmp/var/helper.log"
    OCBAR_SELFTEST_SERVICE="Selftest LAN" run _selftest-fn socks_apply >/dev/null || true
    has "системный SOCKS: socks-set на активный сервис и порт профиля" "socks-set Selftest LAN $port" "$(cat "$tmp/var/helper.log")"
    run _selftest-fn socks_clear_all >/dev/null || true
    has "системный SOCKS: socks-clear снимает свой" "socks-clear Selftest LAN" "$(cat "$tmp/var/helper.log")"
    is "системный SOCKS: в манифесте пусто" "" "$(cat "$tmp/var/socks.state" 2>/dev/null)"
    OCBAR_SELFTEST_SERVICE="Selftest LAN" run _selftest-fn socks_apply >/dev/null || true
    : > "$tmp/var/helper.log"
    run _selftest-fn proxy_stop >/dev/null || true
    check "proxy_stop: openconnect остановлен" gone "$oc"
    check "proxy_stop: свой ocproxy остановлен" gone "$ours"
    check "proxy_stop: чужой «ocproxy -D ${port}» жив" alive "$foreign"
    has "proxy_stop: системный SOCKS снят" "socks-clear Selftest LAN" "$(cat "$tmp/var/helper.log")"
    has "proxy_stop: состояние disconnected" "STATE=disconnected" "$(cat "$tmp/state/proxy.env")"
    has "журнал — во временном каталоге" "прокси остановлен" "$(cat "$tmp/logs/supervisor.log" 2>/dev/null)"

    # Лишние сессии туннеля: наш openconnect, которого нет в pidfile. Прежний
    # хелпер не узнавал свой процесс, не гасил его, и такие копились; клиент
    # их не видел вовсе, а меню называло «чужим туннелем».
    local cur stray
    cur=$(fake_tun "$tmp/var/openconnect.pid"); stray=$(fake_tun "$tmp/var/openconnect.pid"); pids+=("$cur" "$stray")
    sleep 0.2
    printf '%s\n' "$cur" > "$tmp/var/openconnect.pid"
    out=$(run status --short || true)
    has "лишние сессии: номер в status --short" "strays=$stray" "$out"
    hasnt "лишние сессии: текущая не лишняя" "strays=$cur" "$out"
    matches "лишние сессии: список в status --json" "\"strays\": ?\\[\"$stray\"\\]" "$(run status --json | grep '^{' | tail -1)"
    has "лишние сессии: status называет" "pid $stray (с " "$(run status || true)"
    matches "лишние сессии: doctor называет" "Лишние сессии +openconnect: pid $stray" "$(run doctor || true)"
    rm -f "$tmp/var/openconnect.pid"
    out=$(run status --short || true)
    matches "лишние сессии: без текущей обе лишние" "^strays=($cur,$stray|$stray,$cur)\$" "$out"
    matches "лишние сессии: не «чужой туннель»" "^foreign=\$" "$out"
    # openconnect при выходе стирает общий pidfile — текущая узнаётся по
    # отметке запуска, которую пишет хелпер, и лишней не считается.
    printf '%s %s\n' "$cur" "$(ps -p "$cur" -o lstart= | tr -s ' ')" > "$tmp/var/openconnect.started"
    printf 'STATE=connected\nTUNDEV=utun9\n' > "$tmp/var/tunnel.env"
    out=$(run status --short || true)
    has "лишние сессии: pidfile стёрт — текущая по отметке запуска" "state=connected" "$out"
    matches "лишние сессии: pidfile стёрт — лишняя только лишняя" "^strays=$stray\$" "$out"
    printf '%s чужое время\n' "$cur" > "$tmp/var/openconnect.started"
    has "лишние сессии: отметка не того процесса — туннель не поднят" "state=down" "$(run status --short || true)"
    rm -f "$tmp/var/openconnect.started" "$tmp/var/tunnel.env"
    kill "$cur" "$stray" 2>/dev/null || true
    is "лишние сессии: нет процессов — нет и строки" "" "$(run status --short | grep '^strays=' || true)"

    # Маршруты не через utun туннеля: 21.09 tunnel.env говорил utun5, а
    # маршруты шли через utun6 лишней сессии. doctor молчал, супервизор писал
    # «маршруты пропали» каждые 5 с. Таблицу маршрутов подставляет заглушка.
    # Следующие проверки опираются на networks.conf и desired — вернуть как было.
    local nets_saved desired_saved=""; nets_saved=$(cat "$tmp/networks.conf" 2>/dev/null || true)
    [ -f "$tmp/state/desired" ] && desired_saved=$(cat "$tmp/state/desired")
    printf '10.0.0.0/8\n172.16.0.0/12\n' > "$tmp/networks.conf"
    printf '#!/bin/bash\ncase "$1" in 10.*) echo "${OCBAR_STUB_ROUTE_10:-utun9}" ;; *) echo utun9 ;; esac\n' > "$tmp/route"; chmod +x "$tmp/route"
    cur=$(fake_tun "$tmp/var/openconnect.pid"); pids+=("$cur"); sleep 0.2
    printf '%s\n' "$cur" > "$tmp/var/openconnect.pid"
    printf 'STATE=connected\nTUNDEV=utun9\n' > "$tmp/var/tunnel.env"
    matches "doctor: маршруты через utun туннеля" "Маршруты туннеля +через utun9" "$(OCBAR_SELFTEST_ROUTE="$tmp/route" run doctor || true)"
    out=$(OCBAR_SELFTEST_ROUTE="$tmp/route" OCBAR_STUB_ROUTE_10=utun6 run doctor || true)
    has "doctor: маршрут не через utun туннеля назван" "не через utun9: 10.0.0.0/8→utun6" "$out"
    hasnt "doctor: верный маршрут не назван" "172.16.0.0/12→" "$out"
    printf 't\n' > "$tmp/state/desired"; : > "$tmp/logs/supervisor.log"; : > "$tmp/var/helper.log"
    OCBAR_SELFTEST_ROUTE="$tmp/route" OCBAR_STUB_ROUTE_10=utun6 OCBAR_ACCESS_EVERY=99999999999 \
        run supervise --dry-run --iterations=2 >/dev/null || true
    is "супервизор: маршрут восстанавливается каждый круг" 2 "$(grep -c 'route-add 10.0.0.0/8' "$tmp/var/helper.log" || true)"
    is "супервизор: «маршруты пропали» — строка раз, а не каждый круг" 1 "$(grep -c 'маршруты пропали' "$tmp/logs/supervisor.log" || true)"
    # Зависший «запускается»: openconnect жив, до connect дело не дошло.
    # Раньше супервизор в этом состоянии не делал ничего — бесконечно.
    printf 'STATE=starting\n' > "$tmp/var/tunnel.env"; : > "$tmp/logs/supervisor.log"; : > "$tmp/var/helper.log"
    run supervise --dry-run --iterations=1 >/dev/null || true
    hasnt "супервизор: «запускается» меньше срока — не трогает" "tunnel-stop" "$(cat "$tmp/var/helper.log")"
    OCBAR_STARTING_LIMIT=0 run supervise --dry-run --iterations=1 >/dev/null || true
    has "супервизор: завис в «запускается» — останавливает" "tunnel-stop" "$(cat "$tmp/var/helper.log")"
    has "супервизор: завис в «запускается» — причина в журнале" "завис, останавливаю" "$(cat "$tmp/logs/supervisor.log")"
    kill "$cur" 2>/dev/null || true
    printf '%s\n' "$nets_saved" > "$tmp/networks.conf"
    rm -f "$tmp/var/openconnect.pid" "$tmp/var/tunnel.env" "$tmp/state/desired" "$tmp/route"
    [ -z "$desired_saved" ] || printf '%s\n' "$desired_saved" > "$tmp/state/desired"
    has "порт занят не нами — прокси-профиль отказывает" "уже занят" "$(OCBAR_OCPROXY=/usr/bin/true run connect --dry-run px2)"
    # Супервизор: прокси мёртв, ждём вход — свой системный SOCKS снимается не
    # только при старте, но и в цикле (заглушка его «не снимает», и каждое
    # снятие видно в журнале).
    : > "$tmp/state/needs-login"; printf 'Selftest LAN %s\n' "$port" > "$tmp/var/socks.state"; : > "$tmp/var/helper.log"
    OCBAR_STUB_KEEP_SOCKS=1 run supervise --dry-run --iterations=1 >/dev/null || true
    is "супервизор: при «нужен вход» свой системный SOCKS снимается и в цикле" 2 "$(grep -c 'socks-clear' "$tmp/var/helper.log" || true)"
    has "пауза без сессии отказывает" "паузить нечего" "$(run pause)"
    rm -f "$tmp/profiles/px.ocbar" "$tmp/profiles/px2.ocbar" "$tmp/state/proxy.env" "$tmp/state/proxy.pid" \
          "$tmp/state/desired" "$tmp/state/needs-login" "$tmp/var/socks.state"

    # Правила автозаполнения в самом профиле: селектор с «=» должен пережить
    # разбор, импорт — заменить секцию и не тронуть остальное, экспорт —
    # унести правила с собой.
    has "без правил — встроенные" "autofill=builtin" "$(run status --short)"
    printf '\n[Autofill]\nstop div.alert-error\nfill username input[name=username]\nclick button[type=submit]\n' >> "$tmp/profiles/t.ocbar"
    out=$(run rules show t || true)
    has "правила из профиля" "inline" "$out"
    has "селектор с «=» цел" "fill username input[name=username]" "$out"
    has "источник правил в status" "autofill=inline" "$(run status --short)"
    printf 'fill password input[type=password]\nclick! a.other-way\n' > "$tmp/new.rules"
    run rules import "$tmp/new.rules" t >/dev/null || true
    out=$(cat "$tmp/profiles/t.ocbar")
    has "импорт: новое правило на месте" "click! a.other-way" "$out"
    hasnt "импорт: старое правило убрано" "input[name=username]" "$out"
    has "импорт: остальные секции целы" "wiki.example.test:443" "$out"
    has "импорт: резервная копия" "input[name=username]" "$(cat "$tmp/profiles/t.ocbar.bak" 2>/dev/null)"
    printf 'fill nothing x\n' > "$tmp/bad.rules"
    has "непонятное правило отвергнуто" "не приняты" "$(run rules import "$tmp/bad.rules" t)"
    has "экспорт уносит правила" "[Autofill]" "$(run export t)"
    run rules clear t >/dev/null || true
    hasnt "секция убирается" "[Autofill]" "$(cat "$tmp/profiles/t.ocbar")"
    # [Autofill] в середине файла: импорт переносит её в конец, а всё
    # остальное — вместе с комментарием над следующей секцией — побайтно цело.
    printf '[Connection]\nName = Середина\nUrl = vpn.example.test/m\n\n[Autofill]\nfill username input[id=u]\n\n# проверка доступа\n[Health]\nCheck = h:443\n\n[Proxy]\nPort = %s\n' "$port" > "$tmp/profiles/m.ocbar"
    run rules import "$tmp/new.rules" m >/dev/null || true
    printf '[Connection]\nName = Середина\nUrl = vpn.example.test/m\n\n# проверка доступа\n[Health]\nCheck = h:443\n\n[Proxy]\nPort = %s\n\n[Autofill]\nfill password input[type=password]\nclick! a.other-way\n' "$port" > "$tmp/want"
    same "импорт в середину: остальное побайтно цело, [Autofill] в конце" "$tmp/profiles/m.ocbar" "$tmp/want"
    run rules clear m >/dev/null || true
    printf '[Connection]\nName = Середина\nUrl = vpn.example.test/m\n\n# проверка доступа\n[Health]\nCheck = h:443\n\n[Proxy]\nPort = %s\n' "$port" > "$tmp/want"
    same "rules clear: соседние секции побайтно целы" "$tmp/profiles/m.ocbar" "$tmp/want"
    cp "$tmp/profiles/m.ocbar" "$tmp/m.before"; cp "$tmp/profiles/m.ocbar.bak" "$tmp/m.before.bak"
    run rules import "$tmp/bad.rules" m >/dev/null || true
    same "отвергнутые правила: профиль не тронут" "$tmp/profiles/m.ocbar" "$tmp/m.before"
    same "отвергнутые правила: .bak не тронут" "$tmp/profiles/m.ocbar.bak" "$tmp/m.before.bak"
    rm -f "$tmp/profiles/m.ocbar" "$tmp/profiles/m.ocbar.bak"

    # Форма в несколько окон: заголовки шагов из разметки доживают до
    # профиля, шапка файла разметки — нет.
    printf '# Правила автозаполнения формы входа, размечены вручную 2026-09-10.\n# Портал: x\n\n# шаг 1 — idp.test/login\nfill  username input[id=u]\nclick button[id=next]\n# шаг 2 — idp.test/otp\nfill  totp input[id=otp]\nclick button[id=go]\n' > "$tmp/steps.rules"
    out=$(run rules import "$tmp/steps.rules" t || true)
    has "шаги формы: импорт считает окна" "окон формы: 2" "$out"
    out=$(cat "$tmp/profiles/t.ocbar")
    has "шаги формы: заголовок окна в профиле" "# шаг 2 — idp.test/otp" "$out"
    hasnt "шаги формы: шапка разметки в профиль не попадает" "размечены вручную" "$out"
    has "шаги формы: rules show показывает окна" "# шаг 1" "$(run rules show t)"
    has "шаги формы: правила действуют из профиля" "autofill=inline" "$(run status --short)"
    has "шаги формы: экспорт уносит заголовки" "# шаг 2" "$(run export t)"
    run rules clear t >/dev/null || true
    # Правка ключа профиля: заменить, добавить в секцию, завести секцию.
    printf '[Connection]\nName = Ключи\nUrl = vpn.example.test/k\nUser = tester\n\n[Auth]\nTotp = off\nKeychainService = svc\n\n[Health]\nCheck = h:443\n' > "$tmp/k.ocbar"
    pf_set_key "$tmp/k.ocbar" Auth Totp sms || true
    pf_set_key "$tmp/k.ocbar" Auth Password keychain || true
    pf_set_key "$tmp/k.ocbar" Proxy Port 12080 || true
    out=$(cat "$tmp/k.ocbar")
    has "ключ профиля заменяется" "Totp = sms" "$out"
    hasnt "старое значение ключа убрано" "Totp = off" "$out"
    matches "новый ключ — в своей секции" "KeychainService = svc.Password = keychain" "$(printf '%s' "$out" | tr '\n' '.')"
    matches "новая секция: заголовок и ключ подряд" '\[Proxy\]\.Port = 12080(\.|$)' "$(printf '%s' "$out" | tr '\n' '.')"
    has "остальные секции целы" "Check = h:443" "$out"
    # Итог «Запомнить, как я вхожу» применяется к профилю.
    printf '[Connection]\nName = Учусь\nUrl = vpn.example.test/l\nUser = tester\n\n[Auth]\nTotp = auto\n' > "$tmp/profiles/l.ocbar"
    printf '%s' '{"rules": "stop  div.alert-error\n# шаг 1 — idp.test/login\nfill  username input[id=u]\nfill  password input[id=p]\nclick button[id=go]\n# шаг 2 — idp.test/otp\nfill  totp input[id=c]\nfill  manual input[id=cap]\nclick input[id=ok]", "totp": "sms", "password": ""}' > "$tmp/teach.json"
    OCBAR_SELFTEST_TEACH="$tmp/teach.json" run _apply-teach l >/dev/null || true
    has "запомненное: правила в профиле" "fill  manual input[id=cap]" "$(cat "$tmp/profiles/l.ocbar")"
    has "запомненное: Totp = sms" "Totp = sms" "$(cat "$tmp/profiles/l.ocbar")"
    has "Totp = sms виден в secret status" "приходит по SMS" "$(run secret status l)"
    printf '%s' '{"rules": "", "totp": "", "password": "keychain"}' > "$tmp/pw.json"
    OCBAR_SELFTEST_TEACH="$tmp/pw.json" run _apply-teach l >/dev/null || true
    matches "запомненное: Password = keychain" '^Password = keychain$' "$(cat "$tmp/profiles/l.ocbar")"
    cp "$tmp/profiles/l.ocbar" "$tmp/l.before"
    printf '{"totp": "sms", ' > "$tmp/broken.json"
    rc=0; OCBAR_SELFTEST_TEACH="$tmp/broken.json" run _apply-teach l >/dev/null || rc=$?
    is "запомненное: битый итог — код 0" 0 "$rc"
    same "запомненное: битый итог — профиль не тронут" "$tmp/profiles/l.ocbar" "$tmp/l.before"
    if [ "$(id -u)" = 0 ]; then
        omit "запомненное: профиль не на запись" "под root права каталога не мешают записи"
    else
        printf '%s' '{"rules": "fill  username input[id=u]", "totp": "sms", "password": "keychain"}' > "$tmp/ro.json"
        chmod 500 "$tmp/profiles"
        rc=0; out=$(OCBAR_SELFTEST_TEACH="$tmp/ro.json" run _apply-teach l) || rc=$?
        chmod 700 "$tmp/profiles"
        is "запомненное: профиль не на запись — код 0 (вход не рвётся)" 0 "$rc"
        has "запомненное: профиль не на запись — предупреждение" "не записался" "$out"
        same "запомненное: профиль не на запись — файл цел" "$tmp/profiles/l.ocbar" "$tmp/l.before"
    fi
    rm -f "$tmp/profiles/l.ocbar" "$tmp/k.ocbar" "$tmp/k.ocbar.bak"
    # Параметры кода (RFC 6238): читаются, проверяются, уезжают с экспортом,
    # решают судьбу записи из QR и доходят до расчёта кода.
    printf '[Connection]\nName = Параметры\nUrl = vpn.example.test/p\nUser = tester\n\n[Auth]\nTotp = keychain\nTotpAlgorithm = sha256\nTotpDigits = 8\nTotpPeriod = 60\n' > "$tmp/profiles/p.ocbar"
    # Два профиля-файла без умолчания: раньше profile_default возвращал 1, и
    # set -e молча обрывал и список, и connect без имени.
    has "два профиля без умолчания: список виден целиком" "Параметры" "$(run profiles)"
    has "два профиля без умолчания: профиль без имени объясняет" "нет профиля" "$(run _check-profile)"
    out=$(run export p || true)
    has "параметры кода: экспорт уносит алгоритм" "TotpAlgorithm   = SHA256" "$out"
    has "параметры кода: экспорт уносит период" "TotpPeriod      = 60" "$out"
    for bad in "TotpAlgorithm = MD5" "TotpDigits = 9" "TotpPeriod = 5"; do
        make_bad "$(printf '\n[Auth]\n%s' "$bad")"
        has "параметры кода: «${bad}» отвергнуто" "${bad%% *}" "$(run _check-profile bad)"
    done
    rm -f "$tmp/profiles/bad.ocbar"
    has "QR: HOTP отвергнут" "по счётчику" "$(run _qr-check p 'HOTP SHA1 6 30')"
    has "QR: MD5 отвергнут" "не поддерживается" "$(run _qr-check p 'TOTP MD5 6 30')"
    has "QR: SHA256, 8 цифр, 60 с — принято для профиля-файла" "ok" "$(run _qr-check p 'TOTP SHA256 8 60')"
    printf 'default = old\n\n[old]\nurl = vpn.example.test/o\n' > "$tmp/profiles.conf"
    has "QR: нестандартные параметры в старый формат не пишутся" "старого формата" "$(run _qr-check old 'TOTP SHA256 8 60')"
    has "QR: обычная запись в старый формат — принята" "ok" "$(run _qr-check old 'TOTP SHA1 6 30')"
    rm -f "$tmp/profiles.conf"
    # Применение параметров из QR — тем же кодом, что у import-qr, но без
    # связки ключей.
    printf '[Connection]\nName = QR\nUrl = vpn.example.test/q\nUser = tester\n\n[Auth]\nTotp = keychain\n' > "$tmp/profiles/q.ocbar"
    run _qr-apply q 'TOTP SHA512 7 45' >/dev/null || true
    out=$(cat "$tmp/profiles/q.ocbar")
    has "QR: алгоритм кода — в профиль" "TotpAlgorithm = SHA512" "$out"
    has "QR: цифры — в профиль" "TotpDigits = 7" "$out"
    has "QR: период — в профиль" "TotpPeriod = 45" "$out"
    run _qr-apply q 'TOTP SHA1 6 30' >/dev/null || true
    has "QR: обычная запись ставится поверх прежней" "TotpAlgorithm = SHA1" "$(cat "$tmp/profiles/q.ocbar")"
    rm -f "$tmp/profiles/q.ocbar" "$tmp/profiles/q.ocbar.bak"
    printf '%s' '{"rules": "", "totp": "keychain", "password": "", "totp_algorithm": "SHA512", "totp_digits": "8", "totp_period": "30"}' > "$tmp/teach2.json"
    OCBAR_SELFTEST_TEACH="$tmp/teach2.json" run _apply-teach p >/dev/null || true
    out=$(cat "$tmp/profiles/p.ocbar")
    has "запомненное: алгоритм кода в профиле" "TotpAlgorithm = SHA512" "$out"
    has "запомненное: период по умолчанию — поверх прежнего" "TotpPeriod = 30" "$out"
    hasnt "запомненное: прежний период убран" "TotpPeriod = 60" "$out"
    if qa=$(auth_path); then
        has "расчёт кода: SHA256, 8 цифр — вектор RFC 6238" "46119246" \
            "$(OCBAR_TOTP_SECRET=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA OCBAR_TOTP_ALGORITHM=SHA256 OCBAR_TOTP_DIGITS=8 OCBAR_TOTP_AT=59 "$qa" --totp-now 2>&1)"
    else
        omit "расчёт кода: SHA256, 8 цифр — вектор RFC 6238" "не найден ocbar-auth (OCBAR_AUTH или auth/.build/release)"
    fi
    rm -f "$tmp/profiles/p.ocbar"
    printf '[Connection]\nName = Код\nUrl = vpn.example.test/c\nUser = tester\n\n[Auth]\nTotp = command\nTotpCommand = echo 123456\n' > "$tmp/profiles/c.ocbar"
    has "secret code: свежий код из источника профиля" "123456" "$(run secret code c)"
    printf '[Connection]\nName = Руками\nUrl = vpn.example.test/h\nUser = tester\n\n[Auth]\nPassword = ask\nTotp = sms\n' > "$tmp/profiles/h.ocbar"
    is "secret status --short: источники без обращения к секретам" "password=ask totp=sms" "$(run secret status h --short | tr '\n' ' ' | sed 's/ $//' || true)"
    rm -f "$tmp/profiles/h.ocbar"
    rm -f "$tmp/profiles/c.ocbar"
    # app stop возвращается, только когда приложение вышло: за ним сразу
    # идёт start, и живой ещё процесс тот принял бы за работающий.
    # Подставное приложение выходит через секунду после TERM.
    mkdir -p "$tmp/fakeapp/ocbar-selftest.app/Contents/MacOS"
    printf '#!/bin/bash\ntrap "sleep 1; exit 0" TERM\nfor i in $(seq 1 600); do sleep 0.2; done\n' \
        > "$tmp/fakeapp/ocbar-selftest.app/Contents/MacOS/ocbar-app"
    chmod +x "$tmp/fakeapp/ocbar-selftest.app/Contents/MacOS/ocbar-app"
    local fa; fa=$(spawn "$tmp/fakeapp/ocbar-selftest.app/Contents/MacOS/ocbar-app"); pids+=("$fa")
    sleep 0.3
    local chk
    chk=$(OCBAR_SELFTEST_APP_PATTERN='ocbar-selftest\.app/Contents/MacOS/ocbar-app' run app stop)
    has "app stop: остановлено" "остановлено" "$chk"
    check "app stop: вернулся, когда процесс уже вышел" gone_now "$fa"
    # Пароль и код из настроек приложения: значения идут в security через
    # stdin (-i), в аргументах их нет; причина отказа — словами ocbar-auth.
    # Заглушка security ведёт одну запись, как связка на один секрет.
    mkdir -p "$tmp/kc"
    cat > "$tmp/kc/security" <<'STUB'
#!/bin/bash
d="$(dirname "$0")"
printf '%s\n' "$*" >> "$d/argv"
if [ "${1:-}" = -i ]; then
    line=$(cat); printf '%s\n' "$line" >> "$d/stdin"
    printf '%s' "$line" | sed -n 's/.* -w "\(.*\)"$/\1/p' | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' > "$d/value"
    exit 0
fi
case " $* " in *" -w "*) cat "$d/value" 2>/dev/null; exit 0 ;; esac
[ -s "$d/value" ]
STUB
    chmod +x "$tmp/kc/security"
    kcrun() { OCBAR_SELFTEST_SECURITY="$tmp/kc/security" run "$@"; }
    printf '[Connection]\nName = Секреты\nUrl = vpn.example.test/k\nUser = tester\n\n[Auth]\nTotp = keychain\n' > "$tmp/profiles/k.ocbar"
    chk=$(printf '%s\n' 'pa"ss\wo rd' | kcrun secret set-password k --stdin)
    has "пароль со входа: сохранён" "пароль сохранён" "$chk"
    is "пароль со входа: в связке ровно он, с кавычкой и слэшем" 'pa"ss\wo rd' "$(cat "$tmp/kc/value" 2>/dev/null)"
    has "пароль со входа: security вызван с -i" "-i" "$(cat "$tmp/kc/argv" 2>/dev/null)"
    hasnt "пароль со входа: в аргументах security пароля нет" "pa" "$(cat "$tmp/kc/argv" 2>/dev/null)"
    has "пароль со входа: пустой не сохраняется" "пустой пароль" "$(printf '\n' | kcrun secret set-password k --stdin || true)"
    if qa=$(auth_path); then
        : > "$tmp/kc/argv"
        chk=$(printf '%s\n' 'otpauth://totp/VPN:tester?secret=JBSWY3DPEHPK3PXP&digits=8&period=60&algorithm=SHA256' \
              | OCBAR_AUTH="$qa" kcrun secret add-totp k --stdin)
        has "код ссылкой: сохранён" "код сохранён" "$chk"
        matches "код ссылкой: показан текущий код из связки (8 цифр)" '[0-9]{8} — сверьте' "$chk"
        is "код ссылкой: в связке секрет из ссылки" "JBSWY3DPEHPK3PXP" "$(cat "$tmp/kc/value" 2>/dev/null)"
        has "код ссылкой: учётка totp/<пользователь>, подпись как у set-totp" '-a "totp/tester" -l "ocbar: TOTP (tester)"' "$(cat "$tmp/kc/stdin" 2>/dev/null)"
        hasnt "код ссылкой: в аргументах security секрета нет" "JBSWY" "$(cat "$tmp/kc/argv" 2>/dev/null)"
        chk=$(cat "$tmp/profiles/k.ocbar")
        has "код ссылкой: цифры — в профиль" "TotpDigits = 8" "$chk"
        has "код ссылкой: период — в профиль" "TotpPeriod = 60" "$chk"
        has "код ссылкой: источник — связка" "Totp = keychain" "$chk"
        has "код: причина отказа — словами ocbar-auth" "нет ни одной записи TOTP" \
            "$(printf 'not a secret!!\n' | OCBAR_AUTH="$qa" kcrun secret add-totp k --stdin || true)"
        has "код: HOTP не сохраняется" "по счётчику" \
            "$(printf 'otpauth://hotp/VPN:t?secret=JBSWY3DPEHPK3PXP&counter=1\n' | OCBAR_AUTH="$qa" kcrun secret add-totp k --stdin || true)"
        # Экран и камера — без человека: рамку «выделяет» заглушка
        # screencapture (кладёт готовый QR туда, куда просил ocbar), кадры
        # камеры идут из файлов. Дальше путь тот же, что у живых.
        local mig='otpauth-migration://offline?data=CiEKCjEyMzQ1Njc4OTASB3NvbWVvbmUaBE1haWwgASgBMAIKHwoKSGVsbG8h3q2%2B7xIGdGVzdGVyGgNWUE4gASgBMAIQARgBIAAoAA%3D%3D'
        printf '%s\n' 'otpauth://totp/VPN:tester?secret=JBSWY3DPEHPK3PXP' | "$qa" --qr-png "$tmp/kc/one.png"
        printf '%s\n' "$mig" | "$qa" --qr-png "$tmp/kc/two.png"
        # Картинка без QR — как снимок экрана без права на запись.
        printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==' | base64 -D > "$tmp/kc/blank.png"
        cat > "$tmp/kc/screencapture" <<'STUB'
#!/bin/bash
for a; do dst="$a"; done
[ -n "${OCBAR_STUB_SHOT:-}" ] && cp "$OCBAR_STUB_SHOT" "$dst"
exit 0
STUB
        chmod +x "$tmp/kc/screencapture"
        shot_add() { OCBAR_SELFTEST_SCREEN_ACCESS="${OCBAR_SELFTEST_SCREEN_ACCESS:-granted}" OCBAR_AUTH="$qa" OCBAR_SELFTEST_SCREENCAPTURE="$tmp/kc/screencapture" OCBAR_STUB_SHOT="$1" kcrun secret add-totp k --screen "${@:2}" || true; }
        cam_add() { OCBAR_AUTH="$qa" OCBAR_SELFTEST_CAMERA_FRAMES="$1" kcrun secret add-totp k --camera "${@:2}" || true; }
        matches "secret access: права одной строкой, без профиля" '^screen=(granted|denied) camera=[a-z-]+$' \
            "$(OCBAR_AUTH="$qa" run secret access)"
        is "secret access: право на экран — как видит ocbar-auth" "screen=denied" \
            "$(OCBAR_AUTH="$qa" OCBAR_SELFTEST_SCREEN_ACCESS=denied run secret access | cut -d' ' -f1)"
        : > "$tmp/kc/value"
        has "экран: QR из рамки сохранён" "код сохранён" "$(shot_add "$tmp/kc/one.png")"
        is "экран: в связке секрет из QR" "JBSWY3DPEHPK3PXP" "$(cat "$tmp/kc/value" 2>/dev/null)"
        has "экран: Esc — «снимок отменён»" "снимок отменён" "$(shot_add "")"
        chk=$(shot_add "$tmp/kc/two.png")
        has "экран: экспорт на две записи — названы обе" "Mail/someone, VPN/tester" "$chk"
        hasnt "экран: из двух записей ни одна не сохранена молча" "код сохранён" "$chk"
        : > "$tmp/kc/value"
        has "экран: --select выбирает запись из экспорта" "код сохранён" "$(shot_add "$tmp/kc/two.png" --select vpn)"
        is "экран: выбрана нужная запись" "JBSWY3DPEHPK3PXP" "$(cat "$tmp/kc/value" 2>/dev/null)"
        has "экран: без права на запись — сказано про право" "Запись экрана" \
            "$(OCBAR_SELFTEST_SCREEN_ACCESS=denied shot_add "$tmp/kc/blank.png")"
        # Право не дано, но QR прочитан — дело не в праве: называем записи.
        chk=$(OCBAR_SELFTEST_SCREEN_ACCESS=denied shot_add "$tmp/kc/two.png")
        has "экран: без права, но QR прочитан — причина про записи" "Mail/someone, VPN/tester" "$chk"
        hasnt "экран: без права, но QR прочитан — про право не говорим" "Запись экрана" "$chk"
        chk=$(OCBAR_SELFTEST_SCREEN_ACCESS=granted shot_add "$tmp/kc/blank.png")
        has "экран: право есть, QR нет — причина словами ocbar-auth" "нет QR-кода" "$chk"
        hasnt "экран: право есть — про право не говорим" "Запись экрана" "$chk"
        : > "$tmp/kc/value"
        has "камера: кадр без QR и экспорт на две пропущены, нужный QR сохранён" "код сохранён" \
            "$(cam_add "$tmp/kc/blank.png:$tmp/kc/two.png:$tmp/kc/one.png")"
        is "камера: в связке секрет из QR" "JBSWY3DPEHPK3PXP" "$(cat "$tmp/kc/value" 2>/dev/null)"
        has "камера: только экспорт на две — причина, без сохранения" "экспортируйте одну" "$(cam_add "$tmp/kc/two.png")"
        : > "$tmp/kc/value"
        has "камера: --select выбирает запись из экспорта" "код сохранён" "$(cam_add "$tmp/kc/two.png" --select vpn)"
        is "камера: выбрана нужная запись" "JBSWY3DPEHPK3PXP" "$(cat "$tmp/kc/value" 2>/dev/null)"
        # По-английски: сообщения клиента по каталогу, причины ocbar-auth — у
        # источника. Кириллицы не остаётся нигде (имя профиля — латиницей).
        nocyr() { total=$((total+1)); if printf '%s' "$2" | LC_ALL=C grep -q $'\xd0\|\xd1'; then fails=$((fails+1)); bad "$1" "кириллица: $(printf '%s' "$2" | head -3)"; else ok "$1"; fi; }
        chk=$(OCBAR_LANG=en run help); has "по-английски: справка" "OpenConnect for macOS" "$chk"; nocyr "по-английски: справка без кириллицы" "$chk"
        chk=$(OCBAR_LANG=en run profile-check "$tmp/nope.ocbar" || true); has "по-английски: ошибка die" "no such file" "$chk"; nocyr "по-английски: ошибка без кириллицы" "$chk"
        chk=$(printf '%s\n' 'pw' | OCBAR_LANG=en kcrun secret set-password k --stdin); has "по-английски: строка ok с подстановками" "password saved" "$chk"; nocyr "по-английски: строка ok без кириллицы" "$chk"
        chk=$(OCBAR_LANG=en OCBAR_SELFTEST_SCREEN_ACCESS=denied shot_add "$tmp/kc/blank.png"); has "по-английски: про право на запись экрана" "Screen Recording" "$chk"; nocyr "по-английски: право — без кириллицы" "$chk"
        chk=$(OCBAR_LANG=en shot_add "$tmp/kc/blank.png"); has "по-английски: QR нет — причина от ocbar-auth" "no QR code" "$chk"; nocyr "по-английски: причина ocbar-auth без кириллицы" "$chk"
        chk=$(OCBAR_LANG=en cam_add "$tmp/kc/two.png"); has "по-английски: экспорт на две — причина с камеры" "export just the VPN account" "$chk"; nocyr "по-английски: камера без кириллицы" "$chk"
    else
        omit "код ссылкой: сохранение, параметры, причина отказа" "не найден ocbar-auth (OCBAR_AUTH или auth/.build/release)"
    fi
    rm -rf "$tmp/kc" "$tmp/profiles/k.ocbar" "$tmp/profiles/k.ocbar.bak"

    # «В этой сети не подключаться»: сеть опознаётся по MAC маршрутизатора.
    rm -f "$tmp/state/skip-networks"
    is "сеть: пока список пуст — подключаемся" no "$(OCBAR_NETWORK_ID=aa:bb:cc:dd:ee:01 run _selftest-fn network_skipped || true)"
    OCBAR_NETWORK_ID=aa:bb:cc:dd:ee:01 run autoconnect skip-here дом >/dev/null || true
    is "сеть: эта сеть в списке" skip "$(OCBAR_NETWORK_ID=aa:bb:cc:dd:ee:01 run _selftest-fn network_skipped || true)"
    is "сеть: другая сеть не задета" no "$(OCBAR_NETWORK_ID=aa:bb:cc:dd:ee:02 run _selftest-fn network_skipped || true)"
    OCBAR_NETWORK_ID=aa:bb:cc:dd:ee:01 run autoconnect unskip-here >/dev/null || true
    is "сеть: вернули автоподключение" no "$(OCBAR_NETWORK_ID=aa:bb:cc:dd:ee:01 run _selftest-fn network_skipped || true)"
    rm -f "$tmp/state/skip-networks"

    # Импорт профиля Cisco: переносим только адреса серверов.
    printf '%s' '<?xml version="1.0" encoding="UTF-8"?>
<AnyConnectProfile xmlns="http://schemas.xmlsoap.org/encoding/">
 <ServerList>
  <HostEntry><HostName>Office</HostName><HostAddress>vpn.example.test</HostAddress><UserGroup>employees</UserGroup></HostEntry>
  <HostEntry><HostName>Backup</HostName><HostAddress>vpn2.example.test</HostAddress></HostEntry>
 </ServerList>
</AnyConnectProfile>' > "$tmp/cisco.xml"
    out=$(run _selftest-fn cisco_servers "$tmp/cisco.xml" || true)
    has "Cisco XML: адрес с группой" "vpn.example.test/employees" "$out"
    has "Cisco XML: адрес без группы" "vpn2.example.test" "$out"
    run import "$tmp/cisco.xml" >/dev/null 2>&1 || true
    is "Cisco XML: созданы профили" 2 "$(ls "$tmp/profiles" | grep -cE '^(office|backup)\.ocbar$' || true)"
    has "Cisco XML: адрес в профиле" "Url         = vpn.example.test/employees" "$(cat "$tmp/profiles/office.ocbar" 2>/dev/null || true)"
    rm -f "$tmp/profiles/office.ocbar" "$tmp/profiles/backup.ocbar" "$tmp/cisco.xml"

    # Проверка доступа: итог кладётся в файл и попадает в status.
    printf '[Connection]\nName = Доступ\nUrl = vpn.example.test/a\nUser = tester\n\n[Health]\nCheck = 127.0.0.1:9\n' > "$tmp/profiles/ac.ocbar"
    is "доступ: недоступный ресурс — fail" fail "$(run _selftest-fn access_check ac || true)"
    has "доступ: итог попадает в status" "access=fail" "$(run status --short || true)"
    printf '[Connection]\nName = Без проверки\nUrl = vpn.example.test/b\nUser = tester\n' > "$tmp/profiles/nc.ocbar"
    is "доступ: проверять нечего — unknown" ok "$(run _selftest-fn access_check nc || true)"
    has "доступ: без проверки — unknown в status" "access=unknown" "$(run status --short || true)"
    rm -f "$tmp/profiles/ac.ocbar" "$tmp/profiles/nc.ocbar" "$tmp/state/access"

    # Портал перехвата: ответ не «Success» — значит, мы за порталом.
    printf '<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n' > "$tmp/captive-ok.html"
    printf '<html>Войдите в сеть отеля</html>\n' > "$tmp/captive-portal.html"
    is "портал: обычная сеть — не портал" no "$(OCBAR_CAPTIVE_URL="file://$tmp/captive-ok.html" run _selftest-fn captive_portal || true)"
    is "портал: чужая страница вместо Success — портал" portal "$(OCBAR_CAPTIVE_URL="file://$tmp/captive-portal.html" run _selftest-fn captive_portal || true)"
    is "портал: сети нет вовсе — не портал" no "$(OCBAR_CAPTIVE_URL="file://$tmp/нет-такого.html" run _selftest-fn captive_portal || true)"
    rm -f "$tmp/captive-ok.html" "$tmp/captive-portal.html"

    # Транспорт: MTU и отключение DTLS доходят до openconnect, значения проверяются.
    printf '[Connection]\nName = Транспорт\nUrl = vpn.example.test/t\nUser = tester\nMtu = 1300\nDtls = off\n\n[Auth]\nTotp = off\n' > "$tmp/profiles/tr.ocbar"
    out=$(run connect --dry-run tr || true)
    has "транспорт: MTU уходит в spec" "mtu 1300" "$out"
    has "транспорт: DTLS выключается" "nodtls" "$out"
    printf '[Connection]\nName = Плохой MTU\nUrl = vpn.example.test/t\nUser = tester\nMtu = 99\n' > "$tmp/profiles/tb.ocbar"
    is "транспорт: MTU вне диапазона — отказ" fail "$( (run _check-profile tb >/dev/null 2>&1) && echo ok || echo fail)"
    printf '[Connection]\nName = Плохой DTLS\nUrl = vpn.example.test/t\nUser = tester\nDtls = может-быть\n' > "$tmp/profiles/td.ocbar"
    is "транспорт: Dtls принимает только on/off" fail "$( (run _check-profile td >/dev/null 2>&1) && echo ok || echo fail)"
    rm -f "$tmp/profiles/tr.ocbar" "$tmp/profiles/tb.ocbar" "$tmp/profiles/td.ocbar"

    # Автоподключение: политика читается и применяется супервизором.
    rm -f "$tmp/state/autoconnect"
    is "автоподключение: по умолчанию «как в прошлый раз»" resume "$(run _selftest-fn autoconnect_policy || true)"
    run autoconnect manual >/dev/null || true
    is "автоподключение: вручную" manual "$(run _selftest-fn autoconnect_policy || true)"
    is "автоподключение: неизвестный профиль — отказ" fail "$( (run autoconnect always нет-такого >/dev/null 2>&1) && echo ok || echo fail)"
    run autoconnect always t >/dev/null || true
    is "автоподключение: выбранный профиль" "always t" "$(run _selftest-fn autoconnect_policy || true)"
    rm -f "$tmp/state/desired"
    run supervise --iterations=1 --dry-run >/dev/null 2>&1 || true
    is "автоподключение: при входе в систему профиль выбран" "t" "$(cat "$tmp/state/desired" 2>/dev/null || true)"
    run autoconnect manual >/dev/null || true
    out=$(run supervise --iterations=1 --dry-run 2>&1 || true)
    has "автоподключение: вручную — супервизор говорит, что не входит" "сам входить не буду" "$out$(cat "$tmp/logs/supervisor.log" 2>/dev/null)"
    rm -f "$tmp/state/autoconnect" "$tmp/state/desired"

    # Отчёт: корпоративные подробности скрыты, локальные адреса — нет.
    red=$(printf 'Url = https://vpn.corp.example/employees\nUser = alice\nip=10.20.30.40 dns=192.0.2.10\nlocal 127.0.0.1:11080\ncookie=SECRET123\nпочта bob@corp.example\n' | run _selftest-fn report_redact || true)
    is "отчёт: адрес шлюза скрыт" 0 "$(printf '%s' "$red" | grep -c 'vpn.corp.example' || true)"
    is "отчёт: логин скрыт" 0 "$(printf '%s' "$red" | grep -c 'alice' || true)"
    is "отчёт: рабочий адрес скрыт" 0 "$(printf '%s' "$red" | grep -c '10.20.30.40' || true)"
    is "отчёт: cookie скрыт" 0 "$(printf '%s' "$red" | grep -c 'SECRET123' || true)"
    has "отчёт: локальный адрес оставлен" "127.0.0.1" "$red"
    has "отчёт: порт оставлен" "11080" "$red"
    has "отчёт: версия не принята за домен" "0.7.0" "$(printf 'helper=0.7.0\n' | run _selftest-fn report_redact || true)"
    has "отчёт: имя журнала не принято за домен" "supervisor.log" "$(printf 'смотри ~/Library/Logs/ocbar/supervisor.log\n' | run _selftest-fn report_redact || true)"
    is "отчёт: домашний каталог сокращён" 0 "$(printf '%s/x\n' "$HOME" | run _selftest-fn report_redact | grep -c "$HOME" || true)"

    # Итог входа: сеть отделена от «нужен человек» — иначе короткий обрыв
    # останавливал автоподключение до ручного действия.
    is "вход: 0 — прошло" ok "$(run _selftest-fn auth_rc_action 0 || true)"
    is "вход: 5 — нужен человек" human "$(run _selftest-fn auth_rc_action 5 || true)"
    is "вход: 6 — сеть, повторяем молча" network "$(run _selftest-fn auth_rc_action 6 || true)"
    is "вход: прочее — ошибка" fail "$(run _selftest-fn auth_rc_action 9 || true)"

    # Выйти совсем: сначала отключение, потом сброс сессий окна входа.
    has "logout: отключение и сброс сессий окна входа" "--forget-sessions" "$(run logout --dry-run 2>&1 || true)"
    has "logout: есть в справке" "ocbar logout" "$(run --help 2>&1 || true)"

    # Подключение в процессе: живой процесс — да, мёртвый — нет и отметка
    # убрана, мусор — нет. И супервизор при отметке не вмешивается.
    sleep 30 & sp=$!
    printf '%s\n' "$sp" > "$tmp/state/connecting"
    is "подключение идёт: живой процесс — супервизор ждёт" yes "$(run _selftest-fn connect_in_progress || true)"
    sup=$(run supervise --iterations=1 --dry-run 2>&1 || true)
    has "подключение идёт: супервизор пишет, что ждёт" "идёт подключение" "$(cat "$tmp/logs/supervisor.log" 2>/dev/null) $sup"
    kill "$sp" 2>/dev/null || true; wait "$sp" 2>/dev/null || true
    is "подключение идёт: процесс умер — отметка устарела" no "$(run _selftest-fn connect_in_progress || true)"
    is "подключение идёт: устаревшая отметка убрана" no "$([ -f "$tmp/state/connecting" ] && echo yes || echo no)"
    printf 'abc\n' > "$tmp/state/connecting"
    is "подключение идёт: мусор в отметке — нет" no "$(run _selftest-fn connect_in_progress || true)"
    rm -f "$tmp/state/connecting"

    # Запомненный вход сливается с правилами профиля: окна, которых в этот
    # раз не было (окно кода), остаются, окно с тем же адресом обновляется.
    printf '[Connection]\nName = Слияние\nUrl = vpn.example.test/m\n\n[Autofill]\nstop  div.err\n# шаг 1 — idp.test/login\nfill  password input[id=old]\nclick button[id=go]\n# шаг 2 — idp.test/otp\nfill  totp input[id=otp]\nclick input[id=ok]\n' > "$tmp/profiles/mg.ocbar"
    printf '%s' '{"rules": "# Правила, размечены вручную\nstop  div.err2\n# шаг 1 — idp.test/login\nfill  password input[id=new]\nclick button[id=go]\n"}' > "$tmp/merge.json"
    OCBAR_SELFTEST_TEACH="$tmp/merge.json" run _apply-teach mg >/dev/null || true
    out=$(run rules show mg || true)
    has "запомненный вход: окно пароля обновлено" "password input[id=new]" "$out"
    has "запомненный вход: окно кода из прошлой разметки на месте" "totp input[id=otp]" "$out"
    has "запомненный вход: stop прошлый и новый" "div.err2" "$out"
    is "запомненный вход: старое поле пароля ушло" 0 "$(printf '%s\n' "$out" | grep -c 'input\[id=old\]' || true)"
    rm -f "$tmp/profiles/mg.ocbar" "$tmp/profiles/mg.ocbar.bak" "$tmp/merge.json"

    # Копия приложения для лаунчера: бандл из Homebrew копируется, одинаковый
    # не перекладывается, новая версия заменяет старую, сборка проекта — как есть.
    mkb() { mkdir -p "$1/Contents/MacOS"; printf '#!/bin/sh\n# %s\n' "$2" > "$1/Contents/MacOS/ocbar-app"
            printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>\n' "$2" > "$1/Contents/Info.plist"; }
    src="$tmp/Cellar/ocbar/9.9.1/ocbar.app"; dst="$tmp/Applications/ocbar.app"; mkb "$src" 9.9.1
    out=$(OCBAR_APP_COPY="$dst" run _selftest-fn app_sync_copy "$src" || true)
    is "лаунчер: бандл из Homebrew запускается из копии" "$dst" "$out"
    is "лаунчер: в копии та же версия" 9.9.1 "$(plutil -extract CFBundleShortVersionString raw "$dst/Contents/Info.plist" 2>/dev/null || true)"
    : > "$dst/marker"; OCBAR_APP_COPY="$dst" run _selftest-fn app_sync_copy "$src" >/dev/null || true
    is "лаунчер: одинаковая копия не перекладывается" yes "$([ -f "$dst/marker" ] && echo yes || echo no)"
    mkb "$src" 9.9.2; OCBAR_APP_COPY="$dst" run _selftest-fn app_sync_copy "$src" >/dev/null || true
    is "лаунчер: новая версия заменяет копию" "9.9.2 no" "$(plutil -extract CFBundleShortVersionString raw "$dst/Contents/Info.plist" 2>/dev/null) $([ -f "$dst/marker" ] && echo yes || echo no)"
    mkb "$tmp/proj/app/.build/ocbar.app" 9.9.3
    is "лаунчер: сборка проекта не копируется" "$tmp/proj/app/.build/ocbar.app" "$(OCBAR_APP_COPY="$dst" run _selftest-fn app_sync_copy "$tmp/proj/app/.build/ocbar.app" || true)"
    rm -rf "$tmp/Cellar" "$tmp/Applications" "$tmp/proj"

    # Группы уведомлений и повторы.
    np="$tmp/notifyprefs.plist"
    is "уведомления: «нужен вход» — по умолчанию да" yes "$(OCBAR_NOTIFY_PREFS="$np" run _notify-gate 'ocbar: нужен вход' login || true)"
    is "уведомления: то же за 10 минут — нет" no "$(OCBAR_NOTIFY_PREFS="$np" run _notify-gate 'ocbar: нужен вход' login || true)"
    is "уведомления: «восстановлено» — по умолчанию нет" off "$(OCBAR_NOTIFY_PREFS="$np" run _notify-gate 'ocbar: связь восстановлена' events || true)"
    defaults write "$np" NotifyEvents -bool true; defaults write "$np" NotifyProblems -bool false
    is "уведомления: группа включена в настройках" yes "$(OCBAR_NOTIFY_PREFS="$np" run _notify-gate 'ocbar: связь восстановлена' events || true)"
    is "уведомления: группа выключена в настройках" off "$(OCBAR_NOTIFY_PREFS="$np" run _notify-gate 'ocbar: доступа нет' problems || true)"
    rm -f "$np" "$tmp/state/notify.last"

    # Уведомления: только через приложение, с его токеном и разрешением
    # системы; своего запасного показа («Script Editor») у клиента нет.
    tok=0123456789abcdef0123456789abcdef
    printf '%s\n' "$tok" > "$tmp/state/notify.token"; chmod 600 "$tmp/state/notify.token"
    printf '1\n' > "$tmp/state/notify.allowed"
    out=$(OCBAR_SELFTEST_APP=1 run _notify-route 'ocbar: нужен вход' 'Сессия & «истекла»' || true)
    matches "уведомление: через приложение, с токеном" "^app ocbar://notify\?title=[^&]+&body=[^&]+&token=${tok}\$" "$out"
    # Пробел — %20, а не «+»: приложение разбирает адрес как URL, и «+» в
    # тексте уведомления показывался плюсом между слов.
    is "уведомление: пробелы — %20, без «+»" 0 "$(printf '%s' "$out" | grep -c '+' || true)"
    is "уведомление: приложение не запущено — запустить его" launch "$(OCBAR_SELFTEST_APP=0 run _notify-route t b)"
    printf '0\n' > "$tmp/state/notify.allowed"
    matches "уведомление: уведомления запрещены — только журнал" '^off ' "$(OCBAR_SELFTEST_APP=1 run _notify-route t b)"
    printf '1\n' > "$tmp/state/notify.allowed"; chmod 644 "$tmp/state/notify.token"
    matches "уведомление: токен с правами 0644 — только журнал" '^off ' "$(OCBAR_SELFTEST_APP=1 run _notify-route t b)"
    rm -f "$tmp/state/notify.token" "$tmp/state/notify.allowed"
    matches "уведомление: токена нет — только журнал" '^off ' "$(OCBAR_SELFTEST_APP=1 run _notify-route t b)"
    is "уведомление: клиент не зовёт osa""script ни в одной строке кода" 0 "$(grep -v '^[[:space:]]*#' "$SELF" | grep -c 'osa''script' || true)"

    if [ ${#pids[@]} -gt 0 ]; then kill "${pids[@]}" 2>/dev/null || true; fi
    rm -rf "$tmp"
    info "----------------------------------------"
    local tail=""
    if [ "$skipped" -gt 0 ]; then tail=", пропущено: $skipped"; fi
    if [ "$fails" = 0 ]; then info "selftest: всё OK ($total проверок$tail)"; return 0; fi
    info "selftest: провалов $fails из $total$tail"; return 1
}
