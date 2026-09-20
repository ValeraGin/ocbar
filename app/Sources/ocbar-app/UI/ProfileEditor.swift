import SwiftUI

// Редактор профиля .ocbar. Проверка идёт перед сохранением теми же
// правилами, что и в клиенте: файл, который не примет bin/ocbar или
// libexec/ocbar-helper, здесь не сохранится.
//
// Файл профиля пишет не только редактор: разметка формы, «Запомнить, как я
// вхожу», `ocbar rules …`. Поэтому редактор помнит, что было на диске при
// открытии, перечитывает файл сам, если здесь нет правок, и перед записью
// спрашивает, если файл успел измениться, — молча затереть правила, которые
// только что записала разметка, хуже, чем спросить.
struct ProfileEditorView: View {
    @ObservedObject private var store = StatusStore.shared
    @State private var files: [String] = []
    @State private var legacy: [ProfileEntry] = []
    @State private var selected: String?
    @State private var doc = ProfileDoc()
    @State private var issues: [Issue] = []
    // Что лежит на диске, в том же виде, в каком редактор это запишет. Есть
    // ли правки — сравнением с ним, а не по событиям полей: onChange у полей
    // срабатывает и при загрузке профиля, и тогда любой открытый профиль
    // выглядел «несохранённым» — а разметка при правках была заблокирована.
    @State private var savedText: String?
    // Файл, из которого открыт профиль (nil — новый, файла ещё нет), и его
    // содержимое на момент открытия или последней записи.
    @State private var loadedName: String?
    @State private var disk: ProfileStore.DiskStamp?
    @State private var diskChanged = false          // файл поменялся снаружи, а здесь есть правки
    @State private var alert: EditorAlert?
    @State private var afterSave: (() -> Void)?     // что сделать после записи, отложенной вопросом
    private var dirty: Bool { savedText.map { $0 != Self.snapshot(doc) } ?? true }
    private static func snapshot(_ d: ProfileDoc) -> String { d.render(dated: Date(timeIntervalSince1970: 0)) }

