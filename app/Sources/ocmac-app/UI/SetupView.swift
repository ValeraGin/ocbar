import SwiftUI

// Мастер первого запуска: от установленной программы до первого входа.
// Раньше этот путь был только в документации, и человек упирался в терминал
// на первом же шаге. Мастер ничего не делает молча: каждый шаг объясняет,
// что произойдёт, и показывает, чем он кончился.
struct SetupView: View {
    @ObservedObject private var store = StatusStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var doctorText = ""
    @State private var checking = false
    @State private var name = ""
    @State private var descr = ""
    @State private var url = ""
    @State private var user = ""
    @State private var auth = ""
    @State private var saved: String?
    @State private var note: String?
    @State private var busy = false
    @State private var importedIDs: [String] = []
    @State private var importedDoc: ProfileDoc?
    @State private var systemState: ProfileSystemState?
    @State private var checkingSystem = false
    @State private var resource = ""
    @State private var accessResult: Bool?
    @State private var accessChecked = false
    @State private var checkingAccess = false
    private var selectedProfile: String { saved ?? store.status.defaultProfile }
    private var connectedHere: Bool { store.status.state == .connected && store.status.profile == selectedProfile }

    // Шаг мастера; витрина (--step N) открывает нужный для снимка.
    @State private var step: Int = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--step"), i + 1 < a.count, let n = Int(a[i + 1]), (0...2).contains(n) { return n }
        return 0
    }()

    private var helperReady: Bool { store.helperWarning == nil && !doctorText.contains("не установлен") && !doctorText.contains("not installed") && !doctorText.isEmpty }
    private var systemReady: Bool { helperReady && systemState?.ready != false }
    private var hasProfile: Bool { saved != nil || !store.status.profiles.isEmpty }
    private var formFilled: Bool { !name.trimmed.isEmpty && !url.trimmed.isEmpty }
    private static var titles = [L("Системная часть"), L("Профиль"), L("Первый вход")]

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch step {
                case 0: systemStep
                case 1: profileStep
                default: loginStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { useExistingProfiles(); checkHelper(); checkSystem() }
        .onChange(of: resource) { _ in accessChecked = false; accessResult = nil }
        .onChange(of: saved) { _ in checkSystem() }
        .onChange(of: store.status.state) { _ in if connectedHere { checkAccess() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in checkSystem() }
    }

    // --- шапка: знак и шаги ------------------------------------------------

    private var header: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 10) {
                AppMark(size: 34)
                Text("OpenConnect for Mac").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 14)
            steps.padding(.top, 14)
        }
    }

    private func done(_ i: Int) -> Bool {
        switch i {
        case 0: return systemReady
        case 1: return hasProfile && step > 1
        default: return store.status.state == .connected && step == 2
        }
    }

    private var steps: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                if i > 0 {
                    Rectangle().fill(i <= step ? Palette.accent : Palette.groupLine)
                        .frame(width: 90, height: 2).padding(.top, 14)
                }
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(done(i) ? Palette.ok : i == step ? Palette.brand : Color.clear)
                        Circle().strokeBorder(done(i) || i == step ? Color.clear : Palette.line2, lineWidth: 1.5)
                        if done(i) {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(i == step ? Palette.onBrand : Palette.secondary)
                        }
                    }
                    .frame(width: 30, height: 30)
                    Text(Self.titles[i]).font(.system(size: 12, weight: i == step ? .semibold : .regular))
                        .foregroundStyle(i == step ? Palette.text : Palette.secondary)
                        .fixedSize()
                }
                .frame(width: 110)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("Шаг %@: %@%@", "\(i + 1)", Self.titles[i],
                                      done(i) ? L(", готово") : i == step ? L(", текущий") : ""))
            }
        }
    }

    private func pageTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 460)
        .padding(.top, 16)
    }

    // --- шаг 1: системная часть -------------------------------------------

    private var systemStep: some View {
        VStack(spacing: 0) {
            pageTitle(systemReady ? L("Системная часть установлена") : L("Подготовьте системную часть для этого профиля"),
                      systemReady ? L("Можно переходить к профилю.")
                                  : L("Туннель поднимает помощник с правами администратора. Его ставит одна команда с паролем — один раз."))
            Form {
                Section {
                    LabeledContent(L("Состояние")) {
                        if checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(systemReady ? L("установлена") : L("не установлена"),
                                  systemImage: systemReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(systemReady ? Palette.ok : Palette.warn)
                        }
                    }
                    LabeledContent(L("Команда")) {
                        HStack(spacing: 8) {
                            Text("ocmac prepare && sudo ocmac install").font(.ocMono).textSelection(.enabled)
                            CopyButton(text: "ocmac prepare && sudo ocmac install")
                        }
                    }
                    HStack {
                        Spacer()
                        Button(checking ? L("Проверяю…") : L("Проверить ещё раз")) { checkHelper() }.disabled(checking)
                    }
                } footer: {
                    Footnote(store.helperWarning
                             ?? (helperReady
                                 ? L("После обновления OpenConnect for Mac помощника обновляет та же команда.")
                                 : L("Выполните команду в Терминале: sudo спросит пароль там, приложение само этого сделать не может. Режиму «Прокси SOCKS» помощник не нужен.")))
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
        }
    }

    // --- шаг 2: профиль ------------------------------------------------------

    private var profileStep: some View {
        VStack(spacing: 0) {
            pageTitle(saved == nil ? L("Добавьте профиль") : L("Профиль сохранён"),
                      saved == nil ? L("Адрес — как в штатном клиенте: хост и группа. Сети и DNS можно добавить позже.")
                                   : L("Файл %@.ocmac. Изменить его можно в «Настройках → Профили».", saved!))
            Form {
                Section {
                    Button(L("Импортировать файл…")) { importProfile() }.disabled(busy)
                    if importedIDs.count > 1 {
                        Picker(L("Выберите профиль"), selection: Binding(get: { saved ?? importedIDs[0] }, set: { selectImported($0) })) {
                            ForEach(importedIDs, id: \.self) { Text(ProfileStore.load($0)?.name ?? $0).tag($0) }
                        }
                    }
                } header: { Text(L("Есть профиль от коллеги?")) } footer: {
                    Footnote(L("Профиль OpenConnect for Mac (.ocmac) — свой или от коллеги — или профиль Cisco AnyConnect (.xml)."))
                }
                if saved != nil && (checkingSystem || systemState?.ready == false) {
                    Section {
                        if checkingSystem { ProgressView(L("Проверяю готовность…")) }
                        ProfileSetupNotice(state: systemState, checking: checkingSystem, check: checkSystem)
                    }
                }
                Section(L("Подключение")) {
                    TextField(L("Название"), text: $name, prompt: Text(L("Рабочий"))).disabled(saved != nil)
                    TextField(L("Описание"), text: $descr, prompt: Text(L("необязательно"))).disabled(saved != nil)
                    TextField(L("Адрес"), text: $url, prompt: Text("vpn.example.com/employees")).disabled(saved != nil)
                    TextField(L("Пользователь"), text: $user, prompt: Text("alice"))
                }
                Section {
                    Picker(L("Как входить"), selection: $auth) {
                        Text(L("SSO в окне браузера")).tag("")
                        Text(L("Пароль и код из SMS")).tag("password")
                    }
                    .disabled(saved != nil)
                } header: {
                    Text(L("Вход"))
                } footer: {
                    Footnote(auth == "password"
                             ? L("Пароль OpenConnect for Mac подставит из связки ключей, код из SMS спросит окном.")
                             : L("Пароль и источник кода OpenConnect for Mac предложит сохранить после первого входа."))
                }

            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
            .disabled(busy)
        }
    }

    // --- шаг 3: первый вход ------------------------------------------------

    private var loginStep: some View {
        VStack(spacing: 18) {
            pageTitle(connectedHere ? L("VPN подключён") : L("Первый вход"),
                      connectedHere
                      ? L("Дальше OpenConnect for Mac подключается автоматически; если понадобится вход, он скажет в меню.")
                      : L("Войдите как обычно, руками. OpenConnect for Mac запомнит форму входа и предложит сохранить пароль и источник кода."))
            if connectedHere {
                Label(L("Соединение со шлюзом установлено"), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Проверка рабочего ресурса")).font(.headline)
                    TextField(L("Адрес ресурса"), text: $resource, prompt: Text("https://intranet.example.com"))
                        .textFieldStyle(.roundedBorder).disabled(checkingAccess)
                    if checkingAccess { ProgressView(L("Проверяю доступ…")) }
                    else if accessChecked {
                        Label(accessResult == true ? L("Рабочий ресурс отвечает") : L("Ресурс не отвечает. Откройте диагностику, чтобы проверить сети и DNS."),
                              systemImage: accessResult == true ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .foregroundStyle(accessResult == true ? Palette.ok : Palette.warn)
                        if accessResult == false { Button(L("Открыть диагностику")) { WindowBridge.open(WindowID.diagnostics) } }
                    } else {
                        Text(L("Соединение со шлюзом ещё не подтверждает доступ к рабочим сервисам. Укажите адрес одного из них."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Button(L("Проверить доступ")) { checkAccess() }.disabled(checkingAccess || resource.trimmed.isEmpty)
                }.frame(maxWidth: 460)
            } else {
                ProfileSetupNotice(state: systemState, checking: checkingSystem, check: checkSystem)
                WideButton(title: store.busy ?? L("Подключить и запомнить вход…"), systemImage: "person.badge.key",
                           kind: .primary, enabled: !busy && hasProfile && store.busy == nil && systemState?.ready == true && !checkingSystem) {
                    store.connect(profile: selectedProfile, teach: true)
                }
                .frame(width: 320)
                if store.busy != nil {
                    Button(L("Отменить")) { store.cancelCurrent() }.buttonStyle(BrandLinkStyle())
                }
            }
            if let actionNote = store.actionNote { Text(actionNote).font(.system(size: 12)).foregroundStyle(Palette.warn).textSelection(.enabled) }
            Spacer()
        }
    }

    // --- низ: назад, позже, дальше -----------------------------------------

    private var footer: some View {
        HStack(spacing: 10) {
            if step > 0 {
                Button(L("Назад")) { withAnimation { step -= 1 } }
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.bad)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if step < 2 {
                Button(L("Позже")) { dismiss() }
            }
            Button(primaryTitle) { primary() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || (step == 1 && saved == nil && !formFilled && !hasProfile))
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var primaryTitle: String {
        switch step {
        case 0: return L("Продолжить")
        case 1: return saved == nil && formFilled ? L("Сохранить и продолжить") : L("Продолжить")
        default: return L("Готово")
        }
    }

    private func primary() {
        switch step {
        case 0: withAnimation { step = 1 }
        case 1:
            if saved == nil && formFilled { createProfile { withAnimation { step = 2 } } }
            else if let original = importedDoc, user.trimmed != original.user {
                createProfile { withAnimation { step = 2 } }
            } else { checkSystem(); withAnimation { step = 2 }; if connectedHere { checkAccess() } }
        default: dismiss()
        }
    }

    private func checkHelper() {
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let out = OCMacClient.shared.doctor()
            DispatchQueue.main.async { doctorText = out; checking = false; store.refresh() }
        }
    }

    private func createProfile(then: @escaping () -> Void = {}) {
        var doc = importedDoc ?? ProfileDoc()
        if importedDoc == nil {
            doc.name = name.trimmed
            doc.descr = descr.trimmed
            doc.url = url.trimmed
            doc.auth = auth
            doc.fileName = ProfileEditorView.slug(name.trimmed)
        }
        doc.user = user.trimmed
        let issues = ProfileCheck.check(doc).filter { $0.level == .error }
        guard issues.isEmpty else { note = issues.map(\.text).joined(separator: "; "); return }
        let expected = ProfileStore.stamp(doc.fileName)
        if let original = importedDoc {
            guard expected.text == ProfileStore.read(original.fileName),
                  expected.text.map({ ProfileDoc.parse($0, fileName: original.fileName).render(dated: Date(timeIntervalSince1970: 0)) }) == original.render(dated: Date(timeIntervalSince1970: 0)) else {
                note = L("Профиль изменился на диске. Импортируйте его заново или откройте редактор."); return
            }
        } else if expected.text != nil {
            note = L("Профиль с таким именем уже есть. Выберите другое название."); return
        }
        busy = true; note = nil
        ProfileSaveService.save(doc, expected: expected) { result in
            busy = false
            switch result {
            case .saved:
                saved = doc.fileName; importedDoc = doc; store.refresh(); checkSystem(); then()
            case .changed: note = L("Профиль изменился на диске. Импортируйте его заново или откройте редактор.")
            case .rejected(let why): note = L("клиент не принимает профиль: ") + why
            case .failed(let why): note = L("профиль не сохранился: ") + why
            }
        }
    }

    private func useExistingProfiles() {
        guard saved == nil, !formFilled else { return }
        let ids = ProfileStore.list()
        guard let id = ids.contains(selectedProfile) ? selectedProfile : ids.first else { return }
        importedIDs = ids
        selectImported(id)
    }

    private func selectImported(_ id: String) {
        guard let doc = ProfileStore.load(id) else { return }
        importedDoc = doc; saved = id
        name = doc.name; descr = doc.descr; url = doc.url; user = doc.user; auth = doc.auth
        resource = doc.health; systemState = nil; checkSystem()
    }

    private func checkSystem() {
        let id = selectedProfile
        guard !id.isEmpty, !checkingSystem else { return }
        checkingSystem = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = OCMacClient.shared.profileSystemState(id)
            let health = ProfileStore.load(id)?.health ?? ""
            DispatchQueue.main.async {
                checkingSystem = false
                guard selectedProfile == id else { checkSystem(); return }
                systemState = result
                if resource.isEmpty { resource = health }
            }
        }
    }

    private func checkAccess() {
        guard connectedHere, !checkingAccess, !resource.trimmed.isEmpty else { return }
        checkingAccess = true; accessChecked = false
        let target = resource.trimmed
        let id = selectedProfile
        DispatchQueue.global(qos: .userInitiated).async {
            let result = OCMacClient.shared.checkResource(target, profile: id)
            DispatchQueue.main.async {
                checkingAccess = false
                guard connectedHere, selectedProfile == id, resource.trimmed == target else { return }
                accessChecked = true; accessResult = result
            }
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.message = L("Файл профиля .ocmac или профиль Cisco AnyConnect (.xml)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; note = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = OCMacClient.shared.importProfiles(url.path)
            DispatchQueue.main.async {
                busy = false
                if let why = r.error { note = L("не вышло: ") + why }
                else { importedIDs = r.ids; selectImported(r.ids[0]); store.refresh() }
            }
        }
    }
}
