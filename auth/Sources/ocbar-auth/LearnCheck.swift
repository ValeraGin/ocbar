import AppKit
import WebKit
import Foundation

/// Проверка разметки без человека: страница-образец грузится в такой же
/// WKWebView с тем же внедрённым скриптом, у неё спрашиваются селекторы для
/// известных элементов, и отдельно проверяется, что щелчок доходит до
/// приложения через messageHandler. Запускается `--learn-selftest`.
///
/// Скрипты ocbar работают каждый в своём изолированном мире, как в жизни:
/// разметка — LearnSession.world, движок входа — WebAuth.world, запись
/// входа — TeachRecorder.world. Страница-образец — в своём, обычном.
final class LearnCheck: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    private var webView: WKWebView!
    private let done: (Int32) -> Void
    private var failures = 0
    private var passed = 0
    private var clickSelector: String?
    private var messages = 0
    private var teach: TeachRecorder?
    private var popupView: WKWebView?
    private var popups: [String] = []
    private var popupThen: (() -> Void)?

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
      <div id="twostep">
        <div id="s1err" style="display:none">Неверный пароль</div>
        <div id="s1">
          <input type="text" id="s1user"><input type="password" id="s1pass">
          <button type="button" id="s1next" onclick="document.getElementById('s1').style.display='none'; document.getElementById('s2').style.display='block'">Далее</button>
        </div>
        <div id="s2" style="display:none">
          <input type="text" id="s2otp" maxlength="6">
          <button type="button" id="s2done" onclick="window.__twoDone = true">Войти</button>
        </div>
      </div>
      <div id="ms">
        <div id="msf"><input type="text" id="msu"><input type="password" id="msp"></div>
        <input type="submit" id="msbtn" value="Войти" onclick="window.__msClick()">
      </div>
      <div id="teachbox">
        <form id="tf1" onsubmit="event.preventDefault(); if (document.getElementById('tp').value.indexOf('верный') === 0) { this.style.display = 'none'; document.getElementById('tf2').style.display = 'block'; }">
          <input type="text" id="tu"><input type="password" id="tp"><button type="button" id="teye">глаз</button><button type="submit" id="tgo">Войти</button>
        </form>
        <form id="tf2" style="display:none" onsubmit="event.preventDefault(); this.style.display = 'none'; document.getElementById('tf3').style.display = 'block';">
          <input type="text" name="totp" id="tc"><input type="text" id="tcap"><input type="submit" id="tok" value="Подтвердить">
        </form>
        <form id="tf3" style="display:none" onsubmit="event.preventDefault(); window.__teachDone = true;">
          <input type="submit" id="tkmsi" value="Да">
        </form>
      </div>
      <form id="pf1"><input id="pfu" autocomplete="username"><input type="password" id="pfp" autocomplete="current-password"><button id="pfb">Войти</button></form>
      <form id="pf2"><input type="text" name="username" id="u2" autocomplete="on"><input type="password" id="p2" autocomplete="on"><input type="checkbox" id="rm2"><button type="submit" id="b2">Войти</button></form>
      <form id="pf3"><input type="text" name="totp" id="t3"><input type="submit" id="s3" value="Войти"></form>
      <form id="pf4"><input type="password" id="a4"><input type="password" id="c4"><button id="d4">Сменить</button></form>
      <form id="pf5" style="display:none"><input id="h5" autocomplete="username"><button id="k5">Войти</button></form>
      <form id="pf6"><input id="w6" autocomplete="username webauthn"><button type="submit" id="b6">Далее</button></form>
      <form id="cf" onsubmit="event.preventDefault()"><input type="text" id="cu"><input type="password" id="cp"><input type="text" id="ccap"><button type="submit" id="cgo">Войти</button></form>
      <form id="vf" onsubmit="event.preventDefault(); window.__vSent = (window.__vSent || 0) + 1"><input type="password" id="vp"><button type="submit" id="vgo" disabled>Sign In</button></form>
      <form id="hf" onsubmit="event.preventDefault()"><input type="text" id="hu"><input type="password" id="hp"></form>
      <form id="of" onsubmit="event.preventDefault(); this.style.display = 'none'; document.getElementById('og').style.display = 'block';">
        <input type="text" id="ou"><input type="password" id="opw"><button type="submit" id="ogo">Войти</button>
      </form>
      <form id="og" style="display:none" onsubmit="event.preventDefault(); window.__ogDone = true;">
        <input type="password" id="ocode" name="otp" inputmode="numeric" maxlength="6" autocomplete="one-time-code"><button type="submit" id="ogo2">Подтвердить</button>
      </form>
      <script>
        window.__msStage = 0;
        window.__msClick = function () {
          var f = document.getElementById('msf');
          if (f.style.display !== 'none') { f.style.display = 'none'; document.getElementById('msbtn').value = 'Да'; window.__msStage = 1; }
          else { window.__msStage = 2; }
        };
        window.__msReset = function () {
          document.getElementById('msf').style.display = 'block';
          ['msu', 'msp'].forEach(function (i) { document.getElementById(i).value = ''; });
          document.getElementById('msbtn').value = 'Войти';
          window.__msStage = 0;
        };
        window.__teachReset = function () {
          document.getElementById('tf1').style.display = 'block';
          document.getElementById('tf2').style.display = 'none';
          document.getElementById('tf3').style.display = 'none';
          ['tu', 'tp', 'tc', 'tcap'].forEach(function (i) { document.getElementById(i).value = ''; });
          window.__teachDone = false;
        };
        window.__twoReset = function () {
          document.getElementById('s1').style.display = 'block';
          document.getElementById('s2').style.display = 'none';
          ['s1user', 's1pass', 's2otp'].forEach(function (i) { document.getElementById(i).value = ''; });
          window.__twoDone = false;
        };
        // Портал с капчей, который перерисовывает форму: поля пустеют.
        document.getElementById('vp').addEventListener('input', function () {
          setTimeout(function () { document.getElementById('vgo').disabled = !document.getElementById('vp').value; }, 60);
        });
        window.__capRedraw = function () {
          ['cu', 'cp', 'ccap'].forEach(function (i) { document.getElementById(i).value = ''; });
        };
      </script>
    </body></html>
    """

    init(completion: @escaping (Int32) -> Void) { self.done = completion; super.init() }

    func start() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let c = WKUserContentController()
        c.add(self, contentWorld: LearnSession.world, name: "ocbarLearn")
        c.addUserScript(WKUserScript(source: LearnSession.pageScript, injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true, in: LearnSession.world))
        cfg.userContentController = c
        let t = TeachRecorder(username: "alice")
        t.install(into: c)
        teach = t
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), configuration: cfg)
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.test/"))
    }

    // MARK: - помощники

    private func ok(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond { print("  [ OK ] \(name)"); passed += 1 }
        else { print("  [FAIL] \(name)\(detail.isEmpty ? "" : " — " + detail)"); failures += 1 }
    }

    /// В мире страницы — так действует сама страница (или человек в тесте).
    private func eval(_ js: String, _ cb: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(js) { v, _ in cb(v) }
    }

    /// В мире разметки — так действует окно разметки.
    private func learn(_ js: String, _ cb: @escaping (Any?) -> Void) {
        LearnSession.eval(webView, js) { v, _ in cb(v) }
    }

    /// В мире окна входа — так действует движок автозаполнения.
    private func engine(_ js: String, _ cb: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(js, in: nil, in: WebAuth.world) { r in
            if case .success(let v) = r { cb(v) } else { cb(nil) }
        }
    }

    private func after(_ s: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
    }

    // MARK: - селекторы и распознавание

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === popupView {
            after(0.5) { [weak self] in self?.popupThen?() }
            return
        }
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
            learn(js) { [weak self] value in
                guard let self else { return }
                let got = (value as? String) ?? "нет значения"
                self.ok("\(kind): \(query) → \(got)", got == expected, "ожидалось \(expected)")
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
            learn(js) { [weak self] value in
                guard let self else { return }
                let got = (value as? String) ?? "нет значения"
                self.ok("авто: \(query) → \(got)", got == expected, "ожидалось \(expected)")
                pending -= 1
                if pending == 0 {
                    self.checkVerify { self.checkSteps { self.checkRootClick { self.checkPrefill { self.checkAlways {
                        self.checkTeach { self.checkClick { self.checkLearnIsolation { self.checkCaptchaLimits {
                            self.checkHostGuard { self.checkPopups { self.finish() } } } } } } } } } } }
                }
            }
        }
    }

    private func finish() {
        print("проверок: \(passed + failures), провалов: \(failures)")
        print(failures == 0 ? "learn-selftest: всё OK" : "learn-selftest: провалов \(failures)")
        done(failures == 0 ? 0 : 1)
    }

    /// Кнопка «Проверить» в окне разметки: скрытое поле и отсутствующее
    /// должны различаться, иначе проверка бесполезна.
    private func checkVerify(_ then: @escaping () -> Void) {
        let selectors = ["input[id=username]", "button[id=kc-login]", "div[id=hiddenStep]", "div[id=nosuch]"]
        learn(LearnSession.checkScript(for: selectors)) { [weak self] value in
            guard let self else { return }
            let got = (value as? [Int]) ?? []
            self.ok("проверка правил на странице: \(got)", got == [2, 2, 1, 0], "ожидалось [2, 2, 1, 0]")
            then()
        }
    }

    /// Форма в два окна: сначала логин и пароль, потом отдельное окно с
    /// кодом. Проверяется трижды: как размеченное пишется в правила (блоками
    /// по шагам), что движок входа проходит оба окна по этим правилам, и что
    /// кнопка «Пройти шаг» заполняет и жмёт, а без пароля — не жмёт.
    private func checkSteps(_ then: @escaping () -> Void) {
        typealias M = LearnSession.Mark
        let marks = [
            M(kind: "stop", selector: "div[id=s1err]", hint: "", step: 1),
            M(kind: "username", selector: "input[id=s1user]", hint: "", step: 1),
            M(kind: "password", selector: "input[id=s1pass]", hint: "", step: 1),
            M(kind: "click", selector: "button[id=s1next]", hint: "", step: 1),
            M(kind: "totp", selector: "input[id=s2otp]", hint: "", step: 3),     // шаг 2 пуст: перенумерация
            M(kind: "click", selector: "button[id=s2done]", hint: "", step: 3),
        ]
        let text = LearnSession.rulesText(marks: marks, pages: [1: "idp.test/login", 3: "idp.test/otp"],
                                          portal: "example.test", formHost: "idp.test")
        let body = text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
            .split(separator: "\n").map(String.init)
        let want = ["stop  div[id=s1err]", "# шаг 1 — idp.test/login", "fill  username input[id=s1user]",
                    "fill  password input[id=s1pass]", "click button[id=s1next]", "# шаг 2 — idp.test/otp",
                    "fill  totp input[id=s2otp]", "click button[id=s2done]"]
        ok("шаги: правила блоками по окнам, пустой шаг перенумерован", body == want, body.joined(separator: " | "))
        let single = LearnSession.rulesText(marks: marks.map { var m = $0; m.step = 1; return m },
                                            pages: [:], portal: "example.test", formHost: nil)
        ok("шаги: одно окно — без заголовков шагов", !single.contains("# шаг"))

        // Движок входа по размеченным правилам: два прохода — два окна.
        let run = Autofill.script(rules: Autofill.parse(text: text),
                                  creds: Credentials(username: "alice", password: "pw", totpSecret: nil),
                                  totpCode: "123456", allowed: [["h": "example.test", "s": false]])
        learn("window.__ocbarSet(false, 'auto'); 0") { _ in
        self.eval("window.__twoReset(); 'ok'") { _ in
            self.engine(run) { r1 in
                let d1 = r1 as? [String: Any] ?? [:]
                self.ok("движок, окно 1: логин и пароль, «Далее»",
                        (d1["clicked"] as? String) == "button[id=s1next]" && (d1["filled"] as? [String]) == ["username", "password"], "\(d1)")
                self.engine(run) { r2 in
                    let d2 = r2 as? [String: Any] ?? [:]
                    self.ok("движок, окно 2: код, «Войти»",
                            (d2["clicked"] as? String) == "button[id=s2done]" && (d2["filled"] as? [String]) == ["totp"], "\(d2)")
                    self.eval("[window.__twoDone === true, document.getElementById('s1user').value, document.getElementById('s2otp').value]") { r3 in
                        let a = r3 as? [Any] ?? []
                        self.ok("движок прошёл оба окна", a.count == 3 && (a[0] as? Bool) == true
                                && (a[1] as? String) == "alice" && (a[2] as? String) == "123456", "\(a)")
                        self.checkPass(then)
                    }
                }
            }
        }
        }
    }

    private func checkPass(_ then: @escaping () -> Void) {
        let noPassword = LearnSession.passScript(
            fills: [("username", "input[id=s1user]", "alice"), ("password", "input[id=s1pass]", nil)],
            clicks: ["button[id=s1next]"])
        let step1 = LearnSession.passScript(
            fills: [("username", "input[id=s1user]", "alice"), ("password", "input[id=s1pass]", "pw")],
            clicks: ["button[id=s1next]"])
        let step2 = LearnSession.passScript(fills: [("totp", "input[id=s2otp]", "654321")],
                                            clicks: ["button[id=s2done]"])
        eval("window.__twoReset(); 'ok'") { _ in
            self.learn(noPassword) { p1 in
                let d = p1 as? [String: Any] ?? [:]
                self.ok("«Пройти шаг» без пароля кнопку не жмёт", (d["missing"] as? [String]) == ["password"] && d["clicked"] == nil, "\(d)")
                self.learn(step1) { p2 in
                    let d = p2 as? [String: Any] ?? [:]
                    self.ok("«Пройти шаг», окно 1: введённое человеком не трогает, пароль заполняет, жмёт «Далее»",
                            (d["clicked"] as? String) == "button[id=s1next]" && (d["filled"] as? [String]) == ["password"], "\(d)")
                    self.learn(step2) { p3 in
                        let d = p3 as? [String: Any] ?? [:]
                        self.ok("«Пройти шаг», окно 2: код и «Войти»",
                                (d["clicked"] as? String) == "button[id=s2done]" && (d["filled"] as? [String]) == ["totp"], "\(d)")
                        self.eval("[window.__twoDone === true, document.getElementById('s2otp').value]") { r in
                            let a = r as? [Any] ?? []
                            self.ok("форма пройдена кнопкой «Пройти шаг»", a.count == 2 && (a[0] as? Bool) == true
                                    && (a[1] as? String) == "654321", "\(a)")
                            then()
                        }
                    }
                }
            }
        }
    }

    /// Щелчок по пустому месту страницы не должен стать правилом: «stop html»
    /// остановил бы автозаполнение на любой странице — html виден всегда.
    /// Так и случилось на живом окне 2026-09-10: пара случайных щелчков дала
    /// отметку «ошибка=html». Щелчок здесь синтетический — он считается
    /// щелчком человека только с __ocbarTrustSynthetic.
    private func checkRootClick(_ then: @escaping () -> Void) {
        let before = messages
        learn("window.__ocbarSet(true, 'auto'); window.__ocbarTrustSynthetic = true; 0") { _ in
            self.eval("""
            document.body.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
            document.documentElement.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
            'ok'
            """) { _ in
                self.after(0.3) {
                    self.ok("щелчок по пустому месту не стал отметкой", self.messages == before, self.clickSelector ?? "?")
                    self.learn("window.__ocbarTrustSynthetic = false; 0") { _ in then() }
                }
            }
        }
    }

    /// Предзаполнение разметки: что узнаётся без человека и почему. Случай
    /// «autocomplete=on» повторяет первое окно рабочего портала, снятое
    /// 2026-09-10: стандарт там молчит, узнаются пароль по типу, логин как
    /// поле перед паролем и кнопка формы по умолчанию. «name=totp» — второе
    /// окно того же портала по журналу входа.
    private func checkPrefill(_ then: @escaping () -> Void) {
        let cases: [(String, String, [String])] = [
            ("предзаполнение: токены autocomplete из стандарта", "#pf1",
             ["username input[id=pfu] autocomplete=username",
              "password input[id=pfp] autocomplete=current-password",
              "click button[id=pfb] кнопка формы по умолчанию"]),
            ("предзаполнение: autocomplete=on, как на рабочем портале", "#pf2",
             ["password input[id=p2] type=password",
              "username input[id=u2] поле перед паролем",
              "click button[id=b2] кнопка формы по умолчанию"]),
            ("предзаполнение: окно кода name=totp", "#pf3",
             ["totp input[id=t3] похоже на поле кода",
              "click input[id=s3] кнопка формы по умолчанию"]),
            ("предзаполнение: два поля пароля — не угадываем", "#pf4", []),
            ("предзаполнение: скрытая форма не смотрится", "#pf5", []),
            ("предзаполнение: «username webauthn», селектор без пробелов", "#pf6",
             ["username input[id=w6] autocomplete=username",
              "click button[id=b6] кнопка формы по умолчанию"]),
        ]
        func run(_ i: Int) {
            guard i < cases.count else { showMarksCheck(); return }
            let (name, root, want) = cases[i]
            learn("JSON.stringify(window.__ocbarPrefill(document.querySelector(\(LearnSession.js(root)))))") { v in
                let arr = ((v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                           as? [[String: String]]) ?? []
                let got = arr.map { "\($0["kind"] ?? "") \($0["selector"] ?? "") \($0["why"] ?? "")" }
                self.ok(name, got.count == want.count && Set(got) == Set(want), got.joined(separator: " | "))
                run(i + 1)
            }
        }
        func showMarksCheck() {
            learn("""
            window.__ocbarShowMarks(['input[id=pfu]']); window.__ocbarShowMarks(['input[id=pfp]']);
            var r = [document.getElementById('pfu').hasAttribute('data-ocbar-mark'),
                     document.getElementById('pfp').hasAttribute('data-ocbar-mark')];
            window.__ocbarShowMarks([]); r
            """) { v in
                let a = v as? [Any] ?? []
                self.ok("подсветка отметок: прежняя снимается, текущая видна",
                        a.count == 2 && (a[0] as? Bool) == false && (a[1] as? Bool) == true, "\(a)")
                then()
            }
        }
        run(0)
    }

    /// Экран без полей и общая кнопка — как у Microsoft: одна и та же кнопка
    /// «Войти», потом «Да» на «Остаться в системе?». Разметка пишет кнопку
    /// окна без полей как click!, движок проходит оба экрана — и главное:
    /// без пароля не нажимает ни одну кнопку, пустой пароль не уходит.
    private func checkAlways(_ then: @escaping () -> Void) {
        typealias M = LearnSession.Mark
        let marks = [
            M(kind: "username", selector: "input[id=msu]", hint: "", step: 1),
            M(kind: "password", selector: "input[id=msp]", hint: "", step: 1),
            M(kind: "click", selector: "input[id=msbtn]", hint: "", step: 1),
            M(kind: "click", selector: "input[id=msbtn]", hint: "", step: 2),
        ]
        let text = LearnSession.rulesText(marks: marks, pages: [1: "ms.test/login", 2: "ms.test/kmsi"],
                                          portal: "ms.test", formHost: nil)
        let body = text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
            .split(separator: "\n").map(String.init)
        ok("экран без полей: кнопка записана как click!",
           body == ["# шаг 1 — ms.test/login", "fill  username input[id=msu]", "fill  password input[id=msp]",
                    "click input[id=msbtn]", "# шаг 2 — ms.test/kmsi", "click! input[id=msbtn]"], body.joined(separator: " | "))
        let forced = LearnSession.rulesText(
            marks: [M(kind: "username", selector: "input[id=msu]", hint: "", step: 1),
                    M(kind: "click!", selector: "a[id=other]", hint: "", step: 1)],
            pages: [:], portal: "ms.test", formHost: nil)
        ok("вид «Всегда» остаётся click! и на окне с полями", forced.contains("click! a[id=other]"))

        let rules = Autofill.parse(text: text)
        let here: [[String: Any]] = [["h": "example.test", "s": false]]
        let full = Autofill.script(rules: rules, creds: Credentials(username: "alice", password: "pw", totpSecret: nil), totpCode: nil, allowed: here)
        let noPassword = Autofill.script(rules: rules, creds: Credentials(username: "alice", password: nil, totpSecret: nil), totpCode: nil, allowed: here)
        let pass = LearnSession.passScript(fills: [], clicks: ["input[id=msbtn]"])
        learn("window.__ocbarSet(false, 'auto'); 0") { _ in
        self.eval("window.__msReset(); 'ok'") { _ in
            self.engine(full) { _ in
                self.engine(full) { _ in
                    self.eval("window.__msStage") { st in
                        self.ok("движок: «Войти», затем «Да» на экране без полей", (st as? Int) == 2, "стадия \(st ?? "?")")
                        self.eval("window.__msReset(); 'ok'") { _ in
                            self.engine(noPassword) { r in
                                let d = r as? [String: Any] ?? [:]
                                self.engine(noPassword) { _ in
                                    self.eval("[window.__msStage, document.getElementById('msu').value]") { v in
                                        let a = v as? [Any] ?? []
                                        self.ok("без пароля ни одна кнопка не нажата, пустой пароль не ушёл",
                                                a.count == 2 && (a[0] as? Int) == 0 && (a[1] as? String) == "alice"
                                                && d["clicked"] == nil && (d["waiting"] as? String) == "input[id=msp]", "\(a) \(d)")
                                        self.eval("window.__msReset(); window.__msClick(); 'ok'") { _ in
                                            self.learn(pass) { _ in
                                                self.eval("window.__msStage") { st2 in
                                                    self.ok("«Пройти шаг» на экране без полей жмёт кнопку", (st2 as? Int) == 2, "стадия \(st2 ?? "?")")
                                                    then()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        }
    }

    /// Запись входа при настоящем входе (TeachRecorder). Изоляция: страница
    /// не видит обработчик и не может включить запись сама. Запись: ошибся
    /// паролем, нажал «показать пароль», ввёл верный, потом код и капчу, потом
    /// «Да» — должно получиться ровно три окна. Движок по записанному
    /// проходит форму, а на пустой капче (fill manual) останавливается.
    private func checkTeach(_ then: @escaping () -> Void) {
        guard let rec = teach else { ok("запись входа установлена", false); then(); return }
        checkCameraQR()

        // Секрет TOTP принимается только по введённому коду.
        let rfc = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let t0 = Date(timeIntervalSince1970: 1_111_111_109)
        let c0 = TOTP.code(secretBase32: rfc, at: t0) ?? ""
        ok("секрет TOTP: даёт введённый код — принят", TeachDialog.secretMatches(rfc, code: c0, at: t0.addingTimeInterval(20)))
        ok("секрет TOTP: запись с пробелами и строчными — тот же секрет",
           TeachDialog.secretMatches("gezd gnbv gy3t qojq gezd gnbv gy3t qojq", code: c0, at: t0))
        ok("секрет TOTP: чужой секрет — отвергнут", !TeachDialog.secretMatches("JBSWY3DPEHPK3PXP", code: c0, at: t0))
        ok("секрет TOTP: код трёхминутной давности — отвергнут", !TeachDialog.secretMatches(rfc, code: c0, at: t0.addingTimeInterval(180)))
        // Параметры кода (RFC 6238): запись со своими параметрами из ссылки,
        // параметры голого секрета — по введённому коду, HOTP — нет.
        let s256 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA"
        let s512 = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA"
        let p256 = TOTPParams(algorithm: "SHA256", digits: 8, period: 60)
        let c256 = TOTP.code(secretBase32: s256, at: t0, params: p256) ?? ""
        if let e = (try? QRImport.parse("otpauth://totp/VPN:alice?secret=\(s256)&algorithm=SHA256&digits=8&period=60"))?.first {
            ok("параметры: ссылка otpauth с SHA256, 8 цифр, 60 с — запись подходит",
               TeachDialog.entryMatches(e, code: c256, at: t0.addingTimeInterval(40)), e.params.label)
        } else { ok("параметры: ссылка otpauth разобрана", false, "") }
        let p512 = TOTPParams(algorithm: "SHA512", digits: 8, period: 60)
        let c512 = TOTP.code(secretBase32: s512, at: t0, params: p512) ?? ""
        let found = TeachDialog.matchParams(s512, code: c512, at: t0)
        ok("параметры: у голого секрета определены по введённому коду", found == p512, found?.label ?? "не определены")
        if let h = (try? QRImport.parse("otpauth://hotp/VPN:alice?secret=\(rfc)&counter=1"))?.first {
            ok("параметры: HOTP не принимается", !TeachDialog.entryMatches(h, code: c0, at: t0), "")
        }
        ok("параметры: MD5 не поддерживается", !TOTPParams(algorithm: "MD5").isSupported, "")
        let line = KeychainWriter.line(service: "ru.ocbar.client", account: "alice", label: "ocbar-VPN-password", secret: "a b\"") ?? ""
        ok("связка: значение идёт шестнадцатеричной строкой, не в открытом виде",
           line.contains("-X 61206222") && !line.contains("a b"), line)
        ok("связка: имя сервиса с пробелом отвергнуто",
           KeychainWriter.line(service: "ru ocbar", account: "alice", label: "x", secret: "p") == nil)

        rec.enabled = false
        rec.apply(to: webView)                       // флаг в изолированном мире — выключен
        rec.enabled = true                           // приложение готово принять, но страница не включит
        learn("window.__ocbarSet(false, 'auto'); 0") { _ in
            self.eval("""
            window.__teachReset();
            var seen = typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ocbarTeach);
            window.__ocbarTeachOn = true;
            document.getElementById('tu').value = 'alice'; document.getElementById('tp').value = 'верный';
            document.getElementById('tgo').click();
            seen
            """) { seen in
                self.after(0.4) {
                    self.ok("изоляция: страница не видит обработчик записи", (seen as? String) == "undefined", "\(seen ?? "?")")
                    self.ok("изоляция: страница не включает запись сама", rec.steps.isEmpty, "\(rec.steps.count) окон")
                    // Запись включена, синтетические события — не в счёт.
                    rec.apply(to: self.webView)
                    self.after(0.3) {
                        self.checkForgedSubmit(rec) {
                            // Дальше «человек» — синтетические события теста.
                            rec.trustSynthetic = true
                            rec.apply(to: self.webView)
                            self.after(0.2) { self.checkTeachCapture(rec) { self.checkCodeAsPassword(rec, then) } }
                        }
                    }
                }
            }
        }
    }

    /// Страница сама «отправляет форму» с подложным паролем: el.click(),
    /// form.requestSubmit() (WebKit помечает такой submit как isTrusted),
    /// dispatchEvent. Ни одно не должно стать окном записи и паролем.
    private func checkForgedSubmit(_ rec: TeachRecorder, _ then: @escaping () -> Void) {
        eval("""
        window.__teachReset();
        document.getElementById('tu').value = 'alice'; document.getElementById('tp').value = 'верный подложный 1';
        document.getElementById('tgo').click();
        window.__teachReset();
        document.getElementById('tu').value = 'alice'; document.getElementById('tp').value = 'верный подложный 2';
        document.getElementById('tf1').requestSubmit();
        window.__teachReset();
        document.getElementById('tu').value = 'alice'; document.getElementById('tp').value = 'верный подложный 3';
        document.getElementById('tf1').dispatchEvent(new Event('submit', {bubbles: true, cancelable: true}));
        window.__twoReset();
        document.getElementById('s1user').value = 'alice'; document.getElementById('s1pass').value = 'подложный 4';
        document.getElementById('s1next').click();
        window.__twoReset(); window.__teachReset();
        'ok'
        """) { _ in
            self.after(0.4) {
                self.ok("запись: отправку, которую страница сделала сама (click, requestSubmit, dispatchEvent), не записывает",
                        rec.steps.isEmpty && rec.password == nil,
                        "окон \(rec.steps.count), пароль \(rec.password == nil ? "нет" : "записан")")
                then()
            }
        }
    }

    /// Поле кода с type=password (autocomplete one-time-code, inputmode
    /// numeric, maxlength 6, name=otp): код, а не пароль. Паролем остаётся
    /// введённый на первом окне.
    private func checkCodeAsPassword(_ rec: TeachRecorder, _ then: @escaping () -> Void) {
        rec.enabled = true
        rec.trustSynthetic = true
        rec.apply(to: webView)
        let before = rec.steps.count
        after(0.2) {
            self.eval("""
            document.getElementById('of').style.display = ''; document.getElementById('og').style.display = 'none';
            document.getElementById('ou').value = 'alice'; document.getElementById('opw').value = 'настоящий пароль';
            document.getElementById('ogo').click();
            document.getElementById('ocode').value = '482913';
            document.getElementById('ogo2').click();
            'ok'
            """) { _ in
                self.after(0.5) {
                    let new = rec.steps.dropFirst(before)
                    let shape = new.map { s in s.fields.map { "\($0.kind) \($0.selector)" }.joined(separator: ", ") + " → " + (s.button ?? "-") }
                    self.ok("запись: поле кода с type=password записано как код",
                            shape == ["username input[id=ou], password input[id=opw] → button[id=ogo]",
                                      "totp input[id=ocode] → button[id=ogo2]"], shape.joined(separator: " | "))
                    self.ok("запись: паролем остался пароль, а не код", rec.password == "настоящий пароль",
                            rec.password == "482913" ? "паролем записан код" : "")
                    self.ok("запись: код из поля type=password запомнен для проверки секрета", rec.code == "482913")
                    rec.enabled = false
                    rec.trustSynthetic = false
                    rec.apply(to: self.webView)
                    rec.forgetSecrets()
                    self.eval("document.getElementById('of').style.display = 'none'; document.getElementById('og').style.display = 'none'; 'ok'") { _ in then() }
                }
            }
        }
    }

    /// QR с камеры — без камеры: кадр собирается в памяти так, как его отдала
    /// бы камера (BGRA 1280×720, QR экспорта Google Authenticator на две
    /// записи наклонён и смещён), и идёт тем же путём, что настоящие кадры.
    private func checkCameraQR() {
        let ours = Data((0..<20).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let other = Data((0..<20).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
        let payload = Self.migrationPayload([(other, "someone@example.com", "Другое"), (ours, "alice", "VPN")])
        let at = Date()
        let code = TOTP.code(secretBase32: QRImport.base32Encode(ours), at: at) ?? ""
        guard let frame = Self.cameraFrame(qr: payload) else { ok("камера: кадр собран", false, ""); return }
        let found = QRCameraScanner.payloads(pixelBuffer: frame)
        ok("камера: QR найден на кадре 1280×720, наклонён и смещён", found == [payload], "строк: \(found.count)")
        let entries = found.flatMap { (try? QRImport.parse($0)) ?? [] }
        ok("камера: экспорт Google Authenticator разобран, записей две", entries.count == 2, "\(entries.count)")
        let fit = entries.filter { QRCameraWindow.fits($0, code: code, at: at) }
        ok("камера: нужная запись выбрана по введённому коду", fit.count == 1 && fit.first?.name == "alice",
           fit.map(\.name).joined(separator: ", "))
        let empty = Self.cameraFrame(qr: nil).map { QRCameraScanner.payloads(pixelBuffer: $0) } ?? ["?"]
        ok("камера: кадр без QR — пусто", empty.isEmpty, "\(empty)")
    }

    /// Экспорт Google Authenticator: otpauth-migration с protobuf внутри —
    /// ровно то, что показывает «Перенос аккаунтов → Экспорт».
    static func migrationPayload(_ items: [(Data, String, String)]) -> String {
        func varint(_ value: Int) -> Data {
            var v = value, d = Data()
            repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; d.append(b) } while v != 0
            return d
        }
        func bytes(_ n: Int, _ b: Data) -> Data { varint(n << 3 | 2) + varint(b.count) + b }
        func number(_ n: Int, _ v: Int) -> Data { varint(n << 3) + varint(v) }
        var payload = Data()
        for (secret, name, issuer) in items {
            let p = bytes(1, secret) + bytes(2, Data(name.utf8)) + bytes(3, Data(issuer.utf8))
                + number(4, 1) + number(5, 1) + number(6, 2)
            payload += bytes(1, p)
        }
        payload += number(2, 1) + number(3, 1) + number(4, 0) + number(5, 0)
        let b64 = payload.base64EncodedString()
        return "otpauth-migration://offline?data=" + (b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64)
    }

    /// Кадр, как его отдаёт камера: BGRA 1280×720, серый фон, QR в белой
    /// рамке, как на экране телефона, наклонён и не по центру.
    static func cameraFrame(qr payload: String?) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        var img = CIImage(color: CIColor(red: 0.35, green: 0.37, blue: 0.40)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        if let payload, let f = CIFilter(name: "CIQRCodeGenerator") {
            f.setValue(Data(payload.utf8), forKey: "inputMessage")
            f.setValue("M", forKey: "inputCorrectionLevel")
            if var q = f.outputImage {
                q = q.samplingNearest().transformed(by: CGAffineTransform(scaleX: 320 / q.extent.width, y: 320 / q.extent.width))
                q = q.composited(over: CIImage(color: .white).cropped(to: q.extent.insetBy(dx: -24, dy: -24)))
                let r = q.transformed(by: CGAffineTransform(rotationAngle: 0.14))
                img = r.transformed(by: CGAffineTransform(translationX: 760 - r.extent.minX, y: 150 - r.extent.minY)).composited(over: img)
            }
        }
        CIContext().render(img, to: buf)
        return buf
    }

    private func checkTeachCapture(_ rec: TeachRecorder, _ then: @escaping () -> Void) {
        let human = """
        window.__teachReset();
        var u = document.getElementById('tu'), p = document.getElementById('tp');
        u.value = 'alice'; p.value = 'не "тот" пароль';
        document.getElementById('teye').click();
        document.getElementById('tgo').click();
        p.value = 'верный "пароль" с пробелом';
        document.getElementById('tgo').click();
        document.getElementById('tc').value = '123456';
        document.getElementById('tcap').value = 'xk3p';
        document.getElementById('tok').click();
        document.getElementById('tkmsi').click();
        String(window.__teachDone)
        """
        eval(human) { _ in
            self.after(0.6) {
                let st = rec.steps
                let shape = st.map { s in s.fields.map { "\($0.kind) \($0.selector)" }.joined(separator: ", ") + " → " + (s.button ?? "-") }
                self.ok("запись: три окна — «глаз» и повтор после ошибки не плодят шаги",
                        shape == ["username input[id=tu], password input[id=tp] → button[id=tgo]",
                                  "totp input[id=tc], manual input[id=tcap] → input[id=tok]",
                                  " → input[id=tkmsi]"], shape.joined(separator: " | "))
                self.ok("запись: логин узнан по совпадению с логином профиля",
                        st.first?.fields.first?.why == "введён логин профиля", "")
                self.ok("запись: сохранится последний, верный пароль", rec.password == "верный \"пароль\" с пробелом", "")
                self.ok("запись: введённый код запомнен для проверки секрета", rec.code == "123456", "")
                let text = rec.rulesText(portal: "example.test")
                let body = text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
                    .split(separator: "\n").map(String.init)
                let want = ["# шаг 1 — example.test/", "fill  username input[id=tu]", "fill  password input[id=tp]",
                            "click button[id=tgo]", "# шаг 2 — example.test/", "fill  totp input[id=tc]",
                            "fill  manual input[id=tcap]", "click input[id=tok]", "# шаг 3 — example.test/",
                            "click! input[id=tkmsi]"]
                self.ok("запись: правила — окна по порядку, признаки ошибки из встроенного набора впереди",
                        Array(body.drop { $0.hasPrefix("stop") }) == want && body.prefix { $0.hasPrefix("stop") }.count >= 3,
                        body.joined(separator: " | "))
                let run = Autofill.script(rules: Autofill.parse(text: text),
                                          creds: Credentials(username: "alice", password: "верный \"пароль\" с пробелом", totpSecret: nil),
                                          totpCode: "123456", allowed: [["h": "example.test", "s": false]])
                // Сначала на странице видна ошибка входа: встроенные признаки,
                // добавленные к записанному, должны остановить движок — иначе
                // пароль ушёл бы снова. Потом ошибку убираем и проходим форму.
                self.eval("window.__teachReset(); document.getElementById('passwordError').style.display = ''; 'ok'") { _ in
                  self.engine(run) { r0 in
                    let d0 = r0 as? [String: Any] ?? [:]
                    self.ok("движок по записанному: видна ошибка входа — стоит, пароль не уходит",
                            d0["stopped"] != nil && d0["clicked"] == nil, "\(d0)")
                    self.eval("window.__teachReset(); document.getElementById('passwordError').style.display = 'none'; 'ok'") { _ in
                    self.engine(run) { r1 in
                        let d1 = r1 as? [String: Any] ?? [:]
                        self.engine(run) { r2 in
                            let d2 = r2 as? [String: Any] ?? [:]
                            self.ok("движок по записанному: окно 1 пройдено", (d1["clicked"] as? String) == "button[id=tgo]", "\(d1)")
                            self.ok("движок по записанному: на пустой капче стоит и ждёт человека",
                                    d2["clicked"] == nil && (d2["waiting"] as? String) == "input[id=tcap]", "\(d2)")
                            self.eval("document.getElementById('tcap').value = 'xk3p'; document.getElementById('tok').click(); 'ok'") { _ in
                                self.engine(run) { _ in
                                    self.eval("String(window.__teachDone)") { done in
                                        self.ok("движок по записанному: после человека — «Да» на экране без полей",
                                                (done as? String) == "true", "\(done ?? "?")")
                                        rec.enabled = false
                                        rec.apply(to: self.webView)
                                        rec.forgetSecrets()
                                        self.eval("document.getElementById('passwordError').style.display = ''; 'ok'") { _ in then() }
                                    }
                                }
                            }
                        }
                    }
                    }
                  }
                }
            }
        }
    }

    /// Щелчок мышью: событие должно дойти до приложения и не нажать саму
    /// кнопку (иначе разметка отправляла бы форму). Щелчок синтетический —
    /// за щелчок человека он считается только с __ocbarTrustSynthetic.
    private func checkClick(_ then: @escaping () -> Void) {
        learn("window.__ocbarSet(true, 'click'); window.__ocbarTrustSynthetic = true; 0") { _ in
            self.eval("""
            window.__ocbarSubmitted = false;
            document.querySelector('#kc-login').addEventListener('click', function(){ window.__ocbarSubmitted = true; });
            document.querySelector('#lbl').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
            'ok'
            """) { _ in
                self.after(0.3) {
                    self.ok("щелчок дошёл до приложения: \(self.clickSelector ?? "ничего")",
                            self.clickSelector == "button[id=kc-login]")
                    self.eval("window.__ocbarSubmitted") { v in
                        self.ok("кнопка при этом не нажалась", (v as? Bool) == false)
                        self.learn("window.__ocbarTrustSynthetic = false; window.__ocbarSet(false, 'auto'); 0") { _ in then() }
                    }
                }
            }
        }
    }

    // MARK: - изоляция разметки (п.8 проверки 2026-09-10)

    /// Скрипт разметки — в изолированном мире: страница не видит __ocbar* и
    /// обработчик, её синтетический щелчок не становится отметкой, её
    /// подложное __ocbarPrefill не подменяет предзаполнение. И заголовок
    /// шага не рвётся переводом строки из адреса.
    private func checkLearnIsolation(_ then: @escaping () -> Void) {
        let before = messages
        learn("window.__ocbarSet(true, 'auto'); window.__ocbarTrustSynthetic = false; 0") { _ in
            self.eval("""
            var r = [typeof window.__ocbarPrefill, typeof window.__ocbarSet, typeof window.__ocbarShowMarks,
                     typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ocbarLearn)];
            window.__ocbarPrefill = function () { return [{kind: 'password', selector: 'input[id=evil]', why: 'подсунуто'}]; };
            document.getElementById('username').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
            JSON.stringify(r)
            """) { v in
                self.after(0.3) {
                    let seen = (v as? String) ?? "?"
                    self.ok("изоляция разметки: страница не видит __ocbar* и обработчик сообщений",
                            seen == "[\"undefined\",\"undefined\",\"undefined\",\"undefined\"]", seen)
                    self.ok("изоляция разметки: синтетический щелчок страницы не становится отметкой",
                            self.messages == before, self.clickSelector ?? "?")
                    self.learn("JSON.stringify(window.__ocbarPrefill(document.querySelector('#pf1')))") { p in
                        let s = (p as? String) ?? ""
                        self.ok("изоляция разметки: подложное __ocbarPrefill страницы не подменяет предзаполнение",
                                !s.contains("evil") && s.contains("input[id=pfp]"), s)
                        self.eval("delete window.__ocbarPrefill; 'ok'") { _ in
                            self.checkStepTitle()
                            self.learn("window.__ocbarSet(false, 'auto'); 0") { _ in then() }
                        }
                    }
                }
            }
        }
    }

    private func checkStepTitle() {
        let u = URL(string: "https://idp.example.test/a%0Astop%20html/b")!
        let label = LearnSession.pageLabel(u)
        ok("заголовок шага: путь в закодированном виде", label == "idp.example.test/a%0Astop%20html/b", label)
        typealias M = LearnSession.Mark
        let marks = [M(kind: "username", selector: "input[id=u]", hint: "", step: 1),
                     M(kind: "click", selector: "button[id=b]", hint: "", step: 1),
                     M(kind: "totp", selector: "input[id=c]", hint: "", step: 2)]
        let text = LearnSession.rulesText(marks: marks, pages: [1: "idp.test/a\nstop html\r\u{2028}x", 2: "idp.test/\u{0}ok"],
                                          portal: "p\nfill password input", formHost: "h\ny")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rules = Autofill.parse(text: text)
        ok("заголовок шага: перевод строки в адресе не становится правилом",
           !lines.contains("stop html") && !lines.contains { $0.hasPrefix("fill password") && !$0.hasPrefix("#") }
           && rules.count == 3 && lines.contains("# шаг 1 — idp.test/astop htmlx"),
           lines.filter { !$0.isEmpty }.joined(separator: " | "))
    }

    // MARK: - лимиты на окне с полем человека (п.1)

    /// Портал с капчей (fill manual), который перерисовывает форму: движок —
    /// тот же скрипт и AutofillGate, что у окна входа. Пароль должен уйти в
    /// поле не больше двух раз, как бы долго портал ни перерисовывал форму.
    private func checkCaptchaLimits(_ then: @escaping () -> Void) {
        let rules = Autofill.parse(text: """
        fill  username input[id=cu]
        fill  password input[id=cp]
        fill  manual input[id=ccap]
        click button[id=cgo]
        """)
        var gate = AutofillGate()
        var passwordSeen = 0
        var last: AutofillGate.Next = .keepGoing
        func attempt(_ i: Int) {
            guard i < 4 else {
                ok("капча, форма перерисовывается: пароль уходит в поле не больше двух раз",
                   passwordSeen == 2 && gate.passwordFills == 2, "пароль в поле \(passwordSeen) раз, учтено \(gate.passwordFills)")
                ok("капча: дальше — ждать человека на пустом пароле", last == .waitingHuman("input[id=cp]"), "\(last)")
                eval("window.__capRedraw(); 'ok'") { _ in self.checkLateButton(then) }
                return
            }
            gate.newPage()
            let offer = gate.begin()
            let creds = Credentials(username: "alice", password: offer.password ? "pw" : nil, totpSecret: nil)
            let js = Autofill.script(rules: rules, creds: creds, totpCode: nil, allowed: [["h": "example.test", "s": false]])
            engine(js) { r in
                last = gate.record(AutofillGate.Outcome(r as? [String: Any] ?? [:]), signature: "cap\(i)").next
                self.eval("var v = document.getElementById('cp').value; window.__capRedraw(); v") { v in
                    if (v as? String) == "pw" { passwordSeen += 1 }
                    attempt(i + 1)
                }
            }
        }
        attempt(0)
    }

    // MARK: - кнопка включается не сразу после ввода (D67)

    /// Форма включает «Sign In» через мгновение после ввода, как на Vue.
    /// Раньше нажатие уходило в неактивную кнопку и больше не повторялось:
    /// поля уже заполнены, а жать без заполнения в этой попытке было нельзя.
    private func checkLateButton(_ then: @escaping () -> Void) {
        let rules = Autofill.parse(text: "fill  password input[id=vp]\nclick button[id=vgo]")
        let js = Autofill.script(rules: rules, creds: Credentials(username: "alice", password: "pw", totpSecret: nil), totpCode: nil)
        engine(js) { r1 in
            let first = AutofillGate.Outcome(r1 as? [String: Any] ?? [:])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.engine(js) { r2 in
                    let second = AutofillGate.Outcome(r2 as? [String: Any] ?? [:])
                    self.eval("window.__vSent || 0") { sent in
                        self.ok("кнопка включается после ввода: сначала ждём, потом жмём — форма отправлена один раз",
                           first.pending == "button[id=vgo]" && first.clicked == nil
                           && second.clicked == "button[id=vgo]" && (sent as? Int) == 1,
                           "первая попытка: ждать \(first.pending ?? "-"), нажато \(first.clicked ?? "-"); вторая: нажато \(second.clicked ?? "-"); отправок \(String(describing: sent))")
                        then()
                    }
                }
            }
        }
    }

    // MARK: - хост проверяется внутри скрипта (п.3)

    /// Скрипт с чужим списком хостов на этой странице ничего не заполняет —
    /// даже если страница подменила встроенные функции: скрипт работает в
    /// изолированном мире окна входа.
    private func checkHostGuard(_ then: @escaping () -> Void) {
        let rules = Autofill.parse(text: "fill  username input[id=hu]\nfill  password input[id=hp]")
        let creds = Credentials(username: "alice", password: "pw", totpSecret: nil)
        let foreign = Autofill.script(rules: rules, creds: creds, totpCode: nil, allowed: [["h": "idp.other.test", "s": false]])
        let lookalike = Autofill.script(rules: rules, creds: creds, totpCode: nil, allowed: [["h": "ample.test", "s": true]])
        let own = Autofill.script(rules: rules, creds: creds, totpCode: nil, allowed: [["h": "test", "s": true]])
        let values = "[document.getElementById('hu').value, document.getElementById('hp').value]"
        eval("""
        window.__origSome = Array.prototype.some; Array.prototype.some = function () { return true; };
        window.__origLower = String.prototype.toLowerCase; String.prototype.toLowerCase = function () { return 'idp.other.test'; };
        'ok'
        """) { _ in
            self.engine(foreign) { r in
                let d = r as? [String: Any] ?? [:]
                self.eval(values) { v in
                    let a = v as? [String] ?? []
                    self.ok("хост в скрипте: чужая страница — ничего не заполнено, подмена встроенных функций не помогает",
                            (d["offHost"] as? String) == "example.test" && a == ["", ""], "\(d) \(a)")
                    self.eval("Array.prototype.some = window.__origSome; String.prototype.toLowerCase = window.__origLower; 'ok'") { _ in
                        self.engine(lookalike) { r2 in
                            let d2 = r2 as? [String: Any] ?? [:]
                            self.ok("хост в скрипте: «ample.test» не покрывает example.test", d2["offHost"] != nil, "\(d2)")
                            self.engine(own) { r3 in
                                let d3 = r3 as? [String: Any] ?? [:]
                                self.ok("хост в скрипте: свой хост (поддомен из списка) — заполнено",
                                        (d3["filled"] as? [String]) == ["username", "password"] && d3["offHost"] == nil, "\(d3)")
                                self.eval("document.getElementById('hu').value = ''; document.getElementById('hp').value = ''; 'ok'") { _ in then() }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - всплывающие окна (п.4)

    /// Конфигурация окна входа: window.open без жеста человека (скрипт
    /// страницы при загрузке) до приложения не доходит вовсе.
    private func checkPopups(_ then: @escaping () -> Void) {
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200),
                          configuration: WebAuth.configuration(persistent: false))
        v.navigationDelegate = self
        v.uiDelegate = self
        popupView = v
        popupThen = { [weak self] in
            guard let self else { return }
            self.popupThen = nil
            self.ok("window.open без жеста человека в окне входа не открывается",
                    self.popups.isEmpty, self.popups.joined(separator: ", "))
            then()
        }
        v.loadHTMLString("<script>window.open('https://popup.evil.test/'); setTimeout(function () { window.open('https://timer.evil.test/'); }, 50);</script>",
                         baseURL: URL(string: "https://example.test/"))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        popups.append(navigationAction.request.url?.host ?? "?")
        return nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world == LearnSession.world else { return }
        messages += 1
        clickSelector = (message.body as? [String: Any])?["selector"] as? String
    }
}
