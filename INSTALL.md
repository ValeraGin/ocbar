# Установка ocbar на macOS

Проверено на macOS 26.6 (arm64) 2026-09-06. Пометки: **[проверено]** — шаг
выполнялся на живой системе; **[не проверено]** — написано, но на чистой
машине не прогонялось.

Установка делится на три части, и только вторая требует пароля:

1. **Программа** — Homebrew или сборка из исходников, без прав root.
2. **Привилегии** — `sudo ocbar install`, один раз: хелпер, sudoers, агент.
3. **Свои данные** — профили, сети, зоны, пароль и второй фактор.

---

## 1. Что нужно заранее

| Что | Зачем | Проверить |
|---|---|---|
| macOS 13 и новее | `WKWebView`, `launchctl bootstrap` | `sw_vers -productVersion` |
| Command Line Tools | компилятор Swift; **полный Xcode не нужен** | `swift --version` |
| Homebrew | `openconnect` | `brew --version` |
| `openconnect` | сам туннель | `brew install openconnect` |
| KeePassXC | если второй фактор храните там | необязательно |
| SwiftBar | меню в строке состояния | необязательно |

**[проверено]** Swift 6.3.3 идёт с Command Line Tools: полный Xcode не
требуется. Если `swift --version` ругается, поставьте инструменты:

```bash
xcode-select --install
```

---

## 2. Программа

### Из репозитория (так работает сегодня)

```bash
git clone https://github.com/ValeraGin/ocbar.git ~/Projects/ocbar
cd ~/Projects/ocbar
(cd auth && swift build -c release)      # ~1 минута, соберёт ocbar-auth
./bin/ocbar doctor                        # красные строки пока ожидаемы
```

### Через Homebrew

**[проверено 2026-09-06]** — tap опубликован, установка выполнена с нуля
(клонирование, сборка, `brew test`) за полторы минуты:

```bash
brew tap ValeraGin/ocbar
brew trust ValeraGin/ocbar      # tap не из homebrew-core: с 2026 brew не грузит формулы из недоверенных tap
brew install ocbar              # стабильная версия по тегу; --HEAD — с main
```

Репозитории приватные, поэтому нужен доступ к ним: настроенный `gh auth` или
ключ, добавленный на GitHub. Без доступа `brew tap` не сможет клонировать.

Формула собирает `ocbar-auth` из исходников на вашей машине. Это не
прихоть: у проекта нет Apple Developer ID, а собранное локально не получает
карантина, поэтому Gatekeeper не мешает. Подробности и обоснование —
[docs/06-distribution.md](docs/06-distribution.md).

`brew upgrade ocbar` — это и есть автообновление.

---

## 3. Привилегии: один раз с паролем

```bash
sudo ./bin/ocbar install          # из репозитория
sudo ocbar install                # или так, если ставили через brew
```

Команда печатает каждый свой шаг. Что именно она делает:

| Шаг | Зачем |
|---|---|
| каталоги в `/usr/local/{libexec,etc,var}/ocbar` | владелец `root:wheel` — пользователь туда не пишет |
| `ocbar-helper` → `/usr/local/libexec/` | единственный привилегированный компонент |
| копия `openconnect` и штатного `vpnc-script` туда же | root не должен исполнять файлы, доступные пользователю на запись |
| `ocbar-helper trust` | манифест sha256 бинаря и его библиотек |
| `/etc/sudoers.d/ocbar` | `NOPASSWD` на хелпер для группы `admin`, проверяется `visudo -cf` |
| LaunchAgent `ru.ocbar.supervisor` | супервизор: реконнект, сон, смена сети |

Посмотреть, ничего не меняя:

```bash
./bin/ocbar install --dry-run
```

**Почему не `NOPASSWD` на сам `openconnect`.** Так советуют почти все
проекты этой категории, и это дыра: **[проверено]** каталог Homebrew на
Apple Silicon доступен пользователю на запись, и любой процесс от вашего
имени подменит бинарь, получив root без пароля. Поэтому привилегированный
файл лежит в root-каталоге, а его целостность проверяется по манифесту.

После `brew upgrade openconnect` копия перестаёт совпадать с манифестом.
`ocbar doctor` это заметит и подскажет:

```bash
sudo ocbar install --trust
```

