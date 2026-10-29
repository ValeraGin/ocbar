import AppKit
import Combine
import SwiftUI

// Меню в строке состояния — обычное NSMenu, но описанное на SwiftUI:
// NSHostingMenu (macOS 14.4+) сам переводит описание в пункты меню и
// обновляет их на месте, в том числе пока меню открыто. Своего сравнения
// пунктов и пересборки меню нет — от неё мигали подменю и сдвигались пункты.
// Размер, место, клавиатура, Esc и закрытие — у системы.
/// То, что видно в меню, одной сравнимой сводкой. NSHostingMenu при каждой
/// перерисовке трогает пункты (NSMenu.didChangeItem), даже если ничего не
/// изменилось, — и каждое касание закрывает открытое подменю. Поэтому меню
/// следит не за всем StatusStore (трафик там меняется каждые 2 с), а за
/// сводкой, которая публикуется, только когда видимое изменилось.
struct MenuSnapshot: Equatable {
    var status = Status()
    var busy: String?
    var cancelTitle: String?
    var helperWarning: String?
    var actionNote: String?
    var actionFailed = false
    var lastError: String?
    var pendingRoutes: [String: Bool] = [:]
    var pendingZones: [String: Bool] = [:]
    var notifyAllowed = true
    var optionAtOpen = false
    /// Скорость, трафик, задержка — только в сведениях по ⌥.
    var details: [String] = []
}

@MainActor
final class MenuModel: ObservableObject {
    @Published private(set) var snap = MenuSnapshot()
    private let store: StatusStore
    private var watch: [AnyCancellable] = []
    private var queued = false

    init(store: StatusStore) {
        self.store = store
        snap = Self.snapshot(store)
        // objectWillChange приходит до смены значения: сводку берём следующим
        // проходом цикла, когда новое значение уже на месте.
        watch.append(store.objectWillChange.sink { [weak self] _ in self?.queue() })
        watch.append(NotifyState.shared.objectWillChange.sink { [weak self] _ in self?.queue() })
    }

    private func queue() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false
            let next = Self.snapshot(self.store)
            if next != self.snap { self.snap = next }
        }
    }

    static func snapshot(_ store: StatusStore) -> MenuSnapshot {
        var m = MenuSnapshot()
        m.status = store.status
        // The supervisor advances this timestamp even when no visible text changes.
        // Publishing it rebuilds native menu items and interrupts open submenus.
        if !store.optionAtOpen { m.status.accessAt = nil }
        m.busy = store.busy
        m.cancelTitle = store.cancelTitle
        m.helperWarning = store.helperWarning
        m.actionNote = store.actionNote
        m.actionFailed = store.actionFailed
        m.lastError = store.lastError
        m.pendingRoutes = store.pendingRoutes
        m.pendingZones = store.pendingZones
        m.notifyAllowed = NotifyState.shared.allowed
        m.optionAtOpen = store.optionAtOpen
        if store.optionAtOpen {
            m.details = [Size.rate(store.currentDown), Size.bytes(store.totalRx), Size.bytes(store.totalTx),
                         store.latency ?? "—"]
        }
        return m
    }
}

@MainActor
final class HostedMenu: NSObject {
    let statusItem: NSStatusItem
    let menu: NSMenu
    private let store: StatusStore
    private var watch: [AnyCancellable] = []

    init(store: StatusStore, prepare: Bool = true) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSHostingMenu(rootView: MenuContent(store: store, model: MenuModel(store: store)))
        super.init()
        statusItem.menu = menu
        statusItem.button?.setAccessibilityTitle("OpenConnect for Mac")
        // Делегата у NSHostingMenu до macOS 15 нет: открытие и закрытие меню
        // узнаём по уведомлениям самого NSMenu.
        let center = NotificationCenter.default
        watch.append(center.publisher(for: NSMenu.didBeginTrackingNotification, object: menu)
            .sink { [weak self] _ in self?.opened() })
        watch.append(center.publisher(for: NSMenu.didEndTrackingNotification, object: menu)
            .sink { [weak self] _ in self?.closed() })
        // Resolve SwiftUI items and native layout at startup, before the first click.
        // The probe can disable preparation to compare both paths in one build.
        if prepare {
            menu.update()
            _ = menu.size
        }
    }

    var image: NSImage? {
        get { statusItem.button?.image }
        set { statusItem.button?.image = newValue }
    }

    private(set) var isOpen = false

    private func opened() {
        isOpen = true
        // Сведения о соединении — как у Wi‑Fi: меню, открытое с зажатой ⌥.
        // В демо-меню их задаёт кадр, а не клавиша.
        if !CommandLine.arguments.contains("--demo-menu") {
            store.optionAtOpen = NSEvent.modifierFlags.contains(.option)
        }
        // Notification permission is maintained by Notifier's timer. Opening the
        // menu must not synchronously check its token file or contact that service.
        store.menuOpen = true
        store.detailsOpen = store.optionAtOpen
        store.refresh()
    }

    private func closed() {
        isOpen = false
        store.menuOpen = false
        store.detailsOpen = false
    }
}

