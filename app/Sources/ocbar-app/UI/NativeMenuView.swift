import SwiftUI
import MacControlCenterUI

// Меню из строки состояния — как модули Wi‑Fi и Bluetooth: заголовок со
// свитчем, профили строками с круглым значком, сети и зоны раскрываются на
// месте, команды внизу. Компоненты — MacControlCenterUI (вендорная копия).
// Состояния, плашки и действия — те же, что у прежнего MenuView.
struct NativeMenuView: View {
    @EnvironmentObject var store: StatusStore
    @ObservedObject private var notify = NotifyState.shared
    @Environment(\.openWindow) private var openWindow
    @State private var networksExpanded = true
    @State private var zonesExpanded = false
    // Подробности соединения — как у Wi‑Fi: меню, открытое с зажатой ⌥.
    @State private var optionHeld = false
    @State private var flagsMonitor: Any?

    /// Ширина системных меню: по ней MenuProbe находит окно меню.
    static let width = MenuWidth.currentPlatform().width

    private var s: Status { store.status }
    private var look: StateLook { StateLook.of(s) }
    private var idle: Bool { store.busy == nil }
    private var canConnect: Bool { idle && OcbarClient.shared.binary != nil }
    private var target: String? { let n = StateLook.targetName(s); return n.isEmpty ? nil : n }

    /// Туннель поднят или поднимается — свитч в заголовке включён.
    private var up: Bool {
        switch s.presentation {
        case .connected, .lost, .paused, .starting: return true
        default: return false
        }
    }

    private var stage: Bool { CommandLine.arguments.contains("--stage") }

    var body: some View {
        MacControlCenterMenu(isPresented: .constant(true), width: .custom(Self.width)) {
            MenuHeader("VPN") { headerTrailing }
            profilesSection
            MenuSection(divider: false) { banners }
            if store.cancelTitle != nil || [.needsLogin, .down, .foreign].contains(s.presentation) {
                MenuSection(divider: false) { extraActions }
            }
            if look.details, s.isProxySession {
                MenuSection(L("Прокси SOCKS")) { proxyDetails }
            }
            if look.details, !s.isProxySession {
                MenuDisclosureSection(sectionTitle(L("Сети в туннеле"), "\(s.routesOn.count)/\(s.routes.count)"),
                                      isExpanded: $networksExpanded) {
                    if s.routes.isEmpty {
                        Text(L("в профиле нет ни одной сети")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(s.routes) { route in routeRow(route) }
                }
                MenuDisclosureSection(sectionTitle(L("DNS-зоны"), "\(s.zones.filter { $0.enabled }.count)/\(s.zones.count)"),
                                      isExpanded: $zonesExpanded) {
                    ForEach(s.zones) { zone in zoneRow(zone) }
                }
            }
            if optionHeld, look.details {
                MenuSection(L("Сведения о соединении")) { connectionDetails }
            }
            Divider()
            commands
        }
        .background(shortcuts)
        .onAppear {
            optionHeld = NSEvent.modifierFlags.contains(.option) || CommandLine.arguments.contains("--option")
            if !stage {
                Notifier.refreshAllowed()
                flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    optionHeld = event.modifierFlags.contains(.option)
                    return event
                }
            }
            store.menuOpen = true
            store.detailsOpen = true
            store.refresh()
        }
        .onDisappear {
            store.menuOpen = false; store.detailsOpen = false
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
        }
    }

    // --- заголовок ---------------------------------------------------------

    // Свитч — главное действие, как «Wi‑Fi вкл/выкл». Пока идёт действие,
    // рядом его название и индикатор: высота меню от этого не меняется.
    private var headerTrailing: some View {
        HStack(spacing: 6) {
            if let busy = store.busy {
                Text(busy).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
            }
            Toggle("", isOn: Binding(get: { up }, set: { on in
                if on {
                    store.connect(profile: target, show: s.presentation == .needsLogin)
                } else {
                    store.disconnect()
                }
            }))
            .toggleStyle(.switch).labelsHidden()
            .disabled(s.presentation == .missing || (!up && !canConnect))
            .accessibilityLabel(L("Подключение VPN"))
        }
    }

    // --- профили -------------------------------------------------------------

    @MacControlCenterMenuBuilder
    private var profilesSection: [any View] {
        if s.profiles.isEmpty || s.presentation == .missing || s.presentation == .foreign {
            MenuSection(divider: false) { stateRow }
        } else {
            MenuSection(divider: false) {
                ForEach(s.profiles) { profile in profileRow(profile) }
                // Пояснение — под списком: у строки профиля высота строки меню,
                // длинный текст в ней наезжал бы на следующий профиль.
                if let note = look.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if s.profiles.isEmpty, s.presentation != .missing {
            MenuCommand(activatesApp: true, dismissesMenu: false, action: { open(WindowID.setup) }) {
                Text(L("Настроить ocbar…"))
            }
        }
    }

    // Строка профиля: круг залит, когда профиль поднят. Нажатие на другой
    // профиль подключает его — как кнопка «Подключить» в настройках.
    private func profileRow(_ profile: ProfileEntry) -> some View {
        let current = profile.name == StateLook.targetName(s)
        let active = current && up
        return MenuToggle(isOn: .constant(active),
                          style: .init(image: Image(systemName: profile.isPassword ? "key.fill" : "lock.fill"),
                                       color: [.lost, .paused].contains(s.presentation) ? look.color
                                              : Color(nsColor: .controlAccentColor))) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(profile.display).lineLimit(1)
                    if current, s.isProxySession {
                        Text("SOCKS").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                if current { subtitle }
            }
        } onClick: { _ in
            guard !current || !up, canConnect else { return }
            store.connect(profile: profile.name)
        }
    }

    // Состояние словами; то, что требует внимания, — цветом состояния.
    private var subtitle: some View {
        let alarm = [.lost, .paused, .needsLogin].contains(s.presentation)
        var parts = [look.subtitle]
        if look.showsTime { parts.append(humanSince(s.since)) }
        if s.presentation == .connected, !s.isProxySession {
            parts.append("↓ " + Size.rate(store.currentDown))
        }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 11, weight: alarm ? .semibold : .regular))
            .foregroundStyle(alarm ? look.color : .secondary)
            .lineLimit(1).truncationMode(.tail)
    }

