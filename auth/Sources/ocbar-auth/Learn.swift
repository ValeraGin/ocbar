import AppKit
import WebKit
import Foundation

/// Режим обучения: человек показывает мышью, где на его портале поле логина,
/// поле пароля, поле кода и кнопка входа, — а мы записываем это правилами
/// автозаполнения (секция [Autofill] профиля или файл правил).
///
/// Зачем: форма провайдера входа у каждой компании своя, а встроенный набор
/// правил покрывает только типовые (Keycloak, Microsoft). Разметить свой
/// портал мышью — единственный способ обойтись без чтения чужого HTML.
///
/// Форма бывает в несколько окон: сначала логин и пароль, потом отдельно
/// код. Отметки помнят, на каком окне сделаны (шаг), а кнопка «Пройти шаг»
/// заполняет отмеченное настоящими данными из профиля и нажимает отмеченную
/// кнопку — так человек доходит до следующего окна, ничего не вводя руками.
/// Правила пишутся блоками по шагам. Движок входа от шагов не зависит: он на
/// каждой загрузке страницы заполняет то, что видно, — заголовки шагов нужны
/// человеку, чтобы видеть, какое окно что заполняет.
///
/// Сессия окна намеренно НЕ сохраняется (`nonPersistent`): с живой сессией
/// провайдер проводит молча, и размечать становится нечего. Заодно разметка
/// не трогает рабочую сессию входа.
final class LearnSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {

    /// Скрипт разметки живёт в отдельном мире WebKit, как запись входа
    /// (TeachRecorder): DOM общий со страницей, а переменные, функции
    /// `__ocbar*` и обработчик сообщений — свои. Раньше всё это было в мире
    /// страницы, и портал мог сам прислать «отметку» или подменить
    /// предзаполнение.
    static let world = WKContentWorld.world(name: "ocbar-learn")

    /// Выполнить в мире разметки; результат — как у evaluateJavaScript.
    static func eval(_ webView: WKWebView?, _ js: String, _ cb: ((Any?, Error?) -> Void)? = nil) {
        webView?.evaluateJavaScript(js, in: nil, in: world) { r in
            switch r {
            case .success(let v): cb?(v, nil)
            case .failure(let e): cb?(nil, e)
            }
        }
    }

    /// Страница для заголовка шага: хост и путь в закодированном виде —
    /// `%0A` в адресе остаётся тремя символами, а не переводом строки.
    static func pageLabel(_ u: URL) -> String {
        (u.host ?? "") + u.path(percentEncoded: true)
    }

