import AppKit

// Окно «Код из SMS»: одно поле и «Войти». Нужно парольной группе — шлюз
// спрашивает код, который человек видит в телефоне; ocbar его не знает и
// знать не может. Ответ — в stdout одной строкой, секрет в журнал не пишется.
final class PromptDialog {
    let label: String
    let profile: String
    /// Пароль, а не код: поле со звёздочками и другие слова.
    let secure: Bool
    private(set) var alert = NSAlert()
    private var field: NSTextField!

    init(label: String, profile: String, secure: Bool = false) {
        self.label = label
        self.profile = profile
        self.secure = secure
    }

    /// Подпись шлюза «Response:» или «Verification code:» — человеку понятнее
    /// «Код из SMS»; своя подпись шлюза остаётся ниже, мелко.
    private var gatewayLabel: String {
        label.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines))
    }

    func build() {
        alert = NSAlert()
        alert.messageText = secure ? L("Пароль VPN") : L("Код из SMS")
        // У ocbar-auth нет бандла и своей иконки — без этого NSAlert
        // показал бы папку.
        let cfg = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            .applying(.init(paletteColors: [.systemBlue]))
        if let icon = NSImage(systemSymbolName: secure ? "key.fill" : "message.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) { alert.icon = icon }
        // Подпись шлюза («Response:») в окно не выводим: человеку она ничего не
        // говорит; она есть в журнале входа.
        let info = secure
            ? (profile.isEmpty ? L("Введите пароль VPN.") : L("Введите пароль VPN для профиля «%@».", profile))
                + " " + L("Чтобы не спрашивать каждый раз, сохраните его: настройки ocbar → Профили → Вход.")
            : (profile.isEmpty ? L("Введите код из SMS.") : L("Введите код из SMS для профиля «%@».", profile))
        alert.informativeText = info
        alert.addButton(withTitle: L("Войти"))
        alert.addButton(withTitle: L("Отмена"))
        if secure {
            field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            field.contentType = .password
        } else {
            field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
            field.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
            field.placeholderString = L("Код")
            field.alignment = .center
            // Код в SMS приходит и в подсказку над клавиатурой — поле называем
            // как одноразовый код, чтобы macOS её предложила.
            field.contentType = .oneTimeCode
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
    }

    /// Ответ человека или nil (отмена, тайм-аут).
    func run(timeout: TimeInterval) -> String? {
        build()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let t = Timer(timeInterval: timeout, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(t, forMode: .modalPanel)
        let response = alert.runModal()
        t.invalidate()
        guard response == .alertFirstButtonReturn else { return nil }
        let v = secure ? field.stringValue : field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static func shot(to path: String) -> Bool {
        let d = PromptDialog(label: "Response:", profile: L("Парольная группа"))
        d.build()
        d.alert.layout()
        // cacheDisplay не рисует фон окна: в тёмной теме белый текст лёг бы
        // на белое. Снимок — в светлой.
        d.alert.window.appearance = NSAppearance(named: .aqua)
        // Без показа NSAlert не рисует текст — показываем за краем экрана.
        d.alert.window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        d.alert.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let view = d.alert.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
