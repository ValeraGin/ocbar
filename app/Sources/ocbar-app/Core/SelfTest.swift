import Foundation

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

        [Auth]
        Totp         = keepassxc
        KeepassEntry = Группа/Запись

        [Health]
        Check = wiki.example.com:443
        """
        let doc = ProfileDoc.parse(sample, fileName: "sample")
        check("имя профиля", doc.name == "Основной")
        check("адрес", doc.url == "vpn.example.com/employees")
        check("две сети", doc.routes == ["10.0.0.0/8", "172.16.0.0/12"])
        check("три зоны", doc.zones.count == 3)
        check("зона с портом", doc.zones.last?.port == "5353")
        check("резолвер vpn", doc.zones[1].resolver == "vpn")
        check("источник кода", doc.totp == "keepassxc")
        check("проверка доступа", doc.health == "wiki.example.com:443")

        // --- запись и повторный разбор ---
        let again = ProfileDoc.parse(doc.render(), fileName: "sample")
        check("запись и разбор совпадают",
              again.name == doc.name && again.url == doc.url && again.routes == doc.routes
              && again.zones.count == doc.zones.count && again.health == doc.health
              && again.zones.last?.port == "5353")

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
