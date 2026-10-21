import AppKit
import Combine
import SwiftUI

// Меню в строке состояния на обычном NSMenu — как у WireGuard, Tunnelblick и
// sing-box. Размер, место под значком, клавиатура, Esc и закрытие по клику
// мимо — у системы. Состояния, плашки и действия — те же, что у
// NativeMenuView (панель); выбор между ними — ключ MenuStyle.
@MainActor
final class ClassicMenu: NSObject, NSMenuDelegate {
    let statusItem: NSStatusItem
    let menu = NSMenu()
    private let store: StatusStore
    private var watch: [AnyCancellable] = []
    private(set) var isOpen = false
    private var optionAtOpen = false
    private var rebuildQueued = false

    /// Свои виды (шапка, полоска, пояснения) не задают ширину меню: она — по
    /// самому длинному обычному пункту, а виды подстраиваются под неё.
    private static let floorWidth: CGFloat = 200
    private var relayouts: [(CGFloat) -> Void] = []

    init(store: StatusStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        // Колонки галочек в главном меню нет: поднятый профиль отмечен цветом
        // значка, а не галочкой, и текст встаёт ближе к краю. В подменю сетей
        // и зон галочки остаются — там это переключатели.
        menu.showsStateColumn = false
        statusItem.menu = menu
        statusItem.button?.setAccessibilityTitle("ocbar")
        // objectWillChange приходит до смены значения: пересобираем следующим
        // проходом цикла, когда новое состояние уже на месте. Открытое меню
        // обновляется на ходу — система перерисует его сама.
        watch.append(store.objectWillChange.sink { [weak self] _ in self?.queueRebuild() })
        watch.append(NotifyState.shared.objectWillChange.sink { [weak self] _ in self?.queueRebuild() })
        build()
    }

    var image: NSImage? {
        get { statusItem.button?.image }
        set { statusItem.button?.image = newValue }
    }

