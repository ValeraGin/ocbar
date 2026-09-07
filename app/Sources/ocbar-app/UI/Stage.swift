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
            AboutView()
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            LogsView()
                .frame(width: 820, height: 620)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
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
                      expandDetails: Bool = false, expandProfiles: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            MenuView(expandDetails: expandDetails, expandProfiles: expandProfiles)
                .environmentObject(StatusStore(
                    preview: Fixture.status(presentation),
                    samples: Fixture.samples(active: presentation == .connected),
                    latency: "41 мс"))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
        }
    }
}
