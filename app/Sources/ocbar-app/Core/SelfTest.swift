import Foundation
import Carbon.HIToolbox
import AppKit
import SwiftUI

// `ocbar-app --selftest` — проверка того, что можно проверить без человека:
// разбор и запись профиля, правила проверки, чтение состояния. Последний шаг
// самый важный: файл, записанный приложением, скармливается настоящему
// ocbar, и тот должен увидеть профиль.
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
            if condition() {
                print("  [ OK ] \(name)")
            } else {
                failures += 1
                print("  [FAIL] \(name)\(detail.isEmpty ? "" : " — " + detail)")
            }
        }

        print("ocbar-app selftest")

        // --- разбор профиля ---
        let sample = """
        # комментарий
        [Connection]
        Name        = Основной
        Url         = vpn.example.com/employees
        User        = alice
        UserAgent   = AnyConnect Windows 4.10.06079

        [Routes]
        10.0.0.0/8
        172.16.0.0/12

        [DNS]
        example.com      = 10.0.0.1
        corp.example.com = vpn
        odd.example.com  = 10.0.0.2 5353

        [Proxy]
        Port        = 11080
        SystemProxy = on

        [Auth]
        Password     = keepassxc
        Totp         = keepassxc
        KeepassEntry = Группа/Запись

        [Health]
        Check = wiki.example.com:443

        [Autofill]
        stop  div.alert-error
        fill username input[name=username]
        click button[type=submit]

        [Connection]
        Notifications = off

        [Auth]
        Rules = ~/.config/ocbar/autofill.rules
        БудущийКлюч = значение

        [СовсемНоваяСекция]
        Ключ = значение
        """
        let doc = ProfileDoc.parse(sample, fileName: "sample")
        check("имя профиля", doc.name == "Основной")
        check("адрес", doc.url == "vpn.example.com/employees")
        check("две сети", doc.routes == ["10.0.0.0/8", "172.16.0.0/12"])
        check("три зоны", doc.zones.count == 3)
        check("зона с портом", doc.zones.last?.port == "5353")
        check("резолвер vpn", doc.zones[1].resolver == "vpn")
        check("источник кода", doc.totp == "keepassxc")
        check("источник пароля", doc.password == "keepassxc")
        check("файл правил", doc.rulesFile == "~/.config/ocbar/autofill.rules")
        check("уведомления", doc.notifications == "off")

        // Ключи, которых редактор не знает, должны пережить запись: молча
        // потерять чужую строку — худшее, что может сделать редактор.
        let rendered = doc.render()
        check("незнакомый ключ сохранён", rendered.contains("БудущийКлюч"), rendered)
        check("незнакомая секция сохранена", rendered.contains("[СовсемНоваяСекция]"))
        check("значение незнакомого ключа на месте",
              ProfileDoc.parse(rendered, fileName: "s").extras.contains { $0.key == "Ключ" && $0.value == "значение" })
        check("проверка доступа", doc.health == "wiki.example.com:443")
        check("три правила автозаполнения", doc.autofill.count == 3, "\(doc.autofill)")
        check("селектор с «=» цел", doc.autofill[1] == "fill username input[name=username]")
        check("правила переживают запись", ProfileDoc.parse(doc.render(), fileName: "s").autofill == doc.autofill)
        var badRule = doc
        badRule.autofill = ["fill nothing x"]
        check("непонятное правило — ошибка", ProfileCheck.check(badRule).contains { $0.level == .error && $0.text.contains("правило") })
        check("правила приняты как есть", ProfileCheck.check(doc).allSatisfy { !$0.text.contains("правило") })
        let steps = ProfileDoc.parse("[Connection]\nName = s\nUrl = vpn.example.test/s\n\n[Autofill]\n# шаг 1 — idp.test/login\nfill username input[name=u]\nclick button[id=next]\n# шаг 2 — idp.test/otp\nfill totp input[name=otp]\n", fileName: "s")
        check("окна формы: заголовки шагов в [Autofill] сохраняются",
              steps.autofill.count == 5 && steps.render().contains("# шаг 2 — idp.test/otp"), "\(steps.autofill)")
        check("окна формы: заголовок шага — не ошибка", ProfileCheck.check(steps).allSatisfy { !$0.text.contains("правило") })
        check("правило fill manual принимается", ProfileCheck.validRule("fill manual input[id=cap]"))
        var sms = doc
        sms.totp = "sms"
        check("Totp = sms — источник из списка", ProfileDoc.totpSources.contains("sms"))
        check("Totp = sms предупреждает о молчаливом входе",
              ProfileCheck.check(sms).contains { $0.level == .warning && $0.text.contains("SMS") })
        check("Totp = sms переживает запись", ProfileDoc.parse(sms.render(), fileName: "s").totp == "sms")
        let tp = ProfileDoc.parse("[Connection]\nName = p\nUrl = vpn.example.test/p\n\n[Auth]\nTotp = keychain\nTotpAlgorithm = sha256\nTotpDigits = 8\nTotpPeriod = 60\n", fileName: "p")
        check("параметры кода: разобраны", tp.totpAlgorithm == "SHA256" && tp.totpDigits == "8" && tp.totpPeriod == "60")
        let tpAgain = ProfileDoc.parse(tp.render(), fileName: "p")
        check("параметры кода: переживают запись",
              tpAgain.totpAlgorithm == "SHA256" && tpAgain.totpDigits == "8" && tpAgain.totpPeriod == "60", tp.render())
        check("параметры кода по умолчанию в файл не пишутся", !doc.render().contains("TotpAlgorithm"))
        var badDigits = tp
        badDigits.totpDigits = "9"
        check("параметры кода: 9 цифр — ошибка", ProfileCheck.check(badDigits).contains { $0.level == .error && $0.text.contains("цифр") })
        var kpCustom = tp
        kpCustom.totp = "keepassxc"
        kpCustom.keepassEntry = "Группа/Запись"
        check("параметры кода при KeePassXC — предупреждение",
              ProfileCheck.check(kpCustom).contains { $0.level == .warning && $0.text.contains("готовый код") })
        check("режим по умолчанию — туннель", doc.mode == "tunnel")
        check("порт SOCKS", doc.proxyPort == "11080")
        check("галочка системного прокси", doc.systemProxy)

        // --- запись и повторный разбор ---
        let again = ProfileDoc.parse(doc.render(), fileName: "sample")
        check("запись и разбор совпадают",
              again.name == doc.name && again.url == doc.url && again.routes == doc.routes
              && again.zones.count == doc.zones.count && again.health == doc.health
              && again.zones.last?.port == "5353" && again.systemProxy == doc.systemProxy
              && again.proxyPort == doc.proxyPort)

        var proxy = doc
        proxy.mode = "proxy"
        let proxyAgain = ProfileDoc.parse(proxy.render(), fileName: "sample")
        check("режим proxy переживает запись", proxyAgain.mode == "proxy")
        check("прокси-режим напоминает про ocproxy и SOCKS",
              ProfileCheck.check(proxy).contains { $0.level == .warning && $0.text.contains("ocproxy") })
        var pwCmd = doc
        pwCmd.password = "command"; pwCmd.passwordCommand = ""
        check("Password = command без команды — ошибка",
              ProfileCheck.check(pwCmd).contains { $0.level == .error && $0.text.contains("PasswordCommand") })
        var pwAsk = doc
        pwAsk.password = "ask"
        check("Password = ask предупреждает о молчаливом входе",
              ProfileCheck.check(pwAsk).contains { $0.level == .warning && $0.text.contains("молчаливое") })
        check("источник пароля переживает запись",
              ProfileDoc.parse(doc.render(), fileName: "s").password == "keepassxc")

        var badPort = doc
        badPort.proxyPort = "80"
        check("порт ниже 1024 — ошибка",
              ProfileCheck.check(badPort).contains { $0.level == .error })

        // --- правила проверки ---
        check("CIDR принимается", ProfileCheck.validCIDR("10.0.0.0/8"))
        check("CIDR без маски отвергнут", !ProfileCheck.validCIDR("10.0.0.0"))
        check("CIDR с маской 33 отвергнут", !ProfileCheck.validCIDR("10.0.0.0/33"))
        check("октет 300 отвергнут", !ProfileCheck.validIP("10.300.0.1"))
        check("зона принимается", ProfileCheck.validZone("int.example.com"))
        check("зона с косой чертой отвергнута", !ProfileCheck.validZone("a/b"))
        check("зона с точки отвергнута", !ProfileCheck.validZone(".example.com"))
        check("user-agent принимается", ProfileCheck.validUserAgent(ProfileDoc.defaultUserAgent))
        check("user-agent с кавычкой отвергнут", !ProfileCheck.validUserAgent("Any\"Connect"))

        var wide = doc
        wide.routes = ["0.0.0.0/1"]
        check("широкая сеть даёт предупреждение",
              ProfileCheck.check(wide).contains { $0.level == .warning && $0.text.contains("почти весь трафик") })
        var broken = doc
        broken.zones = [ZoneLine(zone: "плохая зона", resolver: "не-адрес", port: "")]
        check("плохая зона — ошибка",
              ProfileCheck.check(broken).contains { $0.level == .error })

        // --- глобальная горячая клавиша ---
        // Сочетание системное: занятое другой программой не регистрируется.
        // Берём заведомо редкое, чтобы проверка не зависела от того, что
        // сейчас запущено, и снимаем за собой.
        let rare = UInt32(kVK_F19)
        let first = GlobalHotkeys.shared.register("проверка", keyCode: rare,
                                                  modifiers: HotkeyCode.cmdOption) {}
        check("горячая клавиша регистрируется", first)
        check("занятое сочетание не регистрируется дважды",
              !GlobalHotkeys.shared.register("вторая", keyCode: rare,
                                             modifiers: HotkeyCode.cmdOption) {})
        GlobalHotkeys.shared.unregisterAll()
        let reRegistered = GlobalHotkeys.shared.register("проверка", keyCode: rare,
                                                         modifiers: HotkeyCode.cmdOption) {}
        check("после снятия регистрируется снова", reRegistered)
        GlobalHotkeys.shared.unregisterAll()

        // --- уведомления от клиента по URL ---
        let savedToken = Notifier.expectedToken
        Notifier.expectedToken = "5e1f7e57"
        defer { Notifier.expectedToken = savedToken }
        let n = Notifier.parse(URL(string: "ocbar://notify?title=ocbar%3A%20%D0%BF%D0%B0%D1%83%D0%B7%D0%B0&body=%D0%9C%D0%B0%D1%80%D1%88%D1%80%D1%83%D1%82%D1%8B%20%D1%81%D0%BD%D1%8F%D1%82%D1%8B&token=5e1f7e57")!)
        check("уведомление разбирается", n != nil)
        check("приставка «ocbar:» убрана", n?.title == "пауза", n?.title ?? "")
        check("текст уведомления", n?.body == "Маршруты сняты")
        check("чужая схема отвергнута", Notifier.parse(URL(string: "http://notify?title=x")!) == nil)
        check("пустое уведомление отвергнуто", Notifier.parse(URL(string: "ocbar://notify?token=5e1f7e57")!) == nil)

        // --- разбор состояния ---
        let status = Status.parse("""
        paused=0
        needs_login=0
        state=connected
        profile=main
        tundev=utun5
        ip=10.20.30.40
        since=1788723116
        dns=10.0.16.4 10.0.0.23
        supervisor=1
        route=10.0.0.0/8 utun5 on
        route=11.0.0.0/8 - off
        zone=example.com 10.0.0.1 applied on
        profile_list=main|Основной||Любые устройства
        default=main
        """)
        check("состояние connected", status.presentation == .connected)
        check("маршрут включён", status.routes.first?.enabled == true)
        check("маршрут без интерфейса", status.routes.last?.via == nil)
        check("выключенный маршрут", status.routes.last?.enabled == false)
        check("два резолвера", status.dns.count == 2)
        check("название профиля из списка", status.profileTitle == "Основной")
        check("туннельная сессия — не прокси", !status.isProxySession)

        let px = Status.parse("""
        paused=0
        needs_login=0
        woke_after_connect=1788723999
        state=connected
        profile=px
        tundev=
        ip=10.9.8.7
        since=1788723116
        mode=proxy
        supervisor=1
        socks=127.0.0.1:11080
        socks_up=1
        system_socks=Wi-Fi,Thunderbolt Bridge
        system_socks_refused=на «Wi-Fi» уже включён чужой SOCKS
        profile_mode=proxy
        proxy_port=11080
        system_proxy=on
        """)
        check("прокси-сессия распознаётся", px.isProxySession)
        check("адрес SOCKS", px.socks == "127.0.0.1:11080")
        check("SOCKS отвечает", px.socksUp)
        check("системный SOCKS на двух сервисах", px.systemSocksOn == ["Wi-Fi", "Thunderbolt Bridge"])
        check("причина отказа хелпера", px.systemSocksRefused.contains("чужой"))
        check("пробуждение после подключения", px.wokeAfterConnect != nil)
        check("прокси без маршрутов", px.routes.isEmpty && px.zones.isEmpty)

        // --- живой ocbar: запись профиля в отдельный каталог и его разбор ---
        if let binary = OcbarClient.shared.binary {
            let tmp = NSTemporaryDirectory() + "ocbar-selftest-\(getpid())"
            let profiles = tmp + "/profiles"
            try? FileManager.default.createDirectory(atPath: profiles, withIntermediateDirectories: true)
            let path = profiles + "/sample.ocbar"
            try? doc.render().write(toFile: path, atomically: true, encoding: .utf8)
            let r = Shell.run(binary, ["profiles"], env: ["OCBAR_CONFIG_DIR": tmp], timeout: 20)
            check("ocbar видит записанный профиль", r.out.contains("sample"), r.out.trimmed + r.err.trimmed)
            let s = Shell.run(binary, ["status", "--short"], env: ["OCBAR_CONFIG_DIR": tmp], timeout: 20)
            let parsed = Status.parse(s.out)
            check("сети профиля попали в status",
                  parsed.routes.map(\.net) == doc.routes, parsed.routes.map(\.net).joined(separator: " "))
            check("зоны профиля попали в status",
                  parsed.zones.count == doc.zones.count, "\(parsed.zones.count)")
            try? FileManager.default.removeItem(atPath: tmp)
        } else {
            print("  [ -- ] живой ocbar не найден, проверка пропущена")
        }

        print(failures == 0 ? "selftest: всё OK" : "selftest: провалов \(failures)")
        return failures == 0 ? 0 : 1
    }
}

