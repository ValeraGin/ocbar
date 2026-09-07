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
brew tap ValeraGin/ocbar
brew install --HEAD ocbar             # собирает из исходников у вас
sudo ocbar install                    # один раз: хелпер, sudoers, агент

mkdir -p ~/.config/ocbar              # без профиля не работает ни одна команда
cp "$(brew --prefix ocbar)"/share/ocbar/examples/*.example ~/.config/ocbar/
cd ~/.config/ocbar && for f in *.example; do mv "$f" "${f%.example}"; done
$EDITOR ~/.config/ocbar/profiles.conf

ocbar secret set-password
ocbar connect --show
```

Из репозитория, без Homebrew:

```bash
brew install openconnect
git clone https://github.com/ValeraGin/ocbar.git ~/Projects/ocbar && cd ~/Projects/ocbar
(cd auth && swift build -c release)   # Swift идёт с Command Line Tools
mkdir -p ~/.config/ocbar && cp etc/profiles.conf.example ~/.config/ocbar/profiles.conf
sudo ./bin/ocbar install
```

`brew upgrade ocbar` — это и есть автообновление. Почему формула, а не
готовый бинарь: без Apple Developer ID собранное локально не получает
карантина, и Gatekeeper не мешает — [docs/06-distribution.md](docs/06-distribution.md).

## Настройка

### Профиль одним файлом

По образцу конфигов WireGuard: один файл — одно подключение, целиком.
Кладётся в `~/.config/ocbar/profiles/<имя>.ocbar`, образец —
[etc/example.ocbar](etc/example.ocbar).

```ini
[Connection]
Name = Основной
Url  = vpn.example.com/employees
User = alice

[Routes]
10.0.0.0/8
172.16.0.0/12

[DNS]
example.com     = 10.0.0.1
corp.example.com = vpn

[Auth]
Totp         = keepassxc
KeepassEntry = Группа/Запись

[Health]
Check = wiki.example.com:443
```

Секретов в файле нет и быть не должно — только ссылки на хранилище, поэтому
такой профиль можно переслать коллеге:

```bash
ocbar import ~/Downloads/office.ocbar        # добавить
ocbar export main office.ocbar               # выгрузить
```

Экспорт работает и как перевод со старого формата: он соберёт профиль вместе
с сетями и зонами из общих конфигов в один самодостаточный файл.

### Старый формат

Прежняя раскладка продолжает работать: общий `profiles.conf` плюс отдельные
`networks.conf` и `zones.conf`.

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

Пароль и одноразовый код берутся из одного из нескольких источников — это
одна и та же схема для обоих. Для KeePassXC в профиле:

```ini
password = keepassxc          # keychain (по умолчанию) | keepassxc | command | ask
totp = keepassxc              # keychain | keepassxc | command | off
keepass_entry = Группа/Запись
keepass_db = ~/путь/база.kdbx
keepass_keychain_service = keepassxc-docs
```

Ни пароль, ни секрет при этом не копируются: `keepassxc-cli` читает базу
напрямую, значения уходят в окружение подпроцесса и нигде не печатаются.
`password = ask` означает «вводит человек» — тогда молчаливого
переподключения не будет.

Мастер-пароль базы берётся из Keychain по имени сервиса и в аргументы не
попадает; `keepassxc-cli` читает файл напрямую, разблокировать окно
KeePassXC не нужно.

База — лишь один из источников. Любой другой подключается командой:

```ini
totp = command
totp_command = op item get VPN --otp

password = command
password_command = op item get VPN --fields password
```

Если источник недоступен, вход не ломается — код вводит человек, причина
пишется в журнал.

### Своя форма входа

Встроенные правила автозаполнения покрывают типовые формы (Keycloak,
Microsoft). У других компаний форма своя — покажите её программе мышью:

```bash
ocbar learn                 # откроется форма входа вашего портала
```

Щёлкайте по полю логина, полю пароля, полю кода и по кнопке отправки: вид
элемента определяется сам (можно поправить, выбрав его слева). Щелчок в
режиме разметки до страницы не доходит — кнопка «Войти» от него не
сработает; чтобы пройти форму дальше, снимите галочку «Отмечать элементы»
или просто печатайте — отмеченное поле получает фокус сразу.

По кнопке «Готово» правила ложатся в `~/.config/ocbar/autofill.rules`,
прошлые остаются рядом с суффиксом `.bak`. Закрытое окно без «Готово» ничего
не пишет. То же самое есть в приложении: «Настройка → Профили → Разметить
портал…».

Формат правил простой и правится руками — [etc/autofill.rules.example](etc/autofill.rules.example).

### Автоподключение и вход

Супервизор поднимает туннель **молча**: окно входа не появляется поверх
работы. Если сохранённой сессии хватило, подключение проходит само. Если
нет, приходит уведомление, автопопытки останавливаются, и решение за вами —
`ocbar connect`.

## Команды

```
ocbar connect [профиль] [--show]      SSO и туннель; окно покажется, если за 2 с не прошло молча
ocbar disconnect
ocbar status [--short]                --short — для плагина меню
ocbar routes add|del|toggle <CIDR>    маршруты на живом туннеле
ocbar dns on|off|toggle <зона>        зоны /etc/resolver
ocbar pause | resume | toggle         «как будто выключен»: маршруты и зоны сняты,
                                      туннель и вход живы, возврат мгновенный
ocbar app start|stop|status           приложение меню-бара; autostart on|off
ocbar version [--all]                 версия; --all — версии и пути всех частей
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

## Самопроверки

Ничего не трогают и не требуют ни сети, ни привилегий: конфиги подставные,
состояние уводится во временный каталог.

```bash
ocbar selftest                      # разбор профиля, сети и зоны, отказы на неверных значениях
ocbar-app --selftest                # разбор и запись профиля, правила проверки, разбор состояния
ocbar-auth --selftest               # TOTP по RFC 6238 и разбор XML
ocbar-auth --learn-selftest         # селекторы разметки на странице-образце
```

Отдельно, уже на живом подключении (меняет состояние и возвращает обратно):

```bash
ocbar-app --selftest --live-actions  # сеть, зона, пауза и возобновление
```

## Песочница интерфейса

Отдельная страница, где меню смотрится во всех состояниях сразу: подключено,
пауза, потеря связи, ожидание входа, отключено. Переключается тема, график
живой.

```bash
ocbar ui-lab            # на данных-образце
ocbar ui-lab --live     # подложить снимок реального состояния
```

Снимок кладётся рядом со страницей и в репозиторий не попадает: в нём
рабочие адреса. Страница самодостаточна — ни одной внешней загрузки,
открывается прямо из файла.

## Меню-бар

Приложение [app/](app/) — SwiftUI, `MenuBarExtra`, macOS 13+. Читает
`ocbar status --short`, действия делает вызовами `ocbar`; собственных
привилегий у него нет.

```bash
ocbar app start                 # запустить
ocbar app autostart on          # запускать при входе в систему
(cd app && ./make-app.sh)       # собрать бандл из репозитория
```

Что в меню: состояние цветом значка, профиль и время, график трафика за
минуту со скоростью, действия, подробности (адрес в туннеле, шлюз, MTU,
резолверы, суммарный трафик, задержка, переключатели сетей и зон).
Отдельными окнами — редактор профиля с проверкой перед сохранением,
просмотр журналов с фильтром, выбор режима и «о программе» с версиями всех
частей.

Состояния различаются целиком, а не одной строкой: подключено, пауза,
восстановление связи, ожидание входа, отключено, чужой туннель, клиент не
найден. Посмотреть их все разом, не рвя связь:

```bash
app/.build/ocbar.app/Contents/MacOS/ocbar-app --stage         # витрина состояний
app/.build/ocbar.app/Contents/MacOS/ocbar-app --selftest      # разбор, запись профиля, правила
```

[swiftbar/ocbar.5s.sh](swiftbar/ocbar.5s.sh) — плагин [SwiftBar](https://github.com/swiftbar/SwiftBar):
статус, профили, тоглы маршрутов и зон, предупреждение «мак просыпался после
подключения». Остаётся запасным вариантом и проверяется без SwiftBar — это
просто stdout.

## Что защищено

- **чужие зоны в `/etc/resolver` не трогаются** — хелпер помнит только свои
  (манифест), чужой файл пропускает и в манифест не берёт;
- **чужой openconnect не трогается** — без нашего pidfile `cleanup` его не убьёт,
  а `disconnect` не погасит чужой `utun`;
- **root исполняет копию из своего каталога**: `openconnect` копируется в
  `/usr/local/libexec/ocbar/` и сверяется по sha256 вместе с библиотеками,
  csd-wrapper берётся только по имени из root-каталога, vpnc-script — сам
  хелпер. Оговорка: библиотеки остаются в каталоге Homebrew, доступном
  пользователю на запись, поэтому проверка ловит случайное расхождение после
  обновления, но не целенаправленную подмену — см. [DECISIONS.md](DECISIONS.md), D30;
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

## Автор

**ValeraGin** — Ignatkovich Valery (Валерий Игнаткович),
[github.com/ValeraGin](https://github.com/ValeraGin).
Лицензия MIT, см. [LICENSE](LICENSE).
