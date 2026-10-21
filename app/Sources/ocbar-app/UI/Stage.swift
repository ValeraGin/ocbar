import SwiftUI

// Витрина: все состояния меню разом, на подставленных данных.
// Открывается флагом `--stage` и нужна только при разработке — так же, как
// tools/ui-lab/index.html, в поставке она не мешает: обычный запуск её не
// показывает.
enum Fixture {
    // Имена и описания — через перевод: витрина снимает кадры для README
    // на обоих языках, и русское имя профиля в английском кадре выглядит ошибкой.
    static var demoProfiles: [(String, String)] { [
        ("main", """
        [Connection]
        Name        = \(L("Основной"))
        Description = \(L("Любые устройства"))
        Url         = vpn.example.com/employees
        User        = alice
        [Routes]
        10.0.0.0/8
        172.16.0.0/12
        [DNS]
        example.com     = 192.0.2.10
        int.example.com = vpn
        [Auth]
        Totp = keychain
        KeychainService = ru.ocbar.stage-demo
        """),
        ("office", """
        [Connection]
        Name        = \(L("Из офиса"))
        Description = \(L("Изнутри сети"))
        Url         = vpn.example.com/office
        User        = alice
        [Routes]
        10.0.0.0/8
        """),
        ("sms", """
        [Connection]
        Name        = \(L("Парольная группа"))
        Description = \(L("пароль + код из SMS"))
        Url         = vpn.example.com/sms
        User        = alice
        """),
    ] }

    /// Временный каталог конфигурации с вымышленными профилями.
    static func demoConfigDir() -> String? {
        let dir = NSTemporaryDirectory() + "ocbar-stage-\(getpid())"
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir + "/profiles", withIntermediateDirectories: true)
            for (name, body) in demoProfiles {
                try (body + "\n").write(toFile: dir + "/profiles/\(name).ocbar", atomically: true, encoding: .utf8)
            }
        } catch { return nil }
        return dir
    }

    static func status(_ presentation: Presentation) -> Status {
        var s = Status()
        s.profile = "main"
        s.profiles = [
            ProfileEntry(name: "main", title: L("Основной"), auth: "", descr: L("Любые устройства"),
                         url: "vpn.example.com/employees"),
            ProfileEntry(name: "office", title: L("Из офиса"), auth: "", descr: L("Изнутри сети"),
                         url: "office-vpn.example.com/inside"),
            ProfileEntry(name: "sms", title: L("Парольная группа"), auth: "password", descr: "",
                         url: "vpn2.example.com/sms"),
        ]
        s.defaultProfile = "main"
        s.iface = "en0"
        s.supervisor = true
        s.tundev = "utun4"
        s.ip = "10.20.30.40"
        s.gateway = "198.51.100.7"
        s.mtu = "1294"
        s.dns = ["192.0.2.10", "192.0.2.11"]
        s.mode = "split"
        s.since = Date().addingTimeInterval(-8_040)
        s.routes = [
            RouteEntry(net: "10.0.0.0/8", via: "utun4", enabled: true),
            RouteEntry(net: "172.16.0.0/12", via: "utun4", enabled: true),
            RouteEntry(net: "11.0.0.0/8", via: nil, enabled: false),
        ]
        s.zones = [
            ZoneEntry(zone: "example.com", dns: "192.0.2.10", applied: true, enabled: true),
            ZoneEntry(zone: "int.example.com", dns: "vpn", applied: true, enabled: true),
            ZoneEntry(zone: "old.example.com", dns: "192.0.2.11", applied: false, enabled: false),
        ]
        switch presentation {
        case .connected: s.state = .connected
        case .lost:
            s.state = .connected
            s.linkLostSince = Date().addingTimeInterval(-18)
        case .paused:
            s.state = .paused; s.paused = true
            s.zones = s.zones.map { ZoneEntry(zone: $0.zone, dns: $0.dns, applied: false, enabled: $0.enabled) }
        case .starting: s.state = .starting; s.connectStage = "login"
        case .needsLogin:
            s.state = .down; s.needsLogin = true
            s.tundev = ""; s.ip = ""; s.gateway = ""
        case .down, .foreign:
            s.state = .down
            s.foreign = presentation == .foreign
            s.tundev = ""; s.ip = ""; s.gateway = ""; s.since = nil
        case .missing:
            s.available = false
            s.profiles = []; s.routes = []; s.zones = []; s.tundev = ""; s.since = nil
        }
        return s
    }

    // Прокси-сессия: интерфейса нет, маршрутов и зон нет, есть адрес SOCKS.
    static func proxy(refused: Bool = false, socksUp: Bool = true) -> Status {
        var s = status(.connected)
        s.mode = "proxy"; s.profileMode = "proxy"; s.proxyPort = "11080"
        s.tundev = ""; s.mtu = ""
        s.routes = []; s.zones = []
        s.socks = "127.0.0.1:11080"; s.socksUp = socksUp
        s.systemProxy = true
        s.systemSocksOn = refused || !socksUp ? [] : ["USB 10/100/1G/2.5G LAN"]
        s.systemSocksRefused = refused ? L("на «USB 10/100/1G/2.5G LAN» уже включён чужой SOCKS 127.0.0.1:10808 — не перезаписываю") : ""
        if !socksUp { s.linkLostSince = Date().addingTimeInterval(-6) }
        return s
    }

    static func woke() -> Status {
        var s = status(.connected)
        s.wokeAfterConnect = Date().addingTimeInterval(-600)
        return s
    }

    // Много профилей: список должен прокручиваться, а не растягивать меню.
    static func many() -> Status {
        var s = status(.connected)
        s.profiles = (1...9).map {
            ProfileEntry(name: "p\($0)", title: L("Профиль %@", $0), auth: $0 == 9 ? "password" : "",
                         descr: $0 % 2 == 0 ? L("описание профиля номер %@", $0) : "")
        }
        s.profile = "p1"
        return s
    }

    static func samples(active: Bool) -> [StatusStore.TrafficSample] {
        (0..<30).map { i in
            let base = active ? 1.2e6 : 0
            let wave = active ? abs(sin(Double(i) * 0.55)) * 9e5 : 0
            return StatusStore.TrafficSample(at: Date().addingTimeInterval(Double(i - 30) * 2),
                                             down: base + wave, up: (base + wave) * 0.12)
        }
    }
}

