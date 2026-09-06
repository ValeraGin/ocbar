# ocbar

Клиент Cisco AnyConnect (OpenConnect) для macOS: SSO через WKWebView с
автозаполнением и TOTP, split DNS через `/etc/resolver`, split tunneling с
переключением сетей на лету, супервизор (реконнект, сон, смена интерфейса),
меню-бар на SwiftBar, раздача через Homebrew tap.

**Статус: 0.1.0, работает вживую.** Вход через SSO, туннель, split DNS,
маршруты и зоны на лету, пауза, супервизор и меню проверены на реальном
шлюзе. Реконнект и смена сетевого интерфейса подтверждены живыми событиями.
Что дальше — [ROADMAP.md](ROADMAP.md), как поставить — [INSTALL.md](INSTALL.md).

## Как это устроено

```
ocbar connect
  │
  ├─ ocbar-auth (Swift, WKWebView)        от пользователя
  │    init → окно SAML → cookie → auth-reply → session-token + server-cert-hash
  │
  └─ sudo -n ocbar-helper tunnel-start    root, NOPASSWD только на него
       ├─ openconnect --cookie-on-stdin --script "ocbar-helper vpnc" -b
       └─ vpnc: ifconfig utunN, наши маршруты, наши зоны /etc/resolver — и ничего больше

ocbar supervise (LaunchAgent)             от пользователя, раз в 5 с
       pid туннеля · kern.waketime · PrimaryInterface · маршруты на месте
```

Три слоя из [docs/05-architecture.md](docs/05-architecture.md): аутентификатор,
супервизор, UI. Привилегированный код — один файл
[libexec/ocbar-helper](libexec/ocbar-helper) с фиксированными подкомандами и
валидацией каждого аргумента; почему так, а не root-демон — [DECISIONS.md](DECISIONS.md).

## Установка

Коротко (подробно и с объяснениями — [INSTALL.md](INSTALL.md)):

```bash
brew install openconnect
git clone https://github.com/ValeraGin/ocbar.git ~/Projects/ocbar && cd ~/Projects/ocbar
(cd auth && swift build -c release)   # Swift идёт с Command Line Tools
sudo ./bin/ocbar install              # один раз: хелпер, sudoers, агент
./bin/ocbar secret set-password
./bin/ocbar connect --show
```

Через Homebrew, когда репозиторий опубликован:

```bash
brew tap ValeraGin/ocbar
brew install --HEAD ocbar             # собирает из исходников у вас
sudo ocbar install
```

`brew upgrade ocbar` — это и есть автообновление. Почему формула, а не
готовый бинарь: без Apple Developer ID собранное локально не получает
карантина, и Gatekeeper не мешает — [docs/06-distribution.md](docs/06-distribution.md).

## Настройка

Конфиги в `~/.config/ocbar/`, образцы в [etc/](etc/):

| Файл | Что |
|---|---|
| `profiles.conf` | профили: `url`, `user`, `auth = sso\|password`, `keychain_service`, `healthcheck` |
| `networks.conf` | CIDR в туннель, по одному на строку |
| `zones.conf` | `<зона> <DNS\|vpn> [порт]` — `vpn` означает DNS, который прислал шлюз |
| `autofill.rules` | правила заполнения формы IdP, читаются при каждом запуске |

Полезные ключи профиля: `healthcheck` — что проверить после подключения
(URL, «хост:порт» или имя); `notifications = off` в шапке файла выключает
уведомления системы.

Секреты — в Keychain, в аргументы не попадают:

```bash
ocbar secret set-password       # спросит security, не ocbar
ocbar secret set-totp           # base32-секрет, если IdP просит код
ocbar secret status             # что есть в связке и включён ли автоввод
```

Секрет TOTP удобнее занести из QR-кода — понимается и обычный `otpauth://`,
и экспорт Google Authenticator. Секрет идёт прямо в Keychain, на экран не
попадает:

```bash
ocbar secret import-qr ~/Downloads/qr.png --list          # что внутри
ocbar secret import-qr ~/Downloads/qr.png --select <часть-имени>   # занести нужное
```

Экспорт почти всегда содержит несколько записей, поэтому без `--select`
импорт откажется работать: занести чужой секрет и получить блокировку
учётной записи на неверных кодах — слишком дорогая ошибка.

Если TOTP живёт в KeePassXC, секрет можно вообще не копировать: `ocbar`
попросит у базы готовый код. В профиле:

```ini
totp = keepassxc
keepass_entry = Группа/Запись
keepass_db = ~/путь/база.kdbx
keepass_keychain_service = keepassxc-docs
```

Мастер-пароль базы берётся из Keychain по имени сервиса и в аргументы не
попадает; `keepassxc-cli` читает файл напрямую, разблокировать окно
KeePassXC не нужно. Если база недоступна, вход не ломается — код вводит
человек, причина пишется в лог.

## Команды

