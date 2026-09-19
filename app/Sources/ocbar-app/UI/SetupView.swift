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
    // Шаг мастера; витрина (--step N) открывает нужный для снимка.
    @State private var step: Int = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--step"), i + 1 < a.count, let n = Int(a[i + 1]), (0...2).contains(n) { return n }
        return 0
    }()

    private var helperReady: Bool { store.helperWarning == nil && !doctorText.contains("не установлен") && !doctorText.isEmpty }
    private var hasProfile: Bool { saved != nil || !store.status.profiles.isEmpty }
    private var formFilled: Bool { !name.trimmed.isEmpty && !url.trimmed.isEmpty }
    private static let titles = ["Системная часть", "Профиль", "Первый вход"]

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
        .onAppear { checkHelper() }
    }

    // --- шапка: знак и шаги ------------------------------------------------

    private var header: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 10) {
                AppMark(size: 34)
                Text("ocbar").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 14)
            steps.padding(.top, 14)
        }
    }

    private func done(_ i: Int) -> Bool {
        switch i {
        case 0: return helperReady
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
                        Circle().fill(done(i) ? Palette.ok : i == step ? Palette.accent : Color.clear)
                        Circle().strokeBorder(done(i) || i == step ? Color.clear : Palette.line2, lineWidth: 1.5)
                        if done(i) {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(i + 1)").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(i == step ? Color.white : Palette.secondary)
                        }
                    }
                    .frame(width: 30, height: 30)
                    Text(Self.titles[i]).font(.system(size: 12, weight: i == step ? .semibold : .regular))
                        .foregroundStyle(i == step ? Palette.text : Palette.secondary)
                        .fixedSize()
                }
                .frame(width: 110)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Шаг \(i + 1): \(Self.titles[i])\(done(i) ? ", готово" : i == step ? ", текущий" : "")")
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
            pageTitle(helperReady ? "Системная часть установлена" : "Установите системную часть",
                      helperReady ? "Можно переходить к профилю."
                                  : "Туннель поднимает помощник с правами администратора. Его ставит одна команда с паролем — один раз.")
            Form {
                Section {
                    LabeledContent("Состояние") {
                        if checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(helperReady ? "установлена" : "не установлена",
                                  systemImage: helperReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(helperReady ? Palette.ok : Palette.warn)
                        }
                    }
                    LabeledContent("Команда") {
                        HStack(spacing: 8) {
                            Text("sudo ocbar install").font(.ocMono).textSelection(.enabled)
                            CopyButton(text: "sudo ocbar install")
                        }
                    }
                    HStack {
                        Spacer()
                        Button(checking ? "Проверяю…" : "Проверить ещё раз") { checkHelper() }.disabled(checking)
                    }
                } footer: {
                    Footnote(store.helperWarning
                             ?? (helperReady
                                 ? "После обновления ocbar помощника обновляет та же команда."
                                 : "Выполните команду в Терминале: sudo спросит пароль там, приложение само этого сделать не может. Режиму «Прокси SOCKS» помощник не нужен."))
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
        }
    }

    // --- шаг 2: профиль ------------------------------------------------------

    private var profileStep: some View {
        VStack(spacing: 0) {
            pageTitle(saved == nil ? "Добавьте профиль" : "Профиль сохранён",
                      saved == nil ? "Адрес — как в штатном клиенте: хост и группа. Сети и DNS можно добавить позже."
                                   : "Файл \(saved!).ocbar. Изменить его можно в «Настройках → Профили».")
            Form {
                Section("Подключение") {
                    TextField("Название", text: $name, prompt: Text("Рабочий"))
                    TextField("Описание", text: $descr, prompt: Text("необязательно"))
                    TextField("Адрес", text: $url, prompt: Text("vpn.example.com/employees"))
                    TextField("Пользователь", text: $user, prompt: Text("alice"))
                }
                .disabled(saved != nil)
                Section {
                    Picker("Как входить", selection: $auth) {
                        Text("SSO в окне браузера").tag("")
                        Text("Пароль и код из SMS").tag("password")
                    }
                    .disabled(saved != nil)
                } header: {
                    Text("Вход")
                } footer: {
                    Footnote(auth == "password"
                             ? "Пароль ocbar подставит из связки ключей, код из SMS спросит окном."
                             : "Пароль и источник кода ocbar предложит сохранить после первого входа.")
                }
                Section {
                    HStack {
                        Button("Импортировать файл…") { importProfile() }.disabled(busy)
                        Spacer()
                    }
                } footer: {
                    Footnote("Профиль ocbar (.ocbar) — свой или от коллеги — или профиль Cisco AnyConnect (.xml).")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560)
        }
    }

    // --- шаг 3: первый вход ------------------------------------------------

    private var loginStep: some View {
        VStack(spacing: 18) {
            pageTitle(store.status.state == .connected ? "Готово — подключено" : "Первый вход",
                      store.status.state == .connected
                      ? "Дальше ocbar подключается автоматически; если понадобится вход, он скажет в меню."
                      : "Войдите как обычно, руками. ocbar запомнит форму входа и предложит сохранить пароль и источник кода.")
            if store.status.state == .connected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Palette.ok)
            } else {
                WideButton(title: store.busy ?? "Подключить и запомнить вход…", systemImage: "person.badge.key",
                           kind: .primary, enabled: !busy && hasProfile && store.busy == nil) {
                    store.connect(profile: saved ?? store.status.defaultProfile, teach: true)
                }
                .frame(width: 320)
                if store.busy != nil {
                    Button("Отменить") { store.cancelCurrent() }.buttonStyle(.link)
                }
            }
            Spacer()
        }
    }

    // --- низ: назад, позже, дальше -----------------------------------------

    private var footer: some View {
        HStack(spacing: 10) {
            if step > 0 {
                Button("Назад") { withAnimation { step -= 1 } }
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.bad)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if step < 2 {
                Button("Позже") { dismiss() }
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
        case 0: return "Продолжить"
        case 1: return saved == nil && formFilled ? "Сохранить и продолжить" : "Продолжить"
        default: return "Готово"
        }
    }

    private func primary() {
        switch step {
        case 0: withAnimation { step = 1 }
        case 1:
            if saved == nil && formFilled { createProfile { withAnimation { step = 2 } } }
            else { withAnimation { step = 2 } }
        default: dismiss()
        }
    }

    private func checkHelper() {
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let out = OcbarClient.shared.doctor()
            DispatchQueue.main.async { doctorText = out; checking = false; store.refresh() }
        }
    }

    private func createProfile(then: @escaping () -> Void = {}) {
        var doc = ProfileDoc()
        doc.name = name.trimmed
        doc.descr = descr.trimmed
        doc.url = url.trimmed
        doc.user = user.trimmed
        doc.auth = auth
        doc.fileName = ProfileEditorView.slug(name.trimmed)
        let issues = ProfileCheck.check(doc).filter { $0.level == .error }
        guard issues.isEmpty else { note = issues.map(\.text).joined(separator: "; "); return }
        busy = true; note = nil
        let file = doc.fileName
        DispatchQueue.global(qos: .userInitiated).async {
            let err = ProfileStore.save(doc)
            DispatchQueue.main.async {
                busy = false
                if let err { note = "профиль не сохранился: " + err } else { saved = file; store.refresh(); then() }
            }
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.message = "Файл профиля .ocbar или профиль Cisco AnyConnect (.xml)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; note = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = OcbarClient.shared.action(["import", url.path], timeout: 30)
            DispatchQueue.main.async {
                busy = false
                if case .failed(_, let why) = r { note = "не вышло: " + why }
                else { saved = url.deletingPathExtension().lastPathComponent; store.refresh() }
            }
        }
    }
}
