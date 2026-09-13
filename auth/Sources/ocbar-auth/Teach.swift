import AppKit
import WebKit
import Foundation
import UniformTypeIdentifiers

/// Разметка при настоящем входе. Человек входит как обычно, руками, а ocbar
/// запоминает, как устроена форма, и после успешного входа предлагает
/// сохранить: правила формы, пароль, источник одноразового кода.
///
/// Размечать ничего не нужно: каждая отправка формы — окно (шаг). Поле
/// пароля узнаётся по типу, логин — по совпадению с логином профиля или как
/// поле перед паролем, код — по тому, что человек ввёл цифрами. Остальные
/// введённые поля становятся `fill manual`: их вводит человек, и пока они
/// пустые, кнопки не жмутся. Повторная отправка тех же полей (ошибся
/// паролем, нажал «показать пароль») заменяет прошлую, а не плодит шаги.
///
/// Скрипт работает в отдельном мире WebKit (WKContentWorld): страница
/// портала не видит ни его, ни обработчик сообщений — не может ни подсунуть
/// поддельные данные, ни включить запись сама.
final class TeachRecorder: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "ocbar-teach")

    struct Field { let kind: String; let selector: String; let why: String }  // username|password|totp|manual
    struct Step { var page: String; var fields: [Field]; var button: String? }

    private(set) var steps: [Step] = []
    // Только в памяти процесса: пароль — чтобы предложить сохранить, код —
    // чтобы проверить секрет TOTP. Ни в журнал, ни в файлы не попадают.
    private(set) var password: String?
    private(set) var code: String?
    private(set) var codeAt: Date?
    var enabled = false
    // Только для --learn-selftest: считать синтетические события настоящими.
    // Флаг живёт в изолированном мире, страница его не видит и не меняет.
    var trustSynthetic = false
    var engineFilledCode = false      // код подставил сам ocbar — спрашивать про него незачем
    var onChange: ((String) -> Void)?
    private let username: String?

    init(username: String?) {
        self.username = username
        super.init()
    }

    func install(into c: WKUserContentController) {
        c.addUserScript(WKUserScript(source: Self.script(username: username), injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true, in: Self.world))
        c.add(self, contentWorld: Self.world, name: "ocbarTeach")
    }

    /// Включить или выключить запись на текущей странице — флаг живёт в
    /// изолированном мире, страница его не видит и не меняет.
    func apply(to webView: WKWebView) {
        webView.evaluateJavaScript("window.__ocbarTeachOn = \(enabled ? "true" : "false"); "
                                   + "window.__ocbarTeachTrustSynthetic = \(trustSynthetic ? "true" : "false"); 0",
                                   in: nil, in: Self.world) { _ in }
    }

    func forgetSecrets() { password = nil; code = nil }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard enabled, message.world == Self.world, let body = message.body as? [String: Any] else { return }
        let page = body["page"] as? String ?? ""
        let fields = (body["fields"] as? [[String: String]] ?? []).compactMap { f -> Field? in
            guard let k = f["kind"], let sel = f["selector"], !sel.isEmpty,
                  !["html", "body"].contains(sel.lowercased()) else { return nil }
            return Field(kind: k, selector: sel, why: f["why"] ?? "")
        }
        let button = (body["button"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let p = body["password"] as? String, !p.isEmpty { password = p }
        if let c = body["code"] as? String, !c.isEmpty { code = c; codeAt = Date() }
        guard !fields.isEmpty || button != nil else { return }
        let step = Step(page: page, fields: fields, button: button)
        let sig = Set(fields.map(\.selector))
        // То же окно — те же поля: повтор после ошибки, «показать пароль»,
        // исправленный пароль. Побеждает последняя отправка.
        if let last = steps.last, Set(last.fields.map(\.selector)) == sig, !sig.isEmpty || last.button == button {
            steps[steps.count - 1] = step
        } else {
            steps.append(step)
        }
        onChange?(summary())
    }

    static func title(_ kind: String) -> String {
        ["username": "логин", "password": "пароль", "totp": "код", "manual": "поле, которое вводите вы"][kind] ?? kind
    }

    func summary() -> String {
        steps.enumerated().map { i, s in
            var parts = s.fields.map { Self.title($0.kind) }
            if s.button != nil { parts.append(s.fields.isEmpty ? "кнопка «всегда»" : "кнопка") }
            return "окно \(i + 1): " + parts.joined(separator: ", ")
        }.joined(separator: " · ")
    }

    var manualCount: Int { steps.reduce(0) { $0 + $1.fields.filter { $0.kind == "manual" }.count } }

    func marks() -> [LearnSession.Mark] {
        var out: [LearnSession.Mark] = []
        // Записанное при входе не знает, как портал показывает ошибку, —
        // берём стандартные признаки из встроенного набора: без них неверный
        // пароль уходил бы снова.
        for r in Autofill.defaultRules {
            if case .stop = r.action {
                out.append(.init(kind: "stop", selector: r.selector, hint: "", step: 1, why: "встроенный признак ошибки"))
            }
        }
        for (i, s) in steps.enumerated() {
            for f in s.fields { out.append(.init(kind: f.kind, selector: f.selector, hint: "", step: i + 1, why: f.why)) }
            if let b = s.button { out.append(.init(kind: "click", selector: b, hint: "", step: i + 1, why: "кнопка отправки")) }
        }
        return out
    }

    func rulesText(portal: String) -> String {
        var pages: [Int: String] = [:]
        for (i, s) in steps.enumerated() { pages[i + 1] = s.page }
        let host = steps.first.flatMap { $0.page.split(separator: "/").first.map(String.init) }
        // Заголовок шага — всегда: по адресу окна CLI сливает запомненное с
        // правилами профиля и не теряет окна, которых в этот вход не было.
        return LearnSession.rulesText(marks: marks(), pages: pages, portal: portal, formHost: host, alwaysHeaders: true)
    }

    /// Скрипт записи. Работает в изолированном мире: DOM общий со страницей,
    /// а переменные и обработчик сообщений — свои.
    static func script(username: String?) -> String {
        let u = username.map { LearnSession.js($0) } ?? "null"
        return """
        (function (username) {
          if (window.__ocbarTeachReady) return;
          window.__ocbarTeachReady = true;
          if (window.__ocbarTeachOn === undefined) window.__ocbarTeachOn = false;
          if (window.__ocbarTeachTrustSynthetic === undefined) window.__ocbarTeachTrustSynthetic = false;
        \(LearnSession.selectorJS)
          function visible(e) { return e && e.offsetParent !== null; }
          function typeOf(e) { return (e.getAttribute('type') || 'text').toLowerCase(); }
          // Настоящие события. Щелчок от страницы (el.click(), dispatchEvent)
          // приходит с isTrusted = false. Но submit, который страница вызвала
          // сама (button.click(), form.requestSubmit()), WebKit помечает
          // isTrusted = true — проверено 2026-09-10. Поэтому отправка формы
          // считается, только если перед ней был настоящий жест человека:
          // нажатие мыши или клавиши (Enter) не раньше чем за полторы секунды.
          var lastGesture = 0;
          function gesture(e) { if (e.isTrusted) lastGesture = Date.now(); }
          document.addEventListener('mousedown', gesture, true);
          document.addEventListener('keydown', gesture, true);
          function trustedClick(e) { return window.__ocbarTeachTrustSynthetic || e.isTrusted; }
          function trustedSubmit(e) {
            return window.__ocbarTeachTrustSynthetic || (e.isTrusted && Date.now() - lastGesture < 1500);
          }
          // Поле type=password, которое на деле — поле одноразового кода: у
          // части порталов код вводится в «пароль». Такой «пароль» нельзя
          // предлагать сохранить вместо настоящего.
          function codeLike(e, v) {
            var ac = (e.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/);
            var mode = (e.getAttribute('inputmode') || '').toLowerCase();
            var len = parseInt(e.getAttribute('maxlength') || '0', 10);
            var n = (e.getAttribute('name') || '') + ' ' + (e.id || '');
            return ac.indexOf('one-time-code') >= 0 || mode === 'numeric' || (len > 0 && len <= 8) ||
                   /otp|totp|one.?time|code|pin/i.test(n) || /^[0-9]{4,8}$/.test(String(v).trim());
          }
          function defaultButton(form) {
            if (!form) return null;
            var b = form.querySelector('button:not([type]),button[type=submit],input[type=submit],input[type=image]');
            return visible(b) ? b : null;
          }
          var skip = ['hidden', 'checkbox', 'radio', 'submit', 'button', 'image', 'reset', 'file'];
          function snapshot(root, button, buttonOnlyOk) {
            if (!window.__ocbarTeachOn) return;
            var scope = root || document;
            var inputs = Array.prototype.filter.call(scope.querySelectorAll('input,textarea'), function (e) {
              return visible(e) && skip.indexOf(typeOf(e)) < 0 && String(e.value || '') !== '';
            });
            if (!inputs.length && !buttonOnlyOk) return;
            var pw = inputs.filter(function (e) { return typeOf(e) === 'password' && !codeLike(e, e.value); });
            var userBefore = null;
            if (pw.length) {
              var before = inputs.filter(function (e) {
                return typeOf(e) !== 'password' && (e.compareDocumentPosition(pw[0]) & Node.DOCUMENT_POSITION_FOLLOWING);
              });
              if (before.length) userBefore = before[before.length - 1];
            }
            var fields = [], password = '', code = '';
            inputs.forEach(function (e) {
              var v = String(e.value), k = 'manual', why = 'вводит человек';
              if (typeOf(e) === 'password') {
                if (codeLike(e, v)) {
                  k = 'totp'; why = 'поле кода с типом password';
                  if (/^[0-9]{4,8}$/.test(v.trim())) code = v.trim();
                } else if (e === pw[0]) { k = 'password'; why = 'поле пароля'; password = v; }
              } else if (username && v.trim().toLowerCase() === String(username).trim().toLowerCase()) {
                k = 'username'; why = 'введён логин профиля';
              } else if (/^[0-9]{4,8}$/.test(v.trim())) {
                k = 'totp'; why = 'введён код из цифр'; code = v.trim();
              } else if (e === userBefore) {
                k = 'username'; why = 'поле перед паролем';
              }
              fields.push({kind: k, selector: selectorFor(e), why: why});
            });
            var b = button || defaultButton(root && root.tagName === 'FORM' ? root : null);
            window.webkit.messageHandlers.ocbarTeach.postMessage({
              page: location.host + location.pathname, fields: fields,
              button: b ? selectorFor(b) : '', password: password, code: code
            });
          }
          // Отправка формы — окно пройдено. submitter — кнопка, которой
          // отправили (стандарт HTML); Enter отправляет кнопкой по умолчанию.
          document.addEventListener('submit', function (e) {
            if (!trustedSubmit(e)) return;
            snapshot(e.target, e.submitter || null, true);
          }, true);
          // Кнопки вне формы и type=button (одностраничные формы) — по щелчку,
          // но только если в полях что-то введено: иначе это «показать
          // пароль», «назад» и прочее, что окном формы не является.
          document.addEventListener('click', function (e) {
            if (!trustedClick(e)) return;
            var b = e.target && e.target.closest ? e.target.closest('button,input[type=submit],input[type=image]') : null;
            if (!b) return;
            var isSubmit = b.tagName === 'BUTTON' ? (!b.getAttribute('type') || typeOf(b) === 'submit') : true;
            if (isSubmit && b.form) return;          // это поймает submit
            snapshot(b.form || null, b, false);
          }, true);
        })(\(u));
        """
    }
}

