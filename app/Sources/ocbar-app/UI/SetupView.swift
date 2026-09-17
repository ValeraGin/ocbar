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
    @State private var url = ""
    @State private var user = ""
    @State private var saved: String?
    @State private var note: String?
    @State private var busy = false

    private var helperReady: Bool { store.helperWarning == nil && !doctorText.contains("не установлен") }
    private var hasProfile: Bool { saved != nil || !store.status.profiles.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Настройка ocbar").font(.system(size: 17, weight: .medium))
                Text("Три шага: системная часть, профиль подключения, первый вход. Всё, что делает мастер, можно сделать и командами — они показаны рядом.")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                step(1, "Системная часть", done: helperReady) {
                    Text("Туннель поднимает привилегированный помощник: его ставит одна команда с паролем, один раз. Приложение само её выполнить не может — sudo спрашивает пароль в терминале.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text("sudo ocbar install").font(.ocMono).textSelection(.enabled)
                        CopyButton(text: "sudo ocbar install")
                        Button(checking ? "Проверяю…" : "Проверить") { checkHelper() }.disabled(checking)
                        Spacer()
                    }
                    if let w = store.helperWarning {
                        Text(w).font(.ocNote).foregroundStyle(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                step(2, "Профиль подключения", done: hasProfile) {
                    Text("Один файл на подключение. Адрес — как в штатном клиенте: хост и группа. Сети и зоны DNS можно добавить позже, в «Настройки → Профили».")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("Название").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            TextField("Рабочий", text: $name).frame(width: 260)
                        }
                        GridRow {
                            Text("Адрес").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            TextField("vpn.example.com/employees", text: $url).frame(width: 260)
                        }
                        GridRow {
                            Text("Пользователь").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            TextField("alice", text: $user).frame(width: 260)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Создать профиль") { createProfile() }
                            .disabled(busy || url.trimmed.isEmpty || name.trimmed.isEmpty)
                        Button("Импортировать файл…") { importProfile() }.disabled(busy)
                        Spacer()
                    }
                    if let saved {
                        Text("профиль сохранён: \(saved).ocbar").font(.ocNote).foregroundStyle(Palette.ok)
                    }
                }

                step(3, "Первый вход", done: store.status.state == .connected) {
                    Text("Войдите как обычно — руками. ocbar запомнит, как устроена форма, и предложит сохранить пароль и источник кода. Дальше подключение будет проходить молча.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Подключить и запомнить вход…") {
                            store.connect(profile: saved ?? store.status.defaultProfile, teach: true)
                        }
                        .disabled(busy || !hasProfile || store.busy != nil)
                        Spacer()
                        if let b = store.busy { Text(b).font(.ocNote).foregroundStyle(Palette.secondary) }
                    }
                }

                if let note {
                    Text(note).font(.ocNote).foregroundStyle(Palette.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(minWidth: 660, minHeight: 560)
        .onAppear { checkHelper() }
    }

    @ViewBuilder
    private func step<C: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                    .foregroundStyle(done ? Palette.ok : Palette.secondary)
                Text(title).font(.system(size: 14, weight: .medium))
            }
            content()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
    }

    private func checkHelper() {
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let out = OcbarClient.shared.doctor()
            DispatchQueue.main.async { doctorText = out; checking = false; store.refresh() }
        }
    }

    private func createProfile() {
        var doc = ProfileDoc()
        doc.name = name.trimmed
        doc.url = url.trimmed
        doc.user = user.trimmed
        doc.fileName = ProfileEditorView.slug(name.trimmed)
        let issues = ProfileCheck.check(doc).filter { $0.level == .error }
        guard issues.isEmpty else { note = issues.map(\.text).joined(separator: "; "); return }
        busy = true; note = nil
        let file = doc.fileName
        DispatchQueue.global(qos: .userInitiated).async {
            let err = ProfileStore.save(doc)
            DispatchQueue.main.async {
                busy = false
                if let err { note = "профиль не сохранился: " + err } else { saved = file; store.refresh() }
            }
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.message = "Файл профиля .ocbar — свой или от коллеги"
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
