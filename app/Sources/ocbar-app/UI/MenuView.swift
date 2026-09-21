import SwiftUI

// Меню из строки состояния, как модуль Пункта управления: карточка состояния
// с одной большой кнопкой действия, трафик, профили списком (как сети в меню
// Wi-Fi), «Сети и DNS» — вторым экраном внутри того же меню.
struct MenuView: View {
    @EnvironmentObject var store: StatusStore
    @ObservedObject private var notify = NotifyState.shared
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var nav: MenuNav
    @State private var showConnection = true
    @State private var contentHeight: CGFloat = 0

    enum Page { case main, networks }

    /// Текущий экран меню держится снаружи: так самопроверка может
    /// переключить его и измерить высоту (меню не должно ни расти без
    /// возврата, ни ужиматься).
    final class MenuNav: ObservableObject {
        /// Тот же объект, что у живого меню: служебная проверка
        /// (ocbar://debug-menu) переключает им экраны и меряет окно.
        static let shared = MenuNav()
        @Published var page: Page
        init(page: Page = .main) { self.page = page }
    }

    private var page: Page {
        get { nav.page }
        nonmutating set { nav.page = newValue }
    }

    /// expandProfiles и switchTo остались от меню со списком профилей: выбор
    /// профиля теперь в настройках, флаги ничего не меняют.
    init(expandDetails: Bool = false, expandProfiles: Bool = false, switchTo: ProfileEntry? = nil,
         nav: MenuNav? = nil) {
        self.nav = nav ?? MenuNav(page: expandDetails ? .networks : .main)
    }

    private var s: Status { store.status }
    private var look: StateLook { StateLook.of(s) }