    /// Строка для комментария в файле правил: без управляющих символов и
    /// разделителей строк. Иначе перевод строки в адресе страницы разрывал
    /// комментарий, и остаток становился настоящим правилом.
    static func commentSafe(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { sc in
            !(sc.properties.generalCategory == .control || sc.value == 0x2028 || sc.value == 0x2029 || sc.value == 0x85)
        }))
    }

    struct Mark {
        let kind: String        // username | password | totp | click | stop
        let selector: String
        let hint: String        // что это было на странице — для строки состояния
        var step: Int = 1       // окно формы, на котором отмечено
        var why: String? = nil  // предзаполнено: почему; nil — отметил человек
    }

    /// Что размечаем сейчас. Порядок кнопок — порядок обычной формы входа.
    private static let kinds: [(id: String, title: String, hint: String)] = [
        ("auto",     "Авто",   "Щёлкайте по полям и кнопке — вид определится сам; щелчок по отмеченному снимает отметку."),
        ("username", "Логин",  "Щёлкните по полю, куда вводится логин"),
        ("password", "Пароль", "Щёлкните по полю пароля"),
        ("totp",     "Код",    "Щёлкните по полю одноразового кода"),
        ("click",    "Кнопка", "Щёлкните по кнопке, которая отправляет это окно формы; на окне без полей её будут жать всегда"),
        ("click!",   "Всегда", "Щёлкните по кнопке, которую жать всегда: «Остаться в системе?», «Другой способ входа». Пока на странице пустое поле из правил, не жмётся и она"),
        ("stop",     "Ошибка", "Щёлкните по строке, где показывается ошибка входа — увидев её, автозаполнение остановится"),
    ]

    private let startURL: URL
    private let outFile: String?
    private let done: (Int32) -> Void
    // Чем заполнять по кнопке «Пройти шаг»: те же источники, что у настоящего
    // входа (ocbar learn кладёт их в окружение). Код берётся в момент
    // нажатия — он живёт тридцать секунд, а размечают минутами.
    private let creds: Credentials
    private let totpSecret: String?
    private let totpCode: String?
    private let totpCommand: String?

    private var window: NSWindow!
    private var webView: WKWebView!
    private var kindPicker: NSSegmentedControl!
    private var modeButton: NSButton!
    private var status: NSTextField!
    private var collected: NSTextField!
    private var stepLabel: NSTextField!
    private var passButton: NSButton!
    private var marks: [Mark] = []
    private var step = 1
    private var pages: [Int: String] = [:]   // шаг → хост и путь страницы, где его отмечали
    private var marking = true
    private var kind = "auto"
    private var finished = false
    private var lastHost: String?      // где реально показалась форма: там же живёт IdP

    init(startURL: URL, outFile: String?, creds: Credentials = Credentials(),
         totpSecret: String? = nil, totpCode: String? = nil, totpCommand: String? = nil,
         completion: @escaping (Int32) -> Void) {
        self.startURL = startURL
        self.outFile = outFile
        self.creds = creds
        self.totpSecret = totpSecret
        self.totpCode = totpCode
        self.totpCommand = totpCommand
        self.done = completion
        super.init()
    }

    // MARK: - окно

    func start() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(self, contentWorld: Self.world, name: "ocbarLearn")
        controller.addUserScript(WKUserScript(source: Self.js, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
        cfg.userContentController = controller

        let width: CGFloat = 720, webHeight: CGFloat = 700, barHeight: CGFloat = 104
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: webHeight), configuration: cfg)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]

        kindPicker = NSSegmentedControl(labels: Self.kinds.map(\.title), trackingMode: .selectOne,
                                        target: self, action: #selector(kindChanged))
        kindPicker.selectedSegment = 0
        kindPicker.frame = NSRect(x: 10, y: webHeight + 74, width: 500, height: 24)

        modeButton = NSButton(checkboxWithTitle: "Отмечать элементы", target: self, action: #selector(modeChanged))
        modeButton.state = .on
        modeButton.frame = NSRect(x: 520, y: webHeight + 76, width: 170, height: 20)
        modeButton.toolTip = "Выключите, чтобы пользоваться страницей обычным образом: нажать «Далее», закрыть баннер, выбрать другой способ входа."

        status = NSTextField(labelWithString: Self.kinds[0].hint)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.frame = NSRect(x: 12, y: webHeight + 52, width: width - 24, height: 16)
        status.autoresizingMask = [.width]

        collected = NSTextField(labelWithString: "отмечено: ничего")
        collected.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        collected.textColor = .tertiaryLabelColor
        collected.lineBreakMode = .byTruncatingTail
        collected.frame = NSRect(x: 12, y: webHeight + 32, width: width - 24, height: 14)
        collected.autoresizingMask = [.width]

        stepLabel = NSTextField(labelWithString: "шаг 1")
        stepLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stepLabel.frame = NSRect(x: 12, y: webHeight + 9, width: 150, height: 16)
        stepLabel.toolTip = "Окно формы, которое размечается сейчас. Новая страница после отмеченного окна — следующий шаг."

        passButton = NSButton(title: "Пройти шаг →", target: self, action: #selector(passStep))
        passButton.bezelStyle = .rounded
        passButton.font = .systemFont(ofSize: 11)
        passButton.frame = NSRect(x: width - 480, y: webHeight + 6, width: 130, height: 22)
        passButton.autoresizingMask = [.minXMargin]
        passButton.toolTip = "Заполнить отмеченные на этом шаге поля вашими данными из профиля и нажать отмеченную кнопку — форма перейдёт к следующему окну"

        let verify = NSButton(title: "Проверить", target: self, action: #selector(checkRules))
        verify.bezelStyle = .rounded
        verify.font = .systemFont(ofSize: 11)
        verify.frame = NSRect(x: width - 344, y: webHeight + 6, width: 86, height: 22)
        verify.autoresizingMask = [.minXMargin]
        verify.toolTip = "Найти отметки этого шага на странице: правило без элемента не сработает"

        let undo = NSButton(title: "Убрать последнее", target: self, action: #selector(undoLast))
        undo.bezelStyle = .rounded
        undo.font = .systemFont(ofSize: 11)
        undo.frame = NSRect(x: width - 252, y: webHeight + 6, width: 134, height: 22)
        undo.autoresizingMask = [.minXMargin]

        let finish = NSButton(title: "Готово", target: self, action: #selector(finishAndSave))
        finish.bezelStyle = .rounded
        finish.keyEquivalent = "\r"
        finish.font = .systemFont(ofSize: 11)
        finish.frame = NSRect(x: width - 110, y: webHeight + 6, width: 100, height: 22)
        finish.autoresizingMask = [.minXMargin]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: webHeight + barHeight))
        content.addSubview(webView)
        [kindPicker, modeButton, status, collected, stepLabel, passButton, verify, undo, finish]
            .forEach { content.addSubview($0!) }

        window = NSWindow(contentRect: content.frame,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "ocbar — разметка формы входа"
        window.contentView = content
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: startURL))
        Log.info("разметка: открыл \(Log.redact(startURL))")
        Log.debug("номер окна: \(window.windowNumber)")
    }

    // MARK: - действия панели

    @objc private func kindChanged() {
        let i = max(0, kindPicker.selectedSegment)
        kind = Self.kinds[i].id
        status.stringValue = Self.kinds[i].hint
        applyState()
    }

    @objc private func modeChanged() {
        marking = modeButton.state == .on
        status.stringValue = marking
            ? Self.kinds.first { $0.id == kind }?.hint ?? ""
            : "Обычная работа: страница ведёт себя как всегда. Включите галочку, когда дойдёте до нужного поля."
        applyState()
    }

    @objc private func undoLast() {
        guard !marks.isEmpty else { return }
        let removed = marks.removeLast()
        status.stringValue = "убрано: \(removed.selector)"
        refreshCollected()
    }

    /// Правило, которое ничего не находит на странице, не сработает и на
    /// живом входе. Проверка отвечает на это сразу, а не через неделю, когда
    /// автозаполнение промолчит. Смотрим только отметки текущего окна: поле
    /// кода на странице с паролем и не должно находиться.
    @objc private func checkRules() {
        let here = marks.filter { $0.step == step }
        guard !here.isEmpty else {
            status.stringValue = marks.isEmpty
                ? "проверять нечего: ничего не отмечено"
                : "на шаге \(displayNumber(step)) ещё ничего не отмечено (всего отметок: \(marks.count))"
            return
        }
        Self.eval(webView, Self.checkScript(for: here.map { $0.selector })) { [weak self] value, _ in
            guard let self, let codes = value as? [Int], codes.count == here.count else {
                self?.status.stringValue = "проверка не удалась"
                return
            }
            var parts: [String] = []
            for (mark, code) in zip(here, codes) {
                let name = self.title(for: mark.kind)
                switch code {
                case 2: parts.append(name + " ✓")
                case 1: parts.append(name + " есть, но скрыт")
                case 0: parts.append(name + " ✗")
                default: parts.append(name + ": селектор не разобрался")
                }
            }
            let others = self.marks.count - here.count
            self.status.stringValue = "шаг \(self.displayNumber(self.step)), на этой странице: " + parts.joined(separator: ", ")
                + (others > 0 ? " · на других шагах ещё \(others)" : "")
        }
    }

    /// «Пройти шаг»: заполнить отмеченные на этом окне поля настоящими
    /// данными и нажать отмеченную кнопку. Без этого до окна с кодом
    /// приходилось добираться, выключив разметку и введя пароль руками.
    @objc private func passStep() {
        let here = marks.filter { $0.step == step }
        guard here.contains(where: { $0.kind == "click" || $0.kind == "click!" }) else {
            status.stringValue = here.isEmpty
                ? "на этом шаге ничего не отмечено: отметьте поля и кнопку, которая ведёт дальше"
                : "отметьте кнопку, которая отправляет это окно, — без неё идти дальше нечем"
            return
        }
        passButton.isEnabled = false
        status.stringValue = "заполняю и нажимаю…"
        let needCode = here.contains { $0.kind == "totp" }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let code = needCode ? self.currentCode() : nil
            DispatchQueue.main.async { self.runPass(here, code: code) }
        }
    }

    private func runPass(_ here: [Mark], code: String?) {
        let fills: [(kind: String, selector: String, value: String?)] = here
            .filter { ["username", "password", "totp"].contains($0.kind) }
            .map { m in
                let v: String?
                switch m.kind {
                case "username": v = creds.username
                case "password": v = creds.password
                default: v = code
                }
                return (m.kind, m.selector, (v?.isEmpty ?? true) ? nil : v)
            }
        let clicks = here.filter { $0.kind == "click" || $0.kind == "click!" }.map(\.selector)
        // Щелчок программы — тоже щелчок: пока разметка включена, страница
        // перехватит его и запишет как отметку. Выключаем на время нажатия.
        let js = "window.__ocbarSet(false, \(Self.jsString(kind))); " + Self.passScript(fills: fills, clicks: clicks)
        Self.eval(webView, js) { [weak self] value, error in
            guard let self else { return }
            self.passButton.isEnabled = true
            let dict = value as? [String: Any] ?? [:]
            if let missing = dict["missing"] as? [String], !missing.isEmpty {
                self.applyState()
                self.status.stringValue = "нечем заполнить: " + missing.map { self.title(for: $0) }.joined(separator: ", ")
                    + " — введите в поле сами и нажмите «Пройти шаг» ещё раз"
                return
            }
            if dict["clicked"] is String {
                let passed = self.displayNumber(self.step)
                self.step += 1
                Log.info("разметка: шаг \(passed) пройден")
                self.refreshCollected()
                self.status.stringValue = "шаг \(passed) пройден — отмечайте поля и кнопку следующего окна. Всё? — «Готово»"
                // Одностраничные формы меняют окно без перехода: включаем
                // разметку обратно сами, не дожидаясь загрузки страницы.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.applyState() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.prefill() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.prefill() }
                return
            }
            self.applyState()
            self.status.stringValue = dict["noButton"] != nil
                ? "отмеченная кнопка на странице не видна — отметьте ту, что видна сейчас"
                : "не получилось: " + (error.map { $0.localizedDescription } ?? "страница не ответила")
        }
    }

    /// Код в момент нажатия: секрет из связки ключей, команда клиента
    /// (KeePassXC или свой источник) или готовый код, если дали только его.
    private func currentCode() -> String? {
        if let s = totpSecret, !s.isEmpty { return TOTP.code(secretBase32: s, params: TOTPParams.fromEnvironment()) }
        if let cmd = totpCommand, !cmd.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let first = String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
            let digits = first.trimmingCharacters(in: .whitespaces)
            return (6...8).contains(digits.count) && digits.allSatisfy(\.isNumber) ? digits : nil
        }
        if let c = totpCode, !c.isEmpty { return c }
        return nil
    }

    @objc private func finishAndSave() {
        guard !finished else { return }
        let text = rulesText()
        if let path = outFile {
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                // Прошлые правила не затираем молча: чинить форму приходится
                // на живом входе, и откатиться должно быть куда.
                try? fm.removeItem(atPath: path + ".bak")
                try? fm.copyItem(atPath: path, toPath: path + ".bak")
            }
            do {
                try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try text.write(toFile: path, atomically: true, encoding: .utf8)
                Log.info("правила записаны: \(path)")
            } catch {
                Log.error("не удалось записать \(path): \(error)")
                complete(1)
                return
            }
        }
        FileHandle.standardOutput.write(Data(text.utf8))
        complete(marks.isEmpty ? 3 : 0)
    }

    func windowWillClose(_ notification: Notification) {
        // Закрытое окно без «Готово» — отказ: ничего не пишем.
        if !finished { Log.info("разметка отменена (окно закрыто)"); complete(3) }
    }

    private func complete(_ code: Int32) {
        guard !finished else { return }
        finished = true
        window?.orderOut(nil)
        done(code)
    }

    // MARK: - приём отметок из страницы

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.world == Self.world else { return }
        guard let body = message.body as? [String: Any],
              let selector = body["selector"] as? String, !selector.isEmpty else {
            status.stringValue = "не удалось составить селектор — попробуйте щёлкнуть по самому полю"
            return
        }
        // Второй заслон для корня страницы: правило на html или body
        // срабатывало бы на любой странице.
        if ["html", "body"].contains(selector.lowercased()) {
            status.stringValue = "щелчок мимо элементов — отметьте само поле или кнопку"
            return
        }
        let hint = (body["hint"] as? String) ?? ""
        // В режиме «Авто» вид определяет сама страница: она видит тип поля,
        // autocomplete, maxlength и имя. Шаги «сначала логин, потом пароль»
        // оказались хуже — человек щёлкает по тому полю, которое видит, а не
        // по тому, которое ждёт мастер.
        let guessed = (body["guess"] as? String) ?? "username"
        let what = kind == "auto" ? guessed : kind
        // Щелчок по уже отмеченному на этом окне снимает отметку — так же
        // снимается и предзаполненное. Если слева выбран другой вид — вид
        // меняется, а не снимается.
        if let i = marks.firstIndex(where: { $0.selector == selector && $0.step == step }) {
            let old = marks[i]
            if kind != "auto" && old.kind != kind {
                if !["click", "click!", "stop"].contains(kind) {
                    marks.removeAll { $0.kind == kind && $0.step == step && $0.selector != selector }
                }
                if let j = marks.firstIndex(where: { $0.selector == selector && $0.step == step }) {
                    marks[j] = Mark(kind: kind, selector: selector, hint: hint, step: step)
                }
                status.stringValue = "теперь \(title(for: kind)): \(selector)"
            } else {
                marks.remove(at: i)
                status.stringValue = "снято: \(title(for: old.kind)) \(selector)"
            }
            refreshCollected()
            return
        }
        // Логин, пароль и код — по одному на окно формы: второе правило того
        // же вида на том же окне молча перебило бы первое. На разных окнах
        // одинаковые виды законны.
        if !["click", "click!", "stop"].contains(what) {
            marks.removeAll { $0.kind == what && $0.step == step }
        }
        marks.append(Mark(kind: what, selector: selector, hint: hint, step: step))
        if pages[step] == nil, let u = webView.url { pages[step] = Self.pageLabel(u) }
        status.stringValue = kind == "auto"
            ? "распознано как \(title(for: what)): \(selector) — не то? выберите вид слева и щёлкните ещё раз"
            : "отмечено \(title(for: what)): \(selector)"
        refreshCollected()
        if what == "username" || what == "password" || what == "totp" {
            // Поле сразу получает фокус: дальше человек просто печатает, не
            // выключая разметку.
            Self.eval(webView, "window.__ocbarFocus(\(Self.jsString(selector))); 0")
        }
    }

    private func title(for id: String) -> String {
        Self.kinds.first { $0.id == id }?.title.lowercased() ?? id
    }

    /// Номер шага, как его увидит человек и как он ляжет в файл: пустые шаги
    /// (страницу перезагрузили, отметки убрали) не считаются.
    private func displayNumber(_ s: Int) -> Int {
        Set(marks.filter { $0.kind != "stop" && $0.step < s }.map(\.step)).count + 1
    }

    private func refreshCollected() {
        stepLabel?.stringValue = "шаг \(displayNumber(step))"
        guard !marks.isEmpty else { collected.stringValue = "отмечено: ничего"; return }
        let stops = marks.filter { $0.kind == "stop" }.map { "ошибка=\($0.selector)" }
        let steps = Array(Set(marks.filter { $0.kind != "stop" }.map(\.step))).sorted()
        let groups = steps.map { s -> String in
            let items = marks.filter { $0.step == s && $0.kind != "stop" }
                .map { "\(title(for: Self.effectiveKind($0, in: marks)))\($0.why == nil ? "" : "*")=\($0.selector)" }
                .joined(separator: ", ")
            return (steps.count > 1 ? "шаг \(displayNumber(s)): " : "") + items
        }
        collected.stringValue = (stops + groups).joined(separator: " · ")
        showMarks()
    }

    /// Отметки текущего окна обводятся на странице: предзаполненное видно
    /// сразу, и понятно, по чему щёлкнуть, чтобы снять.
    private func showMarks() {
        let sels = marks.filter { $0.step == step }.map(\.selector)
        let json = String(data: (try? JSONSerialization.data(withJSONObject: sels)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        Self.eval(webView, "window.__ocbarShowMarks && window.__ocbarShowMarks(\(json)); 0")
    }

    /// Предзаполнение: на новом окне формы отметить то, что узнаётся без
    /// человека (__ocbarPrefill в скрипте страницы), — с причиной у каждой
    /// отметки. Только если на этом окне ещё ничего не отмечено: отметки
    /// человека не перекрываются.
    private func prefill() {
        guard !finished, !marks.contains(where: { $0.step == step }) else { return }
        Self.eval(webView, "JSON.stringify(window.__ocbarPrefill ? window.__ocbarPrefill() : [])") { [weak self] v, _ in
            guard let self, !self.marks.contains(where: { $0.step == self.step }),
                  let text = v as? String,
                  let arr = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: String]],
                  !arr.isEmpty else { return }
            var added: [String] = []
            for f in arr {
                guard let k = f["kind"], let sel = f["selector"], !sel.isEmpty,
                      !["html", "body"].contains(sel.lowercased()) else { continue }
                self.marks.append(Mark(kind: k, selector: sel, hint: "", step: self.step, why: f["why"]))
                added.append("\(self.title(for: k)) (\(f["why"] ?? ""))")
            }
            guard !added.isEmpty else { return }
            if self.pages[self.step] == nil, let u = self.webView.url { self.pages[self.step] = Self.pageLabel(u) }
            Log.info("разметка: предзаполнено на шаге \(self.displayNumber(self.step)): " + added.joined(separator: ", "))
            self.refreshCollected()
            self.status.stringValue = "предзаполнено*: " + added.joined(separator: ", ")
                + " — проверьте; лишнее снимите щелчком по нему"
        }
    }

    /// Форма часто строится скриптом уже после загрузки страницы — пробуем
    /// дважды; вторая попытка ничего не делает, если первая что-то нашла.
    private func schedulePrefill() {
        for delay in [0.8, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.prefill() }
        }
    }

    private func applyState() {
        Self.eval(webView, "window.__ocbarSet(\(marking ? "true" : "false"), \(Self.jsString(kind))); 0")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyState()
        if let host = webView.url?.host {
            lastHost = host
            window.title = "ocbar — разметка формы входа · \(host)"
        }
        // Новая страница после отмеченного окна — следующее окно формы: так
        // шаги различаются и тогда, когда человек прошёл окно сам, руками.
        if marks.contains(where: { $0.step == step }) {
            step += 1
            status.stringValue = "новое окно формы — шаг \(displayNumber(step)): отмечайте его поля и кнопку. Всё? — «Готово»"
        }
        refreshCollected()
        schedulePrefill()
    }

    // MARK: - результат

    func rulesText() -> String {
        Self.rulesText(marks: marks, pages: pages, portal: startURL.host ?? startURL.absoluteString,
                       formHost: lastHost ?? startURL.host)
    }

    /// Правила в том порядке, в каком их читает автозаполнение: сначала
    /// `stop` (иначе пароль уедет в форму с ошибкой), потом окна формы по
    /// очереди — в каждом поля, потом кнопка. Если окон несколько, у каждого
    /// заголовок «# шаг N — страница»; пустые шаги пропускаются.
    static func rulesText(marks: [Mark], pages: [Int: String], portal: String,
                          formHost: String?, date: Date = Date()) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let portal = commentSafe(portal)
        let formHost = formHost.map(commentSafe)
        let pages = pages.mapValues(commentSafe)
        var out = "# Правила автозаполнения формы входа, размечены вручную \(df.string(from: date)).\n"
        out += "# Портал: \(portal)\n"
        out += "# Формат и остальные возможности — etc/autofill.rules.example.\n"
        out += "# Проверить, что получится: ocbar-auth --dump-script --rules <этот файл>\n"
        if let host = formHost {
            out += "#\n# Форма входа живёт на " + host + ". Чтобы заполнять только там,\n"
            out += "# добавьте в профиль:  IdpHosts = " + host + "\n"
        }
        out += "\n"
        if marks.isEmpty { return out + "# Ничего не отмечено.\n" }
        for m in marks where m.kind == "stop" { out += "stop  \(m.selector)\n" }
        let steps = Array(Set(marks.filter { $0.kind != "stop" }.map(\.step))).sorted()
        for (i, s) in steps.enumerated() {
            if steps.count > 1 { out += "# шаг \(i + 1)" + (pages[s].map { " — " + $0 } ?? "") + "\n" }
            for what in ["username", "password", "totp", "manual"] {
                for m in marks where m.step == s && m.kind == what { out += "fill  \(what) \(m.selector)\n" }
            }
            for m in marks where m.step == s && (m.kind == "click" || m.kind == "click!") {
                out += (effectiveKind(m, in: marks) == "click!" ? "click! " : "click ") + m.selector + "\n"
            }
        }
        return out
    }

    /// Какой кнопкой отметка станет в правилах. Обычная кнопка жмётся, только
    /// если на странице что-то заполнили; на окне, где не отмечено ни одного
    /// поля, она не сработала бы никогда — значит, это экран без полей
    /// («Остаться в системе?») и жать её надо всегда. Это следует из правил
    /// движка, а не из догадки. Движок всё равно не нажмёт её, пока на
    /// странице видно пустое поле из правил.
    static func effectiveKind(_ m: Mark, in marks: [Mark]) -> String {
        guard m.kind == "click" else { return m.kind }
        let hasFields = marks.contains { $0.step == m.step && ["username", "password", "totp", "manual"].contains($0.kind) }
        return hasFields ? "click" : "click!"
    }

    /// Скрипт «Пройти шаг»: заполнить видимые пустые поля шага и нажать
    /// первую видимую отмеченную кнопку. Поле, которое пусто и заполнить
    /// нечем, возвращается в missing — и кнопка тогда не жмётся: отправить
    /// форму с пустым паролем значит получить ошибку входа.
    static func passScript(fills: [(kind: String, selector: String, value: String?)], clicks: [String]) -> String {
        let f: [[String: Any]] = fills.map { ["kind": $0.kind, "sel": $0.selector, "value": $0.value.map { $0 as Any } ?? NSNull()] }
        let fj = String(data: (try? JSONSerialization.data(withJSONObject: f)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let cj = String(data: (try? JSONSerialization.data(withJSONObject: clicks)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        return """
        (function (fills, clicks) {
          var visible = function (e) { return e && e.offsetParent !== null; };
          var missing = [], filled = [];
          fills.forEach(function (f) {
            var e; try { e = document.querySelector(f.sel); } catch (x) { return; }
            if (!visible(e) || e.value) return;
            if (f.value === null) { missing.push(f.kind); return; }
            var setter = Object.getOwnPropertyDescriptor(e.constructor.prototype, 'value').set;
            setter.call(e, f.value);
            e.dispatchEvent(new Event('input', {bubbles: true}));
            e.dispatchEvent(new Event('change', {bubbles: true}));
            filled.push(f.kind);
          });
          if (missing.length) return {missing: missing, filled: filled};
          for (var i = 0; i < clicks.length; i++) {
            var b; try { b = document.querySelector(clicks[i]); } catch (x) { continue; }
            if (visible(b)) { b.click(); return {clicked: clicks[i], filled: filled}; }
          }
          return {noButton: true, filled: filled};
        })(\(fj), \(cj))
        """
    }

    private static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = String(data: data, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())
    }

    // MARK: - скрипт страницы

    /// Подсветка под курсором и перехват щелчка. Щелчок в режиме разметки
    /// НЕ доходит до страницы: иначе отметка кнопки «Войти» её же и нажала бы.
    static var pageScript: String { js }

    /// Скрипт проверки: для каждого селектора 2 — виден, 1 — есть, но скрыт,
    /// 0 — не найден, -1 — селектор не разобрался. Отдельной функцией, чтобы
    /// проверка (--learn-selftest) гоняла ровно тот же код, что и кнопка.
    static func checkScript(for selectors: [String]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: selectors)) ?? Data("[]".utf8)
        let array = String(data: json, encoding: .utf8) ?? "[]"
        return "(function(sels){ return sels.map(function(s){"
            + " try { var e = document.querySelector(s); return e ? (e.offsetParent !== null ? 2 : 1) : 0; }"
            + " catch (err) { return -1; } }); })(" + array + ")"
    }
    static func js(_ s: String) -> String { jsString(s) }

    /// Составление селектора по элементу — общее для разметки и для записи
    /// при входе (TeachRecorder): правило, записанное любым путём, выглядит
    /// одинаково.
    static let selectorJS = """
      function safeValue(v) {
        if (v === null || v === undefined || v === '') return null;
        return /^[A-Za-z0-9_:.-]+$/.test(v) ? v : "'" + String(v).replace(/'/g, "") + "'";
      }
      function attrSel(el, name, raw) {
        var v = safeValue(raw);
        return v ? el.tagName.toLowerCase() + '[' + name + '=' + v + ']' : null;
      }
      function unique(sel, el) {
        try { var l = document.querySelectorAll(sel); return l.length === 1 && l[0] === el; }
        catch (e) { return false; }
      }
      function path(el) {
        var parts = [];
        while (el && el.nodeType === 1 && parts.length < 4) {
          var p = el.tagName.toLowerCase();
          if (el.id && /^[A-Za-z0-9_:.-]+$/.test(el.id)) { parts.unshift(p + '[id=' + el.id + ']'); break; }
          var parent = el.parentElement;
          if (parent) {
            var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
            if (same.length > 1) p += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
          }
          parts.unshift(p);
          el = el.parentElement;
        }
        return parts.join('>');
      }
      // Селектор без пробелов: файл правил разбирается по пробелам, и
      // «div .error» развалилось бы на два поля.
      function selectorFor(el) {
        var cands = [];
        cands.push(attrSel(el, 'id', el.id));
        cands.push(attrSel(el, 'name', el.getAttribute && el.getAttribute('name')));
        cands.push(attrSel(el, 'autocomplete', el.getAttribute && el.getAttribute('autocomplete')));
        cands.push(attrSel(el, 'data-testid', el.getAttribute && el.getAttribute('data-testid')));
        cands.push(attrSel(el, 'type', el.getAttribute && el.getAttribute('type')));
        if (el.classList && el.classList.length) {
          for (var c = 0; c < el.classList.length && c < 3; c++) {
            if (/^[A-Za-z0-9_-]+$/.test(el.classList[c]))
              cands.push(el.tagName.toLowerCase() + '.' + el.classList[c]);
          }
        }
        for (var i = 0; i < cands.length; i++) if (cands[i] && unique(cands[i], el)) return cands[i];
        // Ничего однозначного — берём то, что хотя бы попадает в этот элемент
        // первым: правило проверяет видимость, и это чаще всего верно.
        for (var j = 0; j < cands.length; j++) {
          if (!cands[j]) continue;
          try { if (document.querySelector(cands[j]) === el) return cands[j]; } catch (e) {}
        }
        var p = path(el);
        return unique(p, el) ? p : p;
      }

    """

    private static let js = """
    (function () {
      if (window.__ocbarLearnReady) return;
      window.__ocbarLearnReady = true;
      var marking = true, kind = 'username';
      var box = document.createElement('div');
      box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #2f6bbf;' +
                          'background:rgba(47,107,191,.12);border-radius:3px;display:none';
      var tip = document.createElement('div');
      tip.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;display:none;' +
                          'font:11px -apple-system,sans-serif;background:#2f6bbf;color:#fff;padding:1px 5px;border-radius:3px';
      document.documentElement.appendChild(box);
      document.documentElement.appendChild(tip);

      function target(el) {
        if (!el || el.nodeType !== 1) return el;
        if (kind === 'username' || kind === 'password' || kind === 'totp')
          return el.closest('input,textarea') || el;
        if (kind === 'click' || kind === 'click!')
          return el.closest('button,a,input,[role=button],[type=submit]') || el;
        if (kind === 'auto')
          return el.closest('input,textarea,button,a,[role=button],[type=submit]') || el;
        return el;
      }

      // Что это за элемент. Страница знает про него больше, чем человек
      // помнит про шаги мастера: тип поля, autocomplete, длину, имя.
      function guessKind(el) {
        var tag = (el.tagName || '').toLowerCase();
        var type = ((el.getAttribute && el.getAttribute('type')) || '').toLowerCase();
        if (tag === 'input' && type === 'password') return 'password';
        if (tag === 'button' || tag === 'a' || type === 'submit' || type === 'button' ||
            (el.getAttribute && el.getAttribute('role') === 'button')) return 'click';
        if (tag === 'input' || tag === 'textarea') {
          var ac = ((el.getAttribute && el.getAttribute('autocomplete')) || '').toLowerCase();
          var name = ((el.getAttribute && el.getAttribute('name')) || '') + ' ' + (el.id || '');
          var len = parseInt((el.getAttribute && el.getAttribute('maxlength')) || '0', 10);
          if (ac === 'one-time-code' || /otp|otc|totp|one.?time|код|pin|token/i.test(name) ||
              (type === 'tel' && len > 0 && len <= 8)) return 'totp';
          return 'username';
        }
        return 'stop';
      }

    \(LearnSession.selectorJS)
      function place(el) {
        // Страницу целиком не подсвечиваем: у края окна ближайшим предком
        // оказывается body, и мигающая рамка вокруг всего лишь мешает.
        if (el === document.body || el === document.documentElement) { hide(); return; }
        var r = el.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
        box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
        tip.style.display = 'block';
        tip.style.left = r.left + 'px';
        tip.style.top = Math.max(0, r.top - 16) + 'px';
        tip.textContent = selectorFor(el);
      }
      function hide() { box.style.display = 'none'; tip.style.display = 'none'; }

      document.addEventListener('mousemove', function (e) {
        if (!marking) { hide(); return; }
        var el = target(e.target);
        if (el && el.nodeType === 1) place(el); else hide();
      }, true);

      // Только настоящий щелчок: синтетическое событие страница может
      // создать сама и так поставить отметку. __ocbarTrustSynthetic — для
      // --learn-selftest; живёт в изолированном мире, страница его не видит.
      window.__ocbarTrustSynthetic = false;
      document.addEventListener('click', function (e) {
        if (!marking) return;
        if (!e.isTrusted && !window.__ocbarTrustSynthetic) return;
        e.preventDefault(); e.stopPropagation();
        var el = target(e.target);
        if (!el || el.nodeType !== 1) return;
        // Пустое место страницы — не элемент формы: «stop html» остановил бы
        // автозаполнение везде, html виден всегда.
        if (el === document.body || el === document.documentElement) return;
        window.webkit.messageHandlers.ocbarLearn.postMessage({
          selector: selectorFor(el),
          guess: guessKind(el),
          hint: (el.tagName || '') + ' ' + ((el.getAttribute && el.getAttribute('type')) || '')
        });
      }, true);

      // Предзаполнение разметки: что узнаётся без человека, по убыванию
      // надёжности, у каждой отметки — почему. Только видимые поля.
      //   1) токены autocomplete из стандарта HTML: username, current-password, one-time-code;
      //   2) единственное видимое поле type=password;
      //   3) поле кода по имени или цифровое поле длиной 4–8 — это догадка;
      //   4) логин — ближайшее текстовое поле перед паролем в той же форме
      //      (так логин находят менеджеры паролей в браузерах);
      //   5) кнопка — кнопка формы по умолчанию: её по стандарту жмёт Enter.
      // Два поля пароля — пароль не угадывается; нет формы — кнопка тоже.
      function visibleEl(e) { return e && e.offsetParent !== null; }
      function typeOf(e) { return ((e.getAttribute('type') || 'text')).toLowerCase(); }
      function acTokens(e) {
        return (e.getAttribute('autocomplete') || '').toLowerCase().split(' ').filter(function (t) { return t; });
      }
      function otpLike(e) {
        var n = (e.getAttribute('name') || '') + ' ' + (e.id || '');
        if (/otp|totp|otc|one.?time|2fa|mfa|verif/i.test(n)) return true;
        var mode = (e.getAttribute('inputmode') || '').toLowerCase();
        var len = parseInt(e.getAttribute('maxlength') || '0', 10);
        return (typeOf(e) === 'tel' || mode === 'numeric') && len >= 4 && len <= 8;
      }
      function defaultButton(form) {
        if (!form) return null;
        var b = form.querySelector('button:not([type]),button[type=submit],input[type=submit],input[type=image]');
        return visibleEl(b) ? b : null;
      }
      window.__ocbarPrefill = function (root) {
        root = root || document;
        var skip = ['hidden', 'checkbox', 'radio', 'submit', 'button', 'image', 'reset', 'file'];
        var inputs = Array.prototype.filter.call(root.querySelectorAll('input,textarea'), function (e) {
          return visibleEl(e) && skip.indexOf(typeOf(e)) < 0;
        });
        var out = [], used = [];
        function add(el, k, why) { if (used.indexOf(el) < 0) { used.push(el); out.push({el: el, kind: k, why: why}); } }
        function has(k) { return out.some(function (o) { return o.kind === k; }); }
        inputs.forEach(function (e) {
          var ac = acTokens(e);
          if (ac.indexOf('username') >= 0) add(e, 'username', 'autocomplete=username');
          else if (ac.indexOf('current-password') >= 0) add(e, 'password', 'autocomplete=current-password');
          else if (ac.indexOf('one-time-code') >= 0) add(e, 'totp', 'autocomplete=one-time-code');
        });
        var pw = inputs.filter(function (e) { return typeOf(e) === 'password'; });
        if (!has('password') && pw.length === 1) add(pw[0], 'password', 'type=password');
        if (!has('totp')) {
          var otp = inputs.filter(function (e) { return used.indexOf(e) < 0 && typeOf(e) !== 'password' && otpLike(e); });
          if (otp.length === 1) add(otp[0], 'totp', 'похоже на поле кода');
        }
        if (!has('username')) {
          var p = out.filter(function (o) { return o.kind === 'password'; })[0];
          if (p) {
            var before = inputs.filter(function (e) {
              return used.indexOf(e) < 0 && e.form === p.el.form && ['text', 'email'].indexOf(typeOf(e)) >= 0 &&
                     (e.compareDocumentPosition(p.el) & Node.DOCUMENT_POSITION_FOLLOWING);
            });
            if (before.length) add(before[before.length - 1], 'username', 'поле перед паролем');
          }
        }
        var btn = out.length ? defaultButton(out[0].el.form) : null;
        if (btn) out.push({el: btn, kind: 'click', why: 'кнопка формы по умолчанию'});
        return out.map(function (o) { return {kind: o.kind, selector: selectorFor(o.el), why: o.why}; });
      };
      var markStyle = null;
      window.__ocbarShowMarks = function (sels) {
        if (!markStyle) {
          markStyle = document.createElement('style');
          markStyle.textContent = '[data-ocbar-mark]{outline:2px solid #1d7a52 !important;outline-offset:2px !important}';
          document.documentElement.appendChild(markStyle);
        }
        Array.prototype.forEach.call(document.querySelectorAll('[data-ocbar-mark]'), function (e) { e.removeAttribute('data-ocbar-mark'); });
        (sels || []).forEach(function (s) { try { var e = document.querySelector(s); if (e) e.setAttribute('data-ocbar-mark', '1'); } catch (x) {} });
      };

      window.__ocbarSet = function (m, k) { marking = m; kind = k; if (!m) hide(); };
      // Наружу — для проверки: по элементу вернуть тот же селектор, который
      // записался бы при щелчке (ocbar-auth --learn-selftest).
      window.__ocbarSelector = function (el) { return selectorFor(target(el)); };
      window.__ocbarGuess = function (el) { return guessKind(target(el)); };
      window.__ocbarFocus = function (sel) {
        try { var e = document.querySelector(sel); if (e) e.focus(); } catch (err) {}
      };
    })();
    """
}