    // Без профилей, без клиента или с чужим openconnect строки профиля нет —
    // только состояние и пояснение.
    private var stateRow: some View {
        HStack(alignment: .top, spacing: 10) {
            StateDot(color: look.color, pulsing: look.pulsing, size: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(look.title).font(.system(size: 13, weight: .medium))
                Text(look.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                if let note = look.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // --- дополнительные действия ------------------------------------------

    @ViewBuilder
    private var extraActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = store.cancelTitle {
                Button(title) { store.cancelCurrent() }.buttonStyle(.link)
            }
            switch s.presentation {
            case .needsLogin:
                Button(L("Войти")) { store.connect(profile: target, show: true) }
                    .buttonStyle(.borderedProminent).disabled(!idle)
                HStack {
                    Button(L("Войти и запомнить вход…")) { store.connect(profile: target, teach: true) }
                        .disabled(!idle)
                    Spacer()
                    Button(L("Не подключаться")) { store.disconnect() }
                }
                .buttonStyle(.link).font(.system(size: 11))
            case .down, .foreign:
                Button(L("Подключить и запомнить вход…")) { store.connect(profile: target, teach: true) }
                    .buttonStyle(.link).font(.system(size: 11)).disabled(!canConnect)
            default:
                EmptyView()
            }
        }
    }

    // --- плашки --------------------------------------------------------------

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    @ViewBuilder
    private var banners: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let woke = s.wokeAfterConnect, s.state == .connected {
                Banner(color: Palette.warn, symbol: "moon.zzz",
                       text: L("Мак просыпался после подключения (%@) — %@", Self.clock.string(from: woke),
                               s.supervisor ? L("супервизор проверит туннель сам.")
                                            : L("супервизор не работает, проверьте доступ.")))
            }
            if s.isProxySession, !s.systemSocksRefused.isEmpty {
                Banner(color: Palette.warn, symbol: "exclamationmark.triangle",
                       text: L("Системный SOCKS не включён: %@", s.systemSocksRefused), selectable: true)
            }
            if s.access == "fail", s.presentation == .connected {
                Banner(color: Palette.warn, symbol: "exclamationmark.triangle",
                       text: L("Туннель поднят, но проверка доступа не проходит: шлюз может не пускать к этому ресурсу или не хватает сети в профиле."))
            }
            if let warning = store.helperWarning {
                Banner(color: Palette.warn, symbol: "wrench.and.screwdriver", text: warning, selectable: true,
                       fix: MenuView.fix(for: warning))
            }
            if s.available, !s.supervisor {
                Banner(color: Palette.warn, symbol: "exclamationmark.triangle",
                       text: L("Супервизор не запущен — автоподключения не будет."))
            }
            if !notify.allowed {
                Banner(color: Palette.warn, symbol: "bell.slash", text: L("Уведомления выключены"),
                       link: (L("Разрешить"), { Notifier.openSettings() }))
            }
            if let message = store.actionNote ?? (s.presentation == .missing ? nil : store.lastError) {
                let failed = store.actionFailed || store.actionNote == nil
                let fix = MenuView.fix(for: message)
                Banner(color: failed ? Palette.bad : Palette.secondary,
                       symbol: failed ? "xmark.octagon" : "info.circle",
                       text: MenuView.human(message), fix: fix,
                       link: fix == nil && failed ? (L("Журнал"), { open(WindowID.logs) }) : nil,
                       dismiss: store.actionNote != nil ? { store.dismissNote() } : nil)
            }
        }
    }

    // --- сети и зоны -------------------------------------------------------

    private func sectionTitle(_ title: String, _ count: String) -> String {
        s.paused ? "\(title) · \(L("не применяются"))" : "\(title) · \(count)"
    }

