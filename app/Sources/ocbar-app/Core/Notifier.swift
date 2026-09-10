import Foundation
import AppKit
import Security
import UserNotifications

// Уведомления системы — от самого приложения, а не от osascript: тогда они
// приходят с именем и иконкой ocbar, ими можно управлять в «Системных
// настройках → Уведомления», и они не выглядят как чужой скрипт.
//
// Клиент (bin/ocbar) отдаёт сообщение по URL-схеме: open -g
// "ocbar://notify?title=…&body=…&token=…". Приложение не запущено — клиент
// запускает его в фоне и ждёт свежий токен. Уведомления запрещены — клиент
// ничего не показывает сам (иначе система подписала бы их «Script Editor»,
// D61), а меню показывает строку «Уведомления выключены — Разрешить…».
//
// URL-схему может открыть кто угодно — любое приложение и страница в
// браузере, — поэтому без токена уведомление не показывается: иначе от имени
// ocbar можно было бы показать что угодно («нужен вход — введите пароль
// здесь»). Токен приложение кладёт при запуске в свой каталог состояния
// (права 0600), клиент читает его оттуда; рядом — notify.allowed: «1», если
// уведомления разрешены, иначе «0» — по нему клиент решает, отдавать ли адрес.
/// Разрешены ли уведомления ocbar — для строки «Уведомления выключены» в меню.
final class NotifyState: ObservableObject {
    static let shared = NotifyState()
    @Published var allowed = true
}

enum Notifier {
    static let scheme = "ocbar"
    private static let delegate = Delegate()
    private static var ready = false
    /// Токен, без которого ocbar://notify не принимается. nil — не принимается ничего.
    static var expectedToken: String?

    /// Каталог состояния пользователя — тот же, что у bin/ocbar (USER_STATE).
    static var stateDir: String {
        if let dir = ProcessInfo.processInfo.environment["OCBAR_USER_STATE"], !dir.isEmpty { return dir }
        return NSString(string: "~/Library/Application Support/ocbar").expandingTildeInPath
    }

    static func setup() {
        guard !ready else { return }
        ready = true
        if prepareToken(in: stateDir) == nil {
            AppLog.write("уведомления: не удалось записать notify.token в \(stateDir) — уведомления ocbar показываться не будут")
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        refreshAllowed()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            AppLog.write("уведомления: " + (granted ? "разрешены" : "не разрешены")
                         + (error.map { " (\($0.localizedDescription))" } ?? ""))
            refreshAllowed()
        }
    }

    /// Новый одноразовый токен: 16 случайных байт в hex, файл notify.token
    /// с правами 0600 (записывается рядом и переименовывается — клиент не
    /// прочтёт половину). Возвращает токен или nil, если записать не вышло.
    @discardableResult
    static func prepareToken(in dir: String) -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        guard write(token + "\n", to: dir + "/notify.token") else { return nil }
        expectedToken = token
        return token
    }

    /// notify.allowed: «1» — система покажет наше уведомление, «0» — нет.
    @discardableResult
    static func writeAllowed(_ allowed: Bool, in dir: String) -> Bool {
        write(allowed ? "1\n" : "0\n", to: dir + "/notify.allowed")
    }

    static func refreshAllowed() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            writeAllowed(allowed, in: stateDir)
            DispatchQueue.main.async {
                if NotifyState.shared.allowed != allowed { NotifyState.shared.allowed = allowed }
            }
        }
    }

    /// Раздел уведомлений в Системных настройках (macOS 13+), с ocbar, если система умеет.
    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "ru.ocbar.app"
        let urls = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
                    "x-apple.systempreferences:com.apple.preference.notifications"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    private static func write(_ text: String, to path: String) -> Bool {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        do {
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            let tmp = path + ".tmp"
            try? fm.removeItem(atPath: tmp)
            guard fm.createFile(atPath: tmp, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return false }
            if rename(tmp, path) != 0 { try? fm.removeItem(atPath: tmp); return false }
            return true
        } catch {
            return false
        }
    }

    enum Verdict: Equatable {
        case show(title: String, body: String)
        case rejected(String)      // наш адрес, но принять нельзя — причина для журнала
        case notOurs
    }

    /// Разбор ocbar://notify?title=…&body=…&token=… без показа. Заголовок —
    /// без приставки «ocbar:»: имя приложения система показывает сама.
    static func verdict(_ url: URL, token expected: String? = expectedToken) -> Verdict {
        guard url.scheme == scheme, url.host == "notify" else { return .notOurs }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let given = items.first { $0.name == "token" }?.value ?? ""
        guard let expected, !expected.isEmpty, !given.isEmpty, sameBytes(given, expected) else {
            return .rejected(given.isEmpty ? "без токена" : "с чужим токеном")
        }
        var title = items.first { $0.name == "title" }?.value ?? ""
        let body = items.first { $0.name == "body" }?.value ?? ""
        for prefix in ["ocbar: ", "ocbar:"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)); break
        }
        guard !title.isEmpty || !body.isEmpty else { return .rejected("пустое") }
        return .show(title: title.isEmpty ? "ocbar" : title, body: body)
    }

    static func parse(_ url: URL) -> (title: String, body: String)? {
        if case .show(let title, let body) = verdict(url) { return (title, body) }
        return nil
    }

    // Сравнение без раннего выхода: по времени ответа токен не подобрать.
    private static func sameBytes(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// true — адрес наш (показан или отвергнут с записью в журнал).
    static func handle(_ url: URL) -> Bool {
        switch verdict(url) {
        case .show(let title, let body):
            show(title: title, body: body)
            return true
        case .rejected(let why):
            AppLog.write("ocbar://notify \(why) — не показано")
            return true
        case .notOurs:
            return false
        }
    }

    static func show(title: String, body: String) {
        setup()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { AppLog.write("уведомление не показано: \(error.localizedDescription)") }
        }
    }

    // Показывать и когда приложение «активно» (у меню-бара это почти всегда):
    // без делегата система такие уведомления глотает.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list])
        }
    }
}
