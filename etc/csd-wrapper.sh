#!/bin/bash
# Cisco Secure Desktop (HostScan) wrapper для ocbar — аналог csd-post.sh
# из поставки openconnect, адаптированный для macOS.
#
# Вместо запуска hostscan-«трояна» Cisco скрипт отправляет шлюзу готовые
# ответы о состоянии машины. Идеально было бы разобрать DES-шифрованный
# tables.dat и воспроизвести нужные части самого hostscan, но заранее
# подготовленных ответов, подогнанных под то, что шлюз хочет видеть,
# хватает большинству. Значения можно и стоит сделать правдивыми под свою
# политику — правьте REPORT ниже.
#
# Контракт вызова — как у openconnect, чтобы скрипт работал и от ocbar-auth
# (auth/Sources/ocbar-auth/CSD.swift), и от openconnect с --csd-wrapper:
#   argv: <stub> -ticket <ticket> -stub 0 -group <tunnel-group>
#         -certhash <hash> -url https://<host>[:<port>]<host-scan-base-uri>
#         -langselen en-US
#   env:  CSD_HOSTNAME — хост шлюза;
#         CSD_TOKEN    — токен проверки;
#         CSD_SHA256   — pin сертификата шлюза (base64 SHA-256 открытого
#                        ключа), в формате curl --pinnedpubkey.

# --- Отчёт о состоянии машины: ОС, ядро, архитектура и имя — настоящие,
# --- остальное — заглушки из csd-post.sh openconnect (MAC, файрвол, порты).
# --- Если политика шлюза требует конкретных значений (антивирус, файрвол,
# --- версии) — поправьте под то, что она хочет видеть.

REPORT="endpoint.os.version=\"$(sw_vers -productVersion 2>/dev/null || echo Darwin)\";
endpoint.os.servicepack=\"$(uname -r)\";
endpoint.os.architecture=\"$(uname -m)\";
endpoint.policy.location=\"Default\";
endpoint.device.protection=\"none\";
endpoint.device.protection_version=\"3.1.03103\";
endpoint.device.hostname=\"$(hostname 2>/dev/null || echo mac)\";
endpoint.device.MAC[\"FFFF.FFFF.FFFF\"]=\"true\";
endpoint.device.protection_extension=\"3.6.4900.2\";
endpoint.fw[\"IPTablesFW\"]={};
endpoint.fw[\"IPTablesFW\"].exists=\"true\";
endpoint.fw[\"IPTablesFW\"].description=\"IPTables (Linux)\";
endpoint.fw[\"IPTablesFW\"].version=\"1.6.1\";
endpoint.fw[\"IPTablesFW\"].enabled=\"ok\";"

for port in 9217 139 53 22 631 445 9216; do
    REPORT="$REPORT
endpoint.device.port[\"$port\"]=\"true\";
endpoint.device.tcp4port[\"$port\"]=\"true\";
endpoint.device.tcp6port[\"$port\"]=\"true\";"
done

# --- Контракт openconnect: первый аргумент — путь к скачанному stub,
# --- csd-post.sh его игнорирует (shift).

shift

TICKET=
STUB=0
BASE=

while [ "$1" ]; do
    case "$1" in
        -ticket) shift; TICKET=${1//\"/} ;;
        -stub)   shift; STUB=${1//\"/} ;;
        -url)    shift; BASE=$1 ;;
    esac
    shift
done

# База запросов — из -url: там есть порт, когда шлюз не на 443, а
# CSD_HOSTNAME — только хост. Нет -url — стандартный путь, как у csd-post.sh.
if [ -z "$BASE" ]; then
    BASE="https://$CSD_HOSTNAME/+CSCOE+/sdesktop"
fi
BASE=${BASE%/}

# Сертификат шлюза проверяем по pin из CSD_SHA256: -k отключает проверку
# цепочки, но pin остаётся — подмена сертификата не пройдёт. Без pin —
# обычная проверка цепочки curl.
PIN=()
if [ -n "$CSD_SHA256" ]; then
    PIN=(-k --pinnedpubkey "sha256//$CSD_SHA256")
fi

RESPONSE=$(curl -s "${PIN[@]}" "$BASE/token.xml?ticket=$TICKET&stub=$STUB")
rc=$?
if [ $rc -ne 0 ]; then
    echo "csd-wrapper: token.xml недоступен — сертификат шлюза или сеть (curl код $rc)" >&2
    exit 1
fi
TOKEN=$(printf '%s' "$RESPONSE" | sed -n 's/.*<token>\(.*\)<\/token>.*/\1/p')
if [ -z "$TOKEN" ]; then
    echo "csd-wrapper: в ответе token.xml нет <token> — ticket принят шлюзом?" >&2
    exit 1
fi

RESULT=$(curl -s "${PIN[@]}" \
    -H "Content-Type: text/xml" \
    -H "Cookie: sdesktop=$TOKEN" \
    -H "Expect: " \
    --data-binary "$REPORT" \
    "$BASE/scan.xml?reusebrowser=1")
rc=$?
if [ $rc -ne 0 ]; then
    echo "csd-wrapper: отчёт не отправлен (curl код $rc)" >&2
    exit 1
fi
[ -n "$RESULT" ] && printf '%s\n' "$RESULT"
exit 0
