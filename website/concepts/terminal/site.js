"use strict";

// Everything in this small route console is illustrative; it never changes networking.
const routes = { work: true, dev: true };
document.querySelectorAll("[data-route]").forEach(button => {
  button.addEventListener("click", () => {
    const key = button.dataset.route;
    routes[key] = !routes[key];
    button.setAttribute("aria-checked", String(routes[key]));
    const state = document.getElementById(`${key}-state`);
    state.textContent = routes[key] ? "через VPN" : "напрямую";
    state.classList.toggle("off", !routes[key]);
    const count = Object.values(routes).filter(Boolean).length;
    document.getElementById("route-summary").textContent = count === 0
      ? "Обе сети идут напрямую. VPN-маршруты в демо выключены."
      : `${count} ${count === 1 ? "сеть идёт" : "сети идут"} через VPN. Остальное — напрямую.`;
    document.getElementById("vpn-active").style.opacity = count ? "1" : "0";
  });
});

const tabs = [...document.querySelectorAll("[data-tab]")];
function activateTab(tab, focus = false) {
  tabs.forEach(button => {
    const active = button === tab;
    button.classList.toggle("active", active);
    button.setAttribute("aria-selected", String(active));
    button.tabIndex = active ? 0 : -1;
    document.getElementById(`screen-${button.dataset.tab}`).hidden = !active;
  });
  if (focus) tab.focus();
}
tabs.forEach(tab => {
  tab.addEventListener("click", () => activateTab(tab));
  tab.addEventListener("keydown", event => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const index = tabs.indexOf(tab);
    const next = event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1
      : (index + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length;
    activateTab(tabs[next], true);
  });
});

document.getElementById("copy-install").addEventListener("click", async event => {
  const button = event.currentTarget;
  const status = document.getElementById("copy-status");
  const text = document.getElementById("install-code").textContent;
  try {
    await navigator.clipboard.writeText(text);
    button.textContent = "Скопировано ✓";
    status.textContent = "Команды в буфере обмена. Перед выполнением ознакомьтесь с Homebrew tap.";
    setTimeout(() => { button.innerHTML = 'Копировать <span aria-hidden="true">⧉</span>'; }, 2600);
  } catch {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(document.getElementById("install-code"));
    selection.removeAllRanges();
    selection.addRange(range);
    status.textContent = "Команды выделены. Нажмите ⌘C или Ctrl+C, чтобы скопировать.";
  }
});