/// Запись в связку ключей через `security -i`: значение идёт
/// шестнадцатеричной строкой (-X) в stdin, а не в аргументах. Проверено
/// 2026-09-10 во временной связке: пробелы, кавычки, кириллица, пробел в
/// конце ложатся ровно; -w с кавычками их ломает. Запись делает сама
/// security — поэтому ocbar потом читает её без запроса доступа.
enum KeychainWriter {
    static func line(service: String, account: String, label: String, secret: String) -> String? {
        func safe(_ s: String) -> Bool { !s.isEmpty && s.range(of: "^[A-Za-z0-9._@/-]+$", options: .regularExpression) != nil }
        guard safe(service), safe(account), safe(label), !secret.isEmpty else { return nil }
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        return "add-generic-password -U -s \(service) -a \(account) -l \(label) -X \(hex)\n"
    }

    /// Записать и тут же прочитать обратно: «сохранено» — только если в
    /// связке лежит ровно то, что ввёл человек.
    static func save(service: String, account: String, label: String, secret: String) -> Bool {
        guard let line = line(service: service, account: account, label: label, secret: secret) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        inPipe.fileHandleForWriting.write(Data(line.utf8))
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return read(service: service, account: account) == secret
    }

    /// Не-ASCII значение `security -w` отдаёт шестнадцатеричной строкой без
    /// признаков — отличаем по `-g`, где у такого значения префикс 0x.
    static func read(service: String, account: String) -> String? {
        func run(_ args: [String]) -> (out: Data, err: Data) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = args
            let o = Pipe(), e = Pipe()
            p.standardOutput = o; p.standardError = e
            do { try p.run() } catch { return (Data(), Data()) }
            let out = o.fileHandleForReading.readDataToEndOfFile()
            let err = e.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (out, err)
        }
        let g = String(decoding: run(["find-generic-password", "-g", "-s", service, "-a", account]).err, as: UTF8.self)
        if let r = g.range(of: "password: 0x") {
            let hex = g[r.upperBound...].prefix { $0.isHexDigit }
            var bytes = Data(); var i = hex.startIndex
            while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
                if let b = UInt8(hex[i..<j], radix: 16) { bytes.append(b) }
                i = j
            }
            return String(data: bytes, encoding: .utf8)
        }
        guard g.contains("password:") else { return nil }
        var w = String(decoding: run(["find-generic-password", "-w", "-s", service, "-a", account]).out, as: UTF8.self)
        if w.hasSuffix("\n") { w.removeLast() }
        return w
    }
}

