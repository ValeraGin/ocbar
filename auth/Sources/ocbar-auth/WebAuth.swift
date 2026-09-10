import AppKit
import WebKit
import Foundation

/// Окно SAML-логина. Единственная задача — дождаться cookie с токеном
/// (или страницы sso-v2-login-final) и отдать значение cookie наружу.
///
/// Три признака завершения, как в эталоне: точное совпадение URL с
/// login-final, совпадение по префиксу без query, появление cookie.
final class WebAuth: NSObject, WKNavigationDelegate, NSWindowDelegate, WKUIDelegate {
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
        var totpParams = TOTPParams()     // алгоритм, цифры, период секрета — из профиля
        var autofill = true
        var cookieDomain: String? = nil   // домен шлюза: cookie принимаем только оттуда
        var fillHosts: [String] = []      // где разрешено заполнять форму; пусто = везде
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
    private var offHostLogged: String?
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
        super.init()
    }

    // MARK: - запуск

    func start() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // persistent: IdP-сессия переживает перезапуск
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
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
        if let r = recorder {
            let box = NSButton(checkboxWithTitle: "Запомнить, как я вхожу", target: self, action: #selector(teachToggled))
            box.state = r.enabled ? .on : .off
            box.font = .systemFont(ofSize: 11)
            box.frame = NSRect(x: 520 - 200, y: 2, width: 192, height: 18)
            box.autoresizingMask = [.minXMargin]
            box.toolTip = "Входите как обычно — ocbar запомнит, как устроена форма, и после входа предложит сохранить правила, пароль и источник кода. Без вашего подтверждения ничего не сохраняется."
            content.addSubview(box)
            teachBox = box
            statusLabel.frame.size.width = 520 - 16 - 200
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
            // проверки домена сюда попадала бы cookie от другого шлюза или
            // остаток от прошлого запуска.
            let matching = cookies.filter { c in
                guard c.name == self.request.tokenCookieName else { return false }
                guard let want = self.opts.cookieDomain, !want.isEmpty else { return true }
                let dom = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                return want == dom || want.hasSuffix("." + dom)
            }
            if let tok = matching.first {
                Log.info("cookie \(tok.name) получена (домен \(tok.domain), \(tok.value.count) символов)")
                self.finish(.success(tok.value))
                return
            }
            if let errName = self.request.errorCookieName,
               let err = cookies.first(where: { $0.name == errName }), !err.value.isEmpty {
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
        if opts.insecure, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - WKUIDelegate: popup-окна открываем в том же webview

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
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
        let host = webView.url?.host ?? ""
        if !opts.fillHosts.isEmpty && !opts.fillHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            offHost(host)
            return
        }
        let sigJS = "location.href + '|' + document.querySelectorAll('input').length + '|' + (document.body ? document.body.innerText.length : 0)"
        webView.evaluateJavaScript(sigJS) { [weak self] sig, _ in
            guard let self = self, !self.finished, let sig = sig as? String else { return }
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
            let js = Autofill.script(rules: self.opts.rules, creds: creds, totpCode: code)
            self.webView.evaluateJavaScript(js) { result, err in
                if let err = err { Log.debug("autofill JS: \(err.localizedDescription)"); return }
                guard let dict = result as? [String: Any] else { return }
                self.handle(AutofillGate.Outcome(dict), signature: sig)
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