    // Галочка — сеть в туннеле. Пока действие не доехало, состояние — по
    // нажатию, а не по последнему опросу: иначе галочка отскакивает назад.
    private func routeRow(_ r: RouteEntry) -> some View {
        let on = store.routeIsOn(r)
        let settled = store.pendingRoutes[r.net] == nil
        return MenuToggle(isOn: .constant(on), style: .checkmark()) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.net).font(.system(size: 12).monospaced())
                if settled, on, let via = r.via, via != s.tundev {
                    Text(L("идёт мимо туннеля → %@", via)).font(.system(size: 10.5)).foregroundStyle(Palette.warn)
                } else if settled, on, r.via == nil, s.state == .connected {
                    Text(L("нет маршрута")).font(.system(size: 10.5)).foregroundStyle(Palette.warn)
                }
            }
        } onClick: { _ in
            store.toggleRoute(r.net, to: !on)
        }
        .disabled(store.busy != nil || s.paused)
        .accessibilityLabel(L("сеть %@ в туннеле", r.net))
    }

    private func zoneRow(_ z: ZoneEntry) -> some View {
        let on = store.zoneIsOn(z)
        return MenuToggle(isOn: .constant(on), style: .checkmark()) {
            HStack(spacing: 6) {
                Text(z.zone).font(.system(size: 12).monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(z.dns).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        } onClick: { _ in
            store.toggleZone(z.zone, to: !on)
        }
        .disabled(store.busy != nil || s.paused)
        .accessibilityLabel(L("зона %@ через %@", z.zone, z.dns))
    }

    // Прокси-режим: вместо сетей и зон — адрес SOCKS, его можно скопировать.
    private var proxyDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.socks.isEmpty ? "—" : s.socks).font(.system(size: 12).monospaced())
                    .foregroundStyle(s.socksUp ? Palette.text : Palette.bad).textSelection(.enabled)
                Spacer()
                CopyButton(text: s.socks)
            }
            if !s.socksUp {
                Text(L("порт не отвечает — супервизор перезапустит прокси"))
                    .font(.system(size: 11)).foregroundStyle(Palette.bad)
            }
            Text(s.systemSocksOn.isEmpty
                 ? (s.systemProxy ? L("Системный SOCKS: не включён") : L("Системный SOCKS: выключен в профиле"))
                 : L("Системный SOCKS: включён на %@", s.systemSocksOn.joined(separator: ", ")))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // Подробности — меню, открытое с ⌥, как у Wi‑Fi.
    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            KVRow(label: L("Адрес в туннеле"), value: s.ip)
            KVRow(label: L("Шлюз"), value: s.gateway)
            if !s.isProxySession { KVRow(mono: false, label: "MTU", value: s.mtu) }
            KVRow(label: L("Резолверы"), value: s.dns.joined(separator: "\n"))
            if !s.isProxySession {
                KVRow(mono: false, label: L("Принято / отдано"),
                      value: "\(Size.bytes(store.totalRx)) / \(Size.bytes(store.totalTx))")
                KVRow(mono: false, label: L("Задержка"), value: store.latency ?? "—")
                KVRow(mono: false, label: L("Доступ"),
                      value: s.access == "ok"
                          ? (s.accessAt.map { L("проверен в %@", Self.clock.string(from: $0)) } ?? L("проверен"))
                          : s.access == "fail" ? L("не отвечает") : L("не проверялся"),
                      color: s.access == "fail" ? Palette.bad : s.access == "ok" ? Palette.ok : Palette.text)
            }
        }
        .padding(.horizontal, -12)
    }

    // --- команды -------------------------------------------------------------

    @MacControlCenterMenuBuilder
    private var commands: [any View] {
        if [.connected, .lost].contains(s.presentation), !s.isProxySession {
            command(L("Приостановить"), shortcut: pauseHint, enabled: idle) { store.pause() }
        }
        if s.presentation == .paused {
            command(L("Возобновить"), shortcut: pauseHint, enabled: idle) { store.resume() }
        }
        command(L("Настройки…"), shortcut: "⌘,") { open(WindowID.settings) }
        command(L("Диагностика и журналы…")) { open(WindowID.diagnostics) }
        if UserDefaults.standard.bool(forKey: "DeveloperMode"), !stage {
            command(L("Выйти совсем (сброс входа)"), shortcut: "dev", enabled: canConnect) { store.logout() }
        }
        command(up ? L("Выйти из ocbar · туннель останется") : L("Выйти из ocbar"), shortcut: "⌘Q") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var pauseHint: String? { GlobalHotkeys.shared.isRegistered("pause") ? "⌥⌘P" : nil }

    // Окна сами уводят фокус, и меню закрывается, как системное; действия
    // туннеля оставляют меню открытым — видно, чем кончилось.
    private func command(_ title: String, shortcut: String? = nil, enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        MenuCommand(activatesApp: false, dismissesMenu: false, action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
        }
        .disabled(!enabled)
    }

    // Клавиши работают, пока меню открыто: глобального перехвата нет.
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
            Button("") { open(WindowID.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
