import AppKit
import WebKit
import Foundation

/// Режим обучения: человек показывает мышью, где на его портале поле логина,
/// поле пароля, поле кода и кнопка входа, — а мы записываем это правилами
/// автозаполнения (etc/autofill.rules).
///
/// Зачем: форма провайдера входа у каждой компании своя, а встроенный набор
/// правил покрывает только типовые (Keycloak, Microsoft). Разметить свой
/// портал мышью — единственный способ обойтись без чтения чужого HTML.
///
/// Сессия окна намеренно НЕ сохраняется (`nonPersistent`): с живой сессией
/// провайдер проводит молча, и размечать становится нечего. Заодно разметка
/// не трогает рабочую сессию входа.
final class LearnSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {

    struct Mark {
        let kind: String        // username | password | totp | click | stop
        let selector: String
        let hint: String        // что это было на странице — для строки состояния
    }

    /// Что размечаем сейчас. Порядок кнопок — порядок обычной формы входа.
    private static let kinds: [(id: String, title: String, hint: String)] = [
        ("auto",     "Авто",   "Щёлкайте по полям и кнопке — вид определится сам; не тот — выберите слева и щёлкните снова."),
        ("username", "Логин",  "Щёлкните по полю, куда вводится логин"),
        ("password", "Пароль", "Щёлкните по полю пароля"),
        ("totp",     "Код",    "Щёлкните по полю одноразового кода"),
        ("click",    "Кнопка", "Щёлкните по кнопке, которая отправляет форму (можно несколько — по одной на каждом шаге)"),
        ("stop",     "Ошибка", "Щёлкните по строке, где показывается ошибка входа — увидев её, автозаполнение остановится"),
    ]

    private let startURL: URL
    private let outFile: String?
    private let done: (Int32) -> Void

    private var window: NSWindow!
    private var webView: WKWebView!
    private var kindPicker: NSSegmentedControl!
    private var modeButton: NSButton!
    private var status: NSTextField!
    private var collected: NSTextField!
    private var marks: [Mark] = []
    private var marking = true
    private var kind = "auto"
    private var finished = false
    private var lastHost: String?      // где реально показалась форма: там же живёт IdP

    init(startURL: URL, outFile: String?, completion: @escaping (Int32) -> Void) {
        self.startURL = startURL
        self.outFile = outFile
        self.done = completion
        super.init()
    }

    // MARK: - окно