/// Предзаполнение на живой странице без окна и без щелчков:
/// `ocbar-auth --learn-probe --url …` открывает форму входа так же, как
/// разметка, ждёт, пока скрипт портала её построит, и печатает, что
/// предзаполнение отметило бы. Учётных данных не нужно, ничего не нажимает.
/// Нужен, чтобы проверять надёжность на настоящем портале, не открывая окно
/// поверх работы человека (окно разметки однажды перехватило чужие щелчки).
final class LearnProbe: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private let url: URL
    private let done: (Int32) -> Void
    private var generation = 0
    private var reported = false

    init(url: URL, completion: @escaping (Int32) -> Void) {
        self.url = url
        self.done = completion
        super.init()
    }

    func start() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let c = WKUserContentController()
        c.addUserScript(WKUserScript(source: LearnSession.pageScript, injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true, in: LearnSession.world))
        cfg.userContentController = c
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), configuration: cfg)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
        Log.info("пробник: открываю \(url.host ?? url.absoluteString) без окна")
        // Страница, которая так и не успокоилась, — тоже ответ.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.report() }
    }

    // Портал может пройти несколько перенаправлений и промежуточных форм:
    // отчёт — через три секунды после последней загрузки.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, g == self.generation else { return }
            self.report()
        }
    }

    private func report() {
        guard !reported else { return }
        reported = true
        let js = "JSON.stringify({page: location.host + location.pathname, marks: window.__ocbarPrefill ? window.__ocbarPrefill() : null})"
        LearnSession.eval(webView, js) { [weak self] v, error in
            guard let self else { return }
            guard let text = v as? String,
                  let d = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                print("пробник: страница не ответила (\(error.map { $0.localizedDescription } ?? "нет данных"))")
                self.done(1); return
            }
            print("страница: \(d["page"] as? String ?? "?")")
            let marks = d["marks"] as? [[String: String]] ?? []
            if marks.isEmpty { print("  предзаполнение ничего не узнало — размечать руками") }
            for m in marks {
                print("  \((m["kind"] ?? "").padding(toLength: 9, withPad: " ", startingAt: 0)) \(m["selector"] ?? "")  — \(m["why"] ?? "")")
            }
            self.done(0)
        }
    }
}