/// Окно «Запомнить для следующего входа» — после успешного входа, до
/// подключения туннеля. Без подтверждения не сохраняется ничего.
final class TeachDialog: NSObject, NSTextFieldDelegate {
    enum PasswordOffer: Equatable { case none, save, update, askToKeychain, elsewhere(String) }

    /// Галочка пароля по умолчанию. «Сохранить» (пароля ещё нет) —
    /// включена. «Обновить» — выключена: перезаписать рабочий пароль должен
    /// решить человек, а записанное могло оказаться не паролем (код в поле
    /// type=password, подложная отправка формы). «В связку» при вводе
    /// руками — выключена: человек раньше выбрал вводить сам.
    static func defaultOn(_ offer: PasswordOffer) -> Bool {
        if case .save = offer { return true }
        return false
    }
    struct Input {
        var profile: String
        var summary: String
        var manualCount: Int
        var passwordOffer: PasswordOffer
        var offerCode: Bool
        var code: String?
        var codeAt: Date?
    }
    struct Output {
        var saveRules = false
        var savePassword = false
        var codeMode = 0          // 0 не менять, 1 из приложения (секрет ниже), 2 SMS
        var secret: String?
        var params = TOTPParams()
    }

    private let input: Input
    private var alert: NSAlert!
    private var rulesBox: NSButton!
    private var passwordBox: NSButton?
    private var codePopup: NSPopUpButton?
    private var secretField: NSSecureTextField?
    private var secretRow: NSStackView?
    private var qrButton: NSButton?
    private var cameraButton: NSButton?
    private var cameraActive = false
    private var verifyLabel: NSTextField?
    private var secret: String?
    private var params = TOTPParams()
    private var verified = false

