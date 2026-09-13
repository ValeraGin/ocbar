import AppKit
import WebKit
import Foundation

/// Окно SAML-логина. Единственная задача — дождаться cookie с токеном
/// (или страницы sso-v2-login-final) и отдать значение cookie наружу.
///
/// Три признака завершения, как в эталоне: точное совпадение URL с
/// login-final, совпадение по префиксу без query, появление cookie.
final class WebAuth: NSObject, WKNavigationDelegate, NSWindowDelegate, WKUIDelegate, WKScriptMessageHandler {
    struct Options {
        var showAfter: TimeInterval = 2      // окно прячем, пока есть шанс пройти молча
        var alwaysShow = false
        // Молчаливый режим: окно не показывать никогда. Нужен супервизору,
        // который подключается сам — открывать окно поверх работы человека
        // без спроса неправильно, лучше сказать «нужен вход» и ждать.
        var noWindow = false
        var timeout: TimeInterval = 300
        var insecure = false
        var rules: [AutofillRule] = []
        var creds = Credentials()
        var totpSecret: String? = nil     // код считаем в момент заполнения, не заранее
        var totpCode: String? = nil       // если код пришёл готовым (из внешней базы)
        var totpCommand: String? = nil    // команда, печатающая свежий код (кнопка «Вставить код»)
        var totpParams = TOTPParams()     // алгоритм, цифры, период секрета — из профиля
        var autofill = true
        // Хосты шлюза (адрес группы и адрес, где идёт POST): cookie — только
        // с них, --insecure — только к ним, с них начинается цепочка входа.
        var gatewayHosts: [String] = []
        var fillHosts: [String] = []      // IdpHosts; пусто — хосты цепочки входа (FillScope)
        // Запомнить вход: человек входит руками, ocbar записывает форму и
        // после входа предлагает сохранить (TeachRecorder, TeachFlow).
        var teach = false                 // галочка доступна
        var teachOn = false               // и включена сразу (ocbar connect --teach)
    }

    private let request: AuthRequest
    private let opts: Options
    private let done: (Result<String, WebAuthError>) -> Void

    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var finished = false
    private var pollTimer: Timer?
    private var showTimer: Timer?
    private var timeoutTimer: Timer?
    private var fillTimer: Timer?
    private var lastFillURL: String?
    // Лимиты кода, пароля и нажатий, запрет повтора на неизменившейся
    // странице — в AutofillGate: там они проверяются без WebKit.
    private var gate = AutofillGate()
    private var scope: FillScope
    private var lastGesture: Date?
    private var offHostLogged: String?

    /// Изолированный мир окна входа: скрипт автозаполнения, его проверка
    /// хоста и слушатель жестов человека. Страница не видит ни их, ни
    /// обработчик сообщений и не может подменить встроенные функции.
    static let world = WKContentWorld.world(name: "ocbar-auth")

    /// Настоящий (isTrusted) щелчок или клавиша в главном документе — жест
    /// человека: переход сразу после него продлевает цепочку входа.
    static let gestureScript = """
    (function () {
      if (window.__ocbarGestureReady) return;
      window.__ocbarGestureReady = true;
      function g(e) { if (e.isTrusted) window.webkit.messageHandlers.ocbarGesture.postMessage(1); }
      document.addEventListener('mousedown', g, true);
      document.addEventListener('keydown', g, true);
    })();
    """

