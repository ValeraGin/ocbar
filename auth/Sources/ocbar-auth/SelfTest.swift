import Foundation

/// Проверки без WebKit и без сети — часть `ocbar-auth --selftest`. Каждая
/// ловит конкретную ошибку, найденную проверкой 2026-09-10: при её возврате
/// проверка падает.
enum AuthSelfTest {
    private static var failures = 0

    private static func ok(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
        if cond {
            out("  [ OK ] \(name)")
        } else {
            let d = detail()
            out("  [FAIL] \(name)\(d.isEmpty ? "" : " — " + d)")
            failures += 1
        }
    }

    /// Все проверки; возвращает число провалов.
    static func run() -> Int {
        failures = 0
        gate()
        journal()
        qr()
        scope()
        gatewayOnly()
        teachOffer()
        return failures
    }

    // MARK: - окно «Запомнить для следующего входа?» — пароль

    static func teachOffer() {
        out("Запомнить вход — что предложить про пароль:")
        typealias F = TeachFlow
        ok("«новый пароль» из цифр (код) при сохранённом пароле — «Обновить» не предлагается",
           F.passwordOffer(recorded: "123456", stored: "старый", source: "keychain") == .none,
           "\(F.passwordOffer(recorded: "123456", stored: "старый", source: "keychain"))")
        ok("код вместо пароля без сохранённого — «Сохранить» не предлагается",
           F.passwordOffer(recorded: "48291357", stored: "", source: "keychain") == .none
           && F.passwordOffer(recorded: " 4829 ", stored: "", source: "ask") == .none)
        let upd = F.passwordOffer(recorded: "Новый пароль!", stored: "старый", source: "keychain")
        ok("пароль изменился — «Обновить», галочка по умолчанию выключена",
           upd == .update && !TeachDialog.defaultOn(upd), "\(upd) \(TeachDialog.defaultOn(upd))")
        let save = F.passwordOffer(recorded: "пароль1", stored: "", source: "keychain")
        ok("пароля ещё нет — «Сохранить», галочка включена", save == .save && TeachDialog.defaultOn(save), "\(save)")
        ok("тот же пароль — ничего", F.passwordOffer(recorded: "p@ss", stored: "p@ss", source: "keychain") == .none)
        let ask = F.passwordOffer(recorded: "p@ss", stored: "", source: "ask")
        ok("вводите сами — предложить связку, галочка выключена", ask == .askToKeychain && !TeachDialog.defaultOn(ask))
        ok("пароль из KeePassXC — не сохраняем",
           F.passwordOffer(recorded: "p@ss", stored: "", source: "keepassxc") == .elsewhere("KeePassXC"))
        ok("длинный цифровой пароль — пароль, не код", F.passwordOffer(recorded: "1234567890", stored: "", source: "keychain") == .save)
    }

    // MARK: - где можно заполнять форму (FillScope)

