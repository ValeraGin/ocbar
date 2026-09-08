import SwiftUI

// Свёрнутое меню: состояние, профиль, время, график трафика, действия.
// Подробности разворачиваются здесь же — отдельного окна для них не нужно.
struct MenuView: View {
    @EnvironmentObject var store: StatusStore
    @Environment(\.openWindow) private var openWindow
    @State private var showDetails: Bool
    @State private var showProfiles: Bool
    // Смена профиля на живой сессии стоит нового входа: спрашиваем, а не
    // переключаем по первому щелчку.
    @State private var switchTo: ProfileEntry?

    init(expandDetails: Bool = false, expandProfiles: Bool = false, switchTo: ProfileEntry? = nil) {
        _showDetails = State(initialValue: expandDetails)
        _showProfiles = State(initialValue: expandProfiles)
        _switchTo = State(initialValue: switchTo)
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
            if let woke = s.wokeAfterConnect, s.state == .connected {
                Text("Мак просыпался после подключения (\(Self.clock.string(from: woke))) — "
                     + (s.supervisor ? "супервизор проверит туннель сам." : "супервизор не работает, проверьте доступ."))
                    .font(.ocNote).foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13).padding(.top, 5)
            }
            if s.isProxySession, !s.systemSocksRefused.isEmpty {
                Text("Системный SOCKS не включён: \(s.systemSocksRefused)")
                    .font(.ocNote).foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.top, 5)
            }
            if let warning = store.helperWarning {
                Text(warning)
                    .font(.ocNote).foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.top, 5)
            }
            if let message = store.actionNote ?? (s.presentation == .missing ? nil : store.lastError) {
                HStack(alignment: .top, spacing: 6) {
                    Text(message)
                        .font(.ocNote)
                        .foregroundStyle(store.actionFailed || store.actionNote == nil ? Palette.bad : Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    if store.actionNote != nil {
                        Button { store.dismissNote() } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless).foregroundStyle(Palette.tertiary)
                    }
                }
                .padding(.horizontal, 13).padding(.top, 5)
            }
            // В прокси-режиме интерфейса нет, а с ним и счётчиков: график
            // убран, а не рисует нули.
            if look.graph, !s.isProxySession { graph }
            Sep()
            actions
            profiles
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
        .background(shortcuts)
        .onAppear {
            store.menuOpen = true
            if showDetails { store.detailsOpen = true }
            store.refresh()
        }
        .onDisappear { store.menuOpen = false; store.detailsOpen = false; switchTo = nil }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    // Клавиши работают, пока меню открыто: своего глобального перехвата у
    // приложения нет и не заводится — это отдельное разрешение системы.
    private var shortcuts: some View {
        Group {
            Button("") {
                switch s.presentation {
                case .connected, .lost: store.pause()
                case .paused: store.resume()
                default: break
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            Button("") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // --- шапка -----------------------------------------------------------

    private var header: some View {
        HStack(spacing: 8) {
            StateDot(color: look.color, pulsing: look.pulsing)
            Text(look.title).font(.ocTitle).foregroundStyle(Palette.text)
                .lineLimit(1).truncationMode(.tail)
            if s.isProxySession {
                Text("прокси").font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.accent.opacity(0.18)))
                    .foregroundStyle(Palette.accent)
            }
            Spacer(minLength: 6)
            // Индикатор занятости живёт в шапке, а не вместо строк действий:
            // подмена строк меняла высоту меню, и оно прыгало под курсором.
            if store.busy != nil {
                ProgressView().controlSize(.small).scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            }
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

    private var actions: some View {
        actionRows
            .opacity(store.busy == nil ? 1 : 0.4)
            .allowsHitTesting(store.busy == nil)
    }

    @ViewBuilder
    private var actionRows: some View {
        Group {
            switch s.presentation {
            case .connected, .lost:
                // В прокси-режиме паузы нет: снаружи туннеля ничего не
                // изменено, снимать нечего — ocbar так и ответит.
                if !s.isProxySession {
                    MenuRow(action: { store.pause() }) {
                        Text("Приостановить")
                        Spacer()
                        if GlobalHotkeys.shared.isRegistered("pause") {
                            Text("⌥⌘P").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                        }
                    }
                }
                MenuRow(action: { store.disconnect() }) { Text("Отключить") }
            case .paused:
                MenuRow(action: { store.resume() }) {
                    Text("Возобновить").fontWeight(.medium)
                    Spacer()
                    if GlobalHotkeys.shared.isRegistered("pause") {
                        Text("⌥⌘P").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                    }
                }
                MenuRow(action: { store.disconnect() }) { Text("Отключить совсем") }
            case .starting:
                MenuRow(action: { store.disconnect() }) { Text("Отменить подключение") }
            case .needsLogin:
                // Человек нажал сам — окно входа должно появиться сразу, а не
                // после двухсекундной пробы молчаливого прохода.
                MenuRow(action: { store.connect(profile: s.profile.isEmpty ? nil : s.profile, show: true) }) {
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

    @ViewBuilder
    private var profiles: some View {
        if s.profiles.isEmpty {
            if s.available {
                MenuRow(action: { open(WindowID.settings) }) {
                    Text("Профилей нет — создать…")
                    Spacer()
                    Image(systemName: "plus").font(.system(size: 9)).foregroundStyle(Palette.tertiary)
                }
            }
        } else {
            profileList
        }
    }

    private var sessionUp: Bool {
        switch s.presentation {
        case .connected, .lost, .paused, .starting: return true
        default: return false
        }
    }

    private func choose(_ p: ProfileEntry) {
        if sessionUp, p.name != s.profile {
            withAnimation(.easeOut(duration: 0.12)) { switchTo = p }
        } else {
            store.connect(profile: p.name)
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(action: { withAnimation(.easeOut(duration: 0.12)) { showProfiles.toggle() } }) {
                Text("Профили")
                Spacer()
                Text(s.profiles.count.description).font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                Image(systemName: showProfiles ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(Palette.tertiary)
            }
            if showProfiles {
                // Восемь профилей вместе с подробностями не влезают на экран
                // 13" — список прокручивается, а не растягивает меню.
                BoundedScroll(maxHeight: 210) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(s.profiles) { p in
                            MenuRow(enabled: !p.isPassword, action: { choose(p) }) {
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
            if let p = switchTo {
                switchPrompt(p)
            }
        }
    }

    private func switchPrompt(_ p: ProfileEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Переключиться на «\(p.display)»? Текущая сессия закроется, потребуется вход.")
                .font(.ocNote).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Переключиться") {
                    switchTo = nil
                    store.connect(profile: p.name)
                }
                .controlSize(.small).keyboardShortcut(.defaultAction)
                Button("Оставить") { withAnimation(.easeOut(duration: 0.12)) { switchTo = nil } }
                    .controlSize(.small).keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.warn.opacity(0.12)))
        .padding(.horizontal, 13).padding(.vertical, 4)
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
            if showDetails {
                BoundedScroll(maxHeight: 340) {
                    if s.isProxySession { proxyDetails } else { details }
                }
            }
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

    // Прокси-режим: вместо сетей и зон — адрес SOCKS и как им пользоваться.
    // Маршрутов и зон здесь нет не потому, что они выключены, а потому, что
    // бессмысленны, — поэтому их не показываем вовсе.
    private var proxyDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SOCKS").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Spacer(minLength: 8)
                Text(s.socks.isEmpty ? "—" : s.socks)
                    .font(.ocMono).foregroundStyle(s.socksUp ? Palette.text : Palette.bad)
                    .textSelection(.enabled)
                CopyButton(text: s.socks)
            }
            .padding(.horizontal, 13).padding(.vertical, 2)
            if !s.socksUp {
                Text("порт не отвечает — супервизор перезапустит прокси")
                    .font(.ocNote).foregroundStyle(Palette.bad).padding(.horizontal, 13)
            }
            KVRow(label: "Адрес в туннеле", value: s.ip)
            KVRow(label: "Шлюз", value: s.gateway)
            KVRow(label: "Резолверы", value: s.dns.joined(separator: " "))
            KVRow(label: "Системный SOCKS",
                  value: s.systemSocksOn.isEmpty
                      ? (s.systemProxy ? "не включён" : "выключен в профиле")
                      : "включён на " + s.systemSocksOn.joined(separator: ", "),
                  color: s.systemSocksOn.isEmpty && s.systemProxy ? Palette.warn : Palette.text)
            Sep()
            SectionHead(title: "Как направить программу")
            hintRow("curl --socks5-hostname \(s.socks) URL")
            hintRow("ALL_PROXY=socks5h://\(s.socks) команда")
            Text("Имена внутренних хостов резолвит ocproxy по DNS шлюза (socks5h), поэтому в системе ничего не меняется. Паузы в этом режиме нет: снимать нечего.")
                .font(.system(size: 10.5)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13).padding(.top, 3)
        }
    }

    private func hintRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.text)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 4)
            CopyButton(text: text)
        }
        .padding(.horizontal, 13).padding(.vertical, 1)
    }

    private func routeRow(_ r: RouteEntry) -> some View {
        let on = store.routeIsOn(r)
        // Пока действие не доехало, состояние сети показывается по нажатию,
        // а не по последнему опросу: иначе переключатель отщёлкивает назад.
        let settled = store.pendingRoutes[r.net] == nil
        return HStack(spacing: 8) {
            Text(r.net).font(.ocMono)
                .foregroundStyle(on ? Palette.text : Palette.tertiary)
            if settled, on, let via = r.via, via != s.tundev {
                Text("→ \(via)").font(.ocMonoSmall).foregroundStyle(Palette.warn)
            } else if settled, on, r.via == nil, s.state == .connected {
                Text("нет маршрута").font(.ocMonoSmall).foregroundStyle(Palette.warn)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { store.toggleRoute(r.net, to: $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(store.busy != nil || s.paused)
                .accessibilityLabel("сеть \(r.net) в туннеле")
        }
        .padding(.horizontal, 13).padding(.vertical, 1)
    }

    private func zoneRow(_ z: ZoneEntry) -> some View {
        let on = store.zoneIsOn(z)
        return HStack(spacing: 8) {
            Text(z.zone).font(.ocMono)
                .foregroundStyle(on ? Palette.text : Palette.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Text("→ \(z.dns)").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { on }, set: { store.toggleZone(z.zone, to: $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .disabled(store.busy != nil || s.paused)
                .accessibilityLabel("зона \(z.zone) через \(z.dns)")
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

            MenuRow(action: { open(WindowID.settings) }) {
                Text("Настройка…")
                Spacer()
                Text("режим: " + (s.profileMode == "proxy" ? "прокси" : "туннель"))
                    .font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
            }
            // Разметка формы входа — для профиля, который сейчас выбран (или
            // по умолчанию). Правила лягут в сам профиль, секция [Autofill].
            if let target = learnTarget {
                MenuRow(enabled: store.busy == nil, action: { store.learn(profile: target) }) {
                    Text("Разметить форму входа…")
                    Spacer()
                    Text(s.profiles.first { $0.name == target }?.display ?? target)
                        .font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            MenuRow(action: { open(WindowID.diagnostics) }) { Text("Диагностика…") }
            MenuRow(action: { open(WindowID.logs) }) { Text("Журналы…") }
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
    private var learnTarget: String? {
        let name = s.profile.isEmpty ? s.defaultProfile : s.profile
        guard !name.isEmpty, s.available else { return nil }
        guard let p = s.profiles.first(where: { $0.name == name }), !p.isPassword else { return nil }
        return name
    }
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
                         note: s.isProxySession
                             ? "SOCKS не отвечает \(waited) с — супервизор перезапустит прокси целиком."
                             : "Связи нет \(waited) с. openconnect восстанавливает сессию сам — вход не потребуется.",
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
                         note: OcbarClient.shared.lookupNote.isEmpty
                             ? "Искал в /opt/homebrew/bin, /usr/local/bin и рядом с приложением. Путь можно задать переменной OCBAR_BIN."
                             : OcbarClient.shared.lookupNote,
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        }
    }
}