// Витрина окон: «о программе» и журналы на живых данных, чтобы их тоже
// можно было увидеть снимком, а не только открыв руками.
struct StageWindowsView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            if CommandLine.arguments.contains("--diagnostics") {
                DiagnosticsView()
                    .frame(width: 760, height: 620)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            } else if CommandLine.arguments.contains("--logs") {
                LogsView()
                    .frame(width: 860, height: 620)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            } else {
                SettingsWindow()
                    .frame(width: 900, height: 1500)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// Кадр для README: окно настроек в рамке, как в витрине окон.
struct ScreenshotSettingsView: View {
    var body: some View {
        SettingsWindow()
            .frame(width: 1000, height: 660)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// Значок в строке меню во всех состояниях и на каждом шаге подключения —
// проверить глазами: --stage --screenshot icons.
struct ScreenshotIconsView: View {
    private func status(_ p: Presentation, stage: String = "") -> Status {
        var s = Fixture.status(p)
        s.connectStage = stage
        return s
    }

    private func cell(_ title: String, _ s: Status, blink: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: MenuBarIcon.image(for: s, blink: blink))
                .resizable().interpolation(.high).frame(width: 78, height: 54)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(width: 104)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                cell("connected", status(.connected))
                cell("down", status(.down))
                cell("paused", status(.paused))
                cell("lost", status(.lost))
                cell("needsLogin", status(.needsLogin))
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(["gateway", "login", "window", "session", "tunnel"], id: \.self) { stage in
                    let s = status(.starting, stage: stage)
                    cell(ConnectStep.of(s)?.title ?? stage, s)
                }
                cell("login, blink", status(.starting, stage: "login"), blink: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// Демо-меню для кадров README и анимации (tools/menu-shots.sh): настоящее
// меню под своим значком на вымышленных профилях. Кадр задаёт файл
// $OCBAR_DEMO_STATE: «имя кадра» или «имя:option» (сведения как с ⌥).
// Меню обновляется на месте, как живое, — кадры снимаются с открытого меню.
@MainActor
enum DemoMenu {
    static let store = StatusStore(preview: Fixture.status(.connected), samples: Fixture.samples(active: true),
                                   latency: "41 " + L("мс"))
    private static var last = ""
    private static var timer: Timer?
    /// Где открывать меню для кадров (левый верхний угол меню).
    static var anchor = NSPoint(x: 200, y: 800)

    static func open() {
        guard let menu = AppDelegate.hosted?.menu else { return }
        menu.popUp(positioning: nil, at: anchor, in: nil)
    }

    static var stateFile: String {
        ProcessInfo.processInfo.environment["OCBAR_DEMO_STATE"] ?? NSTemporaryDirectory() + "ocbar-demo-state"
    }

    static func start() {
        apply("connected")
        // Таймер в режиме .common и вызов прямо из него: пока меню открыто,
        // цикл событий в режиме меню, а главная очередь может стоять.
        let t = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // OCBAR_DEMO_OPEN=1 — меню открывается само, как от щелчка по значку:
        // съёмке не нужен ни Accessibility, ни щелчок по экрану.
        if ProcessInfo.processInfo.environment["OCBAR_DEMO_OPEN"] == "1" {
            let open = Timer(timeInterval: 1.0, repeats: false) { _ in
                MainActor.assumeIsolated { open() }
            }
            RunLoop.main.add(open, forMode: .common)
        }
    }

    private static func poll() {
        let raw = (try? String(contentsOfFile: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, raw != last else { return }
        last = raw
        apply(raw)
    }

    static func apply(_ raw: String) {
        let parts = raw.split(separator: ":").map(String.init)
        let name = parts.first ?? "connected"
        store.optionAtOpen = parts.contains("option")

        var busy: String?
        let status: Status
        switch name {
        case "down": status = Fixture.status(.down)
        case "connecting": status = connecting("login"); busy = L("Подключаюсь…")
        case "connecting-window": status = connecting("window"); busy = L("Подключаюсь…")
        case "network-busy": status = Fixture.status(.connected); busy = L("Переключаю %@…", "172.16.0.0/12")
        case "network-off": status = withoutSecondRoute()
        case "pausing": status = withoutSecondRoute(); busy = L("Ставлю на паузу…")
        case "paused": status = Fixture.status(.paused)
        case "lost": status = Fixture.status(.lost)
        case "login": status = Fixture.status(.needsLogin)
        case "foreign": status = Fixture.status(.foreign)
        case "missing": status = Fixture.status(.missing)
        case "proxy": status = Fixture.proxy()
        case "woke": status = Fixture.woke()
        default: status = Fixture.status(.connected)
        }
        store.applyPreview(status, busy: busy)
    }

    private static func connecting(_ stage: String) -> Status {
        var s = Fixture.status(.starting)
        s.connectStage = stage
        return s
    }

    private static func withoutSecondRoute() -> Status {
        var s = Fixture.status(.connected)
        s.routes = s.routes.map { $0.net == "172.16.0.0/12" ? RouteEntry(net: $0.net, via: nil, enabled: false) : $0 }
        return s
    }
}
