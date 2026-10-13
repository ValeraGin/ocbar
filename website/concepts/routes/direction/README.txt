ocbar / direction / 2026-10-13

Страница выбора следующего направления из вариантов 3 и 5.
Четыре цветовых варианта исходного знака свитча: lime, mint, amber, violet.
Форма сохранена, фон унифицирован в нейтральный графит. Реальная иконка приложения не менялась.
Переключатель меняет акценты двух обложек, пять иконок и ссылку скачивания SVG.
Обложки — пример сочетания для выбора, а не опубликованная версия сайта.

В atlas/editorial добавлены V2Ray, AmneziaWG (AWG), WireGuard, карточки с
авторскими монограммами и рисунок Cisco AnyConnect в assets/cisco-ocbar.svg.
Это иллюстрация полного туннеля в конкретном профиле. Cisco поддерживает split
 tunneling. V2Ray — технология с несколькими режимами клиентов, а не обещание
автоматического VPN. Настройка стороннего подключения отдельна от ocbar.

Проверенные первоисточники:
https://www.cisco.com/c/en/us/support/docs/security/anyconnect-secure-mobility-client/119006-configure-anyconnect-00.html
https://www.v2fly.org/en_US/
https://docs.amnezia.org/documentation/amnezia-wg/
https://docs.amnezia.org/documentation/instructions/install-configure-protocols/

QA: новый SVG просмотрен в браузере; XML SVG и локальные ссылки проверены;
node --check script.js; переключение цветов обновляет CSS, картинки и download;
CSS viewport 320 без переполнения новой страницы; сравнение Cisco переключается
в обоих вариантах. Иллюстрация сравнения на телефоне прокручивается внутри блока.