    init(_ input: Input) { self.input = input; super.init() }

    /// Код, который человек только что ввёл, подтверждает секрет: секрет с
    /// этими параметрами принимается, только если даёт этот код (± шаг).
    static func matches(_ secret: String, code: String, at: Date, params p: TOTPParams) -> Bool {
        let s = normalize(secret)
        guard p.isSupported, p.digits == code.count, TOTP.base32Decode(s) != nil else { return false }
        for k in -1...1 {
            if TOTP.code(secretBase32: s, at: at.addingTimeInterval(Double(k * p.period)), params: p) == code { return true }
        }
        return false
    }

    /// Параметры голого секрета не видны — определяем по введённому коду:
    /// три алгоритма × периоды 30 и 60 с, цифр — сколько ввёл человек.
    /// Случайное совпадение при таком переборе для 6 цифр — около 1 на 55 000.
    static func matchParams(_ raw: String, code: String, at: Date) -> TOTPParams? {
        for alg in TOTPParams.algorithms {
            for period in [30, 60] {
                let p = TOTPParams(algorithm: alg, digits: code.count, period: period)
                if matches(raw, code: code, at: at, params: p) { return p }
            }
        }
        return nil
    }

    static func secretMatches(_ raw: String, code: String, at: Date) -> Bool {
        matchParams(raw, code: code, at: at) != nil
    }