    static func scope() {
        out("Где заполнять форму и куда пускать всплывающие окна:")
        let u = { (s: String) in URL(string: s)! }
        var s = FillScope(explicit: [], gatewayHosts: ["vpn.example.test"])
        // Старт входа: sso-v2-login на шлюзе, перенаправление к провайдеру.
        let r0 = s.navigation(to: u("https://vpn.example.test/+CSCOE+/saml/sp/login?tgname=X"), humanRecent: false)
        let r1 = s.navigation(to: u("https://idp.example.test/adfs/ls?SAMLRequest=1"), humanRecent: false)
        s.committed(u("https://idp.example.test/adfs/ls"))
        ok("без IdpHosts: шлюз и провайдер, куда увёл шлюз, — в цепочке",
           r0 == .already && r1 == .gatewayChain && s.allowsFill(u("https://idp.example.test/login")), "\(r0) \(r1)")
        ok("без IdpHosts: любой другой хост — нет (раньше — да)",
           !s.allowsFill(u("https://evil.test/login")) && !s.allowsFill(u("https://example.test/")))
        ok("только https: тот же хост по http — нет", !s.allowsFill(u("http://idp.example.test/login")))
        let r2 = s.navigation(to: u("https://evil.test/phish"), humanRecent: false)
        ok("переход, который страница провайдера сделала сама, цепочку не продлевает",
           r2 == .refused && !s.allowsFill(u("https://evil.test/phish")), "\(r2)")
        let r3 = s.navigation(to: u("https://mfa.example.test/"), humanRecent: true)
        ok("переход сразу после жеста человека — продлевает", r3 == .human && s.allowsFill(u("https://mfa.example.test/x")), "\(r3)")
        // Привязка HTTP-POST: страница шлюза сама отправляет форму провайдеру.
        var p = FillScope(explicit: [], gatewayHosts: ["vpn.example.test"])
        _ = p.navigation(to: u("https://vpn.example.test/saml"), humanRecent: false)
        p.committed(u("https://vpn.example.test/saml"))
        ok("автоотправка SAML-формы со страницы шлюза — в цепочке",
           p.navigation(to: u("https://idp2.example.test/sso"), humanRecent: false) == .gatewayChain)
        // Балансировщик: адрес группы vpn.example.test, страница входа — с узла
        // vpn-1.example.test, и уже она отправляет SAML-форму провайдеру.
        var lb = FillScope(explicit: [], gatewayHosts: WebAuth.scopeGatewayHosts(
            ["vpn.example.test"], loginURL: "https://vpn-1.example.test/+CSCOE+/saml/sp/login?tgname=X",
            loginFinalURL: "https://vpn-1.example.test/+CSCOE+/saml_ac_login.html"))
        _ = lb.navigation(to: u("https://vpn-1.example.test/+CSCOE+/saml/sp/login?tgname=X"), humanRecent: false)
        lb.committed(u("https://vpn-1.example.test/+CSCOE+/saml/sp/login"))
        let rlb = lb.navigation(to: u("https://idp3.example.test/auth/realms/x/protocol/saml"), humanRecent: false)
        ok("узел балансировщика шлюза отправляет SAML-форму — провайдер в цепочке",
           rlb == .gatewayChain && lb.allowsFill(u("https://idp3.example.test/auth/realms/x/login-actions/authenticate")), "\(rlb)")
        // Явный список.
        let e = FillScope(explicit: ["corp.test"], gatewayHosts: ["vpn.example.test"])
        ok("IdpHosts: хост и поддомены — да",
           e.allowsFill(u("https://corp.test/")) && e.allowsFill(u("https://login.corp.test/")))
        ok("IdpHosts: похожие чужие хосты и http — нет",
           !e.allowsFill(u("https://corp.test.evil.com/")) && !e.allowsFill(u("https://evilcorp.test/"))
           && !e.allowsFill(u("http://login.corp.test/")))
        // Всплывающие окна.
        ok("всплывающее окно на чужой хост — нет, на хост цепочки — да",
           !s.allowsPopup(u("https://ads.evil.test/")) && s.allowsPopup(u("https://idp.example.test/help"))
           && !s.allowsPopup(u("http://idp.example.test/help")))
        let js = s.jsAllowed.compactMap { $0["h"] as? String }
        ok("в скрипт уходит тот же список хостов", Set(js) == s.chain && s.jsAllowed.allSatisfy { ($0["s"] as? Bool) == false },
           js.joined(separator: ","))
    }

    // MARK: - cookie и --insecure — только хост шлюза

