import SwiftUI

// Свёрнутое меню: состояние, профиль, время, график трафика, действия.
// Подробности разворачиваются здесь же — отдельного окна для них не нужно.
struct MenuView: View {
    @EnvironmentObject var store: StatusStore
    @Environment(\.openWindow) private var openWindow
    @State private var showDetails: Bool
    @State private var showProfiles: Bool

    init(expandDetails: Bool = false, expandProfiles: Bool = false) {
        _showDetails = State(initialValue: expandDetails)
        _showProfiles = State(initialValue: expandProfiles)
    }

    private var s: Status { store.status }
    private var look: StateLook { StateLook.of(s) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let note = look.note {
                Text(note)
                    .font(.ocNote).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13).padding(.top, 5)
            }
            if let error = store.lastError {
                Text(error)
                    .font(.ocNote).foregroundStyle(Palette.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
                    .padding(.horizontal, 13).padding(.top, 5)
            }
            if look.graph { graph }
            Sep()
            actions
            if !s.profiles.isEmpty { profiles }
            // Подробности имеют смысл, только когда есть туннель: у
            // отключённого клиента там одни прочерки.
            if look.details {
                Sep()
                detailsBlock
            }
            Sep()
            footer
        }
        .frame(width: 320)
        .padding(.vertical, 7)
        .onAppear {
            store.menuOpen = true
            if showDetails { store.detailsOpen = true }
            store.refresh()
        }
        .onDisappear { store.menuOpen = false; store.detailsOpen = false }
    }

    // --- шапка -----------------------------------------------------------

    private var header: some View {
        HStack(spacing: 8) {
            StateDot(color: look.color, pulsing: look.pulsing)
            Text(look.title).font(.ocTitle).foregroundStyle(Palette.text)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if look.showsTime {
                Text(humanSince(s.since)).font(.ocMono).foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 13).padding(.top, 4)
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 2) {
            Sparkline(samples: store.samples, capacity: 30, active: look.graphActive)
            HStack {
                Text("↓ " + Size.rate(store.currentDown)).foregroundStyle(Palette.accent)
                Text("↑ " + Size.rate(store.currentUp)).foregroundStyle(Palette.tertiary)
                Spacer()
                Text("за минуту").foregroundStyle(Palette.tertiary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 13)
        }
    }

    // --- действия --------------------------------------------------------

    @ViewBuilder
    private var actions: some View {
        if let busy = store.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text(busy).font(.ocBody).foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 13).padding(.vertical, 5)
        } else {
            switch s.presentation {
            case .connected, .lost:
                MenuRow(action: { store.pause() }) {
                    Label("Приостановить", systemImage: "pause.circle").labelStyle(.titleOnly)
                    Spacer()
                    Text("⌥⌘P").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                }
                MenuRow(action: { store.disconnect() }) { Text("Отключить") }
            case .paused:
                MenuRow(action: { store.resume() }) { Text("Возобновить").fontWeight(.medium) }
                MenuRow(action: { store.disconnect() }) { Text("Отключить совсем") }
            case .starting:
                MenuRow(action: { store.disconnect() }) { Text("Отменить подключение") }
            case .needsLogin:
                MenuRow(action: { store.connect(profile: s.profile.isEmpty ? nil : s.profile) }) {
                    Text("Войти").fontWeight(.medium)
                }
                MenuRow(action: { store.disconnect() }) { Text("Не подключаться") }
            case .down, .foreign:
                let target = s.defaultProfile.isEmpty ? nil : s.defaultProfile
                MenuRow(enabled: OcbarClient.shared.binary != nil, action: { store.connect(profile: target) }) {
                    Text(target.map { name in
                        "Подключить · " + (s.profiles.first { $0.name == name }?.display ?? name)
                    } ?? "Подключить")
                }
            case .missing:
                EmptyView()
            }
        }
    }

    // --- профили ---------------------------------------------------------

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(action: { withAnimation(.easeOut(duration: 0.12)) { showProfiles.toggle() } }) {
                Text("Профили")
                Spacer()
                Text(s.profiles.count.description).font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                Image(systemName: showProfiles ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(Palette.tertiary)
            }
            if showProfiles {
                ForEach(s.profiles) { p in
                    MenuRow(enabled: !p.isPassword, action: { store.connect(profile: p.name) }) {
                        Image(systemName: p.name == s.profile && s.state != .down ? "checkmark" : "")
                            .font(.system(size: 10)).frame(width: 11)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.display).font(.system(size: 12))
                            if p.isPassword {
                                Text("пароль + код из SMS — не через ocbar")
                                    .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                            } else if !p.descr.isEmpty {
                                Text(p.descr).font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // --- подробности -----------------------------------------------------

    private var detailsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(action: {
                withAnimation(.easeOut(duration: 0.12)) { showDetails.toggle() }
                store.detailsOpen = showDetails
                if showDetails { store.refresh() }
            }) {
                Text(showDetails ? "Свернуть" : "Подробнее")
                Spacer()
                Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9)).foregroundStyle(Palette.tertiary)
            }
            if showDetails { details }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            KVRow(label: "Адрес в туннеле", value: s.ip)
            KVRow(label: "Шлюз", value: s.gateway)
            KVRow(label: "MTU", value: s.mtu)
            KVRow(label: "Резолверы", value: s.dns.joined(separator: " "))
            KVRow(label: "Принято / отдано",
                  value: "\(Size.bytes(store.totalRx)) / \(Size.bytes(store.totalTx))")
            KVRow(label: "Задержка", value: store.latency ?? "—")
            Sep()
            SectionHead(title: "Сети в туннеле",
                        trailing: "\(s.routesOn.count) из \(s.routes.count)")
            if s.routes.isEmpty {
                Text("в профиле нет ни одной сети")
                    .font(.ocNote).foregroundStyle(Palette.tertiary).padding(.horizontal, 13)
            }
            ForEach(s.routes) { r in routeRow(r) }
            Sep()
            SectionHead(title: "Зоны DNS",
                        trailing: "\(s.zones.filter { $0.enabled }.count) из \(s.zones.count)")
            ForEach(s.zones) { z in zoneRow(z) }
        }
    }

    private func routeRow(_ r: RouteEntry) -> some View {
        HStack(spacing: 8) {
            Text(r.net).font(.ocMono)
                .foregroundStyle(r.enabled ? Palette.text : Palette.tertiary)
            if r.enabled, let via = r.via, via != s.tundev {
                Text("→ \(via)").font(.ocMonoSmall).foregroundStyle(Palette.warn)
            } else if r.enabled, r.via == nil, s.state == .connected {
                Text("нет маршрута").font(.ocMonoSmall).foregroundStyle(Palette.warn)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { r.enabled }, set: { _ in store.toggleRoute(r.net) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(store.busy != nil || s.paused)
        }
        .padding(.horizontal, 13).padding(.vertical, 1)
    }

    private func zoneRow(_ z: ZoneEntry) -> some View {
        HStack(spacing: 8) {
            Text(z.zone).font(.ocMono)
                .foregroundStyle(z.enabled ? Palette.text : Palette.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Text("→ \(z.dns)").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { z.enabled }, set: { _ in store.toggleZone(z.zone) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(store.busy != nil || s.paused)
        }
        .padding(.horizontal, 13).padding(.vertical, 1)
    }

    // --- подвал ----------------------------------------------------------

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Сеть: \(s.iface.isEmpty ? "?" : s.iface)")
                Text("·")
                Text(s.supervisor ? "супервизор работает" : "супервизор не запущен")
                    .foregroundStyle(s.supervisor ? Palette.tertiary : Palette.warn)
            }
            .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 13).padding(.bottom, 3)

            MenuRow(action: { open(WindowID.profiles) }) { Text("Профили и настройка…") }
            MenuRow(action: { open(WindowID.mode) }) {
                Text("Режим работы…")
                Spacer()
                Text("туннель").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
            }
            MenuRow(action: { open(WindowID.logs) }) { Text("Журналы…") }
            MenuRow(action: { open(WindowID.about) }) { Text("О программе…") }
            MenuRow(action: {
                NSWorkspace.shared.open(URL(fileURLWithPath: OcbarClient.shared.configDir))
            }) { Text("Открыть конфигурацию") }

            MenuRow(action: { NSApplication.shared.terminate(nil) }) {
                Text("Выйти")
                Spacer()
                Text("⌘Q").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
            }
        }
    }
}