    // MARK: - открытие и закрытие

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        // Сведения о соединении — как у Wi‑Fi: меню, открытое с зажатой ⌥.
        optionAtOpen = NSEvent.modifierFlags.contains(.option)
        Notifier.refreshAllowed()
        store.menuOpen = true
        store.detailsOpen = true
        store.refresh()
        build()
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        store.menuOpen = false
        store.detailsOpen = false
    }

    private func queueRebuild() {
        guard !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildQueued = false
            self.build()
        }
    }

    // MARK: - сборка

    private var s: Status { store.status }
    private var look: StateLook { StateLook.of(s) }
    private var idle: Bool { store.busy == nil }
    private var canConnect: Bool { idle && OcbarClient.shared.binary != nil }
    private var target: String? { let n = StateLook.targetName(s); return n.isEmpty ? nil : n }
    private var up: Bool { [.connected, .lost, .paused, .starting].contains(s.presentation) }

    func build() {
        menu.removeAllItems()
        relayouts = []
        menu.addItem(header())
        menu.addItem(.separator())
        profiles()
        banners()
        extraActions()
        if look.details, s.isProxySession { proxySection() }
        if look.details, !s.isProxySession { networksAndZones() }
        if optionAtOpen, look.details { details() }
        menu.addItem(.separator())
        commands()
        // Ширина — по обычным пунктам; свои виды растягиваем до неё. Меряем
        // копию: замер самого меню меняет его раскладку — пункты без значка
        // переставали выравниваться по тексту пунктов со значком.
        let width = max((menu.copy() as? NSMenu)?.size.width ?? 0, Self.floorWidth)
        relayouts.forEach { $0(width) }
    }

    // Шапка — свой вид: свитч в нём меню не закрывает, как у Wi‑Fi.
    private func header() -> NSMenuItem {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Self.floorWidth, height: 30))
        let label = NSTextField(labelWithString: "VPN")
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.frame = NSRect(x: 14, y: 6, width: 60, height: 18)
        v.addSubview(label)
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = up ? .on : .off
        sw.isEnabled = !(s.presentation == .missing || (!up && !canConnect))
        sw.target = self
        sw.action = #selector(switchChanged(_:))
        sw.setAccessibilityLabel(L("Подключение VPN"))
        v.addSubview(sw)
        var spin: NSProgressIndicator?
        var text: NSTextField?
        if let busy = store.busy {
            let p = NSProgressIndicator()
            p.style = .spinning
            p.controlSize = .small
            p.startAnimation(nil)
            v.addSubview(p)
            spin = p
            let t = NSTextField(labelWithString: busy)
            t.font = .systemFont(ofSize: 11)
            t.textColor = .secondaryLabelColor
            t.alignment = .right
            t.lineBreakMode = .byTruncatingTail
            v.addSubview(t)
            text = t
        }
        relayouts.append { w in
            v.frame.size.width = w
            sw.frame = NSRect(x: w - 14 - 38, y: 5, width: 38, height: 20)
            spin?.frame = NSRect(x: w - 14 - 38 - 20, y: 8, width: 14, height: 14)
            text?.frame = NSRect(x: 64, y: 7, width: max(0, w - 64 - 14 - 38 - 26), height: 16)
        }
        let item = NSMenuItem()
        item.view = v
        return item
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        if sender.state == .on {
            store.connect(profile: target, show: s.presentation == .needsLogin)
        } else {
            store.disconnect()
        }
    }

    private func profiles() {
        if s.profiles.isEmpty || s.presentation == .missing || s.presentation == .foreign {
            menu.addItem(textItem(look.title, detail: [look.subtitle, look.note].compactMap { $0 }.joined(separator: "\n"),
                                  symbol: "circle.fill", tint: NSColor(look.color)))
        } else {
            for p in s.profiles { menu.addItem(profileItem(p)) }
            if let step = ConnectStep.of(s) { menu.addItem(progressItem(step)) }
            if let note = look.note { menu.addItem(textItem(nil, detail: note)) }
        }
        if s.profiles.isEmpty, s.presentation != .missing {
            menu.addItem(action(L("Настроить ocbar…")) { WindowBridge.open(WindowID.setup) })
        }
    }

    // Профиль: значок замка или ключа, галочка — поднят. Под текущим — состояние
    // или шаг подключения; то, что требует внимания, — цветом состояния.
    private func profileItem(_ p: ProfileEntry) -> NSMenuItem {
        let current = p.name == StateLook.targetName(s)
        let active = current && up
        let item = action(p.display, symbol: p.isPassword ? "key.fill" : "lock.fill") { [weak self] in
            guard let self, !current || !self.up, self.canConnect else { return }
            self.store.connect(profile: p.name)
        }
        // Поднятый профиль — значок цветом акцента, как круг у Wi‑Fi.
        if active, let symbol = NSImage(systemSymbolName: p.isPassword ? "key.fill" : "lock.fill",
                                        accessibilityDescription: L("подключён")) {
            let color: NSColor = [.lost, .paused].contains(s.presentation) ? NSColor(look.color) : .controlAccentColor
            item.image = symbol.withSymbolConfiguration(.init(paletteColors: [color]))
        }
        if current {
            let step = ConnectStep.of(s)
            let alarm = [.lost, .paused, .needsLogin].contains(s.presentation) || step?.waitsForHuman == true
            var parts = [step.map { "\($0.title) · \($0.index)/\(ConnectStep.total)" } ?? look.subtitle]
            if look.showsTime { parts.append(humanSince(s.since)) }
            if s.presentation == .connected, !s.isProxySession { parts.append("↓ " + Size.rate(store.currentDown)) }
            item.attributedTitle = twoLines(p.display + (s.isProxySession ? "  SOCKS" : ""), parts.joined(separator: " · "),
                                            color: alarm ? NSColor(look.color) : .secondaryLabelColor)
        }
        return item
    }

    private func progressItem(_ step: ConnectStep) -> NSMenuItem {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Self.floorWidth, height: 12))
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = Double(ConnectStep.total)
        bar.doubleValue = Double(step.index)
        bar.setAccessibilityLabel(L("Подключение: шаг %@ из %@", "\(step.index)", "\(ConnectStep.total)"))
        v.addSubview(bar)
        relayouts.append { w in
            v.frame.size.width = w
            bar.frame = NSRect(x: 14, y: 3, width: w - 28, height: 6)
        }
        let item = NSMenuItem()
        item.view = v
        return item
    }

    private func banners() {
        if let woke = s.wokeAfterConnect, s.state == .connected {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            menu.addItem(textItem(nil, detail: L("Мак просыпался после подключения (%@) — %@", f.string(from: woke),
                                                s.supervisor ? L("супервизор проверит туннель сам.")
                                                             : L("супервизор не работает, проверьте доступ.")),
                                  symbol: "moon.zzz", tint: .systemOrange))
        }
        if s.isProxySession, !s.systemSocksRefused.isEmpty {
            menu.addItem(textItem(nil, detail: L("Системный SOCKS не включён: %@", s.systemSocksRefused),
                                  symbol: "exclamationmark.triangle", tint: .systemOrange))
        }
        if s.access == "fail", s.presentation == .connected {
            menu.addItem(textItem(nil, detail: L("Туннель поднят, но проверка доступа не проходит: шлюз может не пускать к этому ресурсу или не хватает сети в профиле."),
                                  symbol: "exclamationmark.triangle", tint: .systemOrange))
        }
        if let warning = store.helperWarning {
            menu.addItem(textItem(nil, detail: warning, symbol: "wrench.and.screwdriver", tint: .systemOrange))
            if let fix = MenuView.fix(for: warning) { menu.addItem(copyItem(fix)) }
        }
        if s.available, !s.supervisor {
            menu.addItem(textItem(nil, detail: L("Супервизор не запущен — автоподключения не будет."),
                                  symbol: "exclamationmark.triangle", tint: .systemOrange))
        }
        if !NotifyState.shared.allowed {
            menu.addItem(textItem(nil, detail: L("Уведомления выключены"), symbol: "bell.slash", tint: .systemOrange))
            let allow = action(L("Разрешить")) { Notifier.openSettings() }
            allow.indentationLevel = 1
            menu.addItem(allow)
        }
        if let message = store.actionNote ?? (s.presentation == .missing ? nil : store.lastError) {
            let failed = store.actionFailed || store.actionNote == nil
            menu.addItem(textItem(nil, detail: MenuView.human(message),
                                  symbol: failed ? "xmark.octagon" : "info.circle",
                                  tint: failed ? .systemRed : .secondaryLabelColor))
            if let fix = MenuView.fix(for: message) {
                menu.addItem(copyItem(fix))
            } else if failed {
                let logs = action(L("Журнал")) { WindowBridge.open(WindowID.logs) }
                logs.indentationLevel = 1
                menu.addItem(logs)
            }
            if store.actionNote != nil {
                let hide = action(L("Скрыть")) { [weak self] in self?.store.dismissNote() }
                hide.indentationLevel = 1
                menu.addItem(hide)
            }
        }
    }

    private func copyItem(_ fix: (title: String, command: String)) -> NSMenuItem {
        let item = action(fix.title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fix.command, forType: .string)
        }
        item.toolTip = L("Скопировать: ") + fix.command
        item.indentationLevel = 1
        return item
    }

    // Как строки «Другие сети…» у Wi‑Fi: действия — обычные строки меню.
    private func extraActions() {
        let wanted = store.cancelTitle != nil || [.needsLogin, .down, .foreign].contains(s.presentation)
        guard wanted else { return }
        menu.addItem(.separator())
        if let title = store.cancelTitle {
            menu.addItem(action(title) { [weak self] in self?.store.cancelCurrent() })
        }
        if s.presentation == .needsLogin {
            menu.addItem(action(L("Войти…"), enabled: idle) { [weak self] in
                guard let self else { return }
                self.store.connect(profile: self.target, show: true)
            })
            menu.addItem(action(L("Войти и запомнить вход…"), enabled: idle) { [weak self] in
                guard let self else { return }
                self.store.connect(profile: self.target, teach: true)
            })
            menu.addItem(action(L("Не подключаться")) { [weak self] in self?.store.disconnect() })
        } else if [.down, .foreign].contains(s.presentation) {
            menu.addItem(action(L("Подключить и запомнить вход…"), enabled: canConnect) { [weak self] in
                guard let self else { return }
                self.store.connect(profile: self.target, teach: true)
            })
        }
    }

    private func proxySection() {
        menu.addItem(.separator())
        menu.addItem(sectionHeader(L("Прокси SOCKS")))
        let socks = action(s.socks.isEmpty ? "—" : s.socks) { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.s.socks, forType: .string)
        }
        socks.toolTip = L("Скопировать: ") + s.socks
        let state = s.systemSocksOn.isEmpty
            ? (s.systemProxy ? L("Системный SOCKS: не включён") : L("Системный SOCKS: выключен в профиле"))
            : L("Системный SOCKS: включён на %@", s.systemSocksOn.joined(separator: ", "))
        socks.attributedTitle = twoLines(s.socks.isEmpty ? "—" : s.socks,
                                         s.socksUp ? state : L("порт не отвечает — супервизор перезапустит прокси"),
                                         color: s.socksUp ? .secondaryLabelColor : .systemRed, monospaced: true)
        menu.addItem(socks)
    }

    private func sectionTitle(_ title: String, _ count: String) -> String {
        s.paused ? "\(title) · \(L("не применяются"))" : "\(title) · \(count)"
    }

    // Сети и зоны — подменю с галочками, как список сетей у Wi‑Fi в прежних
    // macOS. Пока действие не доехало, галочка — по нажатию, а не по опросу.
    private func networksAndZones() {
        menu.addItem(.separator())
        let locked = store.busy != nil || s.paused
        let nets = NSMenuItem(title: sectionTitle(L("Сети в туннеле"), "\(s.routesOn.count)/\(s.routes.count)"),
                              action: nil, keyEquivalent: "")
        let netsMenu = NSMenu()
        netsMenu.autoenablesItems = false
        if s.routes.isEmpty {
            netsMenu.addItem(textItem(nil, detail: L("в профиле нет ни одной сети")))
        }
        for r in s.routes {
            let on = store.routeIsOn(r)
            let settled = store.pendingRoutes[r.net] == nil
            let item = action(r.net, enabled: !locked) { [weak self] in self?.store.toggleRoute(r.net, to: !on) }
            item.state = on ? .on : .off
            var warning: String?
            if settled, on, let via = r.via, via != s.tundev { warning = L("идёт мимо туннеля → %@", via) }
            else if settled, on, r.via == nil, s.state == .connected { warning = L("нет маршрута") }
            item.attributedTitle = warning.map { twoLines(r.net, $0, color: .systemOrange, monospaced: true) }
                ?? mono(r.net)
            item.setAccessibilityLabel(L("сеть %@ в туннеле", r.net))
            netsMenu.addItem(item)
        }
        nets.submenu = netsMenu
        menu.addItem(nets)

        let zones = NSMenuItem(title: sectionTitle(L("DNS-зоны"), "\(s.zones.filter { $0.enabled }.count)/\(s.zones.count)"),
                               action: nil, keyEquivalent: "")
        let zonesMenu = NSMenu()
        zonesMenu.autoenablesItems = false
        for z in s.zones {
            let on = store.zoneIsOn(z)
            let item = action(z.zone, enabled: !locked) { [weak self] in self?.store.toggleZone(z.zone, to: !on) }
            item.state = on ? .on : .off
            item.attributedTitle = twoLines(z.zone, z.dns, color: .secondaryLabelColor, monospaced: true)
            item.setAccessibilityLabel(L("зона %@ через %@", z.zone, z.dns))
            zonesMenu.addItem(item)
        }
        zones.submenu = zonesMenu
        if !s.zones.isEmpty { menu.addItem(zones) }
    }

    private func details() {
        menu.addItem(.separator())
        menu.addItem(sectionHeader(L("Сведения о соединении")))
        var rows: [(String, String)] = [(L("Адрес в туннеле"), s.ip), (L("Шлюз"), s.gateway)]
        if !s.isProxySession { rows.append(("MTU", s.mtu)) }
        rows.append((L("Резолверы"), s.dns.joined(separator: ", ")))
        if !s.isProxySession {
            rows.append((L("Принято / отдано"), "\(Size.bytes(store.totalRx)) / \(Size.bytes(store.totalTx))"))
            rows.append((L("Задержка"), store.latency ?? "—"))
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            rows.append((L("Доступ"), s.access == "ok"
                ? (s.accessAt.map { L("проверен в %@", f.string(from: $0)) } ?? L("проверен"))
                : s.access == "fail" ? L("не отвечает") : L("не проверялся")))
        }
        for (k, v) in rows {
            let item = NSMenuItem(title: k, action: nil, keyEquivalent: "")
            item.attributedTitle = twoLines(k, v.isEmpty ? "—" : v, color: .labelColor, monospaced: true, dimTitle: true)
            item.isEnabled = true
            menu.addItem(item)
        }
    }

    private func commands() {
        let pauseHint = GlobalHotkeys.shared.isRegistered("pause")
        if [.connected, .lost].contains(s.presentation), !s.isProxySession {
            let pause = action(L("Приостановить"), key: pauseHint ? "p" : "", mods: [.command, .option], enabled: idle) {
                [weak self] in self?.store.pause()
            }
            menu.addItem(pause)
        }
        if s.presentation == .paused {
            menu.addItem(action(L("Возобновить"), key: pauseHint ? "p" : "", mods: [.command, .option], enabled: idle) {
                [weak self] in self?.store.resume()
            })
        }
        menu.addItem(action(L("Настройки…"), key: ",") { WindowBridge.open(WindowID.settings) })
        menu.addItem(action(L("Диагностика и журналы…")) { WindowBridge.open(WindowID.diagnostics) })
        if UserDefaults.standard.bool(forKey: "DeveloperMode") {
            // Только для проверок: прячется под ⌥ вместо «Выйти из ocbar».
            let logout = action(L("Выйти совсем (сброс входа)"), key: "q", mods: [.command, .option], enabled: canConnect) {
                [weak self] in self?.store.logout()
            }
            logout.isAlternate = true
            menu.addItem(action(up ? L("Выйти из ocbar · туннель останется") : L("Выйти из ocbar"), key: "q") {
                NSApplication.shared.terminate(nil)
            })
            menu.addItem(logout)
        } else {
            menu.addItem(action(up ? L("Выйти из ocbar · туннель останется") : L("Выйти из ocbar"), key: "q") {
                NSApplication.shared.terminate(nil)
            })
        }
    }

    // MARK: - пункты

    private final class BlockItem: NSMenuItem {
        var handler: (() -> Void)?
    }

    @objc private func fire(_ sender: NSMenuItem) {
        (sender as? BlockItem)?.handler?()
    }

    private func action(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = .command,
                        symbol: String? = nil, enabled: Bool = true,
                        _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = BlockItem(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = self
        item.handler = handler
        item.isEnabled = enabled
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func mono(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
    }

    // Две строки в одном пункте: заголовок и подпись поменьше. Цвет подписи
    // свой — у NSMenuItem.subtitle его нет, и он есть только с macOS 14.4.
    private func twoLines(_ title: String, _ detail: String, color: NSColor,
                          monospaced: Bool = false, dimTitle: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString(string: title, attributes: [
            .font: monospaced && !dimTitle ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.menuFont(ofSize: 13),
            .foregroundColor: dimTitle ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        out.append(NSAttributedString(string: "\n" + detail, attributes: [
            .font: monospaced && dimTitle ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) : NSFont.systemFont(ofSize: 11),
            .foregroundColor: color,
        ]))
        return out
    }

    // Пояснение в несколько строк — свой вид: обычный пункт меню не переносит
    // текст. Высота считается, когда известна ширина меню.
    private func textItem(_ title: String?, detail: String, symbol: String? = nil,
                          tint: NSColor = .secondaryLabelColor) -> NSMenuItem {
        let left: CGFloat = symbol == nil ? 14 : 36
        let text = NSTextField(wrappingLabelWithString: "")
        let body = NSMutableAttributedString()
        if let title {
            body.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]))
        }
        body.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: symbol == nil || title != nil ? NSColor.secondaryLabelColor : NSColor.labelColor]))
        text.attributedStringValue = body
        text.isSelectable = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Self.floorWidth, height: 20))
        v.addSubview(text)
        var icon: NSImageView?
        if let symbol {
            let i = NSImageView()
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            i.contentTintColor = tint
            i.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            v.addSubview(i)
            icon = i
        }
        let place = { (w: CGFloat) in
            let textWidth = w - left - 14
            text.preferredMaxLayoutWidth = textWidth
            let height = ceil(text.sizeThatFits(NSSize(width: textWidth, height: 1000)).height)
            v.frame = NSRect(x: 0, y: 0, width: w, height: height + 8)
            text.frame = NSRect(x: left, y: 4, width: textWidth, height: height)
            icon?.frame = NSRect(x: 14, y: height + 4 - 16, width: 16, height: 16)
        }
        // Узкая раскладка сразу: высота вида не должна раздувать меню, пока
        // ширина не известна.
        place(Self.floorWidth)
        relayouts.append(place)
        let item = NSMenuItem()
        item.view = v
        return item
    }
}

// Окна приложения — сцены SwiftUI, а открыть их умеет только openWindow из
// окружения SwiftUI. Скрытый вид один раз отдаёт его AppKit-меню.
@MainActor
enum WindowBridge {
    private static var openWindow: OpenWindowAction?
    private static var holder: NSWindow?

    static func install() {
        guard holder == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1, height: 1),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.alphaValue = 0
        w.contentView = NSHostingView(rootView: Catcher())
        w.orderFrontRegardless()
        holder = w
    }

    static func open(_ id: String) {
        guard let openWindow else { AppLog.write("окно \(id): openWindow не получен"); return }
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private struct Catcher: View {
        @Environment(\.openWindow) private var openWindow
        var body: some View {
            Color.clear.frame(width: 1, height: 1)
                .onAppear {
                    WindowBridge.openWindow = openWindow
                    // Окно-носитель больше не нужно на экране.
                    DispatchQueue.main.async { WindowBridge.holder?.orderOut(nil) }
                }
        }
    }
}
