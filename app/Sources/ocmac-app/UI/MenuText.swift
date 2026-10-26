import AppKit
import SwiftUI

// Тексты меню: ошибки словами человека и готовые команды-исправления.
enum MenuText {
    /// Сколько строк списка показывать без прокрутки: остальное прокручивается
    /// внутри своей группы.
    static var rowsBeforeScroll: Int {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(5, min(14, Int((screen - 420) / 34)))
    }

    /// Что делать с этой ошибкой: команда, которую приложение выполнить не
    /// может (нужен пароль или Homebrew), но может отдать в буфер обмена.
    static func fix(for message: String) -> (title: String, command: String)? {
        // Клиент говорит на языке системы: узнаём по командам в сообщении,
        // а слова — на обоих языках.
        let m = message.lowercased()
        if m.range(of: #"sudo \S*ocmac install"#, options: .regularExpression) != nil,
           !m.contains("--trust") {
            return (L("Скопировать команду"), "sudo ocmac install")
        }
        if m.contains("brew install openconnect") || m.contains("нет openconnect") || m.contains("no openconnect") {
            return (L("Скопировать команду"), "brew install openconnect")
        }
        if m.contains("brew install ocproxy") || m.contains("нет ocproxy") || m.contains("no ocproxy") {
            return (L("Скопировать команду"), "brew install ocproxy")
        }
        if m.contains("--trust") { return (L("Скопировать команду"), "sudo ocmac install --trust") }
        return nil
    }

    /// Ошибка словами человека: без «ocmac:» и кода возврата хелпера —
    /// подробности в журнале, кнопка рядом.
    static func human(_ message: String) -> String {
        var t = message
        for prefix in ["ocmac: ", "ocmac:"] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)); break }
        if let r = t.range(of: " — хелпер вернул") { t = String(t[..<r.lowerBound]) }
        if let first = t.first { t = first.uppercased() + t.dropFirst() }
        return t
    }
}

// Как выглядит каждое состояние. Различаются не строкой, а целиком: цвет,
// заголовок, пояснение, есть ли график и время.
struct StateLook {
    let color: Color
    let title: String       // профиль: текущий или по умолчанию
    let subtitle: String    // состояние словами
    let note: String?
    let showsTime: Bool
    let graph: Bool
    let graphActive: Bool
    let pulsing: Bool
    let details: Bool

    /// Имя для шапки и строки «Профиль»: текущий профиль, иначе по умолчанию.
    /// К какому профилю относится меню: подключённый; иначе последний
    /// подключённый, профиль по умолчанию, первый в списке.
    static func targetName(_ s: Status) -> String {
        if !s.profile.isEmpty { return s.profile }
        let known = Set(s.profiles.map(\.name))
        if let last = UserDefaults.standard.string(forKey: "LastProfile"), known.contains(last) { return last }
        if !s.defaultProfile.isEmpty { return s.defaultProfile }
        return s.profiles.first?.name ?? ""
    }

    static func profileName(_ s: Status) -> String {
        let n = targetName(s)
        if n.isEmpty { return "OpenConnect for Mac" }
        return s.profiles.first { $0.name == n }?.display ?? n
    }

    static func of(_ s: Status) -> StateLook {
        let name = profileName(s)
        switch s.presentation {
        case .connected:
            return .init(color: Palette.ok, title: name, subtitle: L("Подключено"), note: nil,
                         showsTime: true, graph: true, graphActive: true, pulsing: false, details: true)
        case .lost:
            let waited = s.linkLostSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            return .init(color: Palette.warn, title: name,
                         subtitle: s.isProxySession ? L("SOCKS не отвечает") : L("Нет связи · восстанавливаю"),
                         note: s.isProxySession
                             ? L("SOCKS не отвечает %@ с — супервизор перезапустит прокси целиком.", "\(waited)")
                             : L("Связи нет %@ с — восстанавливаю сессию. Повторный вход не нужен.", "\(waited)"),
                         showsTime: false, graph: true, graphActive: false, pulsing: true, details: true)
        case .paused:
            return .init(color: Palette.warn, title: name, subtitle: L("Приостановлено"),
                         note: L("Сети и DNS временно сняты, сессия жива — возобновление без входа."),
                         showsTime: true, graph: false, graphActive: false, pulsing: false, details: true)
        case .starting:
            return .init(color: Palette.warn, title: name, subtitle: L("Подключается…"), note: nil,
                         showsTime: false, graph: false, graphActive: false, pulsing: true, details: false)
        case .needsLogin:
            return .init(color: Palette.bad, title: name, subtitle: L("Нужен вход"),
                         note: L("Сессия истекла, автоматически войти не удалось. Автоподключение ждёт вас."),
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .down:
            return .init(color: Palette.line2, title: name, subtitle: L("Отключено"), note: nil,
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .foreign:
            return .init(color: Palette.tertiary, title: L("Чужой openconnect"), subtitle: L("поднят не через OpenConnect for Mac"),
                         note: L("Это подключение OpenConnect for Mac не управляет и не трогает."),
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .missing:
            return .init(color: Palette.bad, title: L("Не найден клиент OpenConnect for Mac"), subtitle: L("подключение недоступно"),
                         note: OCMacClient.shared.lookupNote.isEmpty
                             ? L("Искал в /opt/homebrew/bin, /usr/local/bin и рядом с приложением. Путь можно задать переменной OCMAC_BIN.")
                             : OCMacClient.shared.lookupNote,
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        }
    }
}