    func start() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(self, name: "ocbarLearn")
        controller.addUserScript(WKUserScript(source: Self.js, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        cfg.userContentController = controller

        let width: CGFloat = 680, webHeight: CGFloat = 700, barHeight: CGFloat = 84
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: webHeight), configuration: cfg)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]

        kindPicker = NSSegmentedControl(labels: Self.kinds.map(\.title), trackingMode: .selectOne,
                                        target: self, action: #selector(kindChanged))
        kindPicker.selectedSegment = 0
        kindPicker.frame = NSRect(x: 10, y: webHeight + 50, width: 420, height: 24)

        modeButton = NSButton(checkboxWithTitle: "Отмечать элементы", target: self, action: #selector(modeChanged))
        modeButton.state = .on
        modeButton.frame = NSRect(x: 440, y: webHeight + 52, width: 160, height: 20)
        modeButton.toolTip = "Выключите, чтобы пользоваться страницей обычным образом: нажать «Далее», закрыть баннер, выбрать другой способ входа."

        status = NSTextField(labelWithString: Self.kinds[0].hint)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.frame = NSRect(x: 12, y: webHeight + 30, width: width - 24, height: 16)
        status.autoresizingMask = [.width]

        collected = NSTextField(labelWithString: "отмечено: ничего")
        collected.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        collected.textColor = .tertiaryLabelColor
        collected.lineBreakMode = .byTruncatingTail
        collected.frame = NSRect(x: 12, y: webHeight + 12, width: width - 260, height: 14)
        collected.autoresizingMask = [.width]

        let undo = NSButton(title: "Убрать последнее", target: self, action: #selector(undoLast))
        undo.bezelStyle = .rounded
        undo.font = .systemFont(ofSize: 11)
        undo.frame = NSRect(x: width - 250, y: webHeight + 6, width: 130, height: 22)
        undo.autoresizingMask = [.minXMargin]

        let verify = NSButton(title: "Проверить", target: self, action: #selector(checkRules))
        verify.bezelStyle = .rounded
        verify.font = .systemFont(ofSize: 11)
        verify.frame = NSRect(x: width - 340, y: webHeight + 6, width: 86, height: 22)
        verify.autoresizingMask = [.minXMargin]
        verify.toolTip = "Найти отмеченное на этой странице: правило без элемента не сработает"

        let finish = NSButton(title: "Готово", target: self, action: #selector(finishAndSave))
        finish.bezelStyle = .rounded
        finish.keyEquivalent = "\r"
        finish.font = .systemFont(ofSize: 11)
        finish.frame = NSRect(x: width - 110, y: webHeight + 6, width: 100, height: 22)
        finish.autoresizingMask = [.minXMargin]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: webHeight + barHeight))
        content.addSubview(webView)
        [kindPicker, modeButton, status, collected, verify, undo, finish].forEach { content.addSubview($0!) }

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
        Log.info("разметка: открыл \(startURL.absoluteString)")
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
    /// автозаполнение промолчит.
    @objc private func checkRules() {
        guard !marks.isEmpty else {
            status.stringValue = "проверять нечего: ничего не отмечено"
            return
        }
        webView.evaluateJavaScript(Self.checkScript(for: marks.map { $0.selector })) { [weak self] value, _ in
            guard let self, let codes = value as? [Int], codes.count == self.marks.count else {
                self?.status.stringValue = "проверка не удалась"
                return
            }
            var parts: [String] = []
            for (mark, code) in zip(self.marks, codes) {
                let name = self.title(for: mark.kind)
                switch code {
                case 2: parts.append(name + " ✓")
                case 1: parts.append(name + " есть, но скрыт")
                case 0: parts.append(name + " ✗")
                default: parts.append(name + ": селектор не разобрался")
                }
            }
            // Многошаговая форма — это нормально: поле пароля на первой
            // странице и не должно находиться.
            self.status.stringValue = "на этой странице: " + parts.joined(separator: ", ")
                + (codes.contains(0) ? " · ненайденное может быть на другом шаге" : "")
        }
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
        guard let body = message.body as? [String: Any],
              let selector = body["selector"] as? String, !selector.isEmpty else {
            status.stringValue = "не удалось составить селектор — попробуйте щёлкнуть по самому полю"
            return
        }
        let hint = (body["hint"] as? String) ?? ""
        // В режиме «Авто» вид определяет сама страница: она видит тип поля,
        // autocomplete, maxlength и имя. Шаги «сначала логин, потом пароль»
        // оказались хуже — человек щёлкает по тому полю, которое видит, а не
        // по тому, которое ждёт мастер.
        let guessed = (body["guess"] as? String) ?? "username"
        let what = kind == "auto" ? guessed : kind
        // Одно и то же поле дважды не пишем: правило от этого не станет вернее.
        if marks.contains(where: { $0.kind == what && $0.selector == selector }) {
            status.stringValue = "уже отмечено: \(selector)"
            return
        }
        // Логин, пароль и код — по одному на профиль: второе правило того же
        // вида молча перебило бы первое.
        if what != "click" && what != "stop" {
            marks.removeAll { $0.kind == what }
        }
        marks.append(Mark(kind: what, selector: selector, hint: hint))
        status.stringValue = kind == "auto"
            ? "распознано как \(title(for: what)): \(selector) — не то? выберите вид слева и щёлкните ещё раз"
            : "отмечено \(title(for: what)): \(selector)"
        refreshCollected()
        if what == "username" || what == "password" || what == "totp" {
            // Поле сразу получает фокус: дальше человек просто печатает, не
            // выключая разметку.
            webView.evaluateJavaScript("window.__ocbarFocus(\(Self.jsString(selector)))")
        }
    }

    private func title(for id: String) -> String {
        Self.kinds.first { $0.id == id }?.title.lowercased() ?? id
    }

    private func refreshCollected() {
        collected.stringValue = marks.isEmpty
            ? "отмечено: ничего"
            : "отмечено \(marks.count): " + marks.map { "\(title(for: $0.kind))=\($0.selector)" }.joined(separator: ", ")
    }

    private func applyState() {
        webView.evaluateJavaScript("window.__ocbarSet(\(marking ? "true" : "false"), \(Self.jsString(kind)))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyState()
        if let host = webView.url?.host {
            lastHost = host
            window.title = "ocbar — разметка формы входа · \(host)"
        }
    }

    // MARK: - результат

    /// Правила в том порядке, в каком их читает автозаполнение: сначала
    /// `stop` (иначе пароль уедет в форму с ошибкой), потом поля, потом
    /// нажатия.
    func rulesText() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var out = "# Правила автозаполнения формы входа, размечены вручную \(df.string(from: Date())).\n"
        out += "# Портал: \(startURL.host ?? startURL.absoluteString)\n"
        out += "# Формат и остальные возможности — etc/autofill.rules.example.\n"
        out += "# Проверить, что получится: ocbar-auth --dump-script --rules <этот файл>\n"
        if let host = lastHost ?? startURL.host {
            out += "#\n# Форма входа живёт на " + host + ". Чтобы заполнять только там,\n"
            out += "# добавьте в профиль:  IdpHosts = " + host + "\n"
        }
        out += "\n"
        if marks.isEmpty {
            out += "# Ничего не отмечено.\n"
            return out
        }
        for m in marks where m.kind == "stop" { out += "stop  \(m.selector)\n" }
        for what in ["username", "password", "totp"] {
            for m in marks where m.kind == what { out += "fill  \(what) \(m.selector)\n" }
        }
        for m in marks where m.kind == "click" { out += "click \(m.selector)\n" }
        return out
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
        if (kind === 'click')
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

      document.addEventListener('click', function (e) {
        if (!marking) return;
        e.preventDefault(); e.stopPropagation();
        var el = target(e.target);
        if (!el || el.nodeType !== 1) return;
        window.webkit.messageHandlers.ocbarLearn.postMessage({
          selector: selectorFor(el),
          guess: guessKind(el),
          hint: (el.tagName || '') + ' ' + ((el.getAttribute && el.getAttribute('type')) || '')
        });
      }, true);

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


/// Проверка разметки без человека: страница-образец грузится в такой же
/// WKWebView с тем же внедрённым скриптом, у неё спрашиваются селекторы для
/// известных элементов, и отдельно проверяется, что щелчок доходит до
/// приложения через messageHandler. Запускается `--learn-selftest`.
final class LearnCheck: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private let done: (Int32) -> Void
    private var failures = 0
    private var clickSelector: String?

    /// Две типовые формы: Keycloak (id) и Microsoft (name + кнопка с id).
    private static let page = """
    <html><body>
      <div class="alert alert-error" id="passwordError">Неверный пароль</div>
      <div id="hiddenStep" style="display:none">поле следующего шага</div>
      <form>
        <input type="text" id="username" name="username" autocomplete="username">
        <input type="password" id="password" name="password">
        <input type="tel" name="otc" maxlength="6" autocomplete="one-time-code">
        <button type="submit" id="kc-login"><span id="lbl">Войти</span></button>
      </form>
      <form>
        <input type="email" name="loginfmt">
        <input type="submit" value="Далее" data-report-event="Signin_Submit">
      </form>
    </body></html>
    """

    init(completion: @escaping (Int32) -> Void) { self.done = completion; super.init() }

    func start() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let c = WKUserContentController()
        c.add(self, name: "ocbarLearn")
        c.addUserScript(WKUserScript(source: LearnSession.pageScript, injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true))
        cfg.userContentController = c
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: cfg)
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.test/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let cases: [(String, String, String)] = [
            ("#username", "username", "input[id=username]"),
            ("#password", "password", "input[id=password]"),
            ("input[name=otc]", "totp", "input[name=otc]"),
            ("#lbl", "click", "button[id=kc-login]"),          // щелчок по тексту внутри кнопки
            ("input[name=loginfmt]", "username", "input[name=loginfmt]"),
            ("#passwordError", "stop", "div[id=passwordError]"),
        ]
        var pending = cases.count
        for (query, kind, expected) in cases {
            let js = "window.__ocbarSet(true, \(LearnSession.js(kind))); window.__ocbarSelector(document.querySelector(\(LearnSession.js(query))))"
            webView.evaluateJavaScript(js) { [weak self] value, error in
                guard let self else { return }
                let got = (value as? String) ?? "ошибка: \(error.map { "\($0)" } ?? "нет значения")"
                if got == expected {
                    print("  [ OK ] \(kind): \(query) → \(got)")
                } else {
                    print("  [FAIL] \(kind): \(query) → \(got), ожидалось \(expected)")
                    self.failures += 1
                }
                pending -= 1
                if pending == 0 { self.checkGuesses() }
            }
        }
    }

    /// Распознавание вида элемента: в режиме «Авто» человек просто щёлкает,
    /// а вид определяет страница.
    private func checkGuesses() {
        let cases: [(String, String)] = [
            ("#username", "username"),
            ("#password", "password"),
            ("input[name=otc]", "totp"),
            ("#lbl", "click"),                       // текст внутри кнопки
            ("input[name=loginfmt]", "username"),
            ("input[data-report-event=Signin_Submit]", "click"),
            ("#passwordError", "stop"),
        ]
        var pending = cases.count
        for (query, expected) in cases {
            let js = "window.__ocbarSet(true, 'auto'); window.__ocbarGuess(document.querySelector(\(LearnSession.js(query))))"
            webView.evaluateJavaScript(js) { [weak self] value, _ in
                guard let self else { return }
                let got = (value as? String) ?? "нет значения"
                if got == expected {
                    print("  [ OK ] авто: \(query) → \(got)")
                } else {
                    print("  [FAIL] авто: \(query) → \(got), ожидалось \(expected)")
                    self.failures += 1
                }
                pending -= 1
                if pending == 0 { self.checkVerify { self.checkClick() } }
            }
        }
    }

    /// Щелчок мышью: синтетическое событие должно дойти до приложения и не
    /// нажать саму кнопку (иначе разметка отправляла бы форму).
    /// Кнопка «Проверить» в окне разметки: скрытое поле и отсутствующее
    /// должны различаться, иначе проверка бесполезна.
    private func checkVerify(_ then: @escaping () -> Void) {
        let selectors = ["input[id=username]", "button[id=kc-login]", "div[id=hiddenStep]", "div[id=nosuch]"]
        webView.evaluateJavaScript(LearnSession.checkScript(for: selectors)) { [weak self] value, _ in
            guard let self else { return }
            let got = (value as? [Int]) ?? []
            let want = [2, 2, 1, 0]
            if got == want {
                print("  [ OK ] проверка правил на странице: \(got)")
            } else {
                print("  [FAIL] проверка правил: \(got), ожидалось \(want)")
                self.failures += 1
            }
            then()
        }
    }

    private func checkClick() {
        webView.evaluateJavaScript("""
        window.__ocbarSet(true, 'click');
        window.__ocbarSubmitted = false;
        document.querySelector('#kc-login').addEventListener('click', function(){ window.__ocbarSubmitted = true; });
        document.querySelector('#lbl').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
        'ok'
        """) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                if self.clickSelector == "button[id=kc-login]" {
                    print("  [ OK ] щелчок дошёл до приложения: \(self.clickSelector ?? "")")
                } else {
                    print("  [FAIL] щелчок не дошёл (получено: \(self.clickSelector ?? "ничего"))")
                    self.failures += 1
                }
                self.webView.evaluateJavaScript("window.__ocbarSubmitted") { v, _ in
                    if (v as? Bool) == false {
                        print("  [ OK ] кнопка при этом не нажалась")
                    } else {
                        print("  [FAIL] щелчок разметки нажал кнопку — форма ушла бы")
                        self.failures += 1
                    }
                    print(self.failures == 0 ? "learn-selftest: всё OK" : "learn-selftest: провалов \(self.failures)")
                    self.done(self.failures == 0 ? 0 : 1)
                }
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        clickSelector = (message.body as? [String: Any])?["selector"] as? String
    }
}