/// Содержимое меню. Состояния, плашки и действия — те же, что у панели
/// (NativeMenuView); свитча и полоски нет — в NSMenu из SwiftUI своих видов
/// не бывает: вместо свитча пункт «Подключить»/«Отключить», ход подключения —
/// подписью под профилем и на значке.
struct MenuContent: View {
    /// Действия и значения — из хранилища; перерисовка — только по сводке.
    let store: StatusStore
    @ObservedObject var model: MenuModel
    private var notify: NotifyState { NotifyState.shared }

    private var s: Status { model.snap.status }
    private var look: StateLook { StateLook.of(s) }
    private var idle: Bool { store.busy == nil }
    private var canConnect: Bool { idle && OCMacClient.shared.binary != nil }
    private var target: String? { let n = StateLook.targetName(s); return n.isEmpty ? nil : n }
    private var up: Bool { [.connected, .lost, .paused, .starting].contains(s.presentation) }

    var body: some View {
        mainAction
        Divider()
        profiles
        banners
        signInActions
        if look.details, s.isProxySession { proxySection }
        if look.details, !s.isProxySession { networksAndZones }
        if model.snap.optionAtOpen, look.details { detailsSection }
        Divider()
        commands
    }

    // Главное действие — вместо свитча Wi‑Fi. Пока идёт действие, оно само —
    // неактивной строкой, а рядом отмена.
    @ViewBuilder private var mainAction: some View {
        if let busy = store.busy {
            Button {} label: {
                Text(busy)
                if let step = ConnectStep.of(s) { Text("\(step.title) · \(step.index)/\(ConnectStep.total)") }
            }
            .disabled(true)
            if let cancel = store.cancelTitle {
                Button(cancel) { store.cancelCurrent() }
            }
        } else if up {
            Button(L("Отключить VPN")) { store.disconnect() }
        } else if s.presentation != .missing {
            Button {
                store.connect(profile: target, show: s.presentation == .needsLogin)
            } label: {
                Text(L("Подключить VPN"))
                Text(StateLook.profileName(s))
            }
            .disabled(!canConnect)
        }
    }

    @ViewBuilder private var profiles: some View {
        if s.profiles.isEmpty || s.presentation == .missing || s.presentation == .foreign {
            Button {} label: {
                Text(look.title)
                Text(look.subtitle)
            }
            .disabled(true)
            if s.profiles.isEmpty, s.presentation != .missing {
                Button(L("Настроить OpenConnect for Mac…")) { WindowBridge.open(WindowID.setup) }
            }
        } else {
            Section(L("Профили")) {
                ForEach(s.profiles) { profile in profileRow(profile) }
            }
        }
    }

    // Профиль: замок или ключ; у поднятого — закрашенный значок и состояние
    // второй строкой. Нажатие на другой профиль подключает его.
    private func profileRow(_ p: ProfileEntry) -> some View {
        let current = p.name == StateLook.targetName(s)
        let active = current && up
        let symbol = p.isPassword ? (active ? "key.fill" : "key") : (active ? "lock.fill" : "lock")
        return Button {
            guard !current || !up, canConnect else { return }
            store.connect(profile: p.name)
        } label: {
            Image(systemName: symbol)
            Text(p.display + (current && s.isProxySession ? "  SOCKS" : ""))
            if current { Text(profileSubtitle) }
        }
        .disabled(!canConnect && !(current && up))
    }

