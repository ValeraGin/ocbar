# MacControlCenterUI — вендорная копия

SwiftUI-компоненты в стиле меню Пункта управления macOS (Wi‑Fi, Bluetooth):
заголовок со свитчем, круглые переключатели, секции, раскрытие на месте, команды.

- Источник: https://github.com/orchetect/MacControlCenterUI, тег `2.7.4`
  (коммит `0869227`, 2026-08-13). Автор — Steffan Andrews, лицензия MIT, текст — `LICENSE`.
- Копия, а не зависимость SwiftPM: ocbar собирается в песочнице Homebrew без сети,
  у приложения нет сторонних пакетов.

Правки относительно оригинала:

- убран импорт `MenuBarExtraAccess` (`MacControlCenterUI.swift`,
  `Menu/MacControlCenterMenu.swift`, `Menu Abstracts/MenuBody.swift`): привязку
  «меню открыто» ocbar передаёт сам.
- `MacControlCenterMenuBuilder` принимает массив пунктов (`buildExpression([any View])`):
  меню ocbar собирает секции во вспомогательных свойствах.