    /// Запись из QR — файл, камера, ссылка otpauth — со своими параметрами.
    /// HOTP не принимается: счётчик живёт в приложении, и две копии разойдутся.
    static func entryMatches(_ e: QRImport.Entry, code: String, at: Date) -> Bool {
        e.isTOTP && e.params.isSupported && matches(e.secretBase32, code: code, at: at, params: e.params)
    }
    static func normalize(_ s: String) -> String { s.uppercased().filter { !$0.isWhitespace && $0 != "-" } }

    private func label(_ text: String, size: CGFloat = 11.5, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.preferredMaxLayoutWidth = 440
        // Без явной ширины высота блока считается до переноса строк, и
        // длинная подпись обрезается после первой строки.
        l.widthAnchor.constraint(equalToConstant: 440).isActive = true
        // И минимальная высота по собственному тексту: иначе стопка сжимает
        // подписи — список окон пропадал, длинная строка резалась.
        let h = l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 440, height: 10_000)).height ?? 16
        l.heightAnchor.constraint(greaterThanOrEqualToConstant: ceil(h)).isActive = true
        return l
    }

    /// Та же монограмма «oc» на синем поле, что у приложения (make-icon.swift):
    /// ocbar-auth — голый исполняемый файл, и без этого окно показывало бы
    /// чужой значок по умолчанию.
    static func brandIcon(side: CGFloat = 64) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let inset = side * 0.09
            let r = rect.insetBy(dx: inset, dy: inset)
            let shape = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
            NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.44, blue: 0.78, alpha: 1),
                                NSColor(srgbRed: 0.11, green: 0.26, blue: 0.52, alpha: 1)])?.draw(in: shape, angle: -90)
            let base = NSFont.systemFont(ofSize: side * 0.58, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: side * 0.58) } ?? base
            let text = NSAttributedString(string: "oc", attributes: [.font: font, .foregroundColor: NSColor.white,
                                                                      .kern: -side * 0.03])
            let sz = text.size()
            text.draw(at: NSPoint(x: (side - sz.width) / 2, y: (side - sz.height) / 2 - side * 0.02))
            return true
        }
    }

    private func build() {
        alert = NSAlert()
        alert.icon = TeachDialog.brandIcon()
        alert.messageText = "Запомнить для следующего входа?"
        alert.informativeText = "Вход прошёл. Выберите, что сохранить в профиль «\(input.profile)». Без вашего выбора ничего не сохраняется."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        rulesBox = NSButton(checkboxWithTitle: "Правила формы входа", target: nil, action: nil)
        rulesBox.state = .on
        stack.addArrangedSubview(rulesBox)
        stack.addArrangedSubview(label(input.summary))
        if input.manualCount > 0 {
            stack.addArrangedSubview(label("Полей, которые вводите только вы: \(input.manualCount). На них ocbar остановится и подождёт вас — пустыми они не уйдут.", color: .systemOrange))
        }

        switch input.passwordOffer {
        case .none: break
        case .save, .update, .askToKeychain:
            // Заголовок галочки — в одну строку, пояснение — отдельной подписью:
            // длинный заголовок обрезался.
            var title = "Сохранить пароль в связке ключей", note: String?
            switch input.passwordOffer {
            case .update: title = "Обновить пароль в связке ключей"; note = "Введённый пароль отличается от сохранённого."
            case .askToKeychain: note = "Сейчас пароль вводите вы — ocbar будет подставлять его сам."
            default: break
            }
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = Self.defaultOn(input.passwordOffer) ? .on : .off
            stack.addArrangedSubview(box)
            if let note { stack.addArrangedSubview(label(note)) }
            passwordBox = box
        case .elsewhere(let src):
            stack.addArrangedSubview(label("Пароль берётся из \(src) — ocbar его не сохраняет."))
        }

        if input.offerCode {
            stack.addArrangedSubview(label("Одноразовый код вы ввели сами. Откуда он?", size: 12, color: .labelColor))
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: ["Не менять", "Из приложения-аутентификатора — завести здесь",
                                        "Приходит по SMS — вводить каждый раз"])
            popup.target = self
            popup.action = #selector(codeModeChanged)
            stack.addArrangedSubview(popup)
            codePopup = popup

            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
            field.placeholderString = "секрет base32"
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            let qr = NSButton(title: "Файл QR…", target: self, action: #selector(pickQR))
            qr.bezelStyle = .rounded
            // Экспорт Google Authenticator показывается на экране телефона, а
            // снимок экрана телефон часто запрещает, — читаем камерой Mac.
            let cam = NSButton(title: "Камерой…", target: self, action: #selector(scanCamera))
            cam.bezelStyle = .rounded
            cam.toolTip = "Прочитать QR экспорта Google Authenticator с экрана телефона камерой Mac. Кадры не сохраняются."
            cameraButton = cam
            // Строка видна всегда, доступна — только при «из приложения»: окно
            // не растёт после показа, и появившаяся позже строка обрезалась бы.
            let row = NSStackView(views: [field, qr, cam])
            row.orientation = .horizontal
            row.spacing = 6
            stack.addArrangedSubview(row)
            secretField = field
            secretRow = row
            qrButton = qr
            let v = label("Секрет примется, только если даёт тот код, который вы только что ввели.")
            stack.addArrangedSubview(v)
            verifyLabel = v
            setSecretEnabled(false)
        }

        stack.setClippingResistancePriority(.required, for: .vertical)
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: stack.fittingSize.height)
        alert.accessoryView = stack
        alert.layout()
    }

    /// Снимок окна сохранения без показа — чтобы вид проверялся без человека,
    /// как витрина приложения (ocbar-auth --teach-dialog-shot файл.png).
    static func shot(to path: String) -> Bool {
        let d = TeachDialog(.init(profile: "Основной",
                                  summary: "окно 1: логин, пароль, кнопка · окно 2: код, поле, которое вводите вы, кнопка · окно 3: кнопка «всегда»",
                                  manualCount: 1, passwordOffer: .update, offerCode: true,
                                  code: "123456", codeAt: Date()))
        d.build()
        // Снимок без фона окна: в тёмном оформлении текст получился бы
        // белым на белом.
        d.alert.window.appearance = NSAppearance(named: .aqua)
        d.codePopup?.selectItem(at: 1)
        d.codeModeChanged()
        d.alert.layout()
        guard let view = d.alert.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    func run(timeout: TimeInterval = 180) -> Output? {
        build()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Не ответили за три минуты — ничего не сохраняем: туннель ждёт.
        let t = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            // Если открыто окно камеры, первый abortModal закроет его, второй —
            // само окно сохранения.
            let nested = self?.cameraActive == true
            NSApp.abortModal()
            if nested { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.abortModal() } }
        }
        RunLoop.main.add(t, forMode: .modalPanel)
        let response = alert.runModal()
        t.invalidate()
        guard response == .alertFirstButtonReturn else {
            Log.info(response == .abort ? "окно сохранения закрыто по тайм-ауту — ничего не сохранено"
                                        : "сохранять не стали")
            return nil
        }
        var o = Output()
        o.saveRules = rulesBox.state == .on
        o.savePassword = passwordBox?.state == .on
        o.codeMode = codePopup?.indexOfSelectedItem ?? 0
        if o.codeMode == 1 { o.secret = verified ? secret : nil; o.params = params; if !verified { o.codeMode = 0 } }
        return o
    }

    @objc private func codeModeChanged() {
        setSecretEnabled(codePopup?.indexOfSelectedItem == 1)
        refresh()
    }

    private func setSecretEnabled(_ on: Bool) {
        secretField?.isEnabled = on
        qrButton?.isEnabled = on
        cameraButton?.isEnabled = on
        verifyLabel?.textColor = on ? .secondaryLabelColor : .tertiaryLabelColor
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = secretField, let code = input.code, let at = input.codeAt else { return }
        let raw = f.stringValue.trimmingCharacters(in: .whitespaces)
        // Ссылка otpauth:// несёт параметры сама.
        if raw.lowercased().hasPrefix("otpauth://"), let e = (try? QRImport.parse(raw))?.first {
            if TeachDialog.entryMatches(e, code: code, at: at) {
                accept(e, source: "из ссылки")
            } else {
                verified = false
                verifyLabel?.stringValue = e.isTOTP ? "✗ секрет из ссылки не даёт введённый вами код"
                                                    : "✗ это код по счётчику (HOTP) — ocbar его не ведёт"
            }
            refresh()
            return
        }
        if let p = TeachDialog.matchParams(raw, code: code, at: at) {
            secret = TeachDialog.normalize(raw)
            params = p
            verified = true
            verifyLabel?.stringValue = "✓ секрет даёт введённый вами код" + (p.isDefault ? "" : " (\(p.label))")
        } else {
            secret = nil
            verified = false
            verifyLabel?.stringValue = raw.isEmpty
                ? "Секрет примется, только если даёт тот код, который вы только что ввели."
                : "✗ секрет не даёт введённый вами код — проверьте"
        }
        refresh()
    }

    @objc private func pickQR() {
        guard let code = input.code, let at = input.codeAt else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Снимок QR второго фактора (подойдёт и экспорт Google Authenticator)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = try QRImport.decode(file: url.path).flatMap { try QRImport.parse($0) }
            // Из нескольких записей нужная находится сама: та, что даёт код,
            // который человек только что ввёл.
            let fit = entries.filter { TeachDialog.entryMatches($0, code: code, at: at) }
            if let e = fit.first {
                accept(e, source: "из QR")
            } else {
                verified = false
                verifyLabel?.stringValue = entries.isEmpty ? "в QR нет записей TOTP"
                    : "ни одна из записей в QR (\(entries.count)) не даёт введённый вами код"
            }
        } catch {
            verified = false
            verifyLabel?.stringValue = "\(error)"
        }
        refresh()
    }

    private func accept(_ e: QRImport.Entry, source: String) {
        secret = TeachDialog.normalize(e.secretBase32)
        params = e.params
        verified = true
        secretField?.stringValue = ""
        let who = [e.issuer, e.name].filter { !$0.isEmpty }.joined(separator: " · ")
        verifyLabel?.stringValue = "✓ \(source): \(who.isEmpty ? "запись" : who) — даёт введённый вами код"
            + (e.params.isDefault ? "" : " (\(e.params.label))")
    }

    @objc private func scanCamera() {
        guard let code = input.code, let at = input.codeAt else { return }
        cameraActive = true
        let r = QRCameraWindow(code: code, at: at).run()
        cameraActive = false
        if let e = r.entry {
            accept(e, source: "с камеры")
        } else {
            verifyLabel?.stringValue = r.note
        }
        refresh()
    }

    private func refresh() {
        // «Сохранить» с выбранным «из приложения» — только с подтверждённым секретом.
        let needSecret = codePopup?.indexOfSelectedItem == 1
        alert.buttons.first?.isEnabled = !needSecret || verified
    }
}

