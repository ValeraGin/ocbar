'use strict';
const russian = document.documentElement.lang === 'ru';
const base = russian ? '../' : '';
const switches = [...document.querySelectorAll('[data-route]')];
for (const button of switches) {
  button.addEventListener('click', () => {
    const selected = button.getAttribute('aria-checked') !== 'true';
    button.setAttribute('aria-checked', String(selected));
    const destination = button.parentElement.querySelector('[data-destination]');
    destination.textContent = selected ? (russian ? 'Через VPN' : 'Via VPN') : (russian ? 'Напрямую' : 'Direct');
    destination.classList.toggle('off', !selected);
    const count = switches.filter(item => item.getAttribute('aria-checked') === 'true').length;
    document.querySelector('[data-demo-summary]').textContent = russian
      ? `Выбрано сетей: ${count}. Это пример: схема не меняет ваше подключение.`
      : `${count} example network${count === 1 ? '' : 's'} selected. This illustration does not change your connection.`;
    document.querySelector('.map-vpn').style.opacity = count ? '1' : '.45';
    document.querySelector('.path-lines i').style.opacity = count ? '1' : '.2';
  });
}
for (const button of document.querySelectorAll('[data-screen]')) {
  button.addEventListener('click', () => {
    const picture = document.getElementById('app-screenshot');
    picture.src = `${base}assets/${button.dataset.screen}-${russian ? 'ru' : 'en'}.png`;
    picture.alt = button.dataset.screen === 'menu' ? picture.dataset.menuAlt : picture.dataset.profileAlt;
    for (const other of document.querySelectorAll('[data-screen]')) {
      other.setAttribute('aria-pressed', String(other === button));
      other.classList.toggle('selected', other === button);
    }
  });
}
document.getElementById('copy-install').addEventListener('click', async () => {
  const code = document.getElementById('install-code');
  const status = document.getElementById('copy-status');
  try {
    await navigator.clipboard.writeText(code.textContent);
    status.textContent = russian ? 'Три команды установки скопированы.' : 'The three installation commands are copied.';
  } catch {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(code);
    selection.removeAllRanges();
    selection.addRange(range);
    status.textContent = russian ? 'Команды выделены. Скопируйте их через ⌘C или Ctrl+C.' : 'Commands selected. Press ⌘C or Ctrl+C to copy.';
  }
});
