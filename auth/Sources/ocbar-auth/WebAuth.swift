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
        var timeout: TimeInterval = 300
        var insecure = false
        var rules: [AutofillRule] = []
        var creds = Credentials()
        var totpCode: String? = nil
        var autofill = true
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
    private var lastClickSignature: String?
    private var lastFillURL: String?
    private var fillAttempts = 0
    private var clicks = 0
    private let maxClicks = 3        // больше — это уже цикл, а не вход
    private var totpFills = 0        // код одноразовый: подставляем РОВНО один раз
    private var stoppedReason: String?

    enum WebAuthError: Error, CustomStringConvertible {
        case cancelled, timeout, errorCookie(String), stopped(String), navigation(String)
        var description: String {
            switch self {
            case .cancelled: return "окно закрыто пользователем"
            case .timeout: return "тайм-аут ожидания SSO"
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

        window = NSWindow(contentRect: content.frame,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "ocbar — вход в VPN"
        window.contentView = content
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false

        if opts.alwaysShow || opts.showAfter <= 0 {
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
        Log.info("открываю \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    private func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            if let tok = cookies.first(where: { $0.name == self.request.tokenCookieName }) {
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
        Log.debug("страница загружена: \(u)")
        statusLabel.stringValue = u
        if urlLooksFinal(webView.url) {
            Log.info("достигнут sso-v2-login-final, жду cookie")
        }
        checkCookies()
        // новая страница — новая попытка автозаполнения
        if lastFillURL != u { lastFillURL = u; fillAttempts = 0; lastClickSignature = nil }
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
        guard !finished, opts.autofill, !opts.rules.isEmpty, stoppedReason == nil else { return }
        guard fillAttempts < 12 else { return }
        let sigJS = "location.href + '|' + document.querySelectorAll('input').length + '|' + (document.body ? document.body.innerText.length : 0)"
        webView.evaluateJavaScript(sigJS) { [weak self] sig, _ in
            guard let self = self, let sig = sig as? String else { return }
            if sig == self.lastClickSignature { return }   // после клика ждём изменений
            self.fillAttempts += 1
            // Второй автоввод TOTP бессмысленен (тот же секрет) и опасен:
            // несколько неверных кодов подряд блокируют учётную запись.
            let code = self.totpFills > 0 ? nil : self.opts.totpCode
            let js = Autofill.script(rules: self.opts.rules, creds: self.opts.creds, totpCode: code)
            self.webView.evaluateJavaScript(js) { result, err in
                if let err = err { Log.debug("autofill JS: \(err.localizedDescription)"); return }
                guard let dict = result as? [String: Any] else { return }
                if let stopped = dict["stopped"] as? String {
                    Log.info("правило stop: \(stopped)")
                    self.stoppedReason = stopped
                    self.statusLabel.stringValue = "Форма сообщает: \(stopped)"
                    self.show()
                    return
                }
                let filled = (dict["filled"] as? [String]) ?? []
                if !filled.isEmpty { Log.info("заполнено: \(filled.joined(separator: ", "))") }
                if filled.contains("totp") {
                    self.totpFills += 1
                    Log.info("код TOTP подставлен один раз — если форма спросит снова, вводит человек")
                }
                if let clicked = dict["clicked"] as? String {
                    self.clicks += 1
                    Log.info("нажато: \(clicked) (\(self.clicks)/\(self.maxClicks))")
                    self.lastClickSignature = sig
                    if self.clicks >= self.maxClicks {
                        Log.info("лимит нажатий — дальше только человек")
                        self.stoppedReason = "лимит автозаполнения"
                        self.show()
                    }
                    return
                }
                // Ничего не заполнили и не нажали, а поля на странице есть —
                // форму не распознали, человеку пора её увидеть.
                if filled.isEmpty, let inputs = dict["inputs"] as? [String], !inputs.isEmpty {
                    if self.fillAttempts == 1 { Log.info("форма не распознана, поля: \(inputs.joined(separator: " "))") }
                    self.show()
                }
            }
        }
    }
}
