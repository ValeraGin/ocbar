const routeContent = {
  work: '<strong>10.20.0.0/16 → ocbar.</strong> В рабочий туннель попадают адреса выбранной сети. Это правило назначения, а не привязка браузера к VPN.',
  personal: '<strong>Внешний адрес → личный VPN.</strong> В примере путь уже настроен сторонним клиентом. ocbar не настраивает YouTube или другой VPN автоматически.',
  home: '<strong>192.168.50.20 → LAN.</strong> Папки NAS используют локальный маршрут Mac. Рабочий туннель для выбранной сети не забирает этот адрес.'
};
function bindTabs(selector, onSelect) {
  const buttons = [...document.querySelectorAll(selector)];
  function activate(button, focus = false) {
    buttons.forEach(item => {
      const selected = item === button;
      item.setAttribute('aria-selected', String(selected));
      item.tabIndex = selected ? 0 : -1;
    });
    if (focus) button.focus();
    onSelect(button);
  }
  buttons.forEach((button, index) => {
    button.addEventListener('click', () => activate(button));
    button.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowRight') next = (index + 1) % buttons.length;
      if (event.key === 'ArrowLeft') next = (index - 1 + buttons.length) % buttons.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = buttons.length - 1;
      if (next !== undefined) { event.preventDefault(); activate(buttons[next], true); }
    });
  });
}
bindTabs('[data-route]', button => {
  const detail = document.querySelector('#route-detail');
  detail.innerHTML = routeContent[button.dataset.route];
  detail.setAttribute('aria-labelledby', button.id);
});
bindTabs('[data-mode]', button => {
  const all = button.dataset.mode === 'all';
  const panel = document.querySelector('#mode-view');
  panel.classList.toggle('all', all);
  panel.setAttribute('aria-labelledby', button.id);
  document.querySelector('#personal-target').textContent = all ? 'Рабочий VPN' : 'Обычный маршрут / личный VPN';
  document.querySelector('#mode-number').textContent = all ? '02' : '01';
  document.querySelector('#mode-copy').innerHTML = all
    ? '<strong>Туннель для интернет-трафика.</strong> Внешние адреса идут в рабочий VPN. Локальные адреса могут сохранять отдельные маршруты — поведение зависит от конфигурации.'
    : '<strong>Туннель для выбранных сетей.</strong> В примере ocbar направляет 10.20.0.0/16 в рабочий VPN. Прочие адреса используют действующие маршруты Mac.';
});
const dialog = document.querySelector('#image-dialog');
document.querySelectorAll('[data-image]').forEach(button => {
  button.addEventListener('click', () => {
    document.querySelector('#dialog-image').src = button.dataset.image;
    document.querySelector('#dialog-image').alt = button.dataset.title;
    document.querySelector('#image-title').textContent = button.dataset.title;
    dialog.showModal();
  });
});
dialog.addEventListener('click', event => {
  if (event.target !== dialog) return;
  const rect = dialog.getBoundingClientRect();
  if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close();
});
