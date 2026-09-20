import Foundation
import AppKit

// Проверки по итогам аудита 2026-09-10: разбор и запись профиля совпадают
// с bin/ocbar (сверка идёт с живым `ocbar export` во временном каталоге),
// проверки профиля — те же, что у CLI и хелпера, разбор status устойчив к
// «|» и повторам, уведомление без своего токена отвергается, опрос не ждёт
// долгого действия. Всё без окон и без изменения системы.
extension SelfTest {
    final class Tally {
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  [ OK ] \(name)" : "  [FAIL] \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !ok { failures += 1 }
        }
    }

    @MainActor
    static func audit() -> Int32 {
        let t = Tally()
        print("ocbar-app selftest: профиль, проверки, состояние, уведомления, опрос")
        auditProfileParsing(t)
        auditProfileChecks(t)
        auditStatus(t)
        auditNotify(t)
        auditTimeouts(t)
        auditCliParity(t)
        auditStore(t)
        return t.failures
    }

    // --- разбор и запись профиля -----------------------------------------

    static func auditProfileParsing(_ t: Tally) {
        let crlf = ProfileDoc.parse("[Connection]\r\nName = c\r\nUrl = vpn.example.test/c\r\n\r\n[Routes]\r\n10.0.0.0/8\r\n\r\n[DNS]\r\nint.example.test = vpn\r\n", fileName: "c")
        t.check("профиль: CRLF — адрес на месте", crlf.url == "vpn.example.test/c", "«\(crlf.url)»")
        t.check("профиль: CRLF — сети и зоны на месте",
                crlf.routes == ["10.0.0.0/8"] && crlf.zones.count == 1, "\(crlf.routes) \(crlf.zones.count)")
        let bom = ProfileDoc.parse("\u{FEFF}[Connection]\nUrl = vpn.example.test/b\n", fileName: "b")
        t.check("профиль: BOM в начале файла", bom.url == "vpn.example.test/b", "«\(bom.url)»")

        let dup = ProfileDoc.parse("[Connection]\nUrl = first.example.test/a\nName = Один\nUrl = second.example.test/a\n\n[Auth]\nTotp = off\nTotp = keychain\n", fileName: "d")
        t.check("профиль: повтор ключа — первое значение, как pf_get",
                dup.url == "first.example.test/a" && dup.totp == "off", "\(dup.url) \(dup.totp)")
        let dupAgain = ProfileDoc.parse(dup.render(), fileName: "d")
        t.check("профиль: повтор ключа — запись не меняет адрес", dupAgain.url == "first.example.test/a", dupAgain.url)

        let yes = ProfileDoc.parse("[Connection]\nUrl = vpn.example.test/y\n\n[Proxy]\nSystemProxy = yes\n", fileName: "y")
        t.check("профиль: SystemProxy = yes — для CLI это не on", !yes.systemProxy)
        t.check("профиль: неизвестное значение SystemProxy не переписано",
                yes.render().range(of: #"SystemProxy\s*= yes"#, options: .regularExpression) != nil, yes.render())

        let keep = ProfileDoc.parse("[Connection]\nUrl = vpn.example.test/p\n\n[Proxy]\nPort = 12000\n\n[Health]\nTimeout = 5\n", fileName: "p")
        let keepText = keep.render()
        t.check("профиль: [Proxy] в туннельном режиме не теряется", keepText.contains("12000"), keepText)
        t.check("профиль: ключ [Health] без Check не теряется", keepText.contains("Timeout"), keepText)

        let commented = ProfileDoc.parse("""
        # моя заметка о профиле
        [Connection]
        # шлюз офиса
        Url = vpn.example.test/k
        [Routes]
        # офис
        10.1.0.0/16 # офис-2
        10.2.0.0/16
        [DNS]
        ; внутренние
        int.example.test 10.0.0.1
        """, fileName: "k")
        let kText = commented.render()
        t.check("профиль: комментарии переживают запись",
                ["# моя заметка о профиле", "# шлюз офиса", "# офис", "# офис-2", "; внутренние"].allSatisfy { kText.contains($0) }, kText)
        t.check("профиль: заголовок записи не копится при пересохранении",
                ProfileDoc.parse(kText, fileName: "k").render().components(separatedBy: "# Профиль ocbar").count == 2)
        t.check("профиль: строка DNS без «=» — как в CLI",
                commented.zones.contains { $0.zone == "int.example.test" && $0.resolver == "10.0.0.1" },
                commented.zones.map { "\($0.zone)→\($0.resolver)" }.joined(separator: " "))
    }

    // --- проверки профиля -------------------------------------------------

    static func auditProfileChecks(_ t: Tally) {
        let base = ProfileDoc.parse("[Connection]\nName = x\nUrl = vpn.example.test/x\n\n[Routes]\n10.0.0.0/8\n\n[Auth]\nTotp = keychain\n", fileName: "x")
        func errors(_ d: ProfileDoc) -> [String] { ProfileCheck.check(d).filter { $0.level == .error }.map(\.text) }
        t.check("проверка: исходный профиль без ошибок", errors(base).isEmpty, errors(base).joined(separator: "; "))
        var p = base; p.totpPeriod = "+30"
        t.check("проверка: TotpPeriod = +30 — ошибка, как в CLI", errors(p).contains { $0.contains("период") })
        t.check("проверка: маска /008 — не CIDR, как valid_cidr", !ProfileCheck.validCIDR("10.0.0.0/008"))
        t.check("проверка: маска /+8 — не CIDR", !ProfileCheck.validCIDR("10.0.0.0/+8"))
        t.check("проверка: маска /8 — CIDR", ProfileCheck.validCIDR("10.0.0.0/8"))
        for (port, bad) in [("+53", true), ("0", true), ("70000", true), ("5353", false), ("65535", false)] {
            var z = base; z.zones = [ZoneLine(zone: "int.example.test", resolver: "10.0.0.1", port: port)]
            t.check("проверка: порт зоны \(port) — \(bad ? "ошибка" : "принят"), как у хелпера",
                    errors(z).contains { $0.contains("порт") } == bad, errors(z).joined(separator: "; "))
        }
        var a = base; a.autofill = ["; заметка", "# шаг 1 — вход", "fill username input[name=u]"]
        t.check("проверка: «;» в [Autofill] — комментарий", !errors(a).contains { $0.contains("правило") },
                errors(a).joined(separator: "; "))
        a.autofill = ["fill username input[name=u] extra"]
        t.check("проверка: fill с пробелом в селекторе — как valid_rule", !errors(a).contains { $0.contains("правило") },
                errors(a).joined(separator: "; "))
        var r = base; r.routes = ["10.1.0.0/16 # офис"]
        t.check("проверка: комментарий после сети — не ошибка", errors(r).isEmpty, errors(r).joined(separator: "; "))
    }

    // --- разбор status ----------------------------------------------------

    static func auditStatus(_ t: Tally) {
        // JSON от `ocbar status --json`: поля приходят типами, «|» и прочие
        // разделители больше не участвуют.
        let s = Status.parse(json: """
        {"state":"down",
         "profiles":[{"name":"main","title":"Мой|офис","auth":"","descr":"описание","url":""},
                     {"name":"pw","title":"Пароль","auth":"password","descr":"",
                      "url":"https://vpn.example.test/sms?x=1"},
                     {"name":"odd","title":"A|B","auth":"password","descr":"x","url":""}],
         "routes":[{"net":"10.0.0.0/8","via":null,"on":true}]}
        """) ?? Status()
        let main = s.profiles.first { $0.name == "main" }
        t.check("состояние: «|» в названии сохраняется как есть",
                main?.title == "Мой|офис" && main?.isPassword == false, "\(main?.title ?? "—") / \(main?.auth ?? "—")")
        t.check("состояние: парольная группа распознана", s.profiles.first { $0.name == "pw" }?.isPassword == true)
        t.check("состояние: домен профиля — без схемы и группы",
                s.profiles.first { $0.name == "pw" }?.host == "vpn.example.test",
                s.profiles.first { $0.name == "pw" }?.host ?? "—")
        t.check("состояние: адрес профиля — без схемы, с группой",
                s.profiles.first { $0.name == "pw" }?.address == "vpn.example.test/sms?x=1",
                s.profiles.first { $0.name == "pw" }?.address ?? "—")
        t.check("состояние: id профилей уникальны", Set(s.profiles.map(\.id)).count == s.profiles.count)
        t.check("состояние: битый JSON — не состояние, а nil", Status.parse(json: "{не json") == nil)
        t.check("состояние: пустой JSON — состояние по умолчанию",
                Status.parse(json: "{}")?.presentation == .down)
    }

    // --- уведомления ------------------------------------------------------

    static func auditNotify(_ t: Tally) {
        let saved = Notifier.expectedToken
        defer { Notifier.expectedToken = saved }
        Notifier.expectedToken = "0123abcd"
        let good = URL(string: "ocbar://notify?title=t&body=b&token=0123abcd")!
        let bad = URL(string: "ocbar://notify?title=t&body=b&token=ffff")!
        let none = URL(string: "ocbar://notify?title=t&body=b")!
        // Подсказка к ошибке: команда, которую приложение выполнить не может.
        t.check("ошибка: «нужен root» предлагает sudo ocbar install",
                MenuView.fix(for: "ocbar: нужен root: sudo ocbar install (посмотреть шаги — ...)")?.command == "sudo ocbar install")
        t.check("ошибка: нет openconnect — предлагает brew install",
                MenuView.fix(for: "нет openconnect — brew install openconnect")?.command == "brew install openconnect")
        t.check("ошибка: обычная — без подсказки", MenuView.fix(for: "сеть 10.0.0.0/8 не включилась") == nil)
        // Доступ: состояние читается из status --short.
        let acc = Status.parse(json: #"{"state":"connected","access":"fail","access_at":1700000000}"#) ?? Status()
        t.check("доступ: состояние и время разобраны", acc.access == "fail" && acc.accessAt != nil)

        t.check("уведомление: свой токен принят", Notifier.parse(good) != nil)
        t.check("уведомление: чужой токен отвергнут", Notifier.parse(bad) == nil)
        t.check("уведомление: без токена отвергнуто", Notifier.parse(none) == nil)
        t.check("уведомление: при незаписанном токене не принимается ничего",
                Notifier.verdict(good, token: nil) != .show(title: "t", body: "b"))
        // Пробелы: «+» (так кодировал клиент до 0.3.4) и %20 — пробел, %2B — плюс.
        let tk = "0123456789abcdef0123456789abcdef"
        let plus = URL(string: "ocbar://notify?title=a+b&body=c+d%2Be&token=\(tk)")!
        t.check("уведомление: «+» — пробел, %2B — плюс",
                Notifier.verdict(plus, token: tk) == .show(title: "a b", body: "c d+e"))
        let pct = URL(string: "ocbar://notify?title=a%20b&body=%D0%B2%D1%85%D0%BE%D0%B4%20%D0%BD%D1%83%D0%B6%D0%B5%D0%BD&token=\(tk)")!
        t.check("уведомление: %20 — пробел",
                Notifier.verdict(pct, token: tk) == .show(title: "a b", body: "вход нужен"))

        // Токен в файле: одна строка hex, права 0600, notify.allowed рядом.
        let dir = NSTemporaryDirectory() + "ocbar-notify-\(getpid())/state"
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        let token = Notifier.prepareToken(in: dir)
        let file = dir + "/notify.token"
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let perms = ((try? FileManager.default.attributesOfItem(atPath: file))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        t.check("уведомление: токен записан одной строкой hex",
                token != nil && text == (token ?? "") + "\n" && (token ?? "").count == 32
                && (token ?? "").allSatisfy { $0.isHexDigit }, text)
        t.check("уведомление: файл токена — 0600", perms == 0o600, String(perms, radix: 8))
        try? FileManager.default.removeItem(atPath: file)
        Notifier.ensureToken(in: dir)
        let back = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        t.check("уведомление: пропавший файл токена возвращается тем же токеном",
                token != nil && back == (token ?? "") + "\n", back)
        t.check("уведомление: записанный токен принимается",
                Notifier.parse(URL(string: "ocbar://notify?title=t&token=\(token ?? "-")")!) != nil)
        Notifier.writeAllowed(false, in: dir)
        t.check("уведомление: notify.allowed пишется",
                (try? String(contentsOfFile: dir + "/notify.allowed", encoding: .utf8)) == "0\n")
    }

    // --- сроки ------------------------------------------------------------

    static func auditTimeouts(_ t: Tally) {
        t.check("срок подключения — 660 с (вход 300 + сохранение 180 + туннель 40 + запас)",
                OcbarClient.connectTimeout(teach: false) == 660, "\(Int(OcbarClient.connectTimeout(teach: false)))")
        t.check("срок подключения с запоминанием — 900 с",
                OcbarClient.connectTimeout(teach: true) == 900, "\(Int(OcbarClient.connectTimeout(teach: true)))")
        t.check("срок разметки — 1800 с", OcbarClient.learnTimeout == 1800)
    }

    // --- сверка с CLI -----------------------------------------------------
    // Краевые профили: CLI выгружает исходный файл и файл, записанный
    // приложением после разбора. Выгрузки должны совпасть — значит, запись
    // приложения не поменяла смысла, который видит ocbar.

    static let edgeProfiles: [(String, String)] = [
        ("crlf", "# CRLF\r\n[Connection]\r\nName = Перевод строк\r\nUrl = vpn.example.test/crlf\r\nUser = alice\r\n\r\n[Routes]\r\n10.0.0.0/8\r\n\r\n[DNS]\r\nint.example.test = 10.0.0.1\r\n\r\n[Auth]\r\nTotp = keychain\r\n"),
        ("bom", "\u{FEFF}# с меткой порядка байт\n[Connection]\nName = BOM\nUrl = vpn.example.test/bom\n\n[Routes]\n10.0.0.0/8\n"),
        ("dupkey", "[Connection]\nName = Первый\nUrl = first.example.test/a\nName = Второй\nUrl = second.example.test/a\n\n[Auth]\nTotp = keychain\nTotp = off\n\n[Connection]\nUser = bob\nUser = eve\n"),
        ("sysyes", "[Connection]\nName = s\nUrl = vpn.example.test/s\n\n[Proxy]\nPort = 12000\nSystemProxy = yes\n"),
        ("tail", "[Connection]\nUrl = vpn.example.test/t\n\n[Routes]\n10.1.0.0/16 # офис\n# выключено: 10.9.0.0/16\n; и так тоже\n  172.16.0.0/12\n\n[DNS]\nint.example.test 10.0.0.1\nb.example.test = vpn 5353\nc.example.test=10.0.0.2\n"),
        ("autofill", "[Connection]\nUrl = vpn.example.test/f\n\n[Autofill]\n# шаг 1 — вход\n; заметка\nfill username input[name=u]\nclick button[type=submit]\n\n[Health]\nCheck = wiki.example.test:443\nTimeout = 5\n"),
        ("cases", "[connection]\nurl = vpn.example.test/lc\nNAME = Регистр\n\n[ROUTES]\n10.0.0.0/8\n\n[auth]\ntotpperiod = 60\ntotp = keychain\n"),
        ("proxy", "[Connection]\nUrl = vpn.example.test/p\nMode = proxy\n\n[Proxy]\nPort = 11081\nSystemProxy = on\n"),
    ]

    static func auditCliParity(_ t: Tally) {
        guard let binary = OcbarClient.shared.binary else {
            print("  [ -- ] сверка с CLI: живой ocbar не найден, пропущено")
            return
        }
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "ocbar-parity-\(getpid())"
        let cliDir = root + "/cli", appDir = root + "/app"
        for d in [cliDir, appDir] { try? fm.createDirectory(atPath: d + "/profiles", withIntermediateDirectories: true) }
        defer { try? fm.removeItem(atPath: root) }
        let base = ["OCBAR_USER_STATE": root + "/user-state", "OCBAR_STATE_DIR": root + "/state", "OCBAR_NOTIFY": "0"]
        func export(_ dir: String, _ name: String) -> Shell.Result {
            var env = base; env["OCBAR_CONFIG_DIR"] = dir
            return Shell.run(binary, ["export", name], env: env, timeout: 20)
        }
        // Первая строка выгрузки — дата: её не сравниваем.
        func body(_ s: String) -> [String] { Array(s.components(separatedBy: "\n").dropFirst()) }
        for (name, text) in edgeProfiles {
            try? text.write(toFile: "\(cliDir)/profiles/\(name).ocbar", atomically: true, encoding: .utf8)
            let doc = ProfileDoc.parse(text, fileName: name)
            try? doc.render().write(toFile: "\(appDir)/profiles/\(name).ocbar", atomically: true, encoding: .utf8)
            let a = export(cliDir, name), b = export(appDir, name)
            guard a.code == 0 else {
                t.check("сверка с CLI: \(name) — CLI выгружает исходный файл", false, a.err.trimmed)
                continue
            }
            let la = body(a.out), lb = body(b.out)
            var detail = b.code == 0 ? "" : "CLI не принял файл приложения: " + b.err.trimmed
            if detail.isEmpty, la != lb {
                let i = (0..<min(la.count, lb.count)).first { la[$0] != lb[$0] } ?? min(la.count, lb.count)
                detail = "строка \(i + 1): CLI «\(i < la.count ? la[i] : "—")», приложение «\(i < lb.count ? lb[i] : "—")»"
            }
            t.check("сверка с CLI: \(name) — запись приложения не меняет смысла", b.code == 0 && la == lb, detail)
            // И прямо: то, что приложение показывает, — то, что видит CLI.
            let seen = ProfileDoc.parse(a.out, fileName: name)
            t.check("сверка с CLI: \(name) — адрес и сети как у CLI",
                    doc.url == seen.url && routeNets(doc) == routeNets(seen),
                    "\(doc.url) \(routeNets(doc)) против \(seen.url) \(routeNets(seen))")
        }
    }

    static func routeNets(_ d: ProfileDoc) -> [String] {
        d.routes.compactMap { line -> String? in
            let w = line.trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            return w.isEmpty || w.hasPrefix("#") || w.hasPrefix(";") ? nil : w
        }
    }

    // --- опрос и действия -------------------------------------------------

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func inc() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @MainActor
    static func auditStore(_ t: Tally) {
        func spin(_ s: TimeInterval, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        // Долгое действие не держит опрос.
        let polls = Counter()
        let store = StatusStore(testSource: {
            var s = Status(); s.profile = "опрос-\(polls.inc())"; return s
        })
        store.perform("долгое действие") { _ in Thread.sleep(forTimeInterval: 3); return .ok("") }
        spin(0.2)
        let before = polls.value
        store.refresh()
        spin(1.5) { store.status.profile == "опрос-\(before + 1)" }
        t.check("опрос: состояние обновляется во время долгого действия",
                store.busy != nil && polls.value > before && store.status.profile == "опрос-\(before + 1)",
                "занято: \(store.busy ?? "нет"), опросов \(polls.value - before), показано «\(store.status.profile)»")
        spin(3.5) { store.busy == nil }

        // Тики не копятся: пока прошлый опрос идёт, новый пропускается.
        let slow = Counter()
        let slowStore = StatusStore(testSource: { _ = slow.inc(); Thread.sleep(forTimeInterval: 0.6); return Status() })
        for _ in 0..<5 { slowStore.refresh() }
        spin(2.0)
        t.check("опрос: тики не копятся за медленным опросом", slow.value == 1, "вызовов \(slow.value)")

        // «Отключить» посреди долгого входа: вход отменяется (запущенная
        // команда гаснет), следом — отключение. Отключение подставное.
        let disconnects = Counter()
        let cancelStore = StatusStore(testSource: { Status() }, disconnect: { _ = disconnects.inc(); return .ok("") })
        cancelStore.perform("Подключаюсь…", cancel: "Отменить подключение", disconnects: true) { token in
            let r = Shell.run("/bin/sleep", ["30"], timeout: 60, cancel: token)
            return r.code == Shell.cancelledCode ? .cancelled : .ok("")
        }
        spin(0.3)
        let pressed = Date()
        cancelStore.disconnect()
        spin(6) { cancelStore.busy == nil && disconnects.value == 1 }
        let took = Date().timeIntervalSince(pressed)
        t.check("отмена: «Отключить» во время входа гасит вход и отключает",
                disconnects.value == 1 && cancelStore.busy == nil && took < 5,
                "отключений \(disconnects.value), занято: \(cancelStore.busy ?? "нет"), \(String(format: "%.1f", took)) с")

        // Короткое действие не отменяется, а доделывается; отключение — следом.
        let shortStore = StatusStore(testSource: { Status() }, disconnect: { _ = disconnects.inc(); return .ok("") })
        let finished = Counter()
        shortStore.perform("Переключаю…") { _ in Thread.sleep(forTimeInterval: 0.5); _ = finished.inc(); return .ok("") }
        shortStore.disconnect()
        spin(4) { disconnects.value == 2 && shortStore.busy == nil }
        t.check("отмена: короткое действие доделывается, отключение — следом",
                finished.value == 1 && disconnects.value == 2, "доделано \(finished.value), отключений \(disconnects.value - 1)")

        // Отмена гасит и потомков: окно входа (ocbar-auth) — потомок ocbar.
        let token = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { token.cancel() }
        let r = Shell.run("/bin/sh", ["-c", "/bin/sleep 31 & echo $!; wait"], timeout: 20, cancel: token)
        let child = pid_t(r.out.split(separator: "\n").first.map(String.init) ?? "") ?? 0
        t.check("отмена: команда и её потомки погашены",
                r.code == Shell.cancelledCode && child > 0 && kill(child, 0) != 0,
                "код \(r.code), потомок \(child)")
    }
}
