#!/bin/bash
#
# helper-selftest.sh — самопроверка libexec/ocbar-helper целиком на --dry-run.
#
# Ничего не меняет в системе и не требует root. Хелпер копируется во
# временный каталог, и в копии подменяются три строки: PATH (впереди —
# заглушки networksetup, route, nc, id, ifconfig…), PREFIX и RESOLVER_DIR.
# Состояние — в OCBAR_STATE_DIR там же. Настоящий
# /usr/local/libexec/ocbar-helper не вызывается никогда, sudo — тоже.
#
#   tools/helper-selftest.sh [хелпер]    по умолчанию libexec/ocbar-helper рядом
#
# Проверки с номером пункта (1–13) ловят конкретный дефект хелпера до 0.8.0 и
# на старом хелпере должны падать все. «Контроль» — обычное поведение,
# которое должно работать в обеих версиях.
#
# Код выхода: 0 — всё прошло, 1 — есть падения, 2 — проверку не запустить.

set -u
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
umask 022

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/../libexec/ocbar-helper}"
[ "$(id -u)" != 0 ] || { echo "helper-selftest: запускайте без sudo" >&2; exit 2; }
[ -f "$SRC" ] || { echo "helper-selftest: нет $SRC" >&2; exit 2; }
case "$(cd "$(dirname "$SRC")" && pwd -P)/$(basename "$SRC")" in
    /usr/local/libexec/ocbar-helper) echo "helper-selftest: установленный хелпер не трогаю — дайте путь к копии" >&2; exit 2 ;;
esac

T=$(mktemp -d "${TMPDIR:-/tmp}/ocbar-hst.XXXXXX") || exit 2
chmod 700 "$T"
BG=""
finish() {
    local p; for p in $BG; do kill "$p" 2>/dev/null; done
    chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
}
trap finish EXIT

STUB="$T/stub"; SD="$T/stubdata"; PFX="$T/prefix"; RES="$T/resolver"; ST="$T/st"
mkdir -p "$STUB" "$SD" "$PFX/libexec/ocbar/csd" "$PFX/etc/ocbar" "$PFX/var" "$RES"

# ------------------------------------------------------------- заглушки ----
# Всё, что меняет систему, при --dry-run печатается, а не выполняется. Если
# заглушку всё же позвали с меняющей командой — это пишется в CALLED, и
# последняя проверка это ловит.
cat > "$STUB/networksetup" <<EOF
#!/bin/bash
SD="$SD"
case "\${1:-}" in
    -listallnetworkservices) echo "An asterisk (*) denotes that a network service is disabled."; cat "\$SD/services" 2>/dev/null ;;
    -getsocksfirewallproxy) if [ -f "\$SD/socks-\$2" ]; then cat "\$SD/socks-\$2"; else printf 'Enabled: No\nServer: \nPort: 0\n'; fi ;;
    -getdnsservers) if [ -f "\$SD/dns-\$2" ]; then cat "\$SD/dns-\$2"; else echo "There aren't any DNS Servers set on \$2."; fi ;;
    -listnetworkserviceorder) ;;
    *) echo "networksetup \$*" >> "\$SD/CALLED" ;;
esac
exit 0
EOF
cat > "$STUB/route" <<EOF
#!/bin/bash
SD="$SD"
dflt() { printf '   route to: default\ndestination: default\n       mask: default\n    gateway: 192.0.2.1\n  interface: en0\n'; }
if [ "\${1:-}" = -n ] && [ "\${2:-}" = get ]; then
    if [ "\${3:-}" = -net ]; then f="\$SD/route-\$(printf '%s' "\$4" | tr '/' '_')"; [ -f "\$f" ] && cat "\$f" || dflt
    elif [ "\${3:-}" = -host ] && [ -f "\$SD/route-host-\$4" ]; then cat "\$SD/route-host-\$4"
    else dflt; fi
    exit 0