/// После успешного входа: спросить, сохранить выбранное и отдать клиенту
/// итог без секретов (правила и какие ключи профиля поменять).
enum TeachFlow {
    /// Похоже на одноразовый код, а не на пароль: 4–8 цифр.
    static func looksLikeCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return (4...8).contains(t.count) && t.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Что предложить про пароль. «Новый пароль», похожий на одноразовый
    /// код, не предлагается ни сохранить, ни тем более обновить: это почти
    /// наверняка код, введённый в поле type=password.
    static func passwordOffer(recorded: String?, stored: String, source: String) -> TeachDialog.PasswordOffer {
        guard let pw = recorded, !pw.isEmpty else { return .none }
        switch source {
        case "keepassxc": return .elsewhere("KeePassXC")
        case "command": return .elsewhere("команды PasswordCommand")
        default: break
        }
        if looksLikeCode(pw) { return .none }
        if source == "ask" { return .askToKeychain }
        return stored.isEmpty ? .save : (stored == pw ? .none : .update)
    }

    static func finish(recorder rec: TeachRecorder, outFile: String, portal: String) {
        let env = ProcessInfo.processInfo.environment
        let user = env["OCBAR_USERNAME"] ?? ""
        let service = env["OCBAR_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 } ?? "ru.ocbar.client"
        let pwSource = env["OCBAR_PASSWORD_SOURCE"] ?? "keychain"
        let stored = env["OCBAR_PASSWORD"] ?? ""
        let totpSource = env["OCBAR_TOTP_SOURCE"] ?? "keychain"

        if let pw = rec.password, looksLikeCode(pw) {
            Log.info("записанный «пароль» похож на одноразовый код — сохранить или обновить пароль не предлагаю")
        }
        let offer = passwordOffer(recorded: rec.password, stored: stored, source: pwSource)
        let offerCode = rec.code != nil && !rec.engineFilledCode && totpSource != "sms"
        let dialog = TeachDialog(.init(profile: env["OCBAR_PROFILE_NAME"] ?? "профиль", summary: rec.summary(),
                                       manualCount: rec.manualCount, passwordOffer: offer, offerCode: offerCode,
                                       code: rec.code, codeAt: rec.codeAt))
        var result: [String: String] = ["rules": "", "totp": "", "password": ""]
        if let o = dialog.run() {
            if o.saveRules { result["rules"] = rec.rulesText(portal: portal) }
            if o.savePassword, let pw = rec.password {
                if KeychainWriter.save(service: service, account: user, label: "ocbar-VPN-password", secret: pw) {
                    Log.info("пароль сохранён в связке ключей (\(service) / \(user)) и прочитан обратно")
                    if pwSource == "ask" { result["password"] = "keychain" }
                } else {
                    Log.error("пароль в связку ключей не сохранился")
                }
            }
            switch o.codeMode {
            case 1:
                if let s = o.secret,
                   KeychainWriter.save(service: service, account: "totp/\(user)", label: "ocbar-TOTP", secret: s) {
                    Log.info("секрет TOTP проверен по введённому коду и сохранён (\(service) / totp/\(user)), \(o.params.label)")
                    result["totp"] = "keychain"
                    result["totp_algorithm"] = o.params.algorithm
                    result["totp_digits"] = String(o.params.digits)
                    result["totp_period"] = String(o.params.period)
                } else {
                    Log.error("секрет TOTP не сохранился")
                }
            case 2:
                result["totp"] = "sms"
            default: break
            }
        }
        rec.forgetSecrets()
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(to: URL(fileURLWithPath: outFile))
        }
    }
}