// `--selftest --live-actions` — проверка действий на живом подключении тем
// же кодом, которым их делает меню: OcbarClient.action → ocbar → хелпер.
// Меняет состояние системы, поэтому отдельным флагом: сеть и зона
// выключаются и возвращаются, туннель ставится на паузу и снимается с неё.
extension SelfTest {
    static func liveActions() -> Int32 {
        var failures = 0
        let client = OcbarClient.shared
        func step(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: String = "") {
            if condition() { print("  [ OK ] \(name)") }
            else { failures += 1; print("  [FAIL] \(name)\(detail.isEmpty ? "" : " — " + detail)") }
        }
        func settle() { Thread.sleep(forTimeInterval: 1.0) }

        print("ocbar-app selftest --live-actions")
        let start = client.status()
        guard start.presentation == .connected else {
            print("  [ -- ] туннель не поднят (состояние: \(start.state.rawValue)) — проверять нечего")
            return 0
        }
        print("  исходно: \(start.profile) · \(start.tundev) · сетей \(start.routes.count) · зон \(start.zones.count)")

        // --- сеть ---
        if let route = start.routes.first(where: { $0.enabled }) {
            _ = client.toggleRoute(route.net); settle()
            let off = client.status().routes.first { $0.net == route.net }
            step("сеть \(route.net) выключена", off?.enabled == false)
            step("маршрут снят", off?.via != start.tundev, off?.via ?? "нет")
            _ = client.toggleRoute(route.net); settle()
            let on = client.status().routes.first { $0.net == route.net }
            step("сеть \(route.net) вернулась", on?.enabled == true)
            step("маршрут вернулся в \(start.tundev)", on?.via == start.tundev, on?.via ?? "нет")
        }

        // --- зона ---
        if let zone = start.zones.first(where: { $0.enabled && $0.applied }) {
            _ = client.toggleZone(zone.zone); settle()
            let off = client.status().zones.first { $0.zone == zone.zone }
            step("зона \(zone.zone) выключена", off?.enabled == false)
            step("файл в /etc/resolver снят", off?.applied == false)
            _ = client.toggleZone(zone.zone); settle()
            let on = client.status().zones.first { $0.zone == zone.zone }
            step("зона \(zone.zone) вернулась", on?.enabled == true)
            step("файл в /etc/resolver вернулся", on?.applied == true)
        }

        // --- пауза ---
        _ = client.pause(); settle()
        let paused = client.status()
        step("состояние — пауза", paused.presentation == .paused, paused.state.rawValue)
        step("зоны сняты", paused.zones.allSatisfy { !$0.applied }, "\(paused.zonesApplied.count) осталось")
        step("туннель жив", !paused.tundev.isEmpty && paused.tundev == start.tundev)
        _ = client.resume(); settle()
        let resumed = client.status()
        step("возобновлено", resumed.presentation == .connected, resumed.state.rawValue)
        step("сети вернулись",
             resumed.routes.filter { $0.enabled }.allSatisfy { $0.via == resumed.tundev },
             resumed.routes.map { "\($0.net)→\($0.via ?? "нет")" }.joined(separator: " "))
        step("зоны вернулись",
             resumed.zonesApplied.count == start.zonesApplied.count,
             "\(resumed.zonesApplied.count) из \(start.zonesApplied.count)")
        step("сессия та же (время не сбросилось)",
             resumed.since == start.since, humanSince(resumed.since))

        print(failures == 0 ? "live-actions: всё OK" : "live-actions: провалов \(failures)")
        return failures == 0 ? 0 : 1
    }
}

