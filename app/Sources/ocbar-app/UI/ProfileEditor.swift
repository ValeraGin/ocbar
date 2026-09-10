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
        HSplitView {
            sidebar.frame(minWidth: 190, idealWidth: 210, maxWidth: 280)
            editor.frame(minWidth: 480)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { reloadList() }
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
            List(selection: $selected) {
                Section("Профили") {
                    ForEach(files, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(of: name)).font(.system(size: 12))
                            Text(badge(of: name)).font(.system(size: 10)).foregroundStyle(Palette.tertiary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .padding(.vertical, 1)
                        .tag(name)
                    }
                    // Порядок — перетаскиванием; тот же порядок в меню.
                    .onMove { from, to in
                        files.move(fromOffsets: from, toOffset: to)
                        saveOrder()
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
            Divider()
            HStack(spacing: 8) {
                Button {
                    if dirty { alert = .unsaved(.new) } else { newDoc() }
                } label: { Image(systemName: "plus") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: OcbarClient.shared.profileDir)])
                } label: { Image(systemName: "folder") }
                Spacer()
                Text("порядок — перетаскиванием").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
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
                    group("Основное") {
                        field("Название", $doc.name,
                              hint: loadedName == nil ? "как показывать в меню; имя файла подставится само" : "как показывать в меню")
                        field("Адрес", $doc.url, hint: "vpn.example.com/группа")
                        field("Пользователь", $doc.user)
                        sourceRow("Пароль", selection: $doc.password, options: ProfileDoc.passwordSources, status: passwordStatus)
                        if doc.password == "command" {
                            field("Команда для пароля", $doc.passwordCommand,
                                  hint: "печатает пароль первой строкой: op item get VPN --fields password")
                        }
                        if doc.password == "ask" {
                            Text("Пароль вводит человек — молчаливое переподключение работать не будет.")
                                .font(.system(size: 10)).foregroundStyle(Palette.warn)
                                .padding(.leading, 158)
                        }
                        sourceRow("Одноразовый код", selection: $doc.totp, options: ProfileDoc.totpSources, status: totpStatus)
                        if doc.totp == "command" { field("Команда", $doc.totpCommand, hint: "например: op item get VPN --otp") }
                        if doc.totp == "keepassxc" || doc.password == "keepassxc" || !doc.keepassEntry.isEmpty {
                            field("Запись KeePassXC", $doc.keepassEntry, hint: "Группа/Запись")
                            field("База KeePassXC", $doc.keepassDb)
                            field("Мастер-пароль в связке", $doc.keepassKeychain, hint: "имя сервиса в Keychain")
                        }
                    }
                    group("Форма входа") { learnBlock }
                    disclosure("Сети и DNS", summary: netsSummary, isOn: $showNets) {
                        Text("Сети в туннеле").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                        routesEditor
                        Text("Зоны DNS").font(.system(size: 11)).foregroundStyle(Palette.tertiary).padding(.top, 4)
                        zonesEditor
                    }
                    disclosure("Дополнительно",
                               summary: "имя файла, User-Agent, CSD, параметры кода, хосты входа, правила, проверка доступа",
                               isOn: $showMore) {
                        field("Имя файла", $doc.fileName, hint: "профиль будет ~/.config/ocbar/profiles/\(doc.fileName.isEmpty ? "имя" : doc.fileName).ocbar")
                        field("Описание", $doc.descr, hint: "вторая строка в списке профилей")
                        userAgentField
                        field("CsdWrapper", $doc.csdWrapper, hint: "заглушка проверки соответствия, если шлюз просит")
                        if ["auto", "keychain"].contains(doc.totp) || doc.totpAlgorithm != "SHA1"
                            || doc.totpDigits != "6" || doc.totpPeriod != "30" {
                            totpParamsRow
                        }
                        field("Сервис в связке ключей", $doc.keychainService, hint: "по умолчанию ru.ocbar.client")
                        field("Хосты провайдера входа", $doc.idpHosts,
                              hint: "где разрешено автозаполнение; пусто — только цепочка входа от шлюза")
                        rulesEditor
                        field("Проверка доступа", $doc.health, hint: "URL, «хост:порт» или имя — поднятый туннель ещё не значит доступ")
                        Toggle("показать файл, как он будет записан", isOn: $showFile)
                            .toggleStyle(.checkbox).font(.system(size: 11)).padding(.leading, 158)
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
        return "\(nets) сет\(nets % 10 == 1 && nets % 100 != 11 ? "ь" : (2...4).contains(nets % 10) && !(12...14).contains(nets % 100) ? "и" : "ей") · \(zones) зон"
    }

    private var passwordStatus: (String, Color)? {
        guard !dirty, let v = secrets["password"] else { return nil }
        switch v {
        case "keychain ok": return ("сохранён в связке", Palette.ok)
        case "keychain missing": return ("в связке нет — ocbar secret set-password \(doc.fileName)", Palette.warn)
        default: return nil
        }
    }

    private var totpStatus: (String, Color)? {
        guard !dirty, let v = secrets["totp"] else { return nil }
        switch v {
        case "keychain ok": return ("секрет в связке", Palette.ok)
        case "keychain missing": return ("секрета нет — «Подключить и запомнить вход…» или камерой", Palette.warn)
        default: return nil
        }
    }

    private var learnHint: String {
        if doc.fileName.trimmed.isEmpty { return "Укажите имя файла профиля — размечать нужно его форму входа." }
        if !errors.isEmpty { return "В профиле ошибки (внизу окна) — исправьте, и разметка станет доступна." }
        if let busy = store.busy, !learning { return "Сейчас идёт «\(busy)» — разметка станет доступна, когда оно закончится." }
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Параметры кода").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .frame(width: 150, alignment: .trailing)
            Picker("", selection: $doc.totpAlgorithm) {
                ForEach(ProfileDoc.totpAlgorithms, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 96)
            .onChange(of: doc.totpAlgorithm) { _ in touched() }
            Picker("", selection: $doc.totpDigits) {
                ForEach(["6", "7", "8"], id: \.self) { Text("\($0) цифр").tag($0) }
            }
            .labelsHidden().frame(width: 96)
            .onChange(of: doc.totpDigits) { _ in touched() }
            TextField("30", text: $doc.totpPeriod)
                .textFieldStyle(.roundedBorder).frame(width: 48)
                .onChange(of: doc.totpPeriod) { _ in touched() }
            Text("с · обычно SHA1, 6, 30").font(.system(size: 10)).foregroundStyle(Palette.tertiary)
            Spacer()
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

    // Строка сети — как в файле: сеть первым словом, после неё может быть
    // комментарий; строка с «#» или «;» — комментарий целиком.
    private var routesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(doc.routes.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("10.0.0.0/8", text: Binding(
                        get: { i < doc.routes.count ? doc.routes[i] : "" },
                        set: { if i < doc.routes.count { doc.routes[i] = $0; touched() } }))
                        .textFieldStyle(.roundedBorder).font(.ocMono).frame(width: 190)
                    let line = i < doc.routes.count ? doc.routes[i] : ""
                    if let net = ProfileDoc.routeNet(line) {
                        if !ProfileCheck.validCIDR(net) {
                            Text("не CIDR").font(.ocNote).foregroundStyle(Palette.bad)
                        } else if let len = ProfileCheck.prefixLength(net), len < 8 {
                            Text("уводит почти весь трафик").font(.ocNote).foregroundStyle(Palette.warn)
                        }
                    } else if !line.trimmed.isEmpty {
                        Text("комментарий").font(.ocNote).foregroundStyle(Palette.tertiary)
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
                    Label("проверяется при вводе", systemImage: "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                Spacer()
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

    private func title(of name: String) -> String {
        store.status.profiles.first { $0.name == name }?.display ?? name
    }

    private func badge(of name: String) -> String {
        let s = store.status
        var parts: [String] = []
        if s.profile == name && s.state != .down { parts.append("подключён") }
        if s.defaultProfile == name { parts.append("по умолчанию") }
        parts.append(name + ".ocbar")
        return parts.joined(separator: " · ")
    }

    private func sourceRow(_ label: String, selection: Binding<String>, options: [String],
                           status: (String, Color)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .frame(width: 150, alignment: .trailing)
            // Столбец одной ширины: подписи «сохранён в связке» встают друг под другом.
            HStack(spacing: 0) {
                Picker("", selection: selection) {
                    ForEach(options, id: \.self) { Text(Self.sourceTitle($0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: selection.wrappedValue) { _ in touched() }
                Spacer(minLength: 0)
            }
            .frame(width: 200)
            if let status {
                Text(status.0).font(.system(size: 11)).foregroundStyle(status.1)
                    .lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            }
            Spacer()
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

    private func reloadList() {
        files = ProfileStore.list()
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
        if let error = ProfileStore.save(doc) {
            issues.append(Issue(level: .error, text: "не удалось записать: \(error)"))
            return
        }
        loadedName = name
        disk = ProfileStore.stamp(name)
        savedText = Self.snapshot(doc)
        diskChanged = false
        files = ProfileStore.list()
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
