import Foundation
import AppKit
import UserNotifications

// Уведомления системы — от самого приложения, а не от osascript: тогда они
// приходят с именем и иконкой ocbar, ими можно управлять в «Системных
// настройках → Уведомления», и они не выглядят как чужой скрипт.
//
// Клиент (bin/ocbar) отдаёт сообщение по URL-схеме: open -g
// "ocbar://notify?title=…&body=…". Если приложение не запущено, клиент
// показывает уведомление прежним путём — сам, через osascript.
enum Notifier {
    static let scheme = "ocbar"
    private static let delegate = Delegate()
    private static var ready = false
    /// Токен, без которого ocbar://notify не принимается.
    static var expectedToken: String?

    static func setup() {
        guard !ready else { return }
        ready = true
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            AppLog.write("уведомления: " + (granted ? "разрешены" : "не разрешены")
                         + (error.map { " (\($0.localizedDescription))" } ?? ""))
        }
    }

    /// ocbar://notify?title=…&body=… → (заголовок, текст). Заголовок без
    /// приставки «ocbar:» — имя приложения система показывает сама.
    static func parse(_ url: URL) -> (title: String, body: String)? {
        guard url.scheme == scheme, url.host == "notify" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var title = items.first { $0.name == "title" }?.value ?? ""
        let body = items.first { $0.name == "body" }?.value ?? ""
        for prefix in ["ocbar: ", "ocbar:"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)); break
        }
        guard !title.isEmpty || !body.isEmpty else { return nil }
        return (title.isEmpty ? "ocbar" : title, body)
    }

    static func handle(_ url: URL) -> Bool {
        guard let (title, body) = parse(url) else { return false }
        show(title: title, body: body)
        return true
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
