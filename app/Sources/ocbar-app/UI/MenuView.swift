import SwiftUI

// Свёрнутое меню: состояние, профиль, время, график трафика, действия.
// Подробности разворачиваются здесь же — отдельного окна для них не нужно.
struct MenuView: View {
    @EnvironmentObject var store: StatusStore
    @ObservedObject private var notify = NotifyState.shared
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
                .onAppear { if !CommandLine.arguments.contains("--stage") { Notifier.refreshAllowed() } }
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
            if !notify.allowed {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash").font(.system(size: 10))
                    Text("Уведомления выключены").font(.ocNote)
                    Spacer()
                    Button("Разрешить") { Notifier.openSettings() }
                        .buttonStyle(.link).font(.ocNote)
                }
                .foregroundStyle(Palette.warn)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.warn.opacity(0.12)))
                .padding(.horizontal, 13).padding(.top, 6)
            }
            if s.access == "fail", s.presentation == .connected {
                Text("Туннель поднят, но проверка доступа не проходит: шлюз может не пускать к этому ресурсу или не хватает сети в профиле.")
                    .font(.ocNote).foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Text(Self.human(message))
                        .font(.ocNote)
                        .foregroundStyle(store.actionFailed || store.actionNote == nil ? Palette.bad : Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    // Ошибке нужна не только причина, но и следующий шаг:
                    // команду с sudo приложение выполнить не может, но может
                    // положить её в буфер обмена.
                    if let fix = Self.fix(for: message) {
                        Button(fix.title) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fix.command, forType: .string)
                        }
                        .buttonStyle(.link).font(.ocNote)
                        .help("Скопировать: " + fix.command)
                    } else if store.actionFailed || store.actionNote == nil {
                        Button("Журнал") { open(WindowID.logs) }
                            .buttonStyle(.link).font(.ocNote)
                    }
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
            Button("") { open(WindowID.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    // --- шапка -----------------------------------------------------------

    private var header: some View {
        HStack(spacing: 9) {
            StateDot(color: look.color, pulsing: look.pulsing)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(look.title).font(.ocTitle).foregroundStyle(Palette.text)
                        .lineLimit(1).truncationMode(.tail)
                    if s.isProxySession {
                        Text("прокси").font(.system(size: 10))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.accent.opacity(0.18)))
                            .foregroundStyle(Palette.accent)
                    }
                }
                Text(look.showsTime ? "\(look.subtitle) · \(humanSince(s.since))" : look.subtitle)
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            // Индикатор занятости живёт в шапке, а не вместо строк действий:
            // подмена строк меняла высоту меню, и оно прыгало под курсором.
            if store.busy != nil {
                ProgressView().controlSize(.small).scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            }
            // Главный выключатель — самое частое действие одним нажатием.
            // Выключить можно всегда (посреди входа это отмена), включить —
            // когда ничего не идёт.
            if let on = switchOn {
                Toggle("", isOn: Binding(get: { on }, set: { flip($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Palette.ok)
                    .disabled(!on && !(idle && OcbarClient.shared.binary != nil))
                    .accessibilityLabel(on ? "Отключить" : "Подключить")
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

    // Пока идёт действие, строки недоступны — кроме отключения и отмены:
    // вход и разметка ждут человека минутами, и «Отключить» в это время
    // должно работать (store отменит текущее действие и отключится).
    private var idle: Bool { store.busy == nil }

    private var hasDisconnectRow: Bool {
        switch s.presentation {
        case .connected, .lost, .paused, .starting, .needsLogin: return true
        default: return false
        }
    }

    private var actions: some View { actionRows }

    @ViewBuilder
    private var actionRows: some View {
        Group {
            if let title = store.cancelTitle, !(store.cancelDisconnects && hasDisconnectRow) {
                MenuRow(action: { store.cancelCurrent() }) {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Text(store.busy ?? "").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            switch s.presentation {
            case .connected, .lost:
                // В прокси-режиме паузы нет: снаружи туннеля ничего не
                // изменено, снимать нечего — ocbar так и ответит.
                if !s.isProxySession {
                    MenuRow(enabled: idle, action: { store.pause() }) {
                        Text("Приостановить")
                        Spacer()
                        if GlobalHotkeys.shared.isRegistered("pause") {
                            Text("⌥⌘P").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                        }
                    }
                }
            case .paused:
                MenuRow(enabled: idle, action: { store.resume() }) {
                    Text("Возобновить").fontWeight(.medium)
                    Spacer()
                    if GlobalHotkeys.shared.isRegistered("pause") {
                        Text("⌥⌘P").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                    }
                }
            case .starting:
                MenuRow(action: { store.disconnect() }) { Text("Отменить подключение") }
            case .needsLogin:
                // Человек нажал сам — окно входа должно появиться сразу, а не
                // после двухсекундной пробы молчаливого прохода.
                MenuRow(enabled: idle, action: { store.connect(profile: s.profile.isEmpty ? nil : s.profile, show: true) }) {
                    Text("Войти").fontWeight(.medium)
                }
                MenuRow(enabled: idle, action: { store.connect(profile: s.profile.isEmpty ? nil : s.profile, teach: true) }) {
                    Text("Войти и запомнить вход…")
                }
                MenuRow(action: { store.disconnect() }) { Text("Не подключаться") }
            case .down, .foreign:
                let target = s.defaultProfile.isEmpty ? nil : s.defaultProfile
                // Отключённому хватает выключателя в шапке; при чужом туннеле
                // выключателя нет — подключиться можно отсюда.
                if s.presentation == .foreign {
                    MenuRow(enabled: idle && OcbarClient.shared.binary != nil, action: { store.connect(profile: target) }) {
                        Text(target.map { name in
                            "Подключить · " + (s.profiles.first { $0.name == name }?.display ?? name)
                        } ?? "Подключить")
                    }
                }
                // Первый вход: человек входит руками, ocbar запоминает форму и
                // предлагает сохранить пароль и источник кода.
                MenuRow(enabled: idle && OcbarClient.shared.binary != nil, action: { store.connect(profile: target, teach: true) }) {
                    Text("Подключить и запомнить вход…")
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
                MenuRow(action: { open(WindowID.setup) }) {
                    Text("Настроить ocbar…")
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
                Text("Профиль")
                Spacer()
                Text(StateLook.profileName(s)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: showProfiles ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(Palette.tertiary)
            }
            if showProfiles {
                // Восемь профилей вместе с подробностями не влезают на экран
                // 13" — список прокручивается, а не растягивает меню.
                BoundedScroll(maxHeight: 210) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(s.profiles) { p in
                            MenuRow(enabled: idle && !p.isPassword, action: { choose(p) }) {
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
                Text(s.isProxySession ? "SOCKS и туннель" : "Сети и DNS")
                Spacer()
                if !s.isProxySession {
                    Text("\(s.routesOn.count)/\(s.routes.count) · \(s.zones.filter { $0.enabled }.count)/\(s.zones.count)")
                        .font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                }
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
            KVRow(label: "Доступ",
                  value: s.access == "ok" ? "проверен\(s.accessAt.map { " в " + Self.clock.string(from: $0) } ?? "")"
                       : s.access == "fail" ? "не отвечает" : "не проверялся",
                  color: s.access == "fail" ? Palette.bad : Palette.text)
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
            // Сеть и супервизор — в окне диагностики; здесь только то, что
            // требует внимания.
            if s.available, !s.supervisor {
                Text("Супервизор не запущен — автоподключения не будет.")
                    .font(.ocNote).foregroundStyle(Palette.warn)
                    .padding(.horizontal, 13).padding(.bottom, 3)
            }
            if s.available, s.profiles.isEmpty {
                MenuRow(action: { open(WindowID.setup) }) { Text("Первый запуск…") }
            }
            MenuRow(action: { open(WindowID.settings) }) {
                Text("Настройки…")
                Spacer()
                Text("⌘,").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
            }
            // Разметка формы входа — в окне профиля: там видно, куда лягут правила.
            MenuRow(action: { open(WindowID.diagnostics) }) { Text("Диагностика и журналы…") }
            // Только в режиме разработчика (ocbar app devmode on): войти с
            // нуля, с формой. Обычному пользователю живая сессия — удобство.
            if UserDefaults.standard.bool(forKey: "DeveloperMode"), !CommandLine.arguments.contains("--stage") {
                MenuRow(enabled: idle && OcbarClient.shared.binary != nil, action: { store.logout() }) {
                    Text("Выйти совсем (сброс входа)")
                    Spacer()
                    Text("dev").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                }
            }
            MenuRow(action: { NSApplication.shared.terminate(nil) }) {
                Text(hasDisconnectRow ? "Выйти из ocbar (туннель останется)" : "Выйти из ocbar")
                Spacer()
                Text("⌘Q").font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
            }
        }
    }
}

// Окна открываются поверх: приложение живёт значком в меню-баре, и без
// явной активации окно уходит за чужие.
extension MenuView {
    /// Выключатель в шапке: nil — не показывать (чужой туннель, нет ocbar).
    private var switchOn: Bool? {
        switch s.presentation {
        case .connected, .lost, .paused, .starting: return true
        case .needsLogin, .down: return false
        case .foreign, .missing: return nil
        }
    }
    private func flip(_ on: Bool) {
        if on {
            let name = s.profile.isEmpty ? s.defaultProfile : s.profile
            // «Нужен вход»: человек включил сам — окно входа сразу.
            store.connect(profile: name.isEmpty ? nil : name, show: s.presentation == .needsLogin)
        } else {
            store.disconnect()
        }
    }
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