    // Доступна ли разметка — одним выражением: его же видит самопроверка
    // (ocbar-app --selftest открывает редактор на настоящем окне). Кнопки
    // SwiftUI рисует сам, и снаружи их состояние не прочитать.
    // Разметка идёт через общий store: пока идёт любое действие (в том числе
    // разметка, запущенная из меню), вторую не запустить.
    private var learnDisabled: Bool { store.busy != nil || doc.fileName.trimmed.isEmpty || !errors.isEmpty }
    private var learning: Bool { store.busy?.hasPrefix("Идёт разметка") == true }
    static var probeLearnEnabled: Bool?
    // Для пробы: сколько раз редактор сверялся с диском и чем кончилась
    // последняя сверка — без этого провал «не перечитал» не объяснить.
    static var probeDiskChecks = 0
    static var probeDiskNote = ""
    @State private var message: String?
    @State private var showFile = false
    @State private var learnResult: String?
    // Редкое свёрнуто: наверху то, что нужно для входа.
    @State private var showNets = false
    @State private var showMore = false
    // Есть ли пароль и секрет кода в связке — `ocbar secret status --short`.
    @State private var secrets: [String: String] = [:]
    // Редактор разбит на три части, как вкладки профиля: вход, режим, сети.
    enum Segment: Int, CaseIterable { case connection, mode, networks
        var title: String { ["Подключение", "Режим", "Сети и DNS"][rawValue] }
    }
    // Витрина (--segment N) открывает нужную часть для снимка.
    @State private var segment: Segment = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--segment"), i + 1 < a.count, let n = Int(a[i + 1]),
           let v = Segment(rawValue: n) { return v }
        return .connection
    }()
    // Есть ли ocproxy — из `ocbar version --all`, в фоне.
    @State private var ocproxy: Bool?
    // Название и адрес каждого профиля — из его файла: список не должен ждать
    // ответа ocbar и показывать имена файлов вместо названий.
    @State private var heads: [String: (title: String, host: String)] = [:]
    // Имя файла нового профиля подставляется из названия, пока его не правили руками.
    @State private var autoFileName = ""

    private var errors: [Issue] { issues.filter { $0.level == .error } }

    enum Next { case file(String), new }
    enum EditorAlert {
        case unsaved(Next)
        case changedOnDisk
        case exists(String)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            editor.frame(minWidth: 520, maxWidth: .infinity)
        }
        .frame(minWidth: 760, minHeight: 540)
        .onAppear { reloadList(); loadVersions() }
        // Файл могли записать снаружи: ocbar rules из терминала, разметка,
        // запоминание входа. Время изменения дёшево — смотрим раз в две
        // секунды и сразу по завершении любого действия. Цикл в .task, а не
        // Timer.publish в onReceive: издатель, созданный в теле, пересоздаётся
        // при каждой отрисовке, и проба показала — сверка не шла ни разу.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                checkDisk()
            }
        }
        .onChange(of: store.finishedActions) { _ in checkDisk() }
        .onChange(of: loadedName) { _ in secrets = [:]; refreshSecrets() }
        .onChange(of: savedText) { _ in refreshSecrets() }
        .onChange(of: doc.name) { name in
            guard loadedName == nil, doc.fileName.isEmpty || doc.fileName == autoFileName else { return }
            let f = Self.slug(name)
            doc.fileName = f
            autoFileName = f
        }
        .alert(alertTitle, isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
               presenting: alert) { a in
            alertButtons(a)
        } message: { a in
            Text(alertMessage(a))
        }
    }

    // --- вопросы ---------------------------------------------------------

    private var alertTitle: String {
        switch alert {
        case .unsaved: return "Несохранённые правки в «\(doc.fileName.isEmpty ? "новый профиль" : doc.fileName)»"
        case .changedOnDisk: return "Файл профиля изменился на диске"
        case .exists(let name): return "Профиль «\(name)» уже есть"
        case .none: return ""
        }
    }

    private func alertMessage(_ a: EditorAlert) -> String {
        switch a {
        case .unsaved:
            return "Сохранить их, прежде чем открыть другой профиль?"
        case .changedOnDisk:
            return "Пока профиль был открыт, файл записали снаружи — разметка формы, «Запомнить, как я вхожу» или ocbar rules. «Перечитать» покажет файл с диска, правки здесь пропадут; «Перезаписать» запишет форму, и пропадёт то, что записали снаружи."
        case .exists(let name):
            return "Файл \(ProfileStore.path(name)) уже существует. Перезаписать его содержимым этой формы? Прошлая версия останется рядом с суффиксом .bak."
        }
    }

    @ViewBuilder
    private func alertButtons(_ a: EditorAlert) -> some View {
        switch a {
        case .unsaved(let next):
            Button("Сохранить") { save(then: { go(next) }) }
            Button("Не сохранять", role: .destructive) { go(next) }
            Button("Отмена", role: .cancel) {}
        case .changedOnDisk:
            Button("Перечитать") { afterSave = nil; if let name = loadedName { open(name) } }
            Button("Перезаписать", role: .destructive) { let next = afterSave; afterSave = nil; save(force: true, then: next) }
            Button("Отмена", role: .cancel) { afterSave = nil }
        case .exists:
            Button("Перезаписать", role: .destructive) { let next = afterSave; afterSave = nil; save(force: true, then: next) }
            Button("Отмена", role: .cancel) { afterSave = nil }
        }
    }

    // --- список слева ----------------------------------------------------

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Профили").font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            List(selection: $selected) {
                ForEach(files, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title(of: name)).font(.system(size: 13, weight: .medium))
                                .lineLimit(1).truncationMode(.tail)
                            if isConnected(name) {
                                Circle().fill(Palette.ok).frame(width: 7, height: 7)
                                    .accessibilityLabel("подключён")
                            }
                        }
                        Text(badge(of: name)).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.vertical, 4)
                    .tag(name)
                }
                // Порядок — перетаскиванием; тот же порядок в меню.
                .onMove { from, to in
                    files.move(fromOffsets: from, toOffset: to)
                    saveOrder()
                }
                if files.isEmpty {
                    Text("ни одного").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !legacy.isEmpty {
                    Section("Старый формат") {
                        ForEach(legacy) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.display).font(.system(size: 12))
                                Button("перевести в файл") { convert(p.name) }
                                    .buttonStyle(.link).font(.system(size: 11))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .help("Порядок профилей — перетаскиванием; тот же порядок в меню")
            .onChange(of: selected) { name in
                guard let name, name != loadedName else { return }
                // Правки не теряются молча: выбор возвращается на место, пока
                // человек не ответит.
                if dirty {
                    selected = loadedName
                    alert = .unsaved(.file(name))
                } else {
                    open(name)
                }
            }
            HStack(spacing: 6) {
                Button {
                    if dirty { alert = .unsaved(.new) } else { newDoc() }
                } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                    .help("Новый профиль")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: OcbarClient.shared.profileDir)])
                } label: { Image(systemName: "folder").frame(width: 22, height: 20) }
                    .help("Показать папку профилей")
                Spacer()
            }
            .buttonStyle(.bordered)
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func isConnected(_ name: String) -> Bool {
        store.status.profile == name && store.status.state != .down
    }

    // --- форма справа ----------------------------------------------------

    private var editor: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.name.trimmed.isEmpty ? (loadedName == nil ? "Новый профиль" : doc.fileName) : doc.name)
                            .font(.system(size: 20, weight: .semibold)).lineLimit(1)
                        Text(doc.url.trimmed.isEmpty ? "адрес не задан" : doc.url)
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    connectControl
                }
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
            Form {
                switch segment {
                case .connection: connectionSections
                case .mode: modeSections
                case .networks: networkSections
                }
            }
            .formStyle(.grouped)
            Divider()
            bottomBar
        }
    }

    // --- подключить / отключить этот профиль ------------------------------

    // Профиль выбирают здесь, а не в меню: обычно он один, а при нескольких
    // видно, что именно подключаешь. Меню подключает последний.
    @State private var switchAsk = false

    private var isActive: Bool {
        loadedName != nil && store.status.profile == loadedName && store.status.state != .down
    }

    private var otherActive: String? {
        let p = store.status.profile
        guard !p.isEmpty, store.status.state != .down, p != loadedName else { return nil }
        return store.status.profiles.first { $0.name == p }?.display ?? p
    }

    @ViewBuilder
    private var connectControl: some View {
        HStack(spacing: 8) {
            if let busy = store.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            if isActive {
                Label("Подключён", systemImage: "circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Palette.ok)
                    .labelStyle(TightLabel())
                Button("Отключить") { store.disconnect() }
            } else {
                Button("Подключить") {
                    if otherActive != nil { switchAsk = true } else { connectThis() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(loadedName == nil || dirty || store.busy != nil || OcbarClient.shared.binary == nil)
                .help(loadedName == nil || dirty ? "Сначала сохраните профиль" : "Подключиться этим профилем")
            }
        }
        .alert("Переключиться на «\(doc.name.trimmed.isEmpty ? doc.fileName : doc.name)»?", isPresented: $switchAsk) {
            Button("Переключиться") { connectThis() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сейчас подключён «\(otherActive ?? "")». Он отключится, для нового профиля потребуется вход.")
        }
    }

    private func connectThis() {
        guard let name = loadedName else { return }
        store.connect(profile: name)
    }

    // --- Подключение -----------------------------------------------------

    @ViewBuilder
    private var connectionSections: some View {
        Section("Подключение") {
            field("Название", $doc.name, hint: "как в меню")
            field("Описание", $doc.descr, hint: "вторая строка в меню")
            field("Адрес", $doc.url, hint: "vpn.example.com/группа")
            field("Пользователь", $doc.user)
        }
        Section {
            Picker("Как входить", selection: Binding(get: { doc.auth == "password" ? "password" : "" },
                                                     set: { doc.auth = $0; touched() })) {
                Text("SSO в окне браузера").tag("")
                Text("Пароль и код из SMS").tag("password")
            }
            sourceRow("Пароль", selection: $doc.password, options: ProfileDoc.passwordSources, status: passwordStatus)
            if doc.password == "command" {
                field("Команда для пароля", $doc.passwordCommand, hint: "op item get VPN --fields password")
            }
            if doc.auth != "password" {
                sourceRow("Одноразовый код", selection: $doc.totp, options: ProfileDoc.totpSources, status: totpStatus)
                if doc.totp == "command" { field("Команда для кода", $doc.totpCommand, hint: "op item get VPN --otp") }
            }
            if doc.totp == "keepassxc" || doc.password == "keepassxc" || !doc.keepassEntry.isEmpty {
                field("Запись KeePassXC", $doc.keepassEntry, hint: "Группа/Запись")
                field("База KeePassXC", $doc.keepassDb, hint: "~/Passwords.kdbx")
                field("Мастер-пароль в связке", $doc.keepassKeychain, hint: "имя сервиса в Keychain")
            }
        } header: {
            Text("Вход")
        } footer: {
            Footnote(doc.auth == "password"
                 ? "Пароль ocbar подставит сам, код из SMS спросит окном. Молча переподключиться такой профиль не может."
                 : doc.password == "ask" ? "Пароль вводит человек — молчаливое переподключение работать не будет."
                 : "Секреты хранятся вне профиля: в связке ключей или в KeePassXC.")
        }
        if doc.auth != "password" {
            Section {
                learnBlock
            } header: { Text("Форма входа") }
        }
        Section {
            DisclosureGroup(isExpanded: $showMore) {
                field("Имя файла", $doc.fileName, hint: "имя.ocbar в ~/.config/ocbar/profiles")
                userAgentField
                field("CsdWrapper", $doc.csdWrapper, hint: "если шлюз просит проверку соответствия")
                if ["auto", "keychain"].contains(doc.totp) || doc.totpAlgorithm != "SHA1"
                    || doc.totpDigits != "6" || doc.totpPeriod != "30" {
                    totpParamsRow
                }
                field("Сервис в связке ключей", $doc.keychainService, hint: "ru.ocbar.client")
                field("Хосты провайдера входа", $doc.idpHosts, hint: "пусто — только цепочка от шлюза")
                field("Проверка доступа", $doc.health, hint: "URL, хост:порт или имя")
                rulesEditor
                Toggle("Показать файл, как он будет записан", isOn: $showFile)
                if showFile {
                    Text(doc.render())
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                }
            } label: {
                HStack {
                    Text("Дополнительно")
                    Spacer()
                    Text("User-Agent, MTU, DTLS, CSD, правила").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // --- Режим -----------------------------------------------------------

    @ViewBuilder
    private var modeSections: some View {
        Section {
            // Обе карточки — одной высоты: по более высокой.
            HStack(alignment: .top, spacing: 12) {
                modeCard("tunnel", "Туннель", symbol: "point.3.connected.trianglepath.dotted",
                         lines: ["Маршруты и DNS", "Нужен системный помощник"])
                modeCard("proxy", "Прокси SOCKS", symbol: "arrow.left.arrow.right",
                         lines: ["Для программ с поддержкой SOCKS",
                                 ocproxy == false ? "Нужен ocproxy: brew install ocproxy" : "Без прав администратора"])
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        } header: {
            Text("Режим подключения")
        } footer: {
            Footnote("Режим — свойство профиля: новый режим начнёт действовать со следующего подключения.")
        }
        if doc.mode == "proxy" {
            Section {
                LabeledContent("Порт") {
                    HStack(spacing: 8) {
                        if doc.proxyPort.trimmed == "10808" {
                            Text("порт v2ray/Xray — часто занят").font(.system(size: 11)).foregroundStyle(Palette.warn)
                        }
                        TextField("", text: $doc.proxyPort, prompt: Text("11080"))
                            .labelsHidden().font(.ocMono).frame(width: 90)
                            .onChange(of: doc.proxyPort) { _ in touched() }
                    }
                }
                Toggle("Включать системный SOCKS", isOn: $doc.systemProxy)
                    .onChange(of: doc.systemProxy) { _ in touched() }
            } header: {
                Text("Параметры SOCKS")
            } footer: {
                Footnote(doc.systemProxy
                     ? "Прокси ставится на активную сетевую службу и снимается при отключении. Чужой SOCKS ocbar не перезаписывает."
                     : "Система не трогается: SOCKS 127.0.0.1:\(doc.proxyPort) указывают тем программам, которым он нужен.")
            }
            Section {
                Label("Сети и DNS применяются только в режиме «Туннель».", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func modeCard(_ value: String, _ title: String, symbol: String, lines: [String]) -> some View {
        let on = doc.mode == value
        return Button {
            doc.mode = value; touched()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(on ? Palette.accent : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    ForEach(lines, id: \.self) {
                        Text($0).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundStyle(on ? Palette.accent : Color.secondary.opacity(0.6))
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Palette.accent.opacity(0.12) : Palette.group))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? Palette.accent : Palette.groupLine, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func loadVersions() {
        DispatchQueue.global(qos: .utility).async {
            let v = OcbarClient.shared.versions(maxAge: 300)
            DispatchQueue.main.async { ocproxy = v.isEmpty ? nil : v["ocproxy_path"] != nil }
        }
    }

    // --- Сети и DNS ------------------------------------------------------

    @ViewBuilder
    private var networkSections: some View {
        // Кнопка «Добавить» и пояснение — строками внутри группы: в подвале
        // формы кнопка вставала рядом с текстом.
        Section("Сети в туннеле") {
            routesEditor
            Footnote("Что не попало в список, идёт мимо туннеля. «Всё в туннель» — 0.0.0.0/1 и 128.0.0.0/1.")
        }
        Section("DNS-зоны") {
            zonesEditor
            Footnote("«vpn» вместо адреса — резолвер, который прислал шлюз. Более длинная зона перебивает короткую.")
        }
    }

    // Разметка формы: встроенные правила покрывают типовые порталы
    // (Keycloak, Microsoft), а чужую форму человек показывает мышью сам.
    // Результат живёт в самом профиле (секция [Autofill]) и правится здесь же.
    private var learnBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let _ = { Self.probeLearnEnabled = !learnDisabled }()
                Text(rulesSummary).font(.system(size: 12)).foregroundStyle(Palette.text)
                Spacer()
                if learning {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Button("Отменить") { store.cancelCurrent() }.buttonStyle(.link).font(.system(size: 11))
                }
                Button(learning ? "Идёт разметка…" : "Разметить…") { learn() }
                    .disabled(learnDisabled)
            }
            Text(learnHint)
                .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let learnResult {
                Text(learnResult)
                    .font(.system(size: 11)).foregroundStyle(learnResult.hasPrefix("не получилось") ? Palette.bad : Palette.ok)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Сами правила — для тех, кто правит руками; обычно их пишет разметка.
    private var rulesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Правила формы").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            TextEditor(text: Binding(
                get: { doc.autofill.joined(separator: "\n") },
                set: { doc.autofill = $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init); touched() }))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
            Text("По строке: stop <селектор> · fill username|password|totp <селектор> · click <селектор> · click! <селектор>. Строки «# шаг N — …» — заголовки окон формы, их пишет разметка; строки с «#» и «;» — комментарии. Пусто — действует общий файл или встроенные.")
                .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            field("Общий файл правил", $doc.rulesFile,
                  hint: "необязательно: путь к файлу на несколько профилей; при заполненных правилах выше не читается")
        }
    }

    /// Что делает форма входа, словами: «2 окна: логин+пароль → код».
    private var rulesSummary: String {
        let lines = doc.autofill.map { $0.trimmed }.filter { !$0.isEmpty }
        guard lines.contains(where: { !ProfileDoc.isComment($0) }) else {
            if !doc.rulesFile.trimmed.isEmpty { return "правила из общего файла" }
            return FileManager.default.fileExists(atPath: rulesPath) ? "правила из autofill.rules" : "встроенные правила"
        }
        let names = ["username": "логин", "password": "пароль", "totp": "код", "manual": "вручную"]
        var steps: [[String]] = [[]]
        for line in lines {
            if line.hasPrefix("# шаг") { if !(steps.last ?? []).isEmpty { steps.append([]) }; continue }
            if ProfileDoc.isComment(line) { continue }
            let w = line.split(separator: " ").map(String.init)
            if w.first == "fill", w.count > 1 {
                let k = names[w[1]] ?? w[1]
                if !steps[steps.count - 1].contains(k) { steps[steps.count - 1].append(k) }
            }
        }
        let parts = steps.map { $0.joined(separator: "+") }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "\(lines.count) правил в профиле" }
        let n = parts.count
        let word = n == 1 ? "окно" : (2...4).contains(n) ? "окна" : "окон"
        return "\(n) \(word): " + parts.joined(separator: " → ")
    }

    private var netsSummary: String {
        let nets = doc.routes.compactMap { ProfileDoc.routeNet($0) }.count
        let zones = doc.zones.filter { !$0.zone.trimmed.isEmpty }.count
        return "\(nets) сет\(nets % 10 == 1 && nets % 100 != 11 ? "ь" : (2...4).contains(nets % 10) && !(12...14).contains(nets % 100) ? "и" : "ей") · \(zones) зон\(zones % 10 == 1 && zones % 100 != 11 ? "а" : (2...4).contains(zones % 10) && !(12...14).contains(zones % 100) ? "ы" : "")"
    }

    private var passwordStatus: (String, Color)? {
        guard !dirty, let v = secrets["password"] else { return nil }
        switch v {
        case "keychain ok": return ("сохранён в связке ключей", Palette.ok)
        case "keychain missing": return ("не сохранён — ocbar предложит сохранить после входа", Palette.warn)
        default: return nil
        }
    }

    private var totpStatus: (String, Color)? {
        guard !dirty, let v = secrets["totp"] else { return nil }
        switch v {
        case "keychain ok": return ("секрет в связке ключей", Palette.ok)
        case "keychain missing": return ("источник кода не настроен — «Подключить и запомнить вход…»", Palette.warn)
        default: return nil
        }
    }

    private var learnHint: String {
        if doc.fileName.trimmed.isEmpty { return "Укажите имя файла профиля — размечать нужно его форму входа." }
        if !errors.isEmpty { return "В профиле ошибки (внизу окна) — исправьте, и разметка станет доступна." }
        if let busy = store.busy, !learning { return "Сейчас идёт «\(busy)» — разметка станет доступна, когда оно закончится." }
        if !fileExists || dirty { return "Профиль сначала сохранится — разметка идёт по его адресу, а правила ложатся в сам файл." }
        return "Откроется форма входа портала: отметьте мышью поля и кнопку, правила запишутся в профиль. Форма в несколько окон — «Пройти шаг →»."
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: ProfileStore.path(doc.fileName))
    }

    private var rulesPath: String {
        let raw = doc.rulesFile.trimmed
        if raw.isEmpty { return OcbarClient.shared.configDir + "/autofill.rules" }
        return (raw as NSString).expandingTildeInPath
    }

    private func learn() {
        guard store.busy == nil else { return }
        // Разметка идёт по адресу из файла и пишет правила в файл — значит,
        // сначала файл должен совпадать с тем, что на экране.
        if dirty || !fileExists { save(then: { startLearn() }); return }
        startLearn()
    }

    private func startLearn() {
        guard !dirty, fileExists else { return }
        learnResult = nil
        let name = doc.fileName
        // Через store: там флаг занятости, одна разметка на всё приложение, и
        // её видно (и можно отменить) из меню.
        store.learn(profile: name) { result in
            // Правила легли в файл профиля — перечитать его, чтобы редактор
            // показывал то, что на диске.
            if loadedName == name, !dirty { open(name) } else { checkDisk() }
            switch result {
            case .ok(let text):
                learnResult = text.contains("отменена") ? "разметка отменена — профиль не тронут"
                    : "правила записаны в профиль: \(doc.autofill.filter { !ProfileDoc.isComment($0.trimmed) }.count) строк"
            case .needsLogin, .cancelled:
                learnResult = "разметка не завершена"
            case .failed(_, let text):
                learnResult = "не получилось: " + text
            }
        }
    }

    // Параметры кода для секрета в связке ключей: ocbar пишет их сам при
    // импорте QR и после «Запомнить, как я вхожу»; руками — редко.
    private var totpParamsRow: some View {
        LabeledContent("Параметры кода") {
            HStack(spacing: 6) {
                Picker("", selection: $doc.totpAlgorithm) {
                    ForEach(ProfileDoc.totpAlgorithms, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: doc.totpAlgorithm) { _ in touched() }
                Picker("", selection: $doc.totpDigits) {
                    ForEach(["6", "7", "8"], id: \.self) { Text("\($0) цифр").tag($0) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: doc.totpDigits) { _ in touched() }
                TextField("", text: $doc.totpPeriod, prompt: Text("30"))
                    .labelsHidden().frame(width: 44)
                    .onChange(of: doc.totpPeriod) { _ in touched() }
                Text("с").foregroundStyle(.secondary)
            }
        }
    }

    private var userAgentField: some View {
        LabeledContent("User-Agent") {
            HStack(spacing: 6) {
                TextField("", text: $doc.userAgent, prompt: Text(ProfileDoc.defaultUserAgent))
                    .labelsHidden()
                    .onChange(of: doc.userAgent) { _ in touched() }
                Menu {
                    ForEach(ProfileDoc.knownUserAgents, id: \.self) { ua in
                        Button(ua) { doc.userAgent = ua; touched() }
                    }
                } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Строки известных клиентов: шлюзы иногда придираются к User-Agent")
            }
        }
    }

    // Строка сети — как в файле: сеть первым словом, после неё может быть
    // комментарий; строка с «#» или «;» — комментарий целиком.
    private var routesEditor: some View {
        Group {
            ForEach(doc.routes.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("", text: Binding(
                        get: { i < doc.routes.count ? doc.routes[i] : "" },
                        set: { if i < doc.routes.count { doc.routes[i] = $0; touched() } }),
                        prompt: Text("10.0.0.0/8"))
                        .labelsHidden().font(.ocMono).frame(maxWidth: 240)
                    let line = i < doc.routes.count ? doc.routes[i] : ""
                    if let net = ProfileDoc.routeNet(line) {
                        if !ProfileCheck.validCIDR(net) {
                            Text("не CIDR").font(.system(size: 11)).foregroundStyle(Palette.bad)
                        } else if let len = ProfileCheck.prefixLength(net), len < 8 {
                            Text("уводит почти весь трафик").font(.system(size: 11)).foregroundStyle(Palette.warn)
                        }
                    } else if !line.trimmed.isEmpty {
                        Text("комментарий").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { doc.routes.remove(at: i); touched() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Убрать сеть")
                }
            }
            Button { doc.routes.append(""); touched() } label: { Label("Добавить сеть", systemImage: "plus") }
                .buttonStyle(.borderless)
        }
    }

    private var zonesEditor: some View {
        Group {
            ForEach(doc.zones.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("", text: Binding(
                        get: { i < doc.zones.count ? doc.zones[i].zone : "" },
                        set: { if i < doc.zones.count { doc.zones[i].zone = $0; touched() } }),
                        prompt: Text("example.com"))
                        .labelsHidden().font(.ocMono).frame(maxWidth: 240)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("", text: Binding(
                        get: { i < doc.zones.count ? doc.zones[i].resolver : "" },
                        set: { if i < doc.zones.count { doc.zones[i].resolver = $0; touched() } }),
                        prompt: Text("10.0.0.1 или vpn"))
                        .labelsHidden().font(.ocMono).frame(maxWidth: 150)
                    Spacer()
                    Button { doc.zones.remove(at: i); touched() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Убрать зону")
                }
            }
            Button { doc.zones.append(ZoneLine(zone: "", resolver: "vpn", port: "")); touched() } label: {
                Label("Добавить зону", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if diskChanged {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Palette.warn)
                    Text("Файл изменился на диске, пока здесь есть правки: сохранение спросит, что оставить.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Перечитать") { if let name = loadedName { open(name) } }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: issue.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(issue.level == .error ? Palette.bad : Palette.warn)
                            Text(issue.text).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(Palette.ok)
            }
            HStack(spacing: 10) {
                if issues.isEmpty {
                    Label("Профиль без ошибок", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Palette.ok)
                }
                Spacer()
                // «Отменить» возвращает то, что лежит в файле.
                Button("Отменить") { if let name = loadedName { open(name) } else { newDoc() } }
                    .disabled(!dirty)
                Button("Сохранить") { save() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!errors.isEmpty || doc.fileName.trimmed.isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // --- служебное -------------------------------------------------------

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
            content()
        }
    }

    // Строка формы: подпись слева, поле справа; подсказка — серым текстом в
    // пустом поле, а не отдельной строкой под ним.
    private func field(_ label: String, _ text: Binding<String>, hint: String = "") -> some View {
        LabeledContent(label) {
            // Рамка поля — видно, что значение правится, а не просто показано.
            TextField("", text: text, prompt: hint.isEmpty ? nil : Text(hint))
                .labelsHidden().textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 340)
                .onChange(of: text.wrappedValue) { _ in touched() }
        }
    }

    private func title(of name: String) -> String {
        if let t = heads[name]?.title, !t.isEmpty { return t }
        return store.status.profiles.first { $0.name == name }?.display ?? name
    }

    private func badge(of name: String) -> String {
        let s = store.status
        var parts: [String] = []
        if s.defaultProfile == name { parts.append("по умолчанию") }
        let host = heads[name]?.host ?? s.profiles.first { $0.name == name }?.address ?? ""
        parts.append(host.isEmpty ? name + ".ocbar" : host)
        return parts.joined(separator: " · ")
    }

    private func sourceRow(_ label: String, selection: Binding<String>, options: [String],
                           status: (String, Color)?) -> some View {
        LabeledContent {
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text(Self.sourceTitle($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            .onChange(of: selection.wrappedValue) { _ in touched() }
        } label: {
            Text(label)
            // Есть ли секрет в связке — второй строкой под подписью.
            if let status {
                Text(status.0).font(.system(size: 11)).foregroundStyle(status.1)
                    .textSelection(.enabled)
            }
        }
    }

    static func sourceTitle(_ v: String) -> String {
        switch v {
        case "auto": return "авто"
        case "keychain": return "связка ключей"
        case "keepassxc": return "KeePassXC"
        case "command": return "своя команда"
        case "ask": return "вводит человек"
        case "sms": return "SMS — вводит человек"
        case "off": return "не вводить"
        default: return v
        }
    }

    private func disclosure<C: View>(_ title: String, summary: String, isOn: Binding<Bool>,
                                     @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { isOn.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOn.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).frame(width: 10)
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                    if !isOn.wrappedValue {
                        Text(summary).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOn.wrappedValue { content() }
        }
    }

    /// Имя файла из названия: латиница, цифры и дефис.
    static func slug(_ text: String) -> String {
        let map: [Character: String] = ["а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
            "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
            "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts", "ч": "ch",
            "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"]
        var out = ""
        for ch in text.lowercased() {
            if let t = map[ch] { out += t }
            else if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) }
            else if !out.isEmpty, !out.hasSuffix("-") { out += "-" }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // Порядок пишет bin/ocbar (profiles.order) — один писатель на файл; меню
    // берёт порядок из `ocbar status --short` и обновится после записи.
    private func saveOrder() {
        let names = files + legacy.map { $0.name }.filter { !files.contains($0) }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = OcbarClient.shared.action(["profiles", "order"] + names, timeout: 10)
            DispatchQueue.main.async {
                if case .failed(_, let text) = r { message = "порядок не сохранён: " + text }
                store.refresh()
            }
        }
    }

    private func refreshSecrets() {
        guard let name = loadedName else { secrets = [:]; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = OcbarClient.shared.secretStatus(profile: name)
            DispatchQueue.main.async { if loadedName == name { secrets = r } }
        }
    }

    private func touched() {
        message = nil
        issues = ProfileCheck.check(doc)
    }

    // Открыть профиль из файла и запомнить, что было на диске.
    private func open(_ name: String) {
        let stamp = ProfileStore.stamp(name)
        let fresh = stamp.text.map { ProfileDoc.parse($0, fileName: name) } ?? ProfileDoc(fileName: name)
        loadedName = stamp.text == nil ? nil : name
        disk = stamp.text == nil ? nil : stamp
        doc = fresh
        savedText = stamp.text == nil ? nil : Self.snapshot(fresh)
        issues = ProfileCheck.check(fresh)
        diskChanged = false
        message = nil
        learnResult = nil
        selected = name
    }

    private func newDoc() {
        doc = ProfileDoc(fileName: "", userAgent: ProfileDoc.defaultUserAgent)
        loadedName = nil
        disk = nil
        selected = nil
        // Пустая форма — ещё не правка: переход к другому профилю не спрашивает.
        savedText = Self.snapshot(doc)
        issues = ProfileCheck.check(doc)
        diskChanged = false
        message = nil
        learnResult = nil
    }

    private func go(_ next: Next) {
        switch next {
        case .file(let name): open(name)
        case .new: newDoc()
        }
    }

    // Файл открытого профиля поменялся снаружи? Без правок здесь — просто
    // перечитать; с правками — предупредить, сохранение спросит.
    private func checkDisk() {
        Self.probeDiskChecks += 1
        guard let name = loadedName, let known = disk else { Self.probeDiskNote = "нет открытого файла"; return }
        let m = ProfileStore.mtime(name)
        if m != nil, m == known.mtime { Self.probeDiskNote = "время не изменилось"; return }
        let now = ProfileStore.stamp(name)
        if now == known { disk = now; Self.probeDiskNote = "текст тот же"; return }
        Self.probeDiskNote = dirty ? "изменён, есть правки" : "изменён, перечитан"
        if now.text == nil {
            loadedName = nil
            disk = nil
            files = ProfileStore.list()
            message = "файл профиля удалён на диске — «Сохранить» запишет его заново"
            return
        }
        if dirty {
            diskChanged = true
        } else {
            open(name)
            message = "файл изменился на диске — перечитан"
        }
    }

    private func reloadHeads() {
        var h: [String: (title: String, host: String)] = [:]
        for name in files {
            guard let d = ProfileStore.load(name) else { continue }
            let host = ProfileEntry(name: name, title: d.name, auth: d.auth, descr: d.descr, url: d.url).address
            h[name] = (d.name, host)
        }
        heads = h
    }

    private func reloadList() {
        files = ProfileStore.list()
        reloadHeads()
        reloadLegacy()
        if selected == nil, loadedName == nil, let first = files.first {
            open(first)
        }
    }

    // Профили из profiles.conf — из `ocbar status`, в фоне: вызов идёт
    // до секунды-двух, и окно не должно подвисать на это время.
    private func reloadLegacy() {
        DispatchQueue.global(qos: .userInitiated).async {
            let profiles = OcbarClient.shared.status().profiles
            DispatchQueue.main.async {
                legacy = profiles.filter { !files.contains($0.name) }
            }
        }
    }

    private func save(force: Bool = false, then next: (() -> Void)? = nil) {
        issues = ProfileCheck.check(doc)
        guard errors.isEmpty else { return }
        let name = doc.fileName
        if !force {
            // «+» с именем существующего файла или переименование в чужое имя.
            if name != loadedName, FileManager.default.fileExists(atPath: ProfileStore.path(name)) {
                afterSave = next
                alert = .exists(name)
                return
            }
            // Файл записали снаружи после открытия — не затирать молча.
            if name == loadedName, let known = disk, ProfileStore.stamp(name) != known {
                afterSave = next
                alert = .changedOnDisk
                return
            }
        }
        // Последнее слово — за клиентом: он читает профиль при подключении,
        // и его отказ здесь дешевле, чем «не подключается» потом.
        if let why = OcbarClient.shared.profileRejection(doc.render(), name: name) {
            issues.append(Issue(level: .error, text: "клиент не принимает профиль: " + why))
            return
        }
        if let error = ProfileStore.save(doc) {
            issues.append(Issue(level: .error, text: "не удалось записать: \(error)"))
            return
        }
        loadedName = name
        disk = ProfileStore.stamp(name)
        savedText = Self.snapshot(doc)
        diskChanged = false
        files = ProfileStore.list()
        reloadHeads()
        selected = name
        reloadLegacy()
        // Проверяем не своими глазами, а клиентом: профиль должен появиться
        // в его списке — значит файл разобран. В фоне: это вызов ocbar.
        message = "сохранено"
        DispatchQueue.global(qos: .userInitiated).async {
            let seen = OcbarClient.shared.status().profiles.contains { $0.name == name }
            DispatchQueue.main.async {
                guard loadedName == name else { return }
                message = seen
                    ? "сохранено, ocbar видит профиль «\(name)»"
                    : "файл записан, но ocbar профиль не показывает — проверьте ocbar profiles"
            }
        }
        next?()
    }

    // Перевод старого профиля в файл — командой самого клиента, чтобы формат
    // не разошёлся. После этого ocbar читает профиль из файла, а не из
    // profiles.conf: это и есть смысл перевода.
    private func convert(_ name: String) {
        let target = ProfileStore.path(name)
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(atPath: OcbarClient.shared.profileDir,
                                                     withIntermediateDirectories: true)
            let result = OcbarClient.shared.action(["export", name, target], timeout: 20)
            DispatchQueue.main.async {
                switch result {
                case .ok:
                    files = ProfileStore.list()
                    reloadLegacy()
                    if dirty { alert = .unsaved(.file(name)) } else { open(name) }
                    message = "профиль \(name) переведён в файл — теперь ocbar читает его оттуда"
                case .needsLogin, .cancelled:
                    message = nil
                case .failed(_, let text):
                    issues = [Issue(level: .error, text: "перевод не удался: \(text)")]
                }
            }
        }
    }
}