fi
echo "route \$*" >> "\$SD/CALLED"
# «Маршрут уже есть»: так ведёт себя route add при живом чужом host-route.
[ "\${2:-}" = add ] && [ "\${3:-}" = -host ] && [ -f "\$SD/route-busy-\$4" ] && exit 1
exit 0
EOF
for c in ifconfig dscacheutil killall; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/CALLED"\nexit 0\n' "$c" "$SD" > "$STUB/$c"
done
# Порт 53 «молчит»: старый cleanup в этом случае стирал DNS сервиса.
printf '#!/bin/bash\nexit 1\n' > "$STUB/nc"
# id: OCBAR_TEST_UID подменяет только «id -u» — так проверяется отказ под root.
cat > "$STUB/id" <<'EOF'
#!/bin/bash
if [ -n "${OCBAR_TEST_UID:-}" ] && [ "$#" = 1 ] && [ "$1" = -u ]; then echo "$OCBAR_TEST_UID"; exit 0; fi
exec /usr/bin/id "$@"
EOF
chmod 755 "$STUB"/*

# Установка-муляж: копия openconnect, манифесты доверия (новый и старый
# путь), csd-wrapper, штатный vpnc-script старого режима full.
printf '#!/bin/sh\nexit 0\n' > "$PFX/libexec/ocbar/openconnect"
printf '#!/bin/sh\nexit 0\n' > "$PFX/libexec/ocbar/csd/wrap"
printf '#!/bin/sh\nexit 0\n' > "$PFX/libexec/ocbar/vpnc-script-full"
chmod 755 "$PFX/libexec/ocbar/openconnect" "$PFX/libexec/ocbar/csd/wrap" "$PFX/libexec/ocbar/vpnc-script-full"
: > "$PFX/libexec/ocbar/trust.sha256"; : > "$PFX/etc/ocbar/trust.sha256"

# ------------------------------------------------------------ копия хелпера ----
H="$T/ocbar-helper"
sed -e "s|^PATH=\"/usr/bin:/bin:/usr/sbin:/sbin\"\$|PATH=\"$STUB:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
    -e "s|^PREFIX=\"/usr/local\"\$|PREFIX=\"$PFX\"|" \
    -e "s|^RESOLVER_DIR=\"/etc/resolver\"\$|RESOLVER_DIR=\"$RES\"|" "$SRC" > "$H"
chmod 755 "$H"
for pat in "PATH=\"$STUB:" "PREFIX=\"$PFX\"" "RESOLVER_DIR=\"$RES\""; do
    grep -Fq -- "$pat" "$H" || { echo "helper-selftest: в копии не удалась подмена $pat — формат хелпера сменился" >&2; exit 2; }
done
# Вне PREFIX остаться могут только комментарии и запасной путь к
# Homebrew-openconnect: всё остальное указывало бы на настоящую установку.
if grep -n '/usr/local' "$H" | grep -Ev '^[0-9]+:[[:space:]]*#' | grep -v '/usr/local/bin/openconnect' | grep -q .; then
    echo "helper-selftest: в копии остался /usr/local вне PREFIX" >&2; exit 2
fi

# ------------------------------------------------------------------ обвязка ----
PASS=0; FAIL=0; CPASS=0; CFAIL=0; OUT=""; RC=0
HASH=0000000000000000000000000000000000000000
ME=$(/usr/bin/id -un)

fresh() {
    rm -rf "$ST"; mkdir -m 755 "$ST"
    rm -f "$SD"/socks-* "$SD"/dns-* "$SD"/route-* "$RES"/*
    : > "$SD/services"
}
# Запуск копии: вывод (stdout и stderr) — в OUT, код — в RC.
H_()  { OUT=$(OCBAR_STATE_DIR="${STDIR:-$ST}" "$H" --dry-run "$@" 2>&1 </dev/null); RC=$?; }
Hin() { local in="$1"; shift; OUT=$(printf '%s' "$in" | OCBAR_STATE_DIR="$ST" "$H" --dry-run "$@" 2>&1); RC=$?; }
Henv() { OUT=$(env OCBAR_STATE_DIR="$ST" "$@" 2>&1 </dev/null); RC=$?; }
# Без --dry-run: нужно там, где проверяется реакция на код возврата команды
# (в холостом прогоне команда не запускается). Безопасно: каталог состояния
# временный, PATH копии ведёт на заглушки, RESOLVER_DIR подменён.
Hreal() { OUT=$(OCBAR_STATE_DIR="$ST" "$H" "$@" 2>&1 </dev/null); RC=$?; }
has()    { printf '%s' "$OUT" | grep -Fq -- "$1"; }
hasnt()  { ! has "$1"; }
rc0()    { [ "$RC" = 0 ]; }
rcbad()  { [ "$RC" != 0 ]; }
fline()  { grep -Fxq -- "$2" "$1" 2>/dev/null; }
fnoline() { ! fline "$@"; }
fnocontains() { ! grep -Fq -- "$2" "$1" 2>/dev/null; }
route_fixture() { # cidr интерфейс адрес маска
    printf '   route to: %s\ndestination: %s\n       mask: %s\n  interface: %s\n' "$3" "$3" "$4" "$2" > "$SD/route-$(printf '%s' "$1" | tr '/' '_')"
}

check() { # номер, описание, условие…
    local id="$1" name="$2"; shift 2
    if "$@"; then
        if [ "$id" = контроль ]; then CPASS=$((CPASS+1)); else PASS=$((PASS+1)); fi
        printf '  [ OK ] %-9s %s\n' "$id" "$name"
    else
        if [ "$id" = контроль ]; then CFAIL=$((CFAIL+1)); else FAIL=$((FAIL+1)); fi
        printf '  [FAIL] %-9s %s\n' "$id" "$name"
        printf '%s\n' "$OUT" | sed -n '1,6s/^/           | /p'
    fi
    return 0
}
all() { local c; for c in "$@"; do eval "$c" || return 1; done; return 0; }

echo "ocbar-helper selftest: $SRC"
echo "  версия: $("$H" version 2>/dev/null)"

# ------------------------------------------------------------------ 1 ----
fresh
mkdir -m 777 "$T/st777"
STDIR="$T/st777" H_ dns-clear
check 1 "каталог состояния с правами 777 — отказ" all rcbad 'has отказ'
mkdir -m 777 "$T/open"; mkdir -m 755 "$T/open/st"
STDIR="$T/open/st" H_ dns-clear
check 1 "предок каталога состояния пишется всеми — отказ" all rcbad 'has отказ'
ln -s "$T/open/st" "$T/stlink"
STDIR="$T/stlink" H_ dns-clear
check 1 "каталог состояния — симлинк в доступное всем место — отказ" all rcbad 'has отказ'
chmod 777 "$PFX/libexec/ocbar"
H_ dns-clear
chmod 755 "$PFX/libexec/ocbar"
check 1 "LIBDIR пишется всеми — отказ" all rcbad 'has отказ'
fresh
Hin $'cookie=x\nzone ALL ALL=(ALL) NOPASSWD: ALL\nzone ok.test vpn\nzone bad.test vpn 53 extra\nnet 10.1.0.0/16\n' \
    tunnel-start vpn.example.com "$HASH" split user
check 1 "строки zone из stdin проверяются до записи" \
    all 'fnocontains "$ST/zones.wanted" NOPASSWD' 'fnocontains "$ST/zones.wanted" bad.test' 'fline "$ST/zones.wanted" "ok.test vpn 53"'
fresh
mkdir -p "$PFX/var/ocbar"
echo "STATE=connected" > "$PFX/var/ocbar/tunnel.env"
ln -s "$T/elsewhere" "$PFX/var/ocbar/zones.state"
echo x > "$T/hard"; ln "$T/hard" "$PFX/var/ocbar/routes.state"
H_ migrate-state
check 1 "migrate-state: обычный файл переносится, симлинк и жёсткая ссылка — нет" \
    all rc0 'has "mv $PFX/var/ocbar/tunnel.env $ST/tunnel.env"' 'hasnt "mv $PFX/var/ocbar/zones.state"' 'hasnt "mv $PFX/var/ocbar/routes.state"'
rm -rf "$PFX/var/ocbar" "$T/hard"

# ------------------------------------------------------------------ 2 ----
fresh
Hin $'cookie=x\n' tunnel-start vpn.example.com "$HASH" split vpn.login@corp "" wrap
check 2 "--csd-user — локальный пользователь, а не логин VPN" \
    all rc0 'has "--csd-user $ME "' 'hasnt "--csd-user vpn.login@corp"'

# ------------------------------------------------------------------ 3 ----
/bin/sleep 300 & SPID=$!; BG="$BG $SPID"
fresh; echo "$SPID" > "$ST/openconnect.pid"
H_ tunnel-stop
check 3 "tunnel-stop: pid чужого процесса — без сигнала, pidfile убран" \
    all 'hasnt "kill -INT $SPID"' '[ ! -f "$ST/openconnect.pid" ]'
fresh; echo "$SPID" > "$ST/openconnect.pid"
H_ stats
check 3 "stats: pid чужого процесса — без SIGUSR1" all rcbad 'hasnt "kill -USR1"'
fresh; echo "$SPID" > "$ST/openconnect.pid"
H_ reconnect-now
check 3 "reconnect-now: pid чужого процесса — без SIGUSR2" all rcbad 'hasnt "kill -USR2"'
fresh; echo "$SPID" > "$ST/openconnect.pid"; echo z.test > "$ST/zones.state"; echo "nameserver 10.0.0.1" > "$RES/z.test"
H_ cleanup
check 3 "cleanup: pid чужого процесса — туннель мёртв, хвосты убраны" \
    all 'has "зона снята: z.test"' '[ ! -f "$ST/openconnect.pid" ]'
kill "$SPID" 2>/dev/null
( exec -a openconnect /bin/sleep 300 ) & OPID=$!; BG="$BG $OPID"
sleep 0.3
fresh; echo "$OPID" > "$ST/openconnect.pid"
H_ stats
check контроль "stats: живой openconnect получает SIGUSR1" has "kill -USR1 $OPID"
kill "$OPID" 2>/dev/null

# ------------------------------------------------------------------ 4 ----
fresh; printf 'corp.test vpn 53\na.corp.test vpn 53\n' > "$ST/zones.wanted"
H_ zone-del corp.test
check 4 "zone-del снимает зону, а не её поддомены" \
    all rc0 'fline "$ST/zones.wanted" "a.corp.test vpn 53"' 'fnoline "$ST/zones.wanted" "corp.test vpn 53"'
fresh; printf 'corp.test vpn 53\na.corp.test vpn 53\n' > "$ST/zones.wanted"
H_ zone-add test 10.0.0.1
check 4 "zone-add test не стирает зоны *.test" \
    all rc0 'fline "$ST/zones.wanted" "corp.test vpn 53"' 'fline "$ST/zones.wanted" "a.corp.test vpn 53"' 'fline "$ST/zones.wanted" "test 10.0.0.1 53"'

# ------------------------------------------------------------------ 5 ----
fresh; route_fixture 10.5.0.0/16 utun9 10.5.0.0 255.255.0.0
H_ route-del 10.5.0.0/16
check 5 "route-del: сети нет в routes.state — чужой маршрут не трогаем" \
    all 'hasnt "route -n delete"' 'hasnt "маршрут снят"'
fresh; echo "0.0.0.0/0 utun5" > "$ST/routes.state"
H_ route-del 0.0.0.0/0
check 5 "route-del 0.0.0.0/0 — отказ" all rcbad 'hasnt "маршрут снят"'
fresh; echo "0.0.0.0/0 utun5" > "$ST/routes.state"
H_ cleanup
check 5 "cleanup: /0 из routes.state не снимается" all 'hasnt "маршрут снят"' 'hasnt "route -n delete"'
fresh; echo "10.7.0.0/16 utun5" > "$ST/routes.state"; route_fixture 10.7.0.0/16 utun5 10.7.0.0 255.255.0.0
H_ route-del 10.7.0.0/16
check 5 "route-del: свой маршрут снимается с указанием интерфейса" \
    has "route -n delete -net 10.7.0.0/16 -interface utun5"
fresh; echo "10.8.0.0/16 utun5" > "$ST/routes.state"; route_fixture 10.8.0.0/16 utun9 10.8.0.0 255.255.0.0
H_ cleanup
check 5 "cleanup: сеть из routes.state теперь через чужой utun — не трогаем" \
    all 'hasnt "маршрут снят"' 'hasnt "route -n delete -net 10.8"'

# Маршрут до шлюза: наш — только если добавили мы.
fresh; printf '   route to: 198.51.100.9\n    gateway: 203.0.113.7\n  interface: utun3\n' > "$SD/route-host-198.51.100.9"
Henv reason=connect TUNDEV=utun9 INTERNAL_IP4_ADDRESS=10.9.0.2 VPNGATEWAY=198.51.100.9 "$H" --dry-run vpnc
check 5 "маршрут до шлюза уже есть через чужой шлюз — не наш" \
    all 'has "не мой"' 'test ! -f "$ST/gateway.route"'
fresh
Henv reason=connect TUNDEV=utun9 INTERNAL_IP4_ADDRESS=10.9.0.2 VPNGATEWAY=198.51.100.9 "$H" --dry-run vpnc
check 5 "маршрут до шлюза добавили мы — записали в состояние" \
    all 'fline "$ST/gateway.route" "198.51.100.9 192.0.2.1"'
printf '   route to: 198.51.100.9\n    gateway: 203.0.113.7\n  interface: utun3\n' > "$SD/route-host-198.51.100.9"
H_ cleanup
check 5 "маршрут до шлюза теперь через чужой — не снимаем" \
    all 'has "уже не наш"' 'hasnt "route -n delete -host 198.51.100.9"'
fresh; printf '198.51.100.9 192.0.2.1\n' > "$ST/gateway.route"
H_ cleanup
check 5 "маршрут до шлюза наш и не изменился — снимаем" \
    all 'has "route -n delete -host 198.51.100.9 192.0.2.1"'

# Транспорт: MTU и отключение DTLS из spec доходят до openconnect.
fresh
Hin $'cookie=x\nmtu 1300\nnodtls\nnet 10.1.0.0/16\n' tunnel-start vpn.example.com "$HASH" split user
check 10 "tunnel-start: MTU и --no-dtls из spec" all 'has "--base-mtu 1300"' 'has "--no-dtls"'
fresh
Hin $'cookie=x\nmtu 99\n' tunnel-start vpn.example.com "$HASH" split user
check 10 "tunnel-start: негодный MTU пропускается" all 'has "пропускаю mtu"' 'hasnt "--base-mtu"'

# Статус «подключено» — только после маршрутов и зон.
fresh; printf '10.1.0.0/16\n' > "$ST/routes.wanted"; printf 'ok.test vpn 53\n' > "$ST/zones.wanted"
Henv reason=connect TUNDEV=utun9 INTERNAL_IP4_ADDRESS=10.9.0.2 INTERNAL_IP4_DNS=10.0.0.53 "$H" --dry-run vpnc
check 11 "vpnc: сначала маршруты и зоны, потом «подключено»" \
    all 'has "маршруты и зоны применены"' 'fline "$ST/tunnel.env" "STATE=connected"'
fresh; : > "$ST/paused"
Henv reason=connect TUNDEV=utun9 INTERNAL_IP4_ADDRESS=10.9.0.2 "$H" --dry-run vpnc
check 11 "vpnc на паузе: маршруты не применяются, статус всё равно «подключено»" \
    all 'has "стоит пауза"' 'fline "$ST/tunnel.env" "STATE=connected"'
fresh; printf 'STATE=applying\nTUNDEV=utun9\n' > "$ST/tunnel.env"
H_ cleanup
check 11 "уборка говорит о недоведённой настройке" all 'has "не доведена до конца"'

# Свой openconnect — по времени запуска, а не только по имени процесса.
fresh; sleep 30 & sp=$!
printf '%s\n' "$sp" > "$ST/openconnect.pid"
printf '%s чужое время\n' "$sp" > "$ST/openconnect.started"
H_ tunnel-stop
check 3 "pid жив, но время запуска другое — не наш процесс" \
    all 'hasnt "останавливаю openconnect"'
kill "$sp" 2>/dev/null || true; wait "$sp" 2>/dev/null || true

# ------------------------------------------------------------------ 6 ----
fresh; printf 'Wi-Fi\nWi-Fi 2\n' > "$SD/services"
printf 'Wi-Fi 2 11080\n' > "$ST/socks.state"
printf 'Enabled: Yes\nServer: 10.0.0.5\nPort: 1080\n' > "$SD/socks-Wi-Fi"
H_ socks-clear Wi-Fi
check 6 "socks-clear «Wi-Fi» не трогает запись «Wi-Fi 2»" \
    all 'grep -Eq "^Wi-Fi 2[[:space:]]11080$" "$ST/socks.state"' 'hasnt "setsocksfirewallproxystate Wi-Fi off"'
fresh; printf 'Wi-Fi\nWi-Fi 2\n' > "$SD/services"
printf 'Wi-Fi 11080\n' > "$ST/socks.state"
printf 'Enabled: Yes\nServer: 10.0.0.5\nPort: 1080\n' > "$SD/socks-Wi-Fi"
H_ socks-set Wi-Fi 11080
check 6 "socks-set: запись устарела, стоит чужой SOCKS — не перезаписываем" \
    all rcbad 'hasnt "setsocksfirewallproxy Wi-Fi"'
fresh; printf 'Wi-Fi\nWi-Fi 2\n' > "$SD/services"
printf 'Wi-Fi 11080\n' > "$ST/socks.state"
printf 'Enabled: Yes\nServer: 127.0.0.1\nPort: 12000\n' > "$SD/socks-Wi-Fi"
H_ socks-set Wi-Fi 11080
check 6 "socks-set: наш порт сменён на чужой 127.0.0.1:12000 — не перезаписываем" \
    all rcbad 'hasnt "setsocksfirewallproxy Wi-Fi"'
fresh; printf 'Wi-Fi\nWi-Fi 2\n' > "$SD/services"
H_ socks-set "Wi-Fi 2" 11080
check 6 "socks.state: сервис и порт через табуляцию" \
    all rc0 'fline "$ST/socks.state" "Wi-Fi 2	11080"'

# ------------------------------------------------------------------ 7 ----
fresh; printf 'Wi-Fi\n' > "$SD/services"; printf '127.0.0.1\n8.8.8.8\n' > "$SD/dns-Wi-Fi"
H_ cleanup
check 7 "cleanup не стирает DNS сервиса со списком 127.0.0.1 и 8.8.8.8" hasnt "setdnsservers"
fresh; printf 'Wi-Fi\n' > "$SD/services"; printf '127.0.0.1\n' > "$SD/dns-Wi-Fi"
H_ cleanup
check 7 "cleanup не трогает DNS сервиса вовсе (ocbar его не ставит)" hasnt "setdnsservers"

# ------------------------------------------------------------------ 8 ----
fresh; printf 'nameserver 10.0.0.1\n' > "$RES/corp.test"
Hin $'corp.test 10.0.0.1\n' dns-apply
check 8 "/etc/resolver: чужой файл с тем же содержимым не усыновляется" \
    all rc0 'fnoline "$ST/zones.state" corp.test'

# ------------------------------------------------------------------ 9 ----
fresh
Hin $'cookie=x\n' tunnel-start vpn.example.com "$HASH" split user $'Mozilla/5.0\nX-Evil: 1'
check 9 "user-agent с переводом строки — отказ" rcbad
fresh
Hin $'cookie=x\n' tunnel-start vpn.example.com "$HASH" split $'user\nroot'
check 9 "имя пользователя с переводом строки — отказ" rcbad
fresh
Hin $'cookie=x\n' tunnel-start vpn.example.com "$HASH" split user "" ..
check 9 "имя csd-wrapper «..» — отказ" all rcbad 'hasnt "--csd-wrapper"'
fresh
H_ zone-add $'a.test\nb.test' vpn
check 9 "зона с переводом строки — отказ" all rcbad 'fnocontains "$ST/zones.wanted" b.test'
fresh
Henv reason=connect TUNDEV=utun9 INTERNAL_IP4_ADDRESS=10.9.0.2 CISCO_DEF_DOMAIN=$'corp.example\nINJECTED=1' "$H" --dry-run vpnc
check 9 "vpnc: перевод строки от шлюза не дописывает строк в tunnel.env" \
    all rc0 'fnoline "$ST/tunnel.env" INJECTED=1'

# ----------------------------------------------------------------- 10 ----
fresh
Henv reason=connect TUNDEV=utun9 INTERNAL_IP4_ADDRESS=10.9.0.2 CISCO_SPLIT_INC=3 \
     CISCO_SPLIT_INC_0_ADDR=10.0.0.0 CISCO_SPLIT_INC_0_MASKLEN=8 "$H" --dry-run vpnc
check 10 "vpnc: счётчик сетей больше числа записей — не обрыв" \
    all rc0 'fline "$ST/tunnel.env" STATE=connected'
fresh
Henv reason=connect TUNDEV=utun9 INTERNAL_IP4_ADDRESS=10.9.0.2 INTERNAL_IP4_MTU=99999 "$H" --dry-run vpnc
check 10 "vpnc: MTU проверяется перед ifconfig" all rc0 'hasnt "mtu 99999"' 'has "mtu 1400"'
fresh
Henv reason=connect TUNDEV=utun9 INTERNAL_IP4_ADDRESS=10.9.0.2 'INTERNAL_IP6_ADDRESS=zz;zz' "$H" --dry-run vpnc
check 10 "vpnc: IPv6-адрес проверяется перед ifconfig" all rc0 'hasnt inet6'

# ----------------------------------------------------------------- 11 ----
fresh; printf 'STATE=connected\nTUNDEV=utun7\n' > "$ST/tunnel.env"
H_ tunnel-stop
check 11 "tunnel-stop без живого openconnect не гасит utun из записи" hasnt "ifconfig utun7 down"
fresh; printf 'STATE=connected\nTUNDEV=utun7\n' > "$ST/tunnel.env"; echo "203.0.113.1 192.0.2.1" > "$ST/gateway.route"
H_ cleanup
check 11 "cleanup без живого openconnect не гасит utun из записи" hasnt "ifconfig utun7 down"

# ----------------------------------------------------------------- 12 ----
fresh
OUT=$(OCBAR_TEST_UID=0 OCBAR_STATE_DIR="$ST" "$H" --dry-run dns-clear 2>&1 </dev/null); RC=$?
check 12 "--dry-run под root — отказ" all rcbad 'has "под root"'

# ----------------------------------------------------------------- 13 ----
fresh
Hin $'cookie=x\n' tunnel-start vpn.example.com "$HASH" full user
check 13 "режим full — отказ" rcbad

# ------------------------------------------------------------- контроль ----
fresh
Hin $'cookie=x\nnet 10.1.0.0/16\nzone corp.test vpn\n' tunnel-start vpn.example.com "$HASH" split user "Mozilla/5.0 (Macintosh)"
check контроль "tunnel-start split с верными данными проходит" \
    all rc0 'has "--useragent Mozilla/5.0 (Macintosh)"' 'fline "$ST/routes.wanted" 10.1.0.0/16'
fresh
Henv reason=connect TUNDEV=utun9 INTERNAL_IP4_ADDRESS=10.9.0.2 INTERNAL_IP4_DNS=10.0.0.53 "$H" --dry-run vpnc
check контроль "vpnc connect пишет connected и DNS шлюза" \
    all rc0 'fline "$ST/tunnel.env" STATE=connected' 'fline "$ST/tunnel.env" DNS=10.0.0.53' 'has "ifconfig utun9 inet 10.9.0.2"'
fresh; printf 'corp.test vpn 53\n' > "$ST/zones.wanted"
H_ zone-del corp.test
check контроль "zone-del убирает саму зону" all rc0 'fnoline "$ST/zones.wanted" "corp.test vpn 53"'
check контроль "ни одна заглушка не вызвана с меняющей командой" '[' ! -s "$SD/CALLED" ']'

echo "----------------------------------------"
echo "проверки пунктов: прошло $PASS, упало $FAIL; контрольные: прошло $CPASS, упало $CFAIL"
[ "$FAIL" = 0 ] && [ "$CFAIL" = 0 ]