    static let width: CGFloat = 340
    /// Сколько строк списка показывать без прокрутки: остальное прокручивается
    /// внутри своей группы, чтобы длинный список сетей не выгонял меню за
    /// пределы экрана.
    static var rowsBeforeScroll: Int {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(5, min(14, Int((screen - 420) / 34)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            appHeader
            // Меню — ровно по содержимому: окно в строке меню система
            // подгоняет под него сама. Прокрутка здесь только вредила: любая
            // обёртка, меряющая высоту, то растягивала меню, то схлопывала его
            // (проверено живым окном, см. MenuProbe).
            switch page {
            case .main: mainPage
            case .networks: networksPage
            }
        }
        .padding(12)
        .frame(width: Self.width)
        // Высота содержимого — и окно под неё: система сама умеет только
        // увеличивать своё окно.
        .background(GeometryReader { g in
            Color.clear.preference(key: MenuHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(MenuHeightKey.self) { contentHeight = $0 }
        // Высота корня — ровно измеренная: иначе система, подгоняя окно,
        // берёт её с запасом (на 36 точек), а следом приходится уменьшать —
        // и это видно как рывок.
        .frame(height: contentHeight > 0 ? contentHeight : nil, alignment: .top)
        .background(MenuWindowFit(height: contentHeight))
        .background(shortcuts)
        .onAppear {
            if !CommandLine.arguments.contains("--stage") { Notifier.refreshAllowed() }
            store.menuOpen = true
            if page == .networks { store.detailsOpen = true }
            store.refresh()
        }
        .onDisappear {
            store.menuOpen = false; store.detailsOpen = false
            // Закрытое меню открывается с главного экрана: второй экран —
            // отступление, а не место, где меню «живёт».
            if !CommandLine.arguments.contains("--stage") { page = .main }
        }
        // Второго экрана нет, когда нет туннеля: сети отключённого клиента —
        // одни прочерки.
        .onChange(of: look.details) { if !$0 { page = .main } }
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
            Button("") { open(WindowID.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // --- шапка: значок и имя приложения ------------------------------------

    private var appHeader: some View {
        HStack(spacing: 8) {
            AppMark(size: 22)
            Text("ocbar").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
            Spacer()
            // Индикатор занятости живёт в шапке, а не вместо кнопок: подмена
            // кнопок меняла высоту меню, и оно прыгало под курсором.
            if let busy = store.busy {
                Text(busy).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                ProgressView().controlSize(.small).scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 2)
    }

    // --- главный экран -----------------------------------------------------

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusCard
            banners
            // В прокси-режиме интерфейса нет, а с ним и счётчиков: график
            // убран, а не рисует нули.
            if look.graph, !s.isProxySession { trafficCard }
            // Списка профилей в меню нет: обычно профиль один, а выбор и
            // смена — в настройках, где видно, что именно подключаешь.
            if s.profiles.isEmpty { setupRow }
            if look.details { networksLink }
            footer
        }
    }

    private var statusCard: some View {
        let alert = s.presentation == .needsLogin || s.presentation == .missing
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                StateDot(color: look.color, pulsing: look.pulsing, size: 12)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(look.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                            .lineLimit(1).truncationMode(.tail)
                        if s.isProxySession {
                            Text("SOCKS").font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Palette.accent.opacity(0.18)))
                                .foregroundStyle(Palette.accent)
                        }
                    }
                    // Состояние, которое требует внимания (нет связи, пауза,
                    // нужен вход), — цветом и весом: по виду карточка иначе
                    // почти не отличалась от рабочего подключения.
                    let alarm = [.lost, .paused, .needsLogin, .missing].contains(s.presentation)
                    Text(look.showsTime ? L("%@ · сессия %@", look.subtitle, humanSince(s.since)) : look.subtitle)
                        .font(.system(size: 12, weight: alarm ? .semibold : .regular))
                        .foregroundStyle(alarm ? look.color : Palette.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    if let address = s.profiles.first(where: { $0.name == StateLook.targetName(s) })?.address,
                       !address.isEmpty {
                        Text(address).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            actionButtons
            if s.profiles.count > 1 {
                Button(L("Другой профиль…")) { open(WindowID.settings) }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            if let note = look.note {
                Text(note)
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .groupBox(tint: alert ? (s.presentation == .needsLogin ? Palette.warn : Palette.bad) : nil)
    }

    // Пока идёт действие, кнопки недоступны — кроме отключения и отмены:
    // вход и разметка ждут человека минутами, и «Отключить» в это время
    // должно работать (store отменит текущее действие и отключится).
    private var idle: Bool { store.busy == nil }
    private var canConnect: Bool { idle && OcbarClient.shared.binary != nil }

    private var hasDisconnect: Bool {
        switch s.presentation {
        case .connected, .lost, .paused, .starting, .needsLogin: return true
        default: return false
        }
    }

    private var target: String? {
        let name = StateLook.targetName(s)
        return name.isEmpty ? nil : name
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 6) {
            if let title = store.cancelTitle, !(store.cancelDisconnects && hasDisconnect) {
                WideButton(title: title, kind: .neutral) { store.cancelCurrent() }
            }
            switch s.presentation {
            case .connected, .lost:
                WideButton(title: L("Отключить"), kind: .destructive) { store.disconnect() }
                // В прокси-режиме паузы нет: снаружи туннеля ничего не
                // изменено, снимать нечего — ocbar так и ответит.
                if !s.isProxySession {
                    WideButton(title: L("Приостановить"), systemImage: "pause.fill", kind: .neutral, compact: true,
                               hint: GlobalHotkeys.shared.isRegistered("pause") ? "⌥⌘P" : nil,
                               enabled: idle) { store.pause() }
                }
            case .paused:
                WideButton(title: L("Возобновить"), systemImage: "play.fill", kind: .primary,
                           hint: GlobalHotkeys.shared.isRegistered("pause") ? "⌥⌘P" : nil,
                           enabled: idle) { store.resume() }
                WideButton(title: L("Отключить"), kind: .neutral, compact: true) { store.disconnect() }
            case .starting:
                WideButton(title: L("Отменить"), kind: .neutral) { store.disconnect() }
            case .needsLogin:
                // Человек нажал сам — окно входа должно появиться сразу, а не
                // после двухсекундной пробы молчаливого прохода.
                WideButton(title: L("Войти"), kind: .primary, enabled: idle) {
                    store.connect(profile: s.profile.isEmpty ? nil : s.profile, show: true)
                }
                HStack {
                    Button(L("Войти и запомнить вход…")) {
                        store.connect(profile: s.profile.isEmpty ? nil : s.profile, teach: true)
                    }
                    .disabled(!idle)
                    Spacer()
                    Button(L("Не подключаться")) { store.disconnect() }
                }
                .buttonStyle(.link).font(.system(size: 11))
            case .down, .foreign:
                WideButton(title: s.presentation == .foreign
                               ? L("Подключить · %@", StateLook.profileName(s)) : L("Подключить"),
                           kind: .primary, enabled: canConnect) { store.connect(profile: target) }
                // Первый вход: человек входит руками, ocbar запоминает форму и
                // предлагает сохранить пароль и источник кода.
                HStack {
                    Button(L("Подключить и запомнить вход…")) { store.connect(profile: target, teach: true) }
                        .disabled(!canConnect)
                    Spacer()
                }
                .buttonStyle(.link).font(.system(size: 11))
            case .missing:
                EmptyView()
            }
        }
    }

    // Предупреждения — отдельными плашками под карточкой: каждое про одно и
    // со своим следующим шагом.
    @ViewBuilder
    private var banners: some View {
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
                   fix: Self.fix(for: warning))
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
            // Ошибке нужна не только причина, но и следующий шаг: команду с
            // sudo приложение выполнить не может, но может положить её в
            // буфер обмена.
            let fix = Self.fix(for: message)
            Banner(color: failed ? Palette.bad : Palette.secondary,
                   symbol: failed ? "xmark.octagon" : "info.circle",
                   text: Self.human(message), fix: fix,
                   link: fix == nil && failed ? (L("Журнал"), { open(WindowID.logs) }) : nil,
                   dismiss: store.actionNote != nil ? { store.dismissNote() } : nil)
        }
    }

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Скорость за минуту")).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            Sparkline(samples: store.samples, capacity: 30, active: look.graphActive, inset: 0)
            HStack {
                Label(Size.rate(store.currentDown), systemImage: "arrow.down")
                    .foregroundStyle(Palette.accent)
                Spacer()
                Label(Size.rate(store.currentUp), systemImage: "arrow.up")
                    .foregroundStyle(Palette.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .labelStyle(TightLabel())
        }
        .padding(12)
        .groupBox()
    }

    private var setupRow: some View {
        VStack(spacing: 0) {
            MenuRow(enabled: s.available, action: { open(WindowID.setup) }) {
                IconTile(symbol: "plus", color: Palette.accent)
                Text(L("Настроить ocbar…"))
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .groupBox()
    }

    // На паузе правила сохранены, но не действуют — числа «2/3» читались бы
    // как работающие сети.
    private var counts: String {
        if s.paused { return L("не применяются") }
        return L("сети %@/%@ · DNS %@/%@", "\(s.routesOn.count)", "\(s.routes.count)",
                 "\(s.zones.filter { $0.enabled }.count)", "\(s.zones.count)")
    }

    private var networksLink: some View {
        MenuRow(action: {
            MenuWindowFit.freezeUntilFlush()
            page = .networks
            store.detailsOpen = true
            store.refresh()
        }) {
            IconTile(symbol: s.isProxySession ? "arrow.left.arrow.right" : "globe", color: Palette.violet)
            Text(s.isProxySession ? L("Прокси SOCKS") : L("Сети и DNS"))
            Spacer()
            if !s.isProxySession {
                Text(counts).font(.system(size: 12)).opacity(0.6)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).opacity(0.5)
        }
        .padding(.vertical, 4)
        .groupBox()
    }

    // --- подвал ----------------------------------------------------------

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(action: { open(WindowID.settings) }) {
                FooterIcon(symbol: "gearshape")
                Text(L("Настройки…"))
                Spacer()
                Text("⌘,").font(.system(size: 12)).opacity(0.5)
            }
            MenuRow(action: { open(WindowID.diagnostics) }) {
                FooterIcon(symbol: "doc.text.magnifyingglass")
                Text(L("Диагностика и журналы…"))
                Spacer()
            }
            // Только в режиме разработчика (ocbar app devmode on): войти с
            // нуля, с формой. Обычному пользователю живая сессия — удобство.
            if UserDefaults.standard.bool(forKey: "DeveloperMode"), !CommandLine.arguments.contains("--stage") {
                MenuRow(enabled: canConnect, action: { store.logout() }) {
                    FooterIcon(symbol: "person.crop.circle.badge.xmark")
                    Text(L("Выйти совсем (сброс входа)"))
                    Spacer()
                    Text("dev").font(.system(size: 11)).opacity(0.5)
                }
            }
            MenuRow(action: { NSApplication.shared.terminate(nil) }) {
                FooterIcon(symbol: "rectangle.portrait.and.arrow.right")
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Выйти из ocbar"))
                    if hasDisconnect {
                        Text(L("туннель останется")).font(.system(size: 11)).opacity(0.6)
                    }
                }
                Spacer()
                Text("⌘Q").font(.system(size: 12)).opacity(0.5)
            }
        }
        .padding(.top, 2)
    }

    // --- второй экран: сети и DNS ------------------------------------------

    private var networksPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    MenuWindowFit.freezeUntilFlush()
                    page = .main
                    store.detailsOpen = false
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text(L("Назад"))
                    }
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text(s.isProxySession ? L("Прокси SOCKS") : L("Сети и DNS"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // Противовес «Назад», чтобы заголовок стоял по центру.
                Text(L("Назад")).hidden().padding(.leading, 15)
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            HStack(spacing: 8) {
                StateDot(color: look.color, pulsing: look.pulsing)
                Text(look.title).font(.system(size: 12, weight: .medium))
                Text("· " + look.subtitle.lowercased()).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .groupBox()
            VStack(alignment: .leading, spacing: 8) {
                if s.isProxySession { proxyDetails } else { networkGroups }
                connectionDetails
            }
        }
    }

    private var networkGroups: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                GroupHead(title: L("Сети в туннеле"), trailing: "\(s.routesOn.count)/\(s.routes.count)")
                if s.routes.isEmpty {
                    Text(L("в профиле нет ни одной сети"))
                        .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                CappedRows(count: s.routes.count) {
                    ForEach(Array(s.routes.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { RowDivider() }
                        routeRow(r)
                    }
                }
            }
            .padding(.bottom, 4)
            .groupBox()
            VStack(alignment: .leading, spacing: 0) {
                GroupHead(title: L("DNS-зоны"), trailing: "\(s.zones.filter { $0.enabled }.count)/\(s.zones.count)")
                CappedRows(count: s.zones.count) {
                    ForEach(Array(s.zones.enumerated()), id: \.element.id) { i, z in
                        if i > 0 { RowDivider() }
                        zoneRow(z)
                    }
                }
            }
            .padding(.bottom, 4)
            .groupBox()
        }
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                MenuWindowFit.freezeUntilFlush()
                showConnection.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showConnection ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .frame(width: 12)
                    Text(L("Сведения о соединении")).font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 9)
            if showConnection {
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
                .padding(.bottom, 8)
            }
        }
        .groupBox()
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
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            if !s.socksUp {
                Text(L("порт не отвечает — супервизор перезапустит прокси"))
                    .font(.system(size: 11)).foregroundStyle(Palette.bad).padding(.horizontal, 12)
            }
            KVRow(mono: false, label: L("Системный SOCKS"),
                  value: s.systemSocksOn.isEmpty
                      ? (s.systemProxy ? L("не включён") : L("выключен в профиле"))
                      : L("включён на %@", s.systemSocksOn.joined(separator: ", ")),
                  color: s.systemSocksOn.isEmpty && s.systemProxy ? Palette.warn : Palette.text)
            RowDivider().padding(.vertical, 4)
            Text(L("Как направить программу")).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                .padding(.horizontal, 12)
            hintRow("curl --socks5-hostname \(s.socks) URL")
            hintRow(L("ALL_PROXY=socks5h://%@ команда", s.socks))
            Text(L("Имена внутренних хостов резолвит ocproxy по DNS шлюза (socks5h), поэтому в системе ничего не меняется. Паузы в этом режиме нет: снимать нечего."))
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.top, 3).padding(.bottom, 10)
        }
        .groupBox()
    }

    private func hintRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            // Команду для копирования не обрезаем: переносим целиком.
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 4)
            CopyButton(text: text)
        }
        .padding(.horizontal, 12).padding(.vertical, 1)
    }

    private func routeRow(_ r: RouteEntry) -> some View {
        let on = store.routeIsOn(r)
        // Пока действие не доехало, состояние сети показывается по нажатию,
        // а не по последнему опросу: иначе переключатель отщёлкивает назад.
        let settled = store.pendingRoutes[r.net] == nil
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.net).font(.ocMono)
                    .foregroundStyle(on ? Palette.text : Palette.secondary)
                if settled, on, let via = r.via, via != s.tundev {
                    Text(L("идёт мимо туннеля → %@", via)).font(.system(size: 10.5)).foregroundStyle(Palette.warn)
                } else if settled, on, r.via == nil, s.state == .connected {
                    Text(L("нет маршрута")).font(.system(size: 10.5)).foregroundStyle(Palette.warn)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { store.toggleRoute(r.net, to: $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(store.busy != nil || s.paused)
                .accessibilityLabel(L("сеть %@ в туннеле", r.net))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func zoneRow(_ z: ZoneEntry) -> some View {
        let on = store.zoneIsOn(z)
        return HStack(spacing: 8) {
            Text(z.zone).font(.ocMono)
                .foregroundStyle(on ? Palette.text : Palette.secondary)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(z.dns).font(.ocMonoSmall).foregroundStyle(Palette.secondary)
                .lineLimit(1).truncationMode(.middle)
            Toggle("", isOn: Binding(get: { on }, set: { store.toggleZone(z.zone, to: $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(store.busy != nil || s.paused)
                .accessibilityLabel(L("зона %@ через %@", z.zone, z.dns))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}

// Окна открываются поверх: приложение живёт значком в меню-баре, и без
// явной активации окно уходит за чужие.
extension MenuView {
    /// Что делать с этой ошибкой: команда, которую приложение выполнить не
    /// может (нужен пароль или Homebrew), но может отдать в буфер обмена.
    static func fix(for message: String) -> (title: String, command: String)? {
        // Клиент говорит на языке системы: узнаём по командам в сообщении,
        // а слова — на обоих языках.
        let m = message.lowercased()
        if m.range(of: #"sudo \S*ocbar install"#, options: .regularExpression) != nil,
           !m.contains("--trust") {
            return (L("Скопировать команду"), "sudo ocbar install")
        }
        if m.contains("brew install openconnect") || m.contains("нет openconnect") || m.contains("no openconnect") {
            return (L("Скопировать команду"), "brew install openconnect")
        }
        if m.contains("brew install ocproxy") || m.contains("нет ocproxy") || m.contains("no ocproxy") {
            return (L("Скопировать команду"), "brew install ocproxy")
        }
        if m.contains("--trust") { return (L("Скопировать команду"), "sudo ocbar install --trust") }
        return nil
    }

    /// Ошибка словами человека: без «ocbar:» и кода возврата хелпера —
    /// подробности в журнале, кнопка рядом.
    static func human(_ message: String) -> String {
        var t = message
        for prefix in ["ocbar: ", "ocbar:"] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)); break }
        if let r = t.range(of: " — хелпер вернул") { t = String(t[..<r.lowerBound]) }
        if let first = t.first { t = first.uppercased() + t.dropFirst() }
        return t
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
    let title: String       // профиль: текущий или по умолчанию
    let subtitle: String    // состояние словами
    let note: String?
    let showsTime: Bool
    let graph: Bool
    let graphActive: Bool
    let pulsing: Bool
    let details: Bool

    /// Имя для шапки и строки «Профиль»: текущий профиль, иначе по умолчанию.
    /// К какому профилю относится меню: подключённый; иначе последний
    /// подключённый, профиль по умолчанию, первый в списке.
    static func targetName(_ s: Status) -> String {
        if !s.profile.isEmpty { return s.profile }
        let known = Set(s.profiles.map(\.name))
        if let last = UserDefaults.standard.string(forKey: "LastProfile"), known.contains(last) { return last }
        if !s.defaultProfile.isEmpty { return s.defaultProfile }
        return s.profiles.first?.name ?? ""
    }

    static func profileName(_ s: Status) -> String {
        let n = targetName(s)
        if n.isEmpty { return "ocbar" }
        return s.profiles.first { $0.name == n }?.display ?? n
    }

    static func of(_ s: Status) -> StateLook {
        let name = profileName(s)
        switch s.presentation {
        case .connected:
            return .init(color: Palette.ok, title: name, subtitle: L("Подключено"), note: nil,
                         showsTime: true, graph: true, graphActive: true, pulsing: false, details: true)
        case .lost:
            let waited = s.linkLostSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            return .init(color: Palette.warn, title: name,
                         subtitle: s.isProxySession ? L("SOCKS не отвечает") : L("Нет связи · восстанавливаю"),
                         note: s.isProxySession
                             ? L("SOCKS не отвечает %@ с — супервизор перезапустит прокси целиком.", "\(waited)")
                             : L("Связи нет %@ с — восстанавливаю сессию. Повторный вход не нужен.", "\(waited)"),
                         showsTime: false, graph: true, graphActive: false, pulsing: true, details: true)
        case .paused:
            return .init(color: Palette.warn, title: name, subtitle: L("Приостановлено"),
                         note: L("Сети и DNS временно сняты, сессия жива — возобновление без входа."),
                         showsTime: true, graph: false, graphActive: false, pulsing: false, details: true)
        case .starting:
            return .init(color: Palette.warn, title: name, subtitle: L("Подключается…"), note: nil,
                         showsTime: false, graph: false, graphActive: false, pulsing: true, details: false)
        case .needsLogin:
            return .init(color: Palette.bad, title: name, subtitle: L("Нужен вход"),
                         note: L("Сессия истекла, автоматически войти не удалось. Автоподключение ждёт вас."),
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .down:
            return .init(color: Palette.line2, title: name, subtitle: L("Отключено"), note: nil,
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .foreign:
            return .init(color: Palette.tertiary, title: L("Чужой openconnect"), subtitle: L("поднят не через ocbar"),
                         note: L("Это подключение ocbar не управляет и не трогает."),
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .missing:
            return .init(color: Palette.bad, title: L("Не найден клиент ocbar"), subtitle: L("подключение недоступно"),
                         note: OcbarClient.shared.lookupNote.isEmpty
                             ? L("Искал в /opt/homebrew/bin, /usr/local/bin и рядом с приложением. Путь можно задать переменной OCBAR_BIN.")
                             : OcbarClient.shared.lookupNote,
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        }
    }
}
