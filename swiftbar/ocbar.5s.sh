#!/bin/bash
# <xbar.title>ocbar</xbar.title>
# <xbar.desc>Статус и управление OpenConnect VPN (ocbar)</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
#
# Плагин — только stdout: всё состояние берёт из `ocbar status --short`,
# все действия — вызовы `ocbar …`. Ни одной привилегированной операции здесь нет.
# Проверять без SwiftBar: просто запустить и посмотреть вывод.

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LC_CTYPE="${LC_CTYPE:-UTF-8}"

# Плагин обычно лежит в каталоге SwiftBar симлинком на файл в репозитории,
# поэтому $0 сначала разворачиваем — иначе ../bin/ocbar ищется рядом с
# симлинком и не находится.
SELF="$0"
while [ -L "$SELF" ]; do
    _t=$(readlink "$SELF"); case "$_t" in /*) SELF="$_t" ;; *) SELF="$(dirname "$SELF")/$_t" ;; esac
done
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"

OCBAR=""
for c in "${OCBAR_BIN:-}" "$SELF_DIR/../bin/ocbar" "$SELF_DIR/../../bin/ocbar" \
         /opt/homebrew/bin/ocbar /usr/local/bin/ocbar "$HOME/Projects/Personal/ocbar/bin/ocbar"; do
    [ -n "$c" ] && [ -x "$c" ] && { OCBAR="$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"; break; }
done
if [ -z "$OCBAR" ]; then
    echo "| sfimage=exclamationmark.triangle sfcolor=red"; echo "---"
    echo "ocbar не найден | color=red"
    echo "Искал рядом с $SELF и в PATH Homebrew | color=gray size=11"
    echo "Задать путь явно: OCBAR_BIN в окружении плагина | color=gray size=11"
    exit 0
fi

# --- состояние ---
state=""; profile=""; tundev=""; ip=""; since=""; gateway=""; dns=""; mode=""; foreign=""; supervisor=""; iface=""; default=""; paused="0"
routes=(); zones=(); profiles=()
while IFS='=' read -r k v; do
    case "$k" in
        state) state="$v" ;; profile) profile="$v" ;; tundev) tundev="$v" ;; ip) ip="$v" ;; since) since="$v" ;;
        gateway) gateway="$v" ;; dns) dns="$v" ;; mode) mode="$v" ;; foreign) foreign="$v" ;; supervisor) supervisor="$v" ;;
        iface) iface="$v" ;; default) default="$v" ;; paused) paused="$v" ;;
        route) routes+=("$v") ;; zone) zones+=("$v") ;; profile_list) profiles+=("$v") ;;
    esac
done < <("$OCBAR" status --short 2>/dev/null)

since_h() {
    local s=$(( $(date +%s) - ${1:-0} )); [ "$s" -ge 0 ] || s=0
    if [ $s -ge 3600 ]; then printf '%dч %dм' $((s/3600)) $(((s%3600)/60)); elif [ $s -ge 60 ]; then printf '%dм' $((s/60)); else printf '%dс' $s; fi
}
act() { printf 'bash=%s terminal=false refresh=true' "$OCBAR"; }

# --- шапка ---
case "$state" in
    connected) echo "| sfimage=lock.shield.fill sfcolor=green" ;;
    paused)    echo "| sfimage=lock.shield sfcolor=yellow" ;;
    starting)  echo "| sfimage=lock.shield sfcolor=orange" ;;
    *) if [ "$foreign" = 1 ]; then echo "| sfimage=lock.shield sfcolor=gray"; else echo "| sfimage=lock.open sfcolor=gray"; fi ;;
esac
echo "---"

# --- пробуждение после подключения = повод проверить туннель ---
if [ "$state" = connected ] && [ -n "${OS_LAST_WAKE_TIME:-}" ] && [ -n "$since" ]; then
    wake_ts=$(sysctl -n kern.waketime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')
    if [ -n "$wake_ts" ] && [ "$wake_ts" -gt "$since" ]; then
        echo "Мак просыпался после подключения ($(date -r "$wake_ts" '+%H:%M')) | color=orange size=11"
        [ "$supervisor" = 1 ] && echo "Супервизор проверит туннель сам | color=gray size=11"
        echo "---"
    fi
fi

# --- статус и главное действие ---
case "$state" in
    connected)
        echo "Подключён · ${tundev:-?} · ${ip:-?} · $(since_h "$since") | color=green"
        [ -n "$profile" ] && echo "Профиль: $profile · режим $mode | color=gray size=11"
        [ -n "$gateway" ] && echo "Шлюз $gateway · DNS ${dns:-—} | color=gray size=11"
        echo "Приостановить | $(act) param1=pause shortcut=CMD+OPTION+P"
        echo "Трафик пойдёт мимо, вход не потребуется снова | alternate=true color=gray"
        echo "Отключить | $(act) param1=disconnect shortcut=CMD+OPTION+V" ;;
    paused)
        echo "На паузе · туннель жив ($(since_h "$since")) | color=orange"
        [ -n "$profile" ] && echo "Профиль: $profile · маршруты и зоны сняты | color=gray size=11"
        echo "Возобновить | $(act) param1=resume shortcut=CMD+OPTION+P"
        echo "Мгновенно, без входа | alternate=true color=gray"
        echo "Отключить совсем | $(act) param1=disconnect shortcut=CMD+OPTION+V" ;;
    starting)
        echo "Подключается… | color=orange"
        echo "Отменить | $(act) param1=disconnect" ;;
    *)
        if [ "$foreign" = 1 ]; then
            echo "Работает чужой openconnect (не ocbar) | color=gray"
            echo "Это, скорее всего, vpn_manager.sh — ocbar его не трогает | color=gray size=11"
        else
            echo "Отключён | color=gray"
        fi
        if [ -n "$default" ]; then
            echo "Подключить ($default) | $(act) param1=connect param2=$default shortcut=CMD+OPTION+V"
        fi ;;
esac
echo "---"

# --- профили ---
echo "Профили"
for p in "${profiles[@]}"; do
    IFS='|' read -r name title auth descr <<< "$p"
    mark=""; [ "$name" = "$profile" ] && [ "$state" = connected ] && mark="checked=true"
    if [ "$auth" = password ]; then
        echo "-- ${title:-$name} · пароль+OTP, через openconnect | color=gray"
    else
        echo "-- ${title:-$name} | $(act) param1=connect param2=$name $mark"
        [ -n "$descr" ] && echo "-- ${descr} | alternate=true color=gray"
    fi
done
[ "${#profiles[@]}" = 0 ] && echo "-- нет profiles.conf | color=gray"

# --- маршруты ---
if [ "$paused" = 1 ]; then
    echo "Маршруты в туннель (на паузе не действуют)"
else
    echo "Маршруты в туннель"
fi
for r in "${routes[@]}"; do
    read -r net via onoff <<< "$r"
    if [ "$paused" = 1 ]; then
        echo "-- $net | color=gray"
    elif [ "$onoff" = off ]; then
        echo "-- $net | $(act) param1=routes param2=toggle param3=$net color=gray"
    elif [ -n "$via" ] && [ "$via" = "$tundev" ]; then
        echo "-- $net | $(act) param1=routes param2=toggle param3=$net checked=true"
    elif [ -n "$via" ]; then
        echo "-- $net → $via | $(act) param1=routes param2=toggle param3=$net checked=true color=orange"
    else
        echo "-- $net | $(act) param1=routes param2=toggle param3=$net"
    fi
done
[ "${#routes[@]}" = 0 ] && echo "-- нет networks.conf | color=gray"

# --- зоны DNS ---
if [ "$paused" = 1 ]; then
    echo "Зоны DNS (на паузе сняты)"
else
    echo "Зоны DNS"
fi
for z in "${zones[@]}"; do
    read -r zone zdns applied onoff <<< "$z"
    label="$zone → $zdns"
    if [ "$paused" = 1 ]; then
        echo "-- $label | color=gray"
    elif [ "$onoff" = off ]; then
        echo "-- $label | $(act) param1=dns param2=toggle param3=$zone color=gray"
    elif [ "$applied" = applied ]; then
        echo "-- $label | $(act) param1=dns param2=toggle param3=$zone checked=true"
    else
        echo "-- $label | $(act) param1=dns param2=toggle param3=$zone"
    fi
done
[ "${#zones[@]}" = 0 ] && echo "-- нет zones.conf | color=gray"
echo "---"

echo "Сеть: ${iface:-?} · супервизор: $([ "$supervisor" = 1 ] && echo работает || echo 'не запущен') | color=gray size=11"
echo "Диагностика (doctor) | bash=$OCBAR param1=doctor terminal=true"
echo "Уборка (cleanup) | $(act) param1=cleanup"
echo "Открыть конфиги | bash=/usr/bin/open param1=$HOME/.config/ocbar terminal=false"
echo "Лог openconnect | bash=/usr/bin/open param1=-a param2=Console param3=/usr/local/var/ocbar/openconnect.log terminal=false"
echo "Лог супервизора | bash=/usr/bin/open param1=-a param2=Console param3=$HOME/Library/Logs/ocbar/supervisor.log terminal=false"
