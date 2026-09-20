import AppKit
import SwiftUI

// Проверка живого меню без человека: приложение само нажимает свой значок в
// строке состояния, переключает экраны и пишет размеры настоящего окна в
// журнал. Иначе проверить нечем: окно меню создаёт система, в витрине его
// поведение другое, а глазами это смотрит человек.
//
//   open "ocbar://debug-menu?token=<токен уведомлений>"
enum MenuProbe {
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "ocbar", url.host == "debug-menu" else { return false }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "token" }?.value
        guard let token, let expected = Notifier.expectedToken, !expected.isEmpty,
              token == expected else {
            AppLog.write("debug-menu: чужой токен — пропускаю")
            return true
        }
        DispatchQueue.main.async { run() }
        return true
    }

    /// Кнопка значка в строке состояния — её нажатием открывается меню.
    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let button = find(in: sub) { return button } }
        return nil
    }

    /// Окно меню: то, чья ширина совпадает с шириной меню.
    private static func menuWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && abs($0.frame.width - MenuView.width) < 2 }
    }

    private static var heights: [String: CGFloat] = [:]

    @discardableResult
    private static func log(_ step: String) -> CGFloat? {
        guard let w = menuWindow() else { AppLog.write("проверка меню: \(step) — окна нет"); return nil }
        heights[step] = w.frame.height
        AppLog.write(String(format: "проверка меню: %@ h=%.0f верх=%.0f низ=%.0f",
                            step, w.frame.height, w.frame.maxY, w.frame.minY))
        return w.frame.height
    }

    /// Итог: меню должно быть в полный рост, экран сетей — выше главного,
    /// возврат — той же высоты, что до перехода.
    private static func verdict() {
        let main = heights["главный экран"] ?? 0
        let networks = heights["сети и DNS"] ?? 0
        let back = heights["возврат на главный"] ?? 0
        var bad: [String] = []
        if main < 200 { bad.append("главный экран схлопнут (\(Int(main)))") }
        if networks <= main + 40 { bad.append("сети не выше главного (\(Int(networks)) против \(Int(main)))") }
        if abs(back - main) > 2 { bad.append("после возврата высота другая (\(Int(back)) против \(Int(main)))") }
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        if networks > screen - 30 { bad.append("выше экрана (\(Int(networks)))") }
        AppLog.write(bad.isEmpty
                     ? "проверка меню: ИТОГ ОК — главный \(Int(main)), сети \(Int(networks)), возврат \(Int(back))"
                     : "проверка меню: ИТОГ ПЛОХО — " + bad.joined(separator: "; "))
    }

    private static func run() {
        guard let button = statusButton() else { AppLog.write("проверка меню: значок не найден"); return }
        let nav = MenuView.MenuNav.shared
        var step = 0
        let steps: [(String, () -> Void)] = [
            ("меню открыто", { button.performClick(nil) }),
            ("главный экран", {}),
            ("сети и DNS", { nav.page = .networks }),
            ("возврат на главный", { nav.page = .main }),
            ("меню закрыто", { button.performClick(nil) }),
            ("итог", { verdict() }),
        ]
        func next() {
            guard step < steps.count else { return }
            let (name, action) = steps[step]
            step += 1
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                log(name)
                next()
            }
        }
        next()
    }
}
