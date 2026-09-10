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
        return failures
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