    private var profileSubtitle: String {
        if let step = ConnectStep.of(s) { return "\(step.title) · \(step.index)/\(ConnectStep.total)" }
        // Скорости здесь нет: она меняется каждые 2 с, строка меняет ширину,
        // меню перекладывается и закрывает открытое подменю. Скорость — в
        // сведениях по ⌥; время меняется раз в минуту.
        var parts = [look.subtitle]
        if look.showsTime { parts.append(humanSince(s.since)) }
        return parts.joined(separator: " · ")
    }

    // Плашки — строкой со значком; длинное пояснение — второй строкой.
    @ViewBuilder private var banners: some View {
        if let woke = s.wokeAfterConnect, s.state == .connected {
            banner("moon.zzz", L("Мак просыпался после подключения (%@)", Self.clock.string(from: woke)),
                   s.supervisor ? L("супервизор проверит туннель сам.") : L("супервизор не работает, проверьте доступ."))
        }
        if s.isProxySession, !s.systemSocksRefused.isEmpty {
            banner("exclamationmark.triangle", L("Системный SOCKS не включён"), s.systemSocksRefused)
        }
        if s.access == "fail", s.presentation == .connected {
            banner("exclamationmark.triangle", L("Проверка доступа не проходит"),
                   L("шлюз не пускает к ресурсу или не хватает сети в профиле"))
        }
        if let warning = store.helperWarning {
            fixable("wrench.and.screwdriver", warning)
        }
        if s.available, !s.supervisor {
            banner("exclamationmark.triangle", L("Супервизор не запущен"), L("автоподключения не будет"))
        }
        if !notify.allowed {
            Button { Notifier.openSettings() } label: {
                Image(systemName: "bell.slash")
                Text(L("Уведомления выключены"))
                Text(L("Разрешить…"))
            }
        }
        if let message = store.actionNote ?? (s.presentation == .missing ? nil : store.lastError) {
            let failed = store.actionFailed || store.actionNote == nil
            fixable(failed ? "xmark.octagon" : "info.circle", message, journal: failed)
            if store.actionNote != nil {
                Button(L("Скрыть")) { store.dismissNote() }
            }
        }
    }

    private func banner(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Button {} label: {
            Image(systemName: symbol)
            Text(title)
            Text(detail)
        }
        .disabled(true)
    }

