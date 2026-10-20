# FluidMenuBarExtra — вендорная копия

Панель меню под значком в строке состояния вместо `MenuBarExtra(.window)`: своё `NSStatusItem` и
`NSPanel` с `NSHostingView`, окно растёт и сжимается под содержимое, закрывается по клику мимо.

- Источник: https://github.com/lfroms/fluid-menu-bar-extra, `1.2.0` (коммит `81c7af7`, 2025-11-25;
  репозиторий в архиве). Автор — Lukas Romsicki, лицензия MIT, текст — `LICENSE`.
- `PopoverPlacementPolicy.swift` — из форка https://github.com/rurza/fluid-menu-bar-extra
  (коммит `7015f81`, 2026-08-04), та же лицензия.
- Esc — по образцу форка https://github.com/coder/fluid-menu-bar-extra (коммит `5b131c7`).
- Копия, а не зависимость SwiftPM: ocbar собирается в песочнице Homebrew без сети.

Правки относительно оригинала:

- `FluidMenuBarExtra`: значок — `NSImage` и меняется на ходу; `present()`, `dismiss()`, `toggle()`,
  `isPresented`, `isInserted`; наружу — кнопка значка и панель (для `MenuProbe`).
- `FluidMenuBarExtraStatusItem`: позиция — `PopoverPlacementPolicy` (сравнение с `maxX` экрана,
  а не с шириной: на втором мониторе панель не уезжает); повторное открытие во время затухания
  оставляет панель на экране.
- `FluidMenuBarExtraWindow`: новый размер считается от текущей рамки в момент применения, верхний
  левый угол стоит на месте, анимация — только на экране; Esc закрывает панель.
