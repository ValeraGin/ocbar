import AppKit
import AVFoundation
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
    /// Сколько раз окно меняло размер за шаг: одно нажатие должно давать одну
    /// перестройку, иначе меню дёргается.
    private static var resizes = 0
    private static var resizeObserver: NSObjectProtocol?

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
    private static var jitter: [String] = []

    private static func verdict() {
        let main = heights["главный экран"] ?? 0
        let networks = heights["сети и DNS"] ?? 0
        let back = heights["возврат на главный"] ?? 0
        var bad: [String] = []
        if !jitter.isEmpty { bad.append("окно дёргается — перестроений " + jitter.joined(separator: ", ")) }
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
        heights = [:]
        resizes = 0
        jitter = []
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: nil) { note in
            if let w = note.object as? NSWindow, abs(w.frame.width - MenuView.width) < 2 {
                resizes += 1
                AppLog.write(String(format: "проверка меню: перестройка → h=%.0f верх=%.0f", w.frame.height, w.frame.maxY))
            }
        }
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
            resizes = 0
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let count = resizes
                log(name)
                if ["сети и DNS", "возврат на главный"].contains(name) {
                    AppLog.write("проверка меню: перестроений окна на шаге «\(name)»: \(count)")
                    if count > 2 { jitter.append("\(name): \(count)") }
                }
                next()
            }
        }
        next()
    }
}

// Права без человека: видит ли ocbar-auth, запущенный через ocbar (как у
// кнопок «Снять QR с экрана…» и «Камерой…»), те же права, что само
// приложение. Если нет — подсказка про право будет врать.
//
//   open "ocbar://debug-access?token=<токен уведомлений>"
//   итог — строка «проверка прав: ИТОГ» в app.log
enum AccessProbe {
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "ocbar", url.host == "debug-access" else { return false }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "token" }?.value
        guard let token, let expected = Notifier.expectedToken, !expected.isEmpty, token == expected else {
            AppLog.write("debug-access: чужой токен — пропускаю")
            return true
        }
        DispatchQueue.global(qos: .utility).async { run() }
        return true
    }

    static func own() -> (screen: String, camera: String) {
        let screen = CGPreflightScreenCaptureAccess() ? "granted" : "denied"
        let camera: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = "authorized"
        case .denied: camera = "denied"
        case .restricted: camera = "restricted"
        case .notDetermined: camera = "not-determined"
        @unknown default: camera = "unknown"
        }
        return (screen, camera)
    }

    /// «screen=granted camera=authorized» → поля.
    static func parse(_ line: String) -> [String: String] {
        var d: [String: String] = [:]
        for part in line.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { d[kv[0]] = kv[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return d
    }

    private static func run() {
        let mine = own()
        guard let binary = OcbarClient.shared.binary else { AppLog.write("проверка прав: ИТОГ ПЛОХО — ocbar не найден"); return }
        let r = Shell.run(binary, ["secret", "access"], timeout: 20)
        let theirs = parse(r.out)
        AppLog.write("проверка прав: приложение screen=\(mine.screen) camera=\(mine.camera); через ocbar \(r.out.trimmed)")
        let same = theirs["screen"] == mine.screen && theirs["camera"] == mine.camera
        AppLog.write(same ? "проверка прав: ИТОГ ОК — совпадает"
                          : "проверка прав: ИТОГ ПЛОХО — расходится (код \(r.code)\(r.err.isEmpty ? "" : ", " + r.err.trimmed))")
    }
}