```
ocbar connect [профиль] [--show]      SSO и туннель; окно покажется, если за 2 с не прошло молча
ocbar disconnect
ocbar status [--short]                --short — для плагина меню
ocbar routes add|del|toggle <CIDR>    маршруты на живом туннеле
ocbar dns on|off|toggle <зона>        зоны /etc/resolver
ocbar pause | resume | toggle         «как будто выключен»: маршруты и зоны сняты,
                                      туннель и вход живы, возврат мгновенный
ocbar doctor                          диагностика, ничего не меняет
ocbar cleanup                         мусор после падения: зоны, маршруты, DNS 127.0.0.1
ocbar supervise                       цикл реконнекта (его держит LaunchAgent)
--dry-run                             печатать привилегированные команды вместо выполнения
```

Аутентификатор отдельно — удобно для диагностики шлюза без учётных данных:

```bash
auth/.build/release/ocbar-auth --probe --url vpn.example.com/group
auth/.build/release/ocbar-auth --selftest        # TOTP по RFC 6238, разбор XML
auth/.build/release/ocbar-auth --dump-script     # JS автозаполнения по правилам
```

## Меню-бар

[swiftbar/ocbar.5s.sh](swiftbar/ocbar.5s.sh) — плагин [SwiftBar](https://github.com/swiftbar/SwiftBar):
статус, профили, тоглы маршрутов и зон, предупреждение «мак просыпался после
подключения». Проверяется без SwiftBar — это просто stdout.

## Что защищено

- **чужие зоны в `/etc/resolver` не трогаются** — хелпер помнит только свои
  (манифест), чужой файл пропускает и в манифест не берёт;
- **чужой openconnect не трогается** — без нашего pidfile `cleanup` его не убьёт,
  а `disconnect` не погасит чужой `utun`;
- **root никогда не исполняет user-writable файл**: копия `openconnect` в
  `/usr/local/libexec/ocbar/` сверяется по sha256 вместе с dylib, csd-wrapper
  берётся только по имени из root-каталога, vpnc-script — сам хелпер;
- **cookie сессии и пароли** идут через stdin и окружение, в `ps` их нет.

## Пауза вместо отключения

Отключение и повторный вход стоят второго фактора и новой сессии на шлюзе.
Когда VPN нужно просто убрать с дороги — посмотреть на сайт снаружи, сходить
в домашнюю сеть, не гонять трафик через корпоративный канал — есть пауза:

```bash
ocbar pause     # маршруты и зоны сняты, туннель и SSO-сессия живы
ocbar resume    # вернуть, мгновенно и без входа
```

Пауза переживает обрыв связи: если туннель переподнимется сам, маршруты не
вернутся, пока не скажете `resume`. Новое подключение (`connect`) всегда
начинается без паузы.

## Ограничения

- парольные группы (логин + OTP из SMS) `ocbar` не ведёт: SMS-код взять неоткуда.
  Такой профиль помечается `auth = password` и в меню показывается серым;
- «всё в туннель» настраивается сетями `0.0.0.0/1` и `128.0.0.0/1` в конфиге, но шлюз при этом может не выпускать в интернет — проверено;
- IPv6 в туннеле не обрабатывается (адрес ставится, маршруты — нет);
- без Apple Developer ID: только сборка из исходников, поэтому Homebrew formula,
  а не cask — [docs/06-distribution.md](docs/06-distribution.md).

## Документация

| Файл | О чём |
|---|---|
| [01-analysis.md](docs/01-analysis.md) | Что уже написано и что есть в мире |
| [02-protocol.md](docs/02-protocol.md) | SSO: `sso-v2` против `external-browser`, почему нужен webview |
| [03-dns.md](docs/03-dns.md) | Split DNS: `/etc/resolver`, dnsmasq, «плохие ответы» |
| [04-routing.md](docs/04-routing.md) | Split tunneling и динамическое управление маршрутами |
| [05-architecture.md](docs/05-architecture.md) | Три слоя, супервизор, выбор стека |
| [06-distribution.md](docs/06-distribution.md) | Раздача и автообновление без Developer ID |
| [07-requirements.md](docs/07-requirements.md) | Требования со статусом |
| [08-references.md](docs/08-references.md) | Ссылки |
| [DECISIONS.md](DECISIONS.md) | Решения этой реализации и почему |

Практическое:

| Файл | О чём |
|---|---|
| [INSTALL.md](INSTALL.md) | Установка с нуля, настройка, перенос на другую машину, удаление |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Что делать, когда не работает — по реальным отказам |
| [ROADMAP.md](ROADMAP.md) | Что дальше и что решено не делать |

## Соглашения

- Проверенное на живой системе помечено **[проверено ГГГГ-ММ-ДД]** с командой и
  выводом. Непроверенное так и названо. Смешивать нельзя.
- Корпоративная специфика (адреса, DNS, домены, имена групп) живёт только в
  локальных заметках и в `.gitignore`.