// Окна открываются поверх: приложение живёт значком в меню-баре, и без
// явной активации окно уходит за чужие.
extension MenuView {
    func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// Как выглядит каждое состояние. Различаются не строкой, а целиком: цвет,
// заголовок, пояснение, есть ли график и время.
struct StateLook {
    let color: Color
    let title: String
    let note: String?
    let showsTime: Bool
    let graph: Bool
    let graphActive: Bool
    let pulsing: Bool
    let details: Bool

    static func of(_ s: Status) -> StateLook {
        switch s.presentation {
        case .connected:
            return .init(color: Palette.ok, title: s.profileTitle, note: nil,
                         showsTime: true, graph: true, graphActive: true, pulsing: false, details: true)
        case .lost:
            let waited = s.linkLostSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            return .init(color: Palette.warn, title: s.profileTitle,
                         note: "Связи нет \(waited) с. openconnect восстанавливает сессию сам — вход не потребуется.",
                         showsTime: true, graph: true, graphActive: false, pulsing: true, details: true)
        case .paused:
            return .init(color: Palette.warn, title: "На паузе",
                         note: "Маршруты и зоны сняты, туннель и сессия живы — возврат без входа.",
                         showsTime: true, graph: false, graphActive: false, pulsing: false, details: true)
        case .starting:
            return .init(color: Palette.warn, title: "Подключается…", note: nil,
                         showsTime: false, graph: false, graphActive: false, pulsing: true, details: false)
        case .needsLogin:
            return .init(color: Palette.bad, title: "Нужен вход",
                         note: "Сессия истекла, молча войти не удалось. Автоподключение остановлено — решение за вами.",
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .down:
            return .init(color: Palette.line2, title: "Отключён", note: nil,
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .foreign:
            return .init(color: Palette.tertiary, title: "Чужой openconnect",
                         note: "Туннель поднят не через ocbar — он его не трогает.",
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .missing:
            return .init(color: Palette.bad, title: "ocbar не найден",
                         note: "Искал в /opt/homebrew/bin, /usr/local/bin и рядом с приложением. Путь можно задать переменной OCBAR_BIN.",
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        }
    }
}