// Редактор профиля на настоящем окне: у только что открытого профиля и
// после выбора другого в списке кнопка разметки должна быть доступна.
// Раньше onChange полей срабатывал при загрузке профиля, редактор считал его
// «несохранённым», и кнопка была серой — глазами на витрине это не видно.
// Кнопки SwiftUI рисует сам (это не NSButton), а дерево доступности окна
// вне экрана пустое, поэтому редактор сам отдаёт то выражение, что стоит
// у кнопки в .disabled — его и проверяем после настоящей отрисовки.
extension SelfTest {
    @MainActor
    static func editorProbe() -> Int32 {
        guard OcbarClient.shared.binary != nil else {
            print("  [ -- ] редактор: живой ocbar не найден, проверка пропущена")
            return 0
        }
        var failures: Int32 = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  [ OK ] \(name)" : "  [FAIL] \(name)\(detail.isEmpty ? "" : " — " + detail)")
            if !ok { failures += 1 }
        }
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory() + "ocbar-editor-\(getpid())"
        try? fm.createDirectory(atPath: tmp + "/profiles", withIntermediateDirectories: true)
        try? "[Connection]\nName = Альфа\nUrl = vpn.example.test/a\nUser = alice\n\n[Auth]\nTotp = keychain\n"
            .write(toFile: tmp + "/profiles/a.ocbar", atomically: true, encoding: .utf8)
        try? "[Connection]\nName = Бета\nUrl = vpn.example.test/b\nUser = bob\nUserAgent = AnyConnect Linux_64 4.10.06079\n\n[Routes]\n10.0.0.0/8\n\n[Auth]\nPassword = ask\nTotp = off\n"
            .write(toFile: tmp + "/profiles/b.ocbar", atomically: true, encoding: .utf8)
        let oldConfig = ProcessInfo.processInfo.environment["OCBAR_CONFIG_DIR"]
        setenv("OCBAR_CONFIG_DIR", tmp, 1)
        defer {
            if let oldConfig { setenv("OCBAR_CONFIG_DIR", oldConfig, 1) } else { unsetenv("OCBAR_CONFIG_DIR") }
            try? fm.removeItem(atPath: tmp)
        }

        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 900, height: 1500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ProfileEditorView())
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        func views<T: NSView>(_ type: T.Type) -> [T] {
            var out: [T] = [], stack: [NSView] = [window.contentView!]
            while let v = stack.popLast() { if let t = v as? T { out.append(t) }; stack += v.subviews }
            return out
        }
        func shows(_ text: String) -> Bool { views(NSTextField.self).contains { $0.stringValue == text } }
        settle(2.5)
        check("редактор: открыт первый профиль", shows("Альфа"))
        check("редактор: разметка доступна у открытого профиля", ProfileEditorView.probeLearnEnabled == true,
              "кнопка " + (ProfileEditorView.probeLearnEnabled.map { $0 ? "доступна" : "серая" } ?? "не отрисована"))

        // Выбор другого профиля в списке — ровно то, что делает человек.
        // Профили в списке по алфавиту, «b» — последняя строка.
        if let table = views(NSTableView.self).first, table.numberOfRows > 0 {
            table.selectRowIndexes(IndexSet(integer: table.numberOfRows - 1), byExtendingSelection: false)
            settle(2)
            check("редактор: выбран второй профиль", shows("Бета"))
            check("редактор: разметка доступна после выбора другого профиля", ProfileEditorView.probeLearnEnabled == true,
                  "кнопка " + (ProfileEditorView.probeLearnEnabled.map { $0 ? "доступна" : "серая" } ?? "не отрисована"))
            // Файл открытого профиля записал кто-то другой (разметка, ocbar
            // rules): правок в редакторе нет — он должен перечитать файл сам.
            try? "[Connection]\nName = Бета-2\nUrl = vpn.example.test/b\n\n[Routes]\n10.0.0.0/8\n\n[Auth]\nPassword = ask\nTotp = off\n"
                .write(toFile: tmp + "/profiles/b.ocbar", atomically: true, encoding: .utf8)
            let checksBefore = ProfileEditorView.probeDiskChecks
            settle(3.5)
            check("редактор: файл, изменённый на диске, перечитан", shows("Бета-2"),
                  "сверок с диском \(ProfileEditorView.probeDiskChecks - checksBefore), последняя: «\(ProfileEditorView.probeDiskNote)»; поля: "
                  + views(NSTextField.self).map(\.stringValue).filter { $0.contains("Бета") }.joined(separator: ", "))
        } else {
            check("редактор: список профилей найден", false)
        }
        return failures
    }
}
