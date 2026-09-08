import SwiftUI

// Витрина: все состояния меню разом, на подставленных данных.
// Открывается флагом `--stage` и нужна только при разработке — так же, как
// tools/ui-lab/index.html, в поставке она не мешает: обычный запуск её не
// показывает.
enum Fixture {
    static func status(_ presentation: Presentation) -> Status {
        var s = Status()
        s.profile = "main"
        s.profiles = [
            ProfileEntry(name: "main", title: "Основной", auth: "", descr: "Любые устройства"),
            ProfileEntry(name: "office", title: "Из офиса", auth: "", descr: "Изнутри сети"),
            ProfileEntry(name: "sms", title: "Парольная группа", auth: "password", descr: ""),
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
        case .starting: s.state = .starting
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
        s.systemSocksRefused = refused ? "на «USB 10/100/1G/2.5G LAN» уже включён чужой SOCKS 127.0.0.1:10808 — не перезаписываю" : ""
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
            ProfileEntry(name: "p\($0)", title: "Профиль \($0)", auth: $0 == 9 ? "password" : "",
                         descr: $0 % 2 == 0 ? "описание профиля номер \($0)" : "")
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

// Живая витрина: то же меню на настоящем состоянии машины. Нужна для
// проверки разбора `ocbar status --short` глазами, без открытия меню руками.
struct LiveStageView: View {
    @StateObject private var store = StatusStore()

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("живое состояние").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                MenuView()
                    .environmentObject(store)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("живое состояние · подробности").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                MenuView(expandDetails: true, expandProfiles: true)
                    .environmentObject(store)
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

// Витрина окон: «о программе» и журналы на живых данных, чтобы их тоже
// можно было увидеть снимком, а не только открыв руками.
struct StageWindowsView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            if CommandLine.arguments.contains("--mode") {
                ModeView()
                    .frame(width: 700, height: 640)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            } else if CommandLine.arguments.contains("--logs") {
                LogsView()
                    .frame(width: 860, height: 620)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            } else {
                SettingsWindow()
                    .frame(width: 900, height: 900)
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

struct StageView: View {
    private let cases: [(String, Presentation)] = [
        ("подключено", .connected), ("связь пропала", .lost), ("пауза", .paused),
        ("подключается", .starting), ("нужен вход", .needsLogin),
        ("отключено", .down), ("чужой туннель", .foreign), ("ocbar не найден", .missing),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            row(Array(cases[0..<4]))
            row(Array(cases[4..<8]))
            HStack(alignment: .top, spacing: 18) {
                card("подключено · подробности", .connected, expandDetails: true)
                card("подключено · профили", .connected, expandProfiles: true)
                card("пауза · подробности", .paused, expandDetails: true)
                Spacer()
            }
            // Высота меню не должна меняться, пока идёт действие: иначе оно
            // прыгает под курсором ровно в момент нажатия на переключатель.
            HStack(alignment: .top, spacing: 18) {
                card("подключено", .connected)
                card("подключено · идёт действие", .connected, busy: "Переключаю 10.0.0.0/8…")
                card("подключено · не получилось", .connected,
                     note: "ocbar: сеть 11.0.0.0/8 не включилась — хелпер вернул 1")
                card("после сна", Fixture.woke())
                Spacer()
            }
            HStack(alignment: .top, spacing: 18) {
                card("прокси · подробности", Fixture.proxy(), expandDetails: true)
                card("прокси · чужой системный SOCKS", Fixture.proxy(refused: true))
                card("прокси · SOCKS не отвечает", Fixture.proxy(socksUp: false), expandDetails: true)
                card("девять профилей · смена", Fixture.many(), expandProfiles: true,
                     switchTo: ProfileEntry(name: "p4", title: "Профиль 4", auth: "", descr: ""))
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func row(_ items: [(String, Presentation)]) -> some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(items, id: \.0) { name, presentation in card(name, presentation) }
            Spacer()
        }
    }

    private func card(_ name: String, _ presentation: Presentation,
                      expandDetails: Bool = false, expandProfiles: Bool = false,
                      busy: String? = nil, note: String? = nil) -> some View {
        card(name, Fixture.status(presentation), expandDetails: expandDetails,
             expandProfiles: expandProfiles, busy: busy, note: note,
             active: presentation == .connected)
    }

    private func card(_ name: String, _ status: Status,
                      expandDetails: Bool = false, expandProfiles: Bool = false,
                      busy: String? = nil, note: String? = nil, active: Bool = true,
                      switchTo: ProfileEntry? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            MenuView(expandDetails: expandDetails, expandProfiles: expandProfiles, switchTo: switchTo)
                .environmentObject(StatusStore(
                    preview: status,
                    samples: Fixture.samples(active: active),
                    latency: "41 мс", busy: busy, actionNote: note))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
        }
    }
}
