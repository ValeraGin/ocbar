import SwiftUI

// Меню из строки состояния, как модуль Пункта управления: карточка состояния
// с одной большой кнопкой действия, трафик, профили списком (как сети в меню
// Wi-Fi), «Сети и DNS» — вторым экраном внутри того же меню.
struct MenuView: View {
    @EnvironmentObject var store: StatusStore
    @ObservedObject private var notify = NotifyState.shared
    @Environment(\.openWindow) private var openWindow
    @State private var page: Page
    @State private var showConnection = true
    // Смена профиля на живой сессии стоит нового входа: спрашиваем, а не
    // переключаем по первому щелчку.
    @State private var switchTo: ProfileEntry?

    enum Page { case main, networks }

    /// expandProfiles остался от прежнего меню со сворачиваемым списком:
    /// теперь профили видны всегда, флаг ничего не меняет.
    init(expandDetails: Bool = false, expandProfiles: Bool = false, switchTo: ProfileEntry? = nil) {
        _page = State(initialValue: expandDetails ? .networks : .main)
        _switchTo = State(initialValue: switchTo)
    }

    private var s: Status { store.status }
    private var look: StateLook { StateLook.of(s) }

    static let width: CGFloat = 340
    /// Сколько меню может занять по высоте: видимая часть экрана минус строка
    /// меню и шапка ocbar.
    static var maxBodyHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, screen - 90)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            appHeader
            // Всё ниже шапки прокручивается: восемь профилей, вопрос о смене
            // профиля и предупреждения вместе выше экрана 13", и низ меню
            // («Выйти») обрезался.
            BoundedScroll(maxHeight: Self.maxBodyHeight) {
                switch page {
                case .main: mainPage
                case .networks: networksPage
                }
            }
        }
        .padding(12)
        .frame(width: Self.width)
        .background(shortcuts)
        .onAppear {
            if !CommandLine.arguments.contains("--stage") { Notifier.refreshAllowed() }
            store.menuOpen = true
            if page == .networks { store.detailsOpen = true }
            store.refresh()
        }
        .onDisappear {
            store.menuOpen = false; store.detailsOpen = false; switchTo = nil
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
            profilesCard
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
                    Text(look.showsTime ? "\(look.subtitle) · \(humanSince(s.since))" : look.subtitle)
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            actionButtons
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
        let name = s.profile.isEmpty ? s.defaultProfile : s.profile
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
                WideButton(title: "Отключить", kind: .destructive) { store.disconnect() }
                // В прокси-режиме паузы нет: снаружи туннеля ничего не
                // изменено, снимать нечего — ocbar так и ответит.
                if !s.isProxySession {
                    WideButton(title: "Приостановить", systemImage: "pause.fill", kind: .neutral, compact: true,
                               hint: GlobalHotkeys.shared.isRegistered("pause") ? "⌥⌘P" : nil,
                               enabled: idle) { store.pause() }
                }
            case .paused:
                WideButton(title: "Возобновить", systemImage: "play.fill", kind: .primary,
                           hint: GlobalHotkeys.shared.isRegistered("pause") ? "⌥⌘P" : nil,
                           enabled: idle) { store.resume() }
                WideButton(title: "Отключить", kind: .neutral, compact: true) { store.disconnect() }
            case .starting:
                WideButton(title: "Отменить", kind: .neutral) { store.disconnect() }
            case .needsLogin:
                // Человек нажал сам — окно входа должно появиться сразу, а не
                // после двухсекундной пробы молчаливого прохода.
                WideButton(title: "Войти", kind: .primary, enabled: idle) {
                    store.connect(profile: s.profile.isEmpty ? nil : s.profile, show: true)
                }
                HStack {
                    Button("Войти и запомнить вход…") {
                        store.connect(profile: s.profile.isEmpty ? nil : s.profile, teach: true)
                    }
                    .disabled(!idle)
                    Spacer()
                    Button("Не подключаться") { store.disconnect() }
                }
                .buttonStyle(.link).font(.system(size: 11))
            case .down, .foreign:
                WideButton(title: s.presentation == .foreign
                               ? "Подключить · " + StateLook.profileName(s) : "Подключить",
                           kind: .primary, enabled: canConnect) { store.connect(profile: target) }
                // Первый вход: человек входит руками, ocbar запоминает форму и
                // предлагает сохранить пароль и источник кода.
                HStack {
                    Button("Подключить и запомнить вход…") { store.connect(profile: target, teach: true) }
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
                   text: "Мак просыпался после подключения (\(Self.clock.string(from: woke))) — "
                       + (s.supervisor ? "супервизор проверит туннель сам." : "супервизор не работает, проверьте доступ."))
        }
        if s.isProxySession, !s.systemSocksRefused.isEmpty {
            Banner(color: Palette.warn, symbol: "exclamationmark.triangle",
                   text: "Системный SOCKS не включён: \(s.systemSocksRefused)", selectable: true)
        }
        if s.access == "fail", s.presentation == .connected {
            Banner(color: Palette.warn, symbol: "exclamationmark.triangle",
                   text: "Туннель поднят, но проверка доступа не проходит: шлюз может не пускать к этому ресурсу или не хватает сети в профиле.")
        }
        if let warning = store.helperWarning {
            Banner(color: Palette.warn, symbol: "wrench.and.screwdriver", text: warning, selectable: true,
                   fix: Self.fix(for: warning))
        }
        if s.available, !s.supervisor {
            Banner(color: Palette.warn, symbol: "exclamationmark.triangle",
                   text: "Супервизор не запущен — автоподключения не будет.")
        }
        if !notify.allowed {
            Banner(color: Palette.warn, symbol: "bell.slash", text: "Уведомления выключены",
                   link: ("Разрешить", { Notifier.openSettings() }))
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
                   link: fix == nil && failed ? ("Журнал", { open(WindowID.logs) }) : nil,
                   dismiss: store.actionNote != nil ? { store.dismissNote() } : nil)
        }
    }

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("За минуту").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
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

    // --- профили ---------------------------------------------------------

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

    /// Какой профиль отмечен: текущий, а без сессии — по умолчанию.
    private var selected: String { s.profile.isEmpty ? s.defaultProfile : s.profile }

    @ViewBuilder
    private var profilesCard: some View {
        if s.profiles.isEmpty {
            if s.available {
                VStack(spacing: 0) {
                    MenuRow(action: { open(WindowID.setup) }) {
                        IconTile(symbol: "plus", color: Palette.accent)
                        Text("Настроить ocbar…")
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
                .groupBox()
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Профили").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, 12).padding(.top, 8)
                // Девять профилей вместе со всем остальным не влезают на экран
                // 13" — список прокручивается, а не растягивает меню.
                BoundedScroll(maxHeight: 236) {
                    // Выбранный профиль должен быть виден сразу: при восьми
                    // профилях он мог оказаться под краем прокрутки.
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(s.profiles) { p in profileRow(p).id(p.name).help(p.descr) }
                        }
                        .onAppear { proxy.scrollTo(selected, anchor: .center) }
                    }
                }
                if let p = switchTo { switchPrompt(p) }
            }
            .padding(.bottom, 4)
            .groupBox()
        }
    }

    private func profileRow(_ p: ProfileEntry) -> some View {
        let on = p.name == selected
        return MenuRow(enabled: idle, action: { choose(p) }) {
            IconTile(symbol: "link", color: on ? Palette.accent : Color.gray)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(p.display).font(.system(size: 13))
                        .lineLimit(1).truncationMode(.tail)
                    if p.isPassword {
                        Text("пароль + SMS").font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().strokeBorder(Color.primary.opacity(0.3)))
                            .opacity(0.8)
                    }
                }
                // Под названием — адрес с группой: одинаковые названия у
                // разных шлюзов и групп иначе не различить. Описание — в
                // подсказке: вместе с адресом в строку оно не помещалось.
                if !p.address.isEmpty {
                    Text(p.address).font(.system(size: 11)).opacity(0.6)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if on {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .accessibilityLabel("выбран")
            }
        }
    }

    private func switchPrompt(_ p: ProfileEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Переключиться на «\(p.display)»? Текущая сессия закроется, потребуется вход.")
                .font(.system(size: 11)).foregroundStyle(Palette.text)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.warn.opacity(0.12)))
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var counts: String {
        "\(s.routesOn.count)/\(s.routes.count) · \(s.zones.filter { $0.enabled }.count)/\(s.zones.count)"
    }

    private var networksLink: some View {
        MenuRow(action: {
            withAnimation(.easeOut(duration: 0.15)) { page = .networks }
            store.detailsOpen = true
            store.refresh()
        }) {
            IconTile(symbol: s.isProxySession ? "arrow.left.arrow.right" : "globe", color: Palette.violet)
            Text(s.isProxySession ? "SOCKS и туннель" : "Сети и DNS")
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
                Text("Настройки…")
                Spacer()
                Text("⌘,").font(.system(size: 12)).opacity(0.5)
            }
            MenuRow(action: { open(WindowID.diagnostics) }) {
                FooterIcon(symbol: "doc.text.magnifyingglass")
                Text("Диагностика и журналы…")
                Spacer()
            }
            // Только в режиме разработчика (ocbar app devmode on): войти с
            // нуля, с формой. Обычному пользователю живая сессия — удобство.
            if UserDefaults.standard.bool(forKey: "DeveloperMode"), !CommandLine.arguments.contains("--stage") {
                MenuRow(enabled: canConnect, action: { store.logout() }) {
                    FooterIcon(symbol: "person.crop.circle.badge.xmark")
                    Text("Выйти совсем (сброс входа)")
                    Spacer()
                    Text("dev").font(.system(size: 11)).opacity(0.5)
                }
            }
            MenuRow(action: { NSApplication.shared.terminate(nil) }) {
                FooterIcon(symbol: "rectangle.portrait.and.arrow.right")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Выйти из ocbar")
                    if hasDisconnect {
                        Text("туннель останется").font(.system(size: 11)).opacity(0.6)
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
                    withAnimation(.easeOut(duration: 0.15)) { page = .main }
                    store.detailsOpen = false
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Назад")
                    }
                    .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text(s.isProxySession ? "SOCKS и туннель" : "Сети и DNS")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // Противовес «Назад», чтобы заголовок стоял по центру.
                Text("Назад").hidden().padding(.leading, 15)
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
                GroupHead(title: "Сети в туннеле", trailing: "\(s.routesOn.count)/\(s.routes.count)")
                if s.routes.isEmpty {
                    Text("в профиле нет ни одной сети")
                        .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                ForEach(Array(s.routes.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { RowDivider() }
                    routeRow(r)
                }
            }
            .padding(.bottom, 4)
            .groupBox()
            VStack(alignment: .leading, spacing: 0) {
                GroupHead(title: "DNS-зоны", trailing: "\(s.zones.filter { $0.enabled }.count)/\(s.zones.count)")
                ForEach(Array(s.zones.enumerated()), id: \.element.id) { i, z in
                    if i > 0 { RowDivider() }
                    zoneRow(z)
                }
            }
            .padding(.bottom, 4)
            .groupBox()
        }
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showConnection.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showConnection ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .frame(width: 12)
                    Text("Сведения о соединении").font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 9)
            if showConnection {
                VStack(alignment: .leading, spacing: 0) {
                    KVRow(label: "Адрес в туннеле", value: s.ip)
                    KVRow(label: "Шлюз", value: s.gateway)
                    if !s.isProxySession { KVRow(mono: false, label: "MTU", value: s.mtu) }
                    KVRow(label: "Резолверы", value: s.dns.joined(separator: "\n"))
                    if !s.isProxySession {
                        KVRow(mono: false, label: "Принято / отдано",
                              value: "\(Size.bytes(store.totalRx)) / \(Size.bytes(store.totalTx))")
                        KVRow(mono: false, label: "Задержка", value: store.latency ?? "—")
                        KVRow(mono: false, label: "Доступ",
                              value: s.access == "ok" ? "проверен\(s.accessAt.map { " в " + Self.clock.string(from: $0) } ?? "")"
                                   : s.access == "fail" ? "не отвечает" : "не проверялся",
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
                Text("порт не отвечает — супервизор перезапустит прокси")
                    .font(.system(size: 11)).foregroundStyle(Palette.bad).padding(.horizontal, 12)
            }
            KVRow(mono: false, label: "Системный SOCKS",
                  value: s.systemSocksOn.isEmpty
                      ? (s.systemProxy ? "не включён" : "выключен в профиле")
                      : "включён на " + s.systemSocksOn.joined(separator: ", "),
                  color: s.systemSocksOn.isEmpty && s.systemProxy ? Palette.warn : Palette.text)
            RowDivider().padding(.vertical, 4)
            Text("Как направить программу").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                .padding(.horizontal, 12)
            hintRow("curl --socks5-hostname \(s.socks) URL")
            hintRow("ALL_PROXY=socks5h://\(s.socks) команда")
            Text("Имена внутренних хостов резолвит ocproxy по DNS шлюза (socks5h), поэтому в системе ничего не меняется. Паузы в этом режиме нет: снимать нечего.")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.top, 3).padding(.bottom, 10)
        }
        .groupBox()
    }

    private func hintRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.text)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
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
                    .foregroundStyle(on ? Palette.text : Palette.tertiary)
                if settled, on, let via = r.via, via != s.tundev {
                    Text("идёт мимо туннеля → \(via)").font(.system(size: 10.5)).foregroundStyle(Palette.warn)
                } else if settled, on, r.via == nil, s.state == .connected {
                    Text("нет маршрута").font(.system(size: 10.5)).foregroundStyle(Palette.warn)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { store.toggleRoute(r.net, to: $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(store.busy != nil || s.paused)
                .accessibilityLabel("сеть \(r.net) в туннеле")
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    private func zoneRow(_ z: ZoneEntry) -> some View {
        let on = store.zoneIsOn(z)
        return HStack(spacing: 8) {
            Text(z.zone).font(.ocMono)
                .foregroundStyle(on ? Palette.text : Palette.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text(z.dns).font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Toggle("", isOn: Binding(get: { on }, set: { store.toggleZone(z.zone, to: $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(store.busy != nil || s.paused)
                .accessibilityLabel("зона \(z.zone) через \(z.dns)")
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
        let m = message.lowercased()
        if m.contains("sudo ocbar install") || m.contains("нужен root") {
            return ("Скопировать команду", "sudo ocbar install")
        }
        if m.contains("нет openconnect") { return ("Скопировать команду", "brew install openconnect") }
        if m.contains("нет ocproxy") || m.contains("ocproxy —") { return ("Скопировать команду", "brew install ocproxy") }
        if m.contains("--trust") { return ("Скопировать команду", "sudo ocbar install --trust") }
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
    static func profileName(_ s: Status) -> String {
        let n = s.profile.isEmpty ? s.defaultProfile : s.profile
        if n.isEmpty { return "ocbar" }
        return s.profiles.first { $0.name == n }?.display ?? n
    }

    static func of(_ s: Status) -> StateLook {
        let name = profileName(s)
        switch s.presentation {
        case .connected:
            return .init(color: Palette.ok, title: name, subtitle: "Подключено", note: nil,
                         showsTime: true, graph: true, graphActive: true, pulsing: false, details: true)
        case .lost:
            let waited = s.linkLostSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
            return .init(color: Palette.warn, title: name,
                         subtitle: s.isProxySession ? "SOCKS не отвечает" : "Нет связи",
                         note: s.isProxySession
                             ? "SOCKS не отвечает \(waited) с — супервизор перезапустит прокси целиком."
                             : "Связи нет \(waited) с. openconnect восстанавливает сессию сам — вход не потребуется.",
                         showsTime: true, graph: true, graphActive: false, pulsing: true, details: true)
        case .paused:
            return .init(color: Palette.warn, title: name, subtitle: "На паузе",
                         note: "Маршруты и зоны сняты, туннель и сессия живы — возврат без входа.",
                         showsTime: true, graph: false, graphActive: false, pulsing: false, details: true)
        case .starting:
            return .init(color: Palette.warn, title: name, subtitle: "Подключается…", note: nil,
                         showsTime: false, graph: false, graphActive: false, pulsing: true, details: false)
        case .needsLogin:
            return .init(color: Palette.bad, title: name, subtitle: "Нужен вход",
                         note: "Сессия истекла, молча войти не удалось. Автоподключение остановлено — решение за вами.",
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .down:
            return .init(color: Palette.line2, title: name, subtitle: "Отключён", note: nil,
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .foreign:
            return .init(color: Palette.tertiary, title: "Чужой openconnect", subtitle: "поднят не через ocbar",
                         note: "Туннель поднят не через ocbar — он его не трогает.",
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        case .missing:
            return .init(color: Palette.bad, title: "ocbar не найден", subtitle: "нет клиента командной строки",
                         note: OcbarClient.shared.lookupNote.isEmpty
                             ? "Искал в /opt/homebrew/bin, /usr/local/bin и рядом с приложением. Путь можно задать переменной OCBAR_BIN."
                             : OcbarClient.shared.lookupNote,
                         showsTime: false, graph: false, graphActive: false, pulsing: false, details: false)
        }
    }
}
