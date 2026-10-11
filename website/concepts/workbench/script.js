'use strict';
const qs = selector => document.querySelector(selector);
const qsa = selector => [...document.querySelectorAll(selector)];
let toastTimer;
function toast(message) { const el = qs('#toast'); el.textContent = message; el.classList.add('visible'); clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove('visible'), 2800); }
qsa('[data-route]').forEach(button => button.addEventListener('click', () => {
  const enabled = button.getAttribute('aria-checked') !== 'true';
  button.setAttribute('aria-checked', String(enabled));
  const row = button.closest('.patch-row');
  row.classList.toggle('active', enabled);
  row.querySelector('.route-destination strong').textContent = enabled ? 'Через VPN' : 'Напрямую';
  qs('#route-summary').textContent = `Сетей в туннеле: ${qsa('[data-route][aria-checked="true"]').length}`;
}));
const shareSteps = [
  {title: 'Начните с рабочего профиля.', body: 'Проверьте сети, DNS и правила формы входа на своём подключении. Экспорт соберёт их в один файл.', command: 'ocbar export main team.ocbar'},
  {title: 'Передайте файл коллеге.', body: 'Экспорт объединяет настройки и правила SSO. Проверьте логин, локальные пути и команды. Пароли и TOTP из хранилища не экспортируются.', command: 'team.ocbar → вашему коллеге'},
  {title: 'Настройки общие. Вход — свой.', body: 'Коллега импортирует профиль, укажет свои данные и источники секретов. После этого выполнит первый вход в рабочую сеть.', command: 'ocbar import ~/Downloads/team.ocbar'}
];
function setShareStep(index, moveFocus = false) {
  qsa('[data-step]').forEach(button => {const selected = Number(button.dataset.step) === index; button.setAttribute('aria-selected', String(selected)); button.tabIndex = selected ? 0 : -1; if(selected && moveFocus) button.focus();});
  const step = shareSteps[index]; const panel = qs('#share-content');
  panel.setAttribute('aria-labelledby', `step-${index}`); panel.querySelector('h3').textContent = step.title; panel.querySelector('p').textContent = step.body; panel.querySelector('code').textContent = step.command;
}
qsa('[data-step]').forEach(button => button.addEventListener('click', () => setShareStep(Number(button.dataset.step))));
qs('#share-start').addEventListener('click', () => { setShareStep(1); qs('.handover-panel').scrollIntoView({behavior: 'smooth', block: 'center'}); qs('#step-1').focus({preventScroll: true}); });
const commands = {
  brew: {title: 'УСТАНОВКА ИЗ TAP', command: 'brew tap ValeraGin/ocbar\nbrew trust ValeraGin/ocbar\nbrew install ocbar', note: 'Сторонний tap: изучите исходники перед подтверждением доверия. Сборка локальная, без подписанного и нотарифицированного установщика.'},
  app: {title: 'ПОМОЩНИК И ПРИЛОЖЕНИЕ', command: 'sudo ocbar install\nocbar app start', note: 'Для туннеля нужен помощник с привилегиями. Первая команда запросит пароль администратора Mac в Терминале. Затем мастер поможет добавить профиль и войти.'}
};
function setInstall(key) { qsa('[data-install]').forEach(button => {const selected = button.dataset.install === key; button.setAttribute('aria-selected', String(selected)); button.tabIndex = selected ? 0 : -1;}); qs('#install-content').setAttribute('aria-labelledby', `install-tab-${key}`); qs('#code-title').textContent = commands[key].title; qs('#install-code').textContent = commands[key].command; qs('#install-note').textContent = commands[key].note; }
qsa('[data-install]').forEach(button => button.addEventListener('click', () => setInstall(button.dataset.install)));
qs('#copy-install').addEventListener('click', async () => {
  const value = qs('#install-code').textContent;
  try { await navigator.clipboard.writeText(value); toast('Команды скопированы. Запустите их в Терминале.'); }
  catch { const selection = window.getSelection(); const range = document.createRange(); range.selectNodeContents(qs('#install-code')); selection.removeAllRanges(); selection.addRange(range); toast('Выделены команды — нажмите ⌘C или Ctrl+C.'); }
});
const screens = { menu: {image: '../../dist/assets/menu-ru.png', title: 'Меню ocbar — настоящая программа, демо-профиль', alt: 'Меню ocbar: подключение, график трафика, сети и DNS', label: 'OCBAR / MENU & NETWORKS'}, profile: {image: '../../dist/assets/profile-ru.png', title: 'Настройки профиля ocbar', alt: 'Настройки профиля ocbar: подключение, источники секретов и параметры сети', label: 'OCBAR / PROFILE EDITOR'} };
function setScreen(key) { qsa('[data-screen]').forEach(button => { const selected = button.dataset.screen === key; button.setAttribute('aria-selected', String(selected)); button.tabIndex = selected ? 0 : -1; }); const data = screens[key]; qs('#app-screen').setAttribute('aria-labelledby', `screen-tab-${key}`); qs('#app-image').src = data.image; qs('#app-image').alt = data.alt; const button = qs('.profile-screen'); button.dataset.image = data.image; button.dataset.title = data.title; button.setAttribute('aria-label', 'Открыть скриншот: ' + data.title); qs('.app-frame-top>span').textContent = data.label; }
qsa('[data-screen]').forEach(button => button.addEventListener('click', () => setScreen(button.dataset.screen)));
qsa('[role="tablist"]').forEach(tablist => tablist.addEventListener('keydown', event => { if (!['ArrowRight', 'ArrowLeft', 'Home', 'End'].includes(event.key)) return; const tabs = [...tablist.querySelectorAll('[role="tab"]')]; let index = tabs.indexOf(document.activeElement); if(index < 0) return; event.preventDefault(); index = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length; tabs[index].click(); tabs[index].focus(); }));
const lightbox = qs('#lightbox');
qsa('[data-image]').forEach(button => button.addEventListener('click', () => { qs('#lightbox-image').src = button.dataset.image; qs('#lightbox-image').alt = button.dataset.title; qs('#lightbox-title').textContent = button.dataset.title; lightbox.showModal(); }));
qs('#close-lightbox').addEventListener('click', () => lightbox.close());
lightbox.addEventListener('click', event => { const rect = lightbox.getBoundingClientRect(); if(event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) lightbox.close(); });
setShareStep(0); setInstall('brew'); setScreen('profile');