    // Ошибка с готовым исправлением: нажатие копирует команду; без него —
    // открывает журнал.
    @ViewBuilder private func fixable(_ symbol: String, _ message: String, journal: Bool = false) -> some View {
        if let fix = MenuText.fix(for: message) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fix.command, forType: .string)
            } label: {
                Image(systemName: symbol)
                Text(MenuText.human(message))
                Text(fix.title + ": " + fix.command)
            }
        } else if journal {
            Button { WindowBridge.open(WindowID.logs) } label: {
                Image(systemName: symbol)
                Text(MenuText.human(message))
                Text(L("Журнал…"))
            }
        } else {
            banner(symbol, MenuText.human(message), "")
        }
    }

    // Как строки «Другие сети…» у Wi‑Fi: действия — обычные строки меню.
    @ViewBuilder private var signInActions: some View {
        if s.presentation == .needsLogin {
            Divider()
            Button(L("Войти…")) { store.connect(profile: target, show: true) }.disabled(!idle)
            Button(L("Войти и запомнить вход…")) { store.connect(profile: target, teach: true) }.disabled(!idle)
            Button(L("Не подключаться")) { store.disconnect() }
        } else if [.down, .foreign].contains(s.presentation) {
            Divider()
            Button(L("Подключить и запомнить вход…")) { store.connect(profile: target, teach: true) }
                .disabled(!canConnect)
        }
    }

    @ViewBuilder private var proxySection: some View {
        Section(L("Прокси SOCKS")) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.socks, forType: .string)
            } label: {
                Text(s.socks.isEmpty ? "—" : s.socks)
                Text(!s.socksUp ? L("порт не отвечает — супервизор перезапустит прокси")
                     : s.systemSocksOn.isEmpty
                        ? (s.systemProxy ? L("Системный SOCKS: не включён") : L("Системный SOCKS: выключен в профиле"))
                        : L("Системный SOCKS: включён на %@", s.systemSocksOn.joined(separator: ", ")))
            }
        }
    }

    private func sectionTitle(_ title: String, _ count: String) -> String {
        s.paused ? "\(title) · \(L("не применяются"))" : "\(title) · \(count)"
    }

    // Сети и зоны — подменю с галочками. Пока действие не доехало, галочка —
    // по нажатию, а не по последнему опросу.
    @ViewBuilder private var networksAndZones: some View {
        let locked = store.busy != nil || s.paused
        Divider()
        Menu(sectionTitle(L("Сети в туннеле"), "\(s.routesOn.count)/\(s.routes.count)")) {
            if s.routes.isEmpty {
                Text(L("в профиле нет ни одной сети"))
            }
            ForEach(s.routes) { r in
                let on = model.snap.pendingRoutes[r.net] ?? r.enabled
                Toggle(isOn: Binding(get: { on }, set: { store.toggleRoute(r.net, to: $0) })) {
                    Text(r.net)
                    if let warning = routeWarning(r, on: on) { Text(warning) }
                }
                .disabled(locked)
            }
        }
        if !s.zones.isEmpty {
            Menu(sectionTitle(L("DNS-зоны"), "\(s.zones.filter { $0.enabled }.count)/\(s.zones.count)")) {
                ForEach(s.zones) { z in
                    let on = model.snap.pendingZones[z.zone] ?? z.enabled
                    Toggle(isOn: Binding(get: { on }, set: { store.toggleZone(z.zone, to: $0) })) {
                        Text(z.zone)
                        Text(z.dns)
                    }
                    .disabled(locked)
                }
            }
        }
    }

    private func routeWarning(_ r: RouteEntry, on: Bool) -> String? {
        guard model.snap.pendingRoutes[r.net] == nil, on else { return nil }
        if let via = r.via, via != s.tundev { return L("идёт мимо туннеля → %@", via) }
        if r.via == nil, s.state == .connected { return L("нет маршрута") }
        return nil
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    @ViewBuilder private var detailsSection: some View {
        Section(L("Сведения о соединении")) {
            detail(L("Адрес в туннеле"), s.ip)
            detail(L("Шлюз"), s.gateway)
            if !s.isProxySession { detail("MTU", s.mtu) }
            detail(L("Резолверы"), s.dns.joined(separator: ", "))
            if !s.isProxySession {
                detail(L("Скорость"), "↓ " + Size.rate(store.currentDown))
                detail(L("Принято / отдано"), "\(Size.bytes(store.totalRx)) / \(Size.bytes(store.totalTx))")
                detail(L("Задержка"), store.latency ?? "—")
                detail(L("Доступ"), s.access == "ok"
                       ? (s.accessAt.map { L("проверен в %@", Self.clock.string(from: $0)) } ?? L("проверен"))
                       : s.access == "fail" ? L("не отвечает") : L("не проверялся"))
            }
        }
    }

    private func detail(_ key: String, _ value: String) -> some View {
        Button {} label: {
            Text(key)
            Text(value.isEmpty ? "—" : value)
        }
        .disabled(true)
    }

    @ViewBuilder private var commands: some View {
        if [.connected, .lost].contains(s.presentation), !s.isProxySession {
            Button(L("Приостановить")) { store.pause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!idle)
        }
        if s.presentation == .paused {
            Button {
                store.resume()
            } label: {
                Text(L("Возобновить"))
                Text(L("сети и DNS сняты, сессия жива"))
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!idle)
        }
        Button(L("Открыть OpenConnect for Mac")) { WindowBridge.open(WindowID.connection) }
            .keyboardShortcut("o")
        Button(L("Настройки…")) { WindowBridge.open(WindowID.settings) }
            .keyboardShortcut(",")
        Button(L("Диагностика и журналы…")) { WindowBridge.open(WindowID.diagnostics) }
        // Режим разработчика — не для кадров README: в демо-меню его нет.
        if UserDefaults.standard.bool(forKey: "DeveloperMode"), !CommandLine.arguments.contains("--stage") {
            Button(L("Сбросить вход")) { store.logout() }.disabled(!canConnect)
        }
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Text(L("Выйти из OpenConnect for Mac"))
            if up { Text(L("туннель останется")) }
        }
        .keyboardShortcut("q")
    }
}
