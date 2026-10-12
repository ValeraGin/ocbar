(() => {
  const choices = document.querySelectorAll('button[data-mode]');
  const sketch = document.querySelector('#mode-sketch');
  const descriptions = {
    selected: { path: 'Свой маршрут', index: '01 / 02', title: 'Только выбранные сети через ocbar', text: 'В рабочий туннель уходят адреса из выбранных сетей. Путь к остальным адресам определяют другие маршруты на Mac.' },
    all: { path: 'ocbar', index: '02 / 02', title: 'VPN для всего интернет-трафика', text: 'Маршрут по умолчанию ведёт в VPN: интернет-трафик отправляется в рабочий туннель. Доступ к локальной сети зависит от маршрутов и политики шлюза.' }
  };
  choices.forEach(button => button.addEventListener('click', () => {
    const mode = button.dataset.mode;
    const content = descriptions[mode];
    choices.forEach(choice => choice.setAttribute('aria-pressed', String(choice === button)));
    sketch.dataset.mode = mode;
    document.querySelector('#external-path').textContent = content.path;
    document.querySelector('#mode-index').textContent = content.index;
    document.querySelector('#mode-title').textContent = content.title;
    document.querySelector('#mode-text').textContent = content.text;
  }));
})();