    /// Общая конфигурация окна входа — её же проверяет --learn-selftest.
    /// Всплывающие окна без жеста человека WebKit не открывает вовсе.
    static func configuration(persistent: Bool) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        // persistent: IdP-сессия переживает перезапуск
        cfg.websiteDataStore = persistent ? .default() : .nonPersistent()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        return cfg
    }

    /// Cookie токена и cookie ошибки — только с точного хоста шлюза, без
    /// родительского домена: хранилище общее и постоянное, и cookie с тем
    /// же именем мог поставить на весь домен любой соседний хост (или
    /// остаться от прошлого запуска с другим шлюзом). Точка в начале
    /// (Domain=хост шлюза) допускается: такую ставит только сам хост и его
    /// поддомены.
    static func cookieFromGateway(domain: String, hosts: Set<String>) -> Bool {
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        return !d.isEmpty && hosts.contains(d)
    }

    /// --insecure — только к хосту шлюза: страницы провайдера входа, где
    /// вводится пароль, проверяются всегда.
    static func trustsUnverified(host: String, insecure: Bool, gatewayHosts: Set<String>) -> Bool {
        insecure && gatewayHosts.contains(host.lowercased())
    }

    private var cookieHosts: Set<String> {
        var s = scope.gatewayHosts
        for u in [request.loginURL, request.loginFinalURL] {
            if let h = FillScope.host(URL(string: u)) { s.insert(h) }
        }
        return s
    }

    /// Был ли только что настоящий жест человека в видимом окне.
    private var humanRecent: Bool {
        guard shownToHuman, window?.isVisible == true, let t = lastGesture else { return false }
        return Date().timeIntervalSince(t) < 3
    }
    private(set) var recorder: TeachRecorder?
    private var teachBox: NSButton?
    private(set) var shownToHuman = false

    enum WebAuthError: Error, CustomStringConvertible {
        case cancelled, timeout, needsHuman(String), errorCookie(String), stopped(String), navigation(String)
        var description: String {
            switch self {
            case .cancelled: return "окно закрыто пользователем"
            case .timeout: return "тайм-аут ожидания SSO"
            case .needsHuman(let s): return "нужен человек: \(s)"
            case .errorCookie(let s): return "шлюз вернул cookie ошибки: \(s)"
            case .stopped(let s): return "форма показала ошибку: \(s)"
            case .navigation(let s): return "навигация не удалась: \(s)"
            }
        }
    }

    init(request: AuthRequest, options: Options,
         completion: @escaping (Result<String, WebAuthError>) -> Void) {
        self.request = request
        self.opts = options
        self.done = completion
        self.scope = FillScope(explicit: options.fillHosts,
                               gatewayHosts: Self.scopeGatewayHosts(options.gatewayHosts, loginURL: request.loginURL,
                                                                    loginFinalURL: request.loginFinalURL))
        super.init()
    }

    /// Хосты, с которых начинается цепочка входа: адрес группы, адрес POST и
    /// страницы sso-v2-login и login-final. Балансировщик шлюза отдаёт
    /// страницу входа с другого узла (vpn.example → vpn-1.example), и без её
    /// хоста автоотправка SAML-формы оттуда к провайдеру цепочку не
    /// продлевала — форма провайдера не заполнялась совсем.
    static func scopeGatewayHosts(_ hosts: [String], loginURL: String, loginFinalURL: String) -> [String] {
        hosts + [loginURL, loginFinalURL].compactMap { FillScope.host(URL(string: $0)) }
    }

    // MARK: - запуск

    func start() {
        let cfg = Self.configuration(persistent: true)
        cfg.userContentController.addUserScript(WKUserScript(source: Self.gestureScript, injectionTime: .atDocumentStart,
                                                             forMainFrameOnly: true, in: Self.world))
        cfg.userContentController.add(self, contentWorld: Self.world, name: "ocbarGesture")
        if opts.teach {
            let r = TeachRecorder(username: opts.creds.username)
            r.enabled = opts.teachOn
            r.install(into: cfg.userContentController)
            r.onChange = { [weak self] summary in self?.statusLabel?.stringValue = "запоминаю: " + summary }
            recorder = r
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]

        statusLabel = NSTextField(labelWithString: "Вход через SSO…")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.autoresizingMask = [.width]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 702))
        webView.frame = NSRect(x: 0, y: 22, width: 520, height: 680)
        statusLabel.frame = NSRect(x: 8, y: 3, width: 504, height: 16)
        content.addSubview(webView)
        content.addSubview(statusLabel)
        // «Вставить пароль» и «Вставить код»: если автозаполнение не сработало
        // (форма не узналась, окно вне цепочки), человек подставляет данные
        // профиля сам — в поле, где стоит курсор. Значения в журнал не идут.
        let pwButton = NSButton(title: "Вставить пароль", target: self, action: #selector(insertPassword))
        let codeButton = NSButton(title: "Вставить код", target: self, action: #selector(insertCode))
        var x: CGFloat = 6
        for b in [pwButton, codeButton] {
            b.bezelStyle = .inline
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.sizeToFit()
            b.frame = NSRect(x: x, y: 2, width: b.frame.width + 8, height: 18)
            x += b.frame.width + 6
            content.addSubview(b)
        }
        pwButton.isEnabled = !(opts.creds.password ?? "").isEmpty
        pwButton.toolTip = pwButton.isEnabled ? "Подставить пароль из источника профиля в поле, где стоит курсор"
                                              : "Источник профиля пароля не дал"
        codeButton.isEnabled = hasCodeSource
        codeButton.toolTip = codeButton.isEnabled ? "Подставить свежий одноразовый код в поле, где стоит курсор"
                                                  : "У профиля нет источника кода (Totp = off или sms)"
        statusLabel.frame = NSRect(x: x + 4, y: 3, width: 520 - x - 12, height: 16)
        if let r = recorder {
            let box = NSButton(checkboxWithTitle: "Запомнить, как я вхожу", target: self, action: #selector(teachToggled))
            box.state = r.enabled ? .on : .off
            box.font = .systemFont(ofSize: 11)
            box.frame = NSRect(x: 520 - 200, y: 2, width: 192, height: 18)
            box.autoresizingMask = [.minXMargin]
            box.toolTip = "Входите как обычно — ocbar запомнит, как устроена форма, и после входа предложит сохранить правила, пароль и источник кода. Без вашего подтверждения ничего не сохраняется."
            content.addSubview(box)
            teachBox = box
            statusLabel.frame.size.width = max(60, 520 - statusLabel.frame.minX - 208)
            if r.enabled { statusLabel.stringValue = "запоминаю: входите как обычно" }
        }

        window = NSWindow(contentRect: content.frame,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "ocbar — вход в VPN"
        window.contentView = content
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false

        if opts.noWindow {
            // окно не показываем вовсе; поймём по таймауту или по нераспознанной форме
        } else if opts.alwaysShow || opts.showAfter <= 0 {
            show()
        } else {
            showTimer = Timer.scheduledTimer(withTimeInterval: opts.showAfter, repeats: false) { [weak self] _ in
                guard let self = self, !self.finished else { return }
                Log.info("за \(self.opts.showAfter) с молча не прошло — показываю окно")
                self.show()
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkCookies()
        }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: opts.timeout, repeats: false) { [weak self] _ in
            self?.finish(.failure(.timeout))
        }
        if opts.autofill && !opts.rules.isEmpty {
            fillTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.autofillTick()
            }
        }

        guard let url = URL(string: request.loginURL) else {
            finish(.failure(.navigation("некорректный sso-v2-login: \(request.loginURL)")))
            return
        }
        Log.info("открываю \(Log.redact(url))")
        webView.load(URLRequest(url: url))
    }

    private func show() {
        if opts.noWindow {
            // Всё, что в обычном режиме привело бы к показу окна, здесь
            // означает: без человека не обойтись.
            finish(.failure(.needsHuman(statusLabel?.stringValue.isEmpty == false
                                        ? statusLabel.stringValue
                                        : (webView.url?.host ?? "форма входа"))))
            return
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        shownToHuman = true
    }

    private var hasCodeSource: Bool {
        !(opts.totpSecret ?? "").isEmpty || !(opts.totpCommand ?? "").isEmpty || !(opts.totpCode ?? "").isEmpty
    }

    /// Код в момент нажатия: секрет из связки, команда клиента (KeePassXC,
    /// своя) или готовый код, если дали только его.
    private func codeNow() -> String? {
        if let s = opts.totpSecret, !s.isEmpty { return TOTP.code(secretBase32: s, params: opts.totpParams) }
        if let cmd = opts.totpCommand, !cmd.isEmpty {
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
        if let c = opts.totpCode, !c.isEmpty { return c }
        return nil
    }

    @objc private func insertPassword() {
        guard let pw = opts.creds.password, !pw.isEmpty else {
            statusLabel.stringValue = "пароля нет: источник профиля его не дал"; return
        }
        insert(pw, kind: "password")
    }

    @objc private func insertCode() {
        guard let code = codeNow() else {
            statusLabel.stringValue = "кода нет: источник профиля не ответил"; return
        }
        insert(code, kind: "totp")
    }

    /// Поле: где стоит курсор; если курсор не в поле — первое видимое поле
    /// пароля или кода. Установщик значения — родной, с событиями input и
    /// change, как у автозаполнения: формы на Vue и React видят ввод.
    static let insertScript = """
    function usable(e) {
      return e && e.tagName === 'INPUT' && e.offsetParent !== null && !e.disabled && !e.readOnly
        && !/^(hidden|submit|button|checkbox|radio|file|image|reset)$/i.test(e.type || '');
    }
    var e = document.activeElement;
    if (!usable(e)) {
      var q = kind === 'password' ? 'input[type=password]'
        : 'input[autocomplete=one-time-code], input[inputmode=numeric], input[name*=otp i], input[id*=otp i], input[name*=code i], input[id*=code i], input[type=tel]';
      e = Array.prototype.find.call(document.querySelectorAll(q), usable);
    }
    if (!e) return '';
    e.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, v);
    e.dispatchEvent(new Event('input', {bubbles: true}));
    e.dispatchEvent(new Event('change', {bubbles: true}));
    return e.id ? '#' + e.id : (e.name ? '[name=' + e.name + ']' : 'input[type=' + e.type + ']');
    """

    private func insert(_ value: String, kind: String) {
        guard webView.url?.scheme?.lowercased() == "https" else {
            statusLabel.stringValue = "страница не по https — не вставляю"; return
        }
        let what = kind == "password" ? "пароль" : "код"
        webView.callAsyncJavaScript(Self.insertScript, arguments: ["v": value, "kind": kind],
                                    in: nil, in: Self.world) { [weak self] res in
            guard let self = self else { return }
            if case .success(let r) = res, let field = r as? String, !field.isEmpty {
                self.statusLabel.stringValue = "\(what) вставлен в \(field)"
                Log.info("человек вставил \(what) кнопкой: \(field) на \(self.webView.url?.host ?? "?")")
            } else {
                self.statusLabel.stringValue = "некуда вставить \(what): щёлкните в поле и нажмите ещё раз"
            }
        }
    }

    @objc private func teachToggled() {
        guard let r = recorder else { return }
        r.enabled = teachBox?.state == .on
        r.apply(to: webView)
        statusLabel.stringValue = r.enabled ? "запоминаю: входите как обычно" : "запись входа выключена"
    }

    /// Есть что предложить сохранить: запись была включена, окно видел
    /// человек и хоть одно окно формы отправлено.
    var teachOutcome: TeachRecorder? {
        guard let r = recorder, r.enabled, shownToHuman, !r.steps.isEmpty else { return nil }
        return r
    }

    private func finish(_ r: Result<String, WebAuthError>) {
        guard !finished else { return }
        finished = true
        [pollTimer, showTimer, timeoutTimer, fillTimer].forEach { $0?.invalidate() }
        webView.stopLoading()
        window.delegate = nil
        window.orderOut(nil)
        done(r)
    }

    // MARK: - признаки завершения

    private func urlLooksFinal(_ url: URL?) -> Bool {
        guard let u = url?.absoluteString else { return false }
        if u == request.loginFinalURL { return true }
        let prefix = request.loginFinalURL.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.loginFinalURL
        return u.hasPrefix(prefix)
    }

    private func checkCookies() {
        guard !finished else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, !self.finished else { return }
            // Имя cookie задаёт шлюз, а хранилище общее и постоянное. Без
            // проверки домена сюда попадала бы cookie от другого шлюза,
            // соседнего хоста того же домена или остаток от прошлого запуска.
            let hosts = self.cookieHosts
            let fromGateway = cookies.filter { WebAuth.cookieFromGateway(domain: $0.domain, hosts: hosts) }
            if let tok = fromGateway.first(where: { $0.name == self.request.tokenCookieName }) {
                Log.info("cookie \(tok.name) получена (домен \(tok.domain), \(tok.value.count) символов)")
                self.finish(.success(tok.value))
                return
            }
            if let errName = self.request.errorCookieName,
               let err = fromGateway.first(where: { $0.name == errName }), !err.value.isEmpty {
                self.finish(.failure(.errorCookie(err.value)))
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let u = webView.url?.absoluteString ?? "?"
        // В журнал и в строку состояния — без query: строка состояния
        // уходит в журнал как причина «нужен человек» (--no-window).
        Log.debug("страница загружена: \(Log.redact(webView.url))")
        recorder?.apply(to: webView)
        statusLabel.stringValue = Log.redact(webView.url)
        if urlLooksFinal(webView.url) {
            Log.info("достигнут sso-v2-login-final, жду cookie")
        }
        checkCookies()
        // новая страница — новая попытка автозаполнения
        if lastFillURL != u { lastFillURL = u; gate.newPage() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.autofillTick() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.debug("didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        Log.info("провал загрузки: \(error.localizedDescription)")
        statusLabel.stringValue = "Ошибка: \(error.localizedDescription)"
        show()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // cookie могла прийти в этом же ответе — проверим сразу после
        DispatchQueue.main.async { [weak self] in self?.checkCookies() }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           Self.trustsUnverified(host: challenge.protectionSpace.host, insecure: opts.insecure,
                                 gatewayHosts: scope.gatewayHosts),
           let trust = challenge.protectionSpace.serverTrust {
            Log.debug("TLS: сертификат \(challenge.protectionSpace.host) принят без проверки (--insecure, хост шлюза)")
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - цепочка входа (FillScope)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url {
            note(scope.navigation(to: url, humanRecent: humanRecent), url)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        // Перенаправления WebKit и так проводит через decidePolicyFor; это —
        // запасной путь на случай, если какое-то пройдёт мимо.
        if let url = webView.url { note(scope.navigation(to: url, humanRecent: humanRecent), url) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        scope.committed(webView.url)
    }

    private func note(_ reason: FillScope.Reason, _ url: URL) {
        let h = url.host ?? "?"
        switch reason {
        case .already: break
        case .gatewayChain: Log.info("цепочка входа: \(h)")
        case .human: Log.info("человек перешёл на \(h) — там тоже заполняю")
        case .refused:
            if url.scheme == "https" || url.scheme == "http" {
                Log.info("\(h): не из цепочки входа — автозаполнения там не будет")
            }
        }
    }

    // MARK: - WKScriptMessageHandler: жесты человека из изолированного мира

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world == Self.world, message.name == "ocbarGesture" else { return }
        lastGesture = Date()
    }

    // MARK: - WKUIDelegate: popup-окна — в том же webview, но не куда попало

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Сюда доходят только окна по жесту человека (конфигурация). И даже
        // тогда главное окно входа не уходит с цепочки входа: иначе фрейм
        // с чужой страницы увёл бы его туда, где заполнятся логин и пароль.
        guard let url = navigationAction.request.url else { return nil }
        if scope.allowsPopup(url) {
            webView.load(URLRequest(url: url))
        } else {
            Log.info("всплывающее окно на \(Log.redact(url)) не открываю: не https или хост не из цепочки входа")
        }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish(.failure(.cancelled))
    }

    // MARK: - автозаполнение

    /// Скрипт выполняется, пока страница «та же» (по URL и сигнатуре DOM) не
    /// больше N раз, и никогда повторно после click на неизменившейся странице —
    /// иначе кнопка «Войти» нажимается в цикле на форме с ошибкой.
    private func autofillTick() {
        guard !finished, opts.autofill, !opts.rules.isEmpty, gate.stopped == nil else { return }
        guard gate.attempts < gate.maxAttemptsPerPage else { return }
        // Правила — это просто селекторы, они совпадут на любой странице с
        // похожими полями. Без привязки к адресу логин с паролем ушли бы
        // туда, куда увёл бы шлюз.
        // Проверка здесь — чтобы не звать скрипт зря; настоящая — внутри
        // скрипта (allowed), в момент выполнения.
        guard scope.allowsFill(webView.url) else {
            offHost(webView.url?.host ?? "?")
            return
        }
        let sigJS = "location.href + '|' + document.querySelectorAll('input').length + '|' + (document.body ? document.body.innerText.length : 0)"
        webView.evaluateJavaScript(sigJS, in: nil, in: Self.world) { [weak self] res in
            guard let self = self, !self.finished, case .success(let v) = res, let sig = v as? String else { return }
            guard self.gate.mayRun(signature: sig) else { return }   // после клика ждём изменений
            let offer = self.gate.begin()
            // Код считается ЗДЕСЬ, а не при старте: между запуском и появлением
            // поля проходят десятки секунд, а код живёт тридцать. Второй
            // автоввод не даёт AutofillGate: тот же секрет — тот же неверный код.
            var code: String? = nil
            if offer.code {
                if let secret = self.opts.totpSecret, !secret.isEmpty {
                    code = TOTP.code(secretBase32: secret, params: self.opts.totpParams)
                } else {
                    code = self.opts.totpCode
                }
            }
            var creds = self.opts.creds
            if !offer.password { creds.password = nil }
            let js = Autofill.script(rules: self.opts.rules, creds: creds, totpCode: code,
                                     allowed: self.scope.jsAllowed)
            self.webView.evaluateJavaScript(js, in: nil, in: Self.world) { res in
                switch res {
                case .failure(let err): Log.debug("autofill JS: \(err.localizedDescription)")
                case .success(let v):
                    guard let dict = v as? [String: Any] else { return }
                    self.handle(AutofillGate.Outcome(dict), signature: sig)
                }
            }
        }
    }

    private func handle(_ o: AutofillGate.Outcome, signature: String) {
        let first = gate.attempts == 1
        let d = gate.record(o, signature: signature)
        if !o.filled.isEmpty { Log.info("заполнено: \(o.filled.joined(separator: ", "))") }
        if d.passwordLimitReached {
            Log.info("пароль подставлен \(gate.passwordFills) раза — дальше вводит человек: неверный пароль не должен уходить по кругу")
        }
        if d.countedCode {
            recorder?.engineFilledCode = true
            Log.info("код TOTP подставлен один раз — если форма спросит снова, вводит человек")
        }
        switch d.next {
        case .keepGoing:
            break
        case .formError(let s):
            Log.info("правило stop: \(s)")
            statusLabel.stringValue = "Форма сообщает: \(s)"
            show()
        case .offHost(let h):
            offHost(h)
        case .clicked(let c):
            Log.info("нажато: \(c) (\(gate.clicks)/\(gate.maxClicks))")
        case .clickLimit:
            Log.info("нажато (\(gate.clicks)/\(gate.maxClicks)) — лимит нажатий, дальше только человек")
            show()
        case .waitingHuman(let w):
            // Кнопку не нажали, потому что видно пустое поле из правил и
            // заполнить его нечем, — дальше решает человек.
            if first || !o.filled.isEmpty {
                Log.info("поле \(w) пустое, заполнить нечем — форму не отправляю, её увидит человек")
            }
            show()
        case .unknownForm(let inputs):
            // Ничего не заполнили и не нажали, а поля на странице есть —
            // форму не распознали, человеку пора её увидеть.
            if first { Log.info("форма не распознана, поля: \(inputs.joined(separator: " "))") }
            show()
        }
    }

    /// Страница не из разрешённых: заполняет человек. Пишем в журнал один
    /// раз на хост, окно показываем.
    private func offHost(_ host: String) {
        if offHostLogged != host {
            offHostLogged = host
            Log.info("страница \(host) не в списке разрешённых для автозаполнения — заполняет человек")
        }
        show()
    }
}
