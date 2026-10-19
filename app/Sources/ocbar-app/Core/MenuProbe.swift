import AppKit
import AVFoundation
import SwiftUI

// Проверка живого меню без человека: приложение само нажимает свой значок в
// строке состояния, открывает меню и пишет размеры настоящего окна в
// журнал. Иначе проверить нечем: окно меню создаёт система, в витрине его
// поведение другое, а глазами это смотрит человек.
//
//   open "ocbar://debug-menu?token=<токен уведомлений>"
/// Что проверка меню меняет в живом меню и что из него читает.
final class MenuProbeState: ObservableObject {
    static let shared = MenuProbeState()
    /// Лишняя высота меню: так проверка меняет содержимое и смотрит, вырастет
    /// ли окно и сожмётся ли обратно.
    @Published var extra: CGFloat = 0
    /// Высота содержимого, как её намерило меню.
    var contentHeight: CGFloat = 0
}

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
        NSApp.windows.first { $0.isVisible && abs($0.frame.width - NativeMenuView.width) < 2 }
    }

    /// То же окно, даже если меню успело закрыться: щелчок человека в другом
    /// месте закрывает меню посреди проверки, а размер окна система держит
    /// и у скрытого.
    private static func menuWindowAny() -> NSWindow? {
        menuWindow() ?? NSApp.windows.first {
            String(describing: type(of: $0)).contains("MenuBarExtra") && abs($0.frame.width - NativeMenuView.width) < 2
        }
    }

    private struct Shot { let height: CGFloat; let top: CGFloat; let content: CGFloat }
    private static var shots: [String: Shot] = [:]
    /// Сколько раз окно меняло размер за шаг: одно изменение содержимого
    /// должно давать одну перестройку, иначе меню дёргается.
    private static var resizes = 0
    private static var resizeObserver: NSObjectProtocol?
    private static var jitter: [String] = []
    /// Шаги, на которых меню оказалось закрытым не по сценарию.
    private static var closed: [String] = []

    private static func log(_ step: String) {
        let content = MenuProbeState.shared.contentHeight
        guard let w = menuWindowAny() else {
            let all = NSApp.windows.map {
                String(format: "%@ %@ %.0fx%.0f", String(describing: type(of: $0)), $0.isVisible ? "видно" : "скрыто",
                       $0.frame.width, $0.frame.height)
            }
            AppLog.write("проверка меню: \(step) — окна нет; окна: " + all.joined(separator: ", "))
            return
        }
        shots[step] = Shot(height: w.frame.height, top: w.frame.maxY, content: content)
        if !w.isVisible { closed.append(step) }
        AppLog.write(String(format: "проверка меню: %@ окно=%.0f содержимое=%.0f верх=%.0f перестроений=%d%@",
                            step, w.frame.height, content, w.frame.maxY, resizes, w.isVisible ? "" : " (меню закрыто)"))
        if resizes > 2 { jitter.append("\(step): \(resizes)") }
    }

    /// Итог: окно ровно по содержимому, растёт и сжимается обратно, верх
    /// стоит под значком, перестройка одна.
    private static func verdict() {
        var bad: [String] = []
        let steps = ["главный экран", "содержимое выросло", "содержимое вернулось", "открыто выше", "открыто ниже"]
        let missing = steps.filter { shots[$0] == nil }
        if !missing.isEmpty { bad.append("окна нет на шагах: " + missing.joined(separator: ", ")) }
        if let main = shots["главный экран"], let tall = shots["содержимое выросло"],
           let back = shots["содержимое вернулось"] {
            if main.height < 200 { bad.append("меню схлопнуто (\(Int(main.height)))") }
            for (name, shot) in [("главный экран", main), ("содержимое выросло", tall), ("содержимое вернулось", back)]
            where abs(shot.height - shot.content) > 2 {
                bad.append("\(name): окно \(Int(shot.height)) при содержимом \(Int(shot.content))")
            }
            if tall.height < main.height + 150 { bad.append("окно не выросло (\(Int(main.height)) → \(Int(tall.height)))") }
            if abs(back.height - main.height) > 2 { bad.append("окно не сжалось (\(Int(main.height)) → \(Int(back.height)))") }
            if let high = shots["открыто выше"], let low = shots["открыто ниже"] {
                for (name, shot) in [("открыто выше", high), ("открыто ниже", low)]
                where abs(shot.height - shot.content) > 2 {
                    bad.append("\(name): окно \(Int(shot.height)) при содержимом \(Int(shot.content))")
                }
                if abs(low.height - main.height) > 2 { bad.append("после повторного открытия окно не сжалось (\(Int(low.height)))") }
                if abs(high.top - main.top) > 1 || abs(low.top - main.top) > 1 { bad.append("верх окна уехал при повторном открытии") }
            }
            if abs(tall.top - main.top) > 1 || abs(back.top - main.top) > 1 { bad.append("верх окна уехал") }
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            if main.height > screen - 30 { bad.append("выше экрана (\(Int(main.height)))") }
        }
        if !jitter.isEmpty { bad.append("окно дёргается — перестроений " + jitter.joined(separator: ", ")) }
        let note = closed.isEmpty ? "" : "; меню закрылось само на шагах: " + closed.joined(separator: ", ")
        AppLog.write(bad.isEmpty
                     ? "проверка меню: ИТОГ ОК — высота \(Int(shots["главный экран"]?.height ?? 0))" + note
                     : "проверка меню: ИТОГ ПЛОХО — " + bad.joined(separator: "; ") + note)
    }

    private static func run() {
        guard let button = statusButton() else { AppLog.write("проверка меню: значок не найден"); return }
        shots = [:]
        resizes = 0
        jitter = []
        closed = []
        MenuProbeState.shared.extra = 0
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: nil) { note in
            if let w = note.object as? NSWindow, abs(w.frame.width - NativeMenuView.width) < 2 { resizes += 1 }
        }
        // Меню могло остаться открытым: начинаем с закрытого.
        if menuWindow() != nil { button.performClick(nil) }
        var step = 0
        // Сначала содержимое меняется в открытом меню, потом — пока меню
        // закрыто (так бывает, когда сменилось состояние): окно открывается
        // заново и должно быть ровно по новому содержимому.
        let close = { if menuWindow() != nil { button.performClick(nil) } }
        let steps: [(String, () -> Void)] = [
            ("главный экран", { button.performClick(nil) }),
            ("содержимое выросло", { MenuProbeState.shared.extra = 200 }),
            ("содержимое вернулось", { MenuProbeState.shared.extra = 0 }),
            ("закрыто", { close(); MenuProbeState.shared.extra = 200 }),
            ("открыто выше", { button.performClick(nil) }),
            ("закрыто снова", { close(); MenuProbeState.shared.extra = 0 }),
            ("открыто ниже", { button.performClick(nil) }),
        ]
        func next() {
            guard step < steps.count else {
                verdict()
                if menuWindow() != nil { button.performClick(nil) }
                return
            }
            let (name, action) = steps[step]
            step += 1
            resizes = 0
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if !name.hasPrefix("закрыто") { log(name) }
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
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
