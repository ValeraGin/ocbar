import SwiftUI

// Редактор профиля .ocbar. Проверка идёт перед сохранением теми же
// правилами, что и в клиенте: файл, который не примет bin/ocbar или
// libexec/ocbar-helper, здесь не сохранится.
struct ProfileEditorView: View {
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
    private var dirty: Bool { savedText.map { $0 != Self.snapshot(doc) } ?? true }
    private static func snapshot(_ d: ProfileDoc) -> String { d.render(dated: Date(timeIntervalSince1970: 0)) }

    // Доступна ли разметка — одним выражением: его же видит самопроверка
    // (ocbar-app --selftest открывает редактор на настоящем окне). Кнопки
    // SwiftUI рисует сам, и снаружи их состояние не прочитать.
    private var learnDisabled: Bool { learning || doc.fileName.trimmed.isEmpty || !errors.isEmpty }
    static var probeLearnEnabled: Bool?
    @State private var message: String?
    @State private var showFile = false
    @State private var learning = false
    @State private var learnResult: String?

    private var errors: [Issue] { issues.filter { $0.level == .error } }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 210, maxWidth: 280)
            editor.frame(minWidth: 480)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { reloadList() }
    }

    // --- список слева ----------------------------------------------------

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selected) {
                Section("Файлы-профили") {
                    ForEach(files, id: \.self) { name in
                        Text(name).font(.system(size: 12)).tag(name)
                    }
                    if files.isEmpty {
                        Text("ни одного").font(.ocNote).foregroundStyle(Palette.tertiary)
                    }
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
            .onChange(of: selected) { name in
                guard let name else { return }
                doc = ProfileStore.load(name) ?? ProfileDoc(fileName: name)
                issues = ProfileCheck.check(doc)
                savedText = ProfileStore.load(name).map(Self.snapshot)
                message = nil
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    doc = ProfileDoc(fileName: "", userAgent: ProfileDoc.defaultUserAgent)
                    selected = nil; savedText = nil; issues = ProfileCheck.check(doc)
                } label: { Image(systemName: "plus") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: OcbarClient.shared.profileDir)])
                } label: { Image(systemName: "folder") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    // --- форма справа ----------------------------------------------------

    private var editor: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Подключение") {
                        field("Имя файла", $doc.fileName, hint: "профиль будет ~/.config/ocbar/profiles/\(doc.fileName.isEmpty ? "имя" : doc.fileName).ocbar")
                        field("Название", $doc.name, hint: "как показывать в меню")
                        field("Описание", $doc.descr)
                        field("Адрес", $doc.url, hint: "vpn.example.com/группа")
                        field("Пользователь", $doc.user)
                        userAgentField
                        field("CsdWrapper", $doc.csdWrapper, hint: "заглушка проверки соответствия, если шлюз просит")
                    }
                    group("Сети в туннеле") { routesEditor }
                    group("Зоны DNS") { zonesEditor }
                    group("Вход") {
                        Picker("Пароль", selection: $doc.password) {
                            ForEach(ProfileDoc.passwordSources, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: doc.password) { _ in touched() }
                        if doc.password == "command" {
                            field("Команда для пароля", $doc.passwordCommand,
                                  hint: "печатает пароль первой строкой: op item get VPN --fields password")
                        }
                        if doc.password == "ask" {
                            Text("Пароль вводит человек — молчаливое переподключение работать не будет.")
                                .font(.system(size: 10)).foregroundStyle(Palette.warn)
                        }
                        Picker("Одноразовый код", selection: $doc.totp) {
                            ForEach(ProfileDoc.totpSources, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: doc.totp) { _ in touched() }
                        if doc.totp == "command" { field("Команда", $doc.totpCommand, hint: "например: op item get VPN --otp") }
                        if doc.totp == "keepassxc" || doc.password == "keepassxc" || !doc.keepassEntry.isEmpty {
                            field("Запись KeePassXC", $doc.keepassEntry, hint: "Группа/Запись")
                            field("База KeePassXC", $doc.keepassDb)
                            field("Мастер-пароль в связке", $doc.keepassKeychain, hint: "имя сервиса в Keychain")
                        }
                        field("Сервис в связке ключей", $doc.keychainService, hint: "по умолчанию ru.ocbar.client")
                        field("Хосты провайдера входа", $doc.idpHosts, hint: "где разрешено автозаполнение")
                    }
                    group("Форма входа на портале") { learnBlock }
                    group("Проверка доступа") {
                        field("Что проверять", $doc.health, hint: "URL, «хост:порт» или имя — поднятый туннель ещё не значит доступ")
                    }
                    if showFile {
                        group("Файл, как он будет записан") {
                            Text(doc.render())
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            bottomBar
        }
    }

    // Разметка формы: встроенные правила покрывают типовые порталы
    // (Keycloak, Microsoft), а чужую форму человек показывает мышью сам.
    // Результат живёт в самом профиле (секция [Autofill]) и правится здесь же.
    private var learnBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let _ = { Self.probeLearnEnabled = !learnDisabled }()
                Button(learning ? "Идёт разметка…" : "Разметить портал…") { learn() }
                    .disabled(learnDisabled)
                if learning { ProgressView().controlSize(.small).scaleEffect(0.6) }
                Spacer()
                Text(doc.autofill.isEmpty
                     ? (doc.rulesFile.trimmed.isEmpty
                        ? (FileManager.default.fileExists(atPath: rulesPath) ? "действует общий файл autofill.rules" : "действуют встроенные правила")
                        : "действует файл из Rules")
                     : "\(doc.autofill.filter { !$0.trimmed.isEmpty && !$0.trimmed.hasPrefix("#") }.count) правил в профиле")
                    .font(.system(size: 10.5)).foregroundStyle(Palette.tertiary)
            }
            Text(learnHint)
                .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(
                get: { doc.autofill.joined(separator: "\n") },
                set: { doc.autofill = $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init); touched() }))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
            Text("Правила профиля, по строке: stop <селектор> · fill username|password|totp <селектор> · click <селектор> · click! <селектор>. Строки «# шаг N — …» — заголовки окон формы, их пишет разметка. Пусто — действует общий файл или встроенные.")
                .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            field("Общий файл правил", $doc.rulesFile,
                  hint: "необязательно: путь к файлу на несколько профилей; при заполненной секции выше не читается")
            if let learnResult {
                Text(learnResult)
                    .font(.system(size: 11)).foregroundStyle(learnResult.hasPrefix("не получилось") ? Palette.bad : Palette.ok)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var learnHint: String {
        if doc.fileName.trimmed.isEmpty { return "Укажите имя файла профиля — размечать нужно его форму входа." }
        if !errors.isEmpty { return "В профиле ошибки (внизу окна) — исправьте, и разметка станет доступна." }
        if !fileExists || dirty { return "Профиль сначала сохранится — разметка идёт по его адресу, а правила ложатся в сам файл." }
        return "Откроется форма входа вашего портала. Отмечайте мышью поля и кнопку — правила запишутся в этот профиль сами. Форма в несколько окон (сначала пароль, потом код)? Отметьте первое окно и нажмите «Пройти шаг →»: ocbar заполнит его вашими данными и перейдёт к следующему. Прошлая версия профиля останется рядом с суффиксом .bak."
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
        guard !learning else { return }
        // Разметка идёт по адресу из файла и пишет правила в файл — значит,
        // сначала файл должен совпадать с тем, что на экране.
        if dirty || !fileExists {
            save()
            guard !dirty, fileExists else { return }
        }
        learning = true
        learnResult = nil
        let name = doc.fileName
        DispatchQueue.global(qos: .userInitiated).async {
            // Окно разметки живёт, пока человек не нажмёт «Готово»: ждём долго.
            let result = OcbarClient.shared.action(["learn", name], timeout: 1800)
            DispatchQueue.main.async {
                learning = false
                switch result {
                case .ok(let text):
                    // Правила легли в файл профиля — перечитать его, чтобы
                    // редактор показывал то, что на диске.
                    if let fresh = ProfileStore.load(name) {
                        doc = fresh; issues = ProfileCheck.check(doc); savedText = Self.snapshot(fresh)
                    }
                    learnResult = text.contains("отменена") ? "разметка отменена — профиль не тронут"
                        : "правила записаны в профиль: \(doc.autofill.count) строк"
                case .needsLogin:
                    learnResult = "разметка не завершена"
                case .failed(_, let text):
                    learnResult = "не получилось: " + text
                }
            }
        }
    }

    private var userAgentField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("User-Agent").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .frame(width: 150, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    TextField(ProfileDoc.defaultUserAgent, text: $doc.userAgent)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: doc.userAgent) { _ in touched() }
                    Menu {
                        ForEach(ProfileDoc.knownUserAgents, id: \.self) { ua in
                            Button(ua) { doc.userAgent = ua; touched() }
                        }
                    } label: { Image(systemName: "list.bullet") }
                        .menuStyle(.borderlessButton).frame(width: 28)
                }
                Text("шлюзы иногда придираются к строке клиента")
                    .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            }
        }
    }

    private var routesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(doc.routes.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("10.0.0.0/8", text: Binding(
                        get: { i < doc.routes.count ? doc.routes[i] : "" },
                        set: { if i < doc.routes.count { doc.routes[i] = $0; touched() } }))
                        .textFieldStyle(.roundedBorder).font(.ocMono).frame(width: 190)
                    if !doc.routes[i].trimmed.isEmpty, !ProfileCheck.validCIDR(doc.routes[i].trimmed) {
                        Text("не CIDR").font(.ocNote).foregroundStyle(Palette.bad)
                    } else if let len = ProfileCheck.prefixLength(doc.routes[i].trimmed), len < 8 {
                        Text("уводит почти весь трафик").font(.ocNote).foregroundStyle(Palette.warn)
                    }
                    Spacer()
                    Button { doc.routes.remove(at: i); touched() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Добавить сеть") { doc.routes.append(""); touched() }
                .buttonStyle(.link).font(.system(size: 11))
        }
    }

    private var zonesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(doc.zones.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("example.com", text: Binding(
                        get: { i < doc.zones.count ? doc.zones[i].zone : "" },
                        set: { if i < doc.zones.count { doc.zones[i].zone = $0; touched() } }))
                        .textFieldStyle(.roundedBorder).font(.ocMono).frame(width: 190)
                    Text("→").foregroundStyle(Palette.tertiary)
                    TextField("10.0.0.1 или vpn", text: Binding(
                        get: { i < doc.zones.count ? doc.zones[i].resolver : "" },
                        set: { if i < doc.zones.count { doc.zones[i].resolver = $0; touched() } }))
                        .textFieldStyle(.roundedBorder).font(.ocMono).frame(width: 130)
                    Spacer()
                    Button { doc.zones.remove(at: i); touched() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Добавить зону") { doc.zones.append(ZoneLine(zone: "", resolver: "vpn", port: "")); touched() }
                .buttonStyle(.link).font(.system(size: 11))
            Text("«vpn» вместо адреса — резолвер, который прислал шлюз. Более длинная зона перебивает короткую.")
                .font(.system(size: 10)).foregroundStyle(Palette.tertiary)
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                Toggle("показать файл", isOn: $showFile).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                Button("Проверить") { issues = ProfileCheck.check(doc) }
                Button("Сохранить") { save() }
                    .keyboardShortcut("s")
                    .disabled(!errors.isEmpty || doc.fileName.trimmed.isEmpty)
            }
        }
        .padding(12)
    }

    // --- служебное -------------------------------------------------------

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
            content()
        }
    }

    private func field(_ label: String, _ text: Binding<String>, hint: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .frame(width: 150, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text.wrappedValue) { _ in touched() }
                if !hint.isEmpty {
                    Text(hint).font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                }
            }
        }
    }

    private func touched() {
        message = nil
        issues = ProfileCheck.check(doc)
    }

    private func reloadList() {
        files = ProfileStore.list()
        let status = OcbarClient.shared.status()
        legacy = status.profiles.filter { !files.contains($0.name) }
        if selected == nil, let first = files.first {
            selected = first
            doc = ProfileStore.load(first) ?? ProfileDoc(fileName: first)
            savedText = ProfileStore.load(first).map(Self.snapshot)
            issues = ProfileCheck.check(doc)
        }
    }

    private func save() {
        issues = ProfileCheck.check(doc)
        guard errors.isEmpty else { return }
        if let error = ProfileStore.save(doc) {
            issues.append(Issue(level: .error, text: "не удалось записать: \(error)"))
            return
        }
        savedText = Self.snapshot(doc)
        // Проверяем не своими глазами, а клиентом: профиль должен появиться
        // в его списке — значит файл разобран.
        let seen = OcbarClient.shared.status().profiles.contains { $0.name == doc.fileName }
        message = seen
            ? "сохранено, ocbar видит профиль «\(doc.fileName)»"
            : "файл записан, но ocbar профиль не показывает — проверьте ocbar profiles"
        reloadList()
        selected = doc.fileName
    }

    // Перевод старого профиля в файл — командой самого клиента, чтобы формат
    // не разошёлся. После этого ocbar читает профиль из файла, а не из
    // profiles.conf: это и есть смысл перевода.
    private func convert(_ name: String) {
        let target = ProfileStore.path(name)
        try? FileManager.default.createDirectory(atPath: OcbarClient.shared.profileDir,
                                                 withIntermediateDirectories: true)
        switch OcbarClient.shared.action(["export", name, target], timeout: 20) {
        case .ok:
            message = "профиль \(name) переведён в файл — теперь ocbar читает его оттуда"
            reloadList()
            selected = name
        case .needsLogin:
            message = nil
        case .failed(_, let text):
            issues = [Issue(level: .error, text: "перевод не удался: \(text)")]
        }
    }
}