    static func gatewayOnly() {
        out("Cookie и --insecure — только хост шлюза:")
        let hosts: Set<String> = ["vpn.example.test"]
        ok("cookie с хоста шлюза — принимается",
           WebAuth.cookieFromGateway(domain: "vpn.example.test", hosts: hosts)
           && WebAuth.cookieFromGateway(domain: ".vpn.example.test", hosts: hosts)
           && WebAuth.cookieFromGateway(domain: "VPN.Example.Test", hosts: hosts))
        ok("cookie с родительского домена — нет (раньше — да)",
           !WebAuth.cookieFromGateway(domain: ".example.test", hosts: hosts)
           && !WebAuth.cookieFromGateway(domain: "example.test", hosts: hosts))
        ok("cookie соседнего и чужого хоста — нет",
           !WebAuth.cookieFromGateway(domain: "idp.example.test", hosts: hosts)
           && !WebAuth.cookieFromGateway(domain: "evil.test", hosts: hosts)
           && !WebAuth.cookieFromGateway(domain: "", hosts: hosts))
        ok("--insecure: хост шлюза — без проверки сертификата",
           WebAuth.trustsUnverified(host: "vpn.example.test", insecure: true, gatewayHosts: hosts))
        ok("--insecure: страницы провайдера входа проверяются всегда (раньше — нет)",
           !WebAuth.trustsUnverified(host: "idp.example.test", insecure: true, gatewayHosts: hosts))
        ok("без --insecure — проверка и на шлюзе",
           !WebAuth.trustsUnverified(host: "vpn.example.test", insecure: false, gatewayHosts: hosts))
    }

    // MARK: - QR

    static func qr() {
        out("QR второго фактора:")
        let secret = "JBSWY3DPEHPK3PXP"
        let upper = (try? QRImport.parse("OTPAUTH://TOTP/VPN:alice?secret=\(secret)&issuer=VPN")) ?? []
        ok("схема OTPAUTH:// в верхнем регистре принимается",
           upper.count == 1 && upper.first?.secretBase32 == secret && upper.first?.isTOTP == true,
           "\(upper.count) записей")
        let migration = LearnCheck.migrationPayload([(Data((0..<20).map { UInt8($0) }), "alice", "VPN")])
        let mixed = (try? QRImport.parse(migration.replacingOccurrences(of: "otpauth-migration://", with: "OtpAuth-Migration://"))) ?? []
        ok("схема otpauth-migration:// без учёта регистра", mixed.count == 1, "\(mixed.count) записей")
        // Похоже на ссылку с секретом, но схема другая: в текст ошибки,
        // который видит человек и журнал, не должно попасть ни куска.
        let alien = "otpauht://totp/VPN:alice?secret=\(secret)"
        var message = ""
        do { _ = try QRImport.parse(alien) } catch { message = "\(error)" }
        ok("чужой QR: ошибка без содержимого QR", !message.isEmpty && !message.contains("JBSWY") && !message.contains("otpauht"),
           message)
        var wifi = ""
        do { _ = try QRImport.parse("WIFI:S:home;T:WPA;P:hunter2;;") } catch { wifi = "\(error)" }
        ok("QR сети Wi-Fi: пароль сети в ошибку не попадает", !wifi.contains("hunter2") && wifi.contains("не QR второго фактора"), wifi)
    }

    // MARK: - журнал в --verbose

    static func journal() {
        out("Журнал --verbose — без токенов и query:")
        let two = "<a><session-token>AAA111</session-token><x/><session-token>BBB222</session-token></a>"
        let m2 = mask(two)
        ok("mask: скрыты все вхождения тега", !m2.contains("AAA111") && !m2.contains("BBB222"), m2)
        let attr = "<sso-token id=\"t\">SECRETSSO</sso-token><session-id>SID42</session-id>\n<session-token\n>MULTI\nLINE</session-token>"
        let ma = mask(attr)
        ok("mask: тег с атрибутами, многострочное значение, session-id",
           !ma.contains("SECRETSSO") && !ma.contains("SID42") && !ma.contains("MULTI"), ma)
        ok("mask: пустой тег и прочее не трогает",
           mask("<session-token/><opaque>x</opaque>") == "<session-token/><opaque>x</opaque>")
        let u = Log.redact("https://idp.example.test:8443/saml/login?SAMLRequest=abc&RelayState=zzz#frag")
        ok("адрес в журнале — без query и fragment",
           u == "https://idp.example.test:8443/saml/login?…" && !u.contains("SAMLRequest") && !u.contains("frag"), u)
        ok("адрес без query — как есть", Log.redact("https://vpn.example.test/grp") == "https://vpn.example.test/grp")
        ok("адрес с логином и паролем — без них",
           !Log.redact("https://user:pw@h.test/p").contains("pw@"), Log.redact("https://user:pw@h.test/p"))
    }