---

## 4. Свои данные

Сначала заведите каталог и возьмите образцы — без файла профилей не работает
ни одна команда:

```bash
mkdir -p ~/.config/ocbar
cp etc/profiles.conf.example ~/.config/ocbar/profiles.conf
cp etc/networks.conf.example ~/.config/ocbar/networks.conf
cp etc/zones.conf.example    ~/.config/ocbar/zones.conf
$EDITOR ~/.config/ocbar/profiles.conf
```

Для установки через Homebrew образцы лежат в
`$(brew --prefix ocbar)/share/ocbar/examples`.

Файл `autofill.rules` не обязателен: без него используется встроенный набор
правил для типовых форм входа. Заводите его, только если форма вашего
провайдера входа не распознаётся.

Дальше по файлам.

### Профили — `profiles.conf`

```ini
default = main

[main]
url = vpn.example.com/employees
name = Основной
user = alice
mode = split                  # split — свои маршруты и зоны; full — всё в туннель
```

Профилей может быть сколько угодно, они переключаются из меню. Группы, где
вход идёт логином с паролем и одноразовым кодом из SMS, помечайте
`auth = password`: `ocbar` их не ведёт (код из SMS взять неоткуда) и честно
об этом скажет.

### Сети — `networks.conf`

По одной подсети на строку, попадают в туннель:

```
10.0.0.0/8
172.16.0.0/12
```

**Важно.** Список ваш, а не шлюза. **[проверено]** шлюз просил забрать всю
`192.168.0.0/16` — выполнив это, штатный `vpnc-script` увёл бы в туннель
домашнюю сеть и лабораторию. `ocbar` ставит только то, что перечислено здесь.

### Зоны DNS — `zones.conf`

```
# зона → резолвер; более длинная зона перебивает более короткую
example.com          10.0.0.1
int.example.com      192.168.10.12
# vpn вместо адреса = тот резолвер, что прислал шлюз
corp.example.com     vpn
```

**Комментарий пишется отдельной строкой.** Третье поле в строке зоны — это
номер порта, поэтому `example.com 10.0.0.1 # что-то` будет отброшено как
строка с недопустимым портом, причём молча.

Создать из готового списка доменов:

```bash
./bin/ocbar dns init ~/domains.txt vpn
```

### Своя форма входа

Если вход не проходит сам, а в журнале видно «форму не распознал», покажите
форму программе мышью — правила составятся сами:

```bash
ocbar learn
```

