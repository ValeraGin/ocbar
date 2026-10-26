import SwiftUI

struct QuickProfileView: View {
    @ObservedObject private var flow = QuickProfileFlow.shared
    @ObservedObject private var store = StatusStore.shared
    @FocusState private var loginFocused: Bool

    private var connected: Bool {
        store.status.state == .connected && store.status.profile == flow.doc?.fileName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                AppMark(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(connected ? L("Вы подключены") : L("Подключитесь с готовым профилем"))
                        .font(.system(size: 22, weight: .semibold))
                    Text(L("Откройте профиль → введите логин → подключитесь"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let doc = flow.doc {
                if flow.ids.count > 1 {
                    Picker(L("Профиль"), selection: Binding(get: { doc.fileName }, set: { flow.select($0) })) {
                        ForEach(flow.ids, id: \.self) { Text(ProfileStore.load($0)?.name ?? $0).tag($0) }
                    }.disabled(flow.busy || flow.checking || flow.waitingForSetup || store.busy != nil)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(doc.name.trimmed.isEmpty ? doc.fileName : doc.name).font(.headline)
                    Text(doc.url).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(L("Сети и DNS уже взяты из профиля."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if connected {
                    Label(L("Откройте рабочий ресурс и проверьте доступ."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.ok)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Ваш корпоративный логин")).font(.system(size: 13, weight: .medium))
                        TextField(L("Введите свой логин"), text: $flow.user)
                            .textFieldStyle(.roundedBorder).focused($loginFocused)
                            .disabled(flow.busy || flow.waitingForSetup || store.busy != nil)
                        Text(L("Пароль и второй фактор вы введёте в окне входа организации."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !doc.csdScriptBase64.isEmpty || !doc.csdWrapper.isEmpty || !doc.passwordCommand.isEmpty || !doc.totpCommand.isEmpty {
                        Text(L("Профиль содержит скрипты или команды. Подключайтесь, только если доверяете отправителю."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if flow.waitingForSetup {
                        Label(L("Введите пароль администратора в Терминале. После подготовки подключение продолжится."), systemImage: "terminal")
                            .font(.system(size: 13))
                    } else if flow.system != nil && !flow.ready {
                        Text(flow.system?.error ?? L("Перед первым входом подготовим системную часть. macOS попросит пароль администратора в Терминале."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if store.status.state == .connected && store.status.profile != doc.fileName {
                        Text(L("Это подключение заменит текущее VPN-соединение."))
                            .font(.system(size: 12)).foregroundStyle(Palette.warn)
                    }
                }
            } else {
                Text(L("Получили файл от коллеги? Откройте его здесь или двойным щелчком в Finder."))
                    .foregroundStyle(.secondary)
                Button(L("Открыть профиль…")) { flow.chooseFile() }.controlSize(.large)
            }
            if let note = flow.note ?? store.actionNote {
                Text(note).font(.system(size: 12)).foregroundStyle(Palette.warn).textSelection(.enabled)
            }
            if flow.busy || flow.checking || flow.waitingForSetup || store.busy != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(store.busy ?? (flow.waitingForSetup ? L("Жду подготовки…") : L("Проверяю профиль…")))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                if flow.doc != nil {
                    Button(L("Другой профиль…")) { flow.chooseFile() }
                        .disabled(flow.busy || flow.waitingForSetup || store.busy != nil)
                    Button(L("Все настройки…")) { WindowBridge.open(WindowID.settings) }
                } else {
                    Button(L("Настроить вручную…")) { WindowBridge.open(WindowID.setup) }
                }
                Spacer()
                if flow.waitingForSetup {
                    Button(L("Отменить ожидание")) { flow.stopWaiting() }
                } else if store.busy != nil {
                    Button(L("Отменить")) { store.cancelCurrent() }
                } else if flow.doc != nil && !connected {
                    Button(L("Подключиться")) { flow.connect() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(flow.user.trimmed.isEmpty || flow.busy || flow.checking)
                }
            }
        }
        .padding(24).frame(width: 620).fixedSize(horizontal: false, vertical: true)
        .onAppear { loginFocused = true }
        .onChange(of: flow.doc?.fileName) { _ in loginFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in flow.check() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                flow.pollSetup()
            }
        }
        .onDisappear { flow.stopWaiting() }
    }
}