    // MARK: - цикл автозаполнения (AutofillGate)

    static func gate() {
        out("Цикл автозаполнения — лимиты:")
        typealias O = AutofillGate.Outcome

        // Окно с полем человека (капча, fill manual), которое портал
        // перерисовывает: пароль подставляется, форма не уходит — ждём
        // человека. Третьей попытке пароля не дают.
        var g = AutofillGate()
        var offers: [AutofillGate.Offer] = []
        for i in 0..<4 {
            g.newPage()                                   // форма перерисована
            let offer = g.begin()
            offers.append(offer)
            let filled = offer.password ? ["username", "password"] : ["username"]
            _ = g.record(O(filled: filled, waiting: "input[id=captcha]"), signature: "p\(i)")
        }
        ok("окно с полем человека: пароль не больше двух раз",
           offers.map(\.password) == [true, true, false, false] && g.passwordFills == 2,
           "пароль давали: \(offers.map(\.password)), подставлен \(g.passwordFills)")

        // Код и поле человека на одном окне: код ушёл один раз.
        var c = AutofillGate()
        let c1 = c.begin()
        let d1 = c.record(O(filled: ["totp"], waiting: "input[id=captcha]"), signature: "a")
        c.newPage()
        let c2 = c.begin()
        ok("окно с полем человека: код подставляется один раз",
           c1.code && d1.countedCode && !c2.code && c.totpFills == 1,
           "первый \(c1.code), учтён \(d1.countedCode), второй \(c2.code)")
        ok("окно с полем человека: решение — ждать человека",
           d1.next == .waitingHuman("input[id=captcha]"), "\(d1.next)")

        // Пароль, подставленный до правила stop, тоже считается.
        var s = AutofillGate()
        _ = s.begin()
        let ds = s.record(O(filled: ["password"], stopped: "Неверный пароль"), signature: "s")
        ok("stop после заполнения: пароль учтён, дальше — стоп",
           s.passwordFills == 1 && ds.next == .formError("Неверный пароль") && !s.mayRun(signature: "x"),
           "\(s.passwordFills) \(ds.next)")

        // Нажатие на неизменившейся странице не повторяется.
        var r = AutofillGate()
        _ = r.begin()
        _ = r.record(O(filled: ["username"], clicked: "button[id=next]"), signature: "A")
        ok("после нажатия та же страница — скрипт не повторяется", !r.mayRun(signature: "A"))
        ok("после нажатия страница изменилась — можно", r.mayRun(signature: "B"))
        r.newPage()
        ok("новая страница с той же сигнатурой — можно", r.mayRun(signature: "A"))
        // Источник кода в момент заполнения: секрет считаем сами, команду
        // спрашиваем заново, готовый код — последним. Готовый приходит из
        // окружения до открытия окна и за десятки секунд протухает.
        let p6 = TOTPParams()
        let bySecret = WebAuth.freshCode(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", params: p6, command: "echo 111111", ready: "222222")
        let byCommand = WebAuth.freshCode(secret: nil, params: p6, command: "echo 333333", ready: "222222")
        let byReady = WebAuth.freshCode(secret: nil, params: p6, command: nil, ready: "222222")
        let badCommand = WebAuth.freshCode(secret: nil, params: p6, command: "echo не-код", ready: "222222")
        ok("код: секрет важнее команды и готового", bySecret != nil && bySecret != "111111" && bySecret != "222222", bySecret ?? "-")
        ok("код: команда спрашивается заново, а не берётся готовый", byCommand == "333333", byCommand ?? "-")
        ok("код: без секрета и команды — готовый", byReady == "222222", byReady ?? "-")
        ok("код: команда ответила мусором — берём готовый", badCommand == "222222", badCommand ?? "-")
        // Правила из разметки без логина: провайдер помнил логин, и человек
        // его не отмечал. После сброса входа поле пустое — заполняем сами.
        let noUser = Autofill.parse(text: "fill  password input[id=password]\nclick button[type=submit]")
        let alice = Credentials(username: "alice", password: "pw", totpSecret: nil)
        let implicit = Autofill.withImplicitUsername(noUser, creds: alice)
        let firstFill = implicit.first { if case .fill = $0.action { return true }; return false }
        ok("логин: правила молчат о нём — встроенные селекторы логина перед паролем",
           firstFill.map { if case .fill(let w) = $0.action { return w == "username" }; return false } ?? false,
           "\(implicit.count) правил")
        ok("логин: в скрипте подставляется alice",
           Autofill.script(rules: noUser, creds: alice, totpCode: nil).contains("\"alice\""))
        let withUser = Autofill.parse(text: "fill  username input[id=u]\nfill  password input[id=password]")
        ok("логин: правило про логин есть — чужие селекторы не добавляются",
           Autofill.withImplicitUsername(withUser, creds: alice).count == withUser.count)
        ok("логин: логина в профиле нет — правила не меняются",
           Autofill.withImplicitUsername(noUser, creds: Credentials(username: nil, password: "pw", totpSecret: nil)).count == noUser.count)
        // Сеть отделена от «нужен человек»: молчаливый вход при обрыве
        // должен повторяться сам, а не останавливать автоподключение.
        ok("сбой сети — не «нужен человек»",
           WebAuth.networkFailure(NSURLErrorNotConnectedToInternet)
           && WebAuth.networkFailure(NSURLErrorTimedOut)
           && WebAuth.networkFailure(NSURLErrorCannotFindHost)
           && !WebAuth.networkFailure(NSURLErrorUserAuthenticationRequired)
           && !WebAuth.networkFailure(NSURLErrorBadServerResponse))
        // Нажатие ушло в неготовую форму: страница та же — одно повторное через 4 с.
        var rc = AutofillGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = rc.begin(); _ = rc.record(O(filled: ["password"], clicked: "b"), signature: "S", now: t0)
        let early = rc.mayRun(signature: "S", now: t0.addingTimeInterval(2))
        let late = rc.mayRun(signature: "S", now: t0.addingTimeInterval(4.5))
        _ = rc.begin(); _ = rc.record(O(clicked: "b"), signature: "S", now: t0.addingTimeInterval(5))
        let again = rc.mayRun(signature: "S", now: t0.addingTimeInterval(30))
        ok("нажатие без перехода: через 4 с — одно повторное, не больше", !early && late && !again && rc.clicks == 2,
           "рано \(early), через 4 с \(late), ещё раз \(again)")
        var pc = AutofillGate()
        _ = pc.begin()
        let dp = pc.record(O(filled: ["password"], pending: "b"), signature: "P")
        ok("кнопка неактивна: ждать следующей попытки, нажатием не считать",
           dp.next == .pendingClick("b") && pc.clicks == 0 && pc.mayRun(signature: "P"), "\(dp.next)")

        // Лимит нажатий — пять за вход.
        var k = AutofillGate()
        var nexts: [AutofillGate.Next] = []
        for i in 0..<5 {
            k.newPage()
            _ = k.begin()
            nexts.append(k.record(O(filled: [], clicked: "b"), signature: "k\(i)").next)
        }
        ok("пятое нажатие — лимит, дальше только человек",
           nexts.last == .clickLimit && nexts.dropLast().allSatisfy { $0 == .clicked("b") } && !k.mayRun(signature: "z"),
           "\(nexts)")

        // Попыток на одной странице — не больше двенадцати.
        var a = AutofillGate()
        var runs = 0
        while a.mayRun(signature: "same"), runs < 50 { _ = a.begin(); _ = a.record(O(), signature: "same"); runs += 1 }
        ok("на одной странице не больше \(a.maxAttemptsPerPage) попыток", runs == a.maxAttemptsPerPage, "\(runs)")

        // Нераспознанная форма — к человеку.
        var u = AutofillGate()
        _ = u.begin()
        ok("поля есть, ни одно не узнано — показать человеку",
           u.record(O(inputs: ["text:q"]), signature: "u").next == .unknownForm(["text:q"]))
    }
}