Подробнее — в [README](README.md#своя-форма-входа); то же есть в приложении:
«Настройка → Профили → Разметить портал…».

### Пароль и второй фактор

Пароль — в связке ключей, ввод спрашивает системная утилита, не `ocbar`:

```bash
./bin/ocbar secret set-password
```

Второй фактор, три варианта на выбор:

```bash
# 1. Секрет в связке ключей
./bin/ocbar secret set-totp

# 2. Из QR-кода (в том числе экспорт Google Authenticator)
./bin/ocbar secret import-qr ~/Downloads/qr.png --list
./bin/ocbar secret import-qr ~/Downloads/qr.png --select <часть имени>

# 3. Из KeePassXC — секрет остаётся в базе, наружу идёт только код
```

Для KeePassXC в профиль добавьте:

```ini
totp = keepassxc
keepass_entry = Группа/Запись
keepass_db = ~/путь/база.kdbx
keepass_keychain_service = keepassxc-docs   # где лежит мастер-пароль базы
```

**[проверено]** окно KeePassXC разблокировывать не нужно, `keepassxc-cli`
читает файл базы напрямую.

Что настроено — покажет:

```bash
./bin/ocbar secret status
```

---

## 5. Первый вход

```bash
./bin/ocbar connect --show
```

`--show` открывает окно сразу, чтобы видеть происходящее. Без него окно
появится только если за две секунды вход не прошёл молча.

Логин и пароль подставятся сами. Второй фактор — из базы или связки ключей,
**ровно одна попытка**: несколько неверных кодов подряд блокируют учётную
запись. Всё, что не распознано (SMS, выбор способа входа, настройка нового
фактора), остаётся вам — и `ocbar` ничего не нажимает на такой форме.

Проверить:

```bash
./bin/ocbar status
route -n get <адрес внутри корпоративной сети>   # interface: utunN
dscacheutil -q host -a name <внутреннее имя>     # приватный адрес
```

---

## 6. Меню в строке состояния

### Приложение (основной путь)

Ставится вместе с остальным; запускать и заводить в автозапуск — решение ваше:

```bash
ocbar app start                 # запустить сейчас
ocbar app autostart on          # запускать при входе в систему
ocbar app status                # где бандл, работает ли, включён ли автозапуск
ocbar app stop && ocbar app start   # после brew upgrade — подхватить новую сборку
```

Из репозитория, без Homebrew, приложение собирается отдельно:

```bash
(cd app && ./make-app.sh)       # → app/.build/ocbar.app
```

Значок в строке состояния показывает состояние цветом, меню — профиль,
время, график трафика за минуту, скорость, действия и подробности:
адрес в туннеле, шлюз, MTU, резолверы, суммарный трафик, задержку,
переключатели сетей и зон. Отдельными окнами — профили, журналы,
режим работы и «о программе».

Привилегий приложению не нужно: оно читает `ocbar status --short` и зовёт
`ocbar`, а всё, что требует root, по-прежнему делает хелпер. Пункт
«Диагностика…» показывает `ocbar doctor` и умеет уборку следов прошлой
сессии — то же, что `ocbar cleanup`.

Профилю с `Mode = proxy` нужен `ocproxy` — он не входит в формулу, потому
что нужен только этому режиму:

```bash
brew install ocproxy
```

### Плагин SwiftBar (запасной вариант)

```bash
brew install --cask swiftbar
```

При первом запуске SwiftBar спросит каталог плагинов. Положите туда ссылку:

```bash
ln -s ~/Projects/ocbar/swiftbar/ocbar.5s.sh <каталог плагинов>/
```

Плагин показывает состояние, профили, переключатели маршрутов и зон, паузу.
Он не делает ничего привилегированного — только зовёт `ocbar` и читает его
вывод, поэтому его можно запустить прямо в терминале и посмотреть результат.

---

## 7. Перенос на другую машину

Копируется:

- репозиторий (или ставится через brew);
- `~/.config/ocbar/` — профили, сети, зоны, правила автозаполнения.

Если ставите через Homebrew, шаг с `git clone` и `swift build` не нужен —
формула соберёт всё сама.

**Не копируется**: пароли и секреты второго фактора. На новой машине их
заводят заново — `secret set-password`, `secret import-qr` или KeePassXC.
Каталог `/usr/local/…` создаёт `sudo ocbar install`.

Итого на новой машине:

```bash
brew install openconnect
git clone https://github.com/ValeraGin/ocbar.git ~/Projects/ocbar && cd ~/Projects/ocbar
(cd auth && swift build -c release)
cp -r <откуда>/.config/ocbar ~/.config/ocbar
sudo ./bin/ocbar install
./bin/ocbar secret set-password
./bin/ocbar doctor
./bin/ocbar connect --show
```

---

## 8. Удаление

```bash
./bin/ocbar disconnect
sudo ./bin/ocbar uninstall     # приложение и его автозапуск, агент, sudoers, хелпер, /usr/local/libexec/ocbar
sudo rm -rf /usr/local/var/ocbar                      # состояние: uninstall его оставляет
rm -rf ~/.config/ocbar ~/Library/Logs/ocbar
rm -rf "$HOME/Library/Application Support/ocbar"      # выбранный профиль, тумблеры меню
rm -rf ~/Library/WebKit/ocbar-auth ~/Library/HTTPStorages/ocbar-auth.binarycookies
security delete-generic-password -s ru.ocbar.client   # если заводили секреты
```

`uninstall` намеренно оставляет каталог состояния: там манифест зон, по
которому убираются файлы в системном каталоге резолверов. Удаляйте его
последним и только после `disconnect`.

Последние две строки стоит выполнить и без удаления программы, если нужно
оборвать сохранённую сессию SSO: **[проверено]** cookie провайдера входа
живут в этом хранилище месяцами, и отключение VPN их не трогает.

---

## Если не заработало

Сначала:

```bash
./bin/ocbar doctor
```

Он проверяет каждый компонент отдельно и говорит, что именно чинить.
Разбор типичных отказов — [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
