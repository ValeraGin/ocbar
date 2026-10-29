import SwiftUI

/// Компактное главное окно. Выбор профиля не запускает подключение сам.
@MainActor
struct ConnectionView: View {
    @ObservedObject private var store: StatusStore
    private let demo: Bool
    @State private var selectedProfile = ""

    init(store: StatusStore? = nil, demo: Bool = false) {
        self.store = store ?? .shared
        self.demo = demo || CommandLine.arguments.contains("--stage") || CommandLine.arguments.contains("--demo-menu")
    }

    private var status: Status { store.status }
    private var look: StateLook { StateLook.of(status) }
    private var active: Bool { [.connected, .lost, .paused, .starting].contains(status.presentation) }
    private var selected: ProfileEntry? { status.profiles.first { $0.name == selectedProfile } }
    private var locked: Bool { active || store.busy != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Профиль"))
                Picker(L("Профиль"), selection: $selectedProfile) {
                    if !selectedProfile.isEmpty && selected == nil { Text(selectedProfile).tag(selectedProfile) }
                    if status.profiles.isEmpty && selectedProfile.isEmpty { Text("—").tag("") }
                    ForEach(status.profiles) { profile in
                        Text(profile.display).tag(profile.name)
                    }
                }
                .labelsHidden()
                .disabled(locked || status.profiles.isEmpty)
            }

            if let address = selected?.address, !address.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Сервер"))
                    Spacer()
                    Text(address).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle).help(address)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 8) {
                StateDot(color: look.color, pulsing: look.pulsing)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.busy ?? look.subtitle).fontWeight(.medium)
                    if let step = ConnectStep.of(status) {
                        Text(step.title).foregroundStyle(.secondary)
                    } else if let note = look.note {
                        Text(note).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let message = store.actionNote ?? store.lastError ?? status.error ?? store.helperWarning {
                Text(MenuText.human(message))
                    .foregroundStyle(store.actionFailed || store.actionNote == nil ? Color.red : Color.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Button(L("Журнал…")) { if !demo { WindowBridge.open(WindowID.logs) } }
            }

            HStack {
                Button(L("Настройки…")) { if !demo { WindowBridge.open(WindowID.settings) } }
                Spacer()
                if status.presentation == .missing {
                    Button(L("Настроить OpenConnect for Mac…")) { if !demo { WindowBridge.open(WindowID.setup) } }
                } else if status.profiles.isEmpty && !active && store.busy == nil {
                    Button(L("Открыть профиль…")) { if !demo { QuickProfileFlow.shared.chooseFile() } }
                        .disabled(store.busy != nil)
                    Button(L("Новый профиль")) { if !demo { WindowBridge.open(WindowID.setup) } }
                        .disabled(store.busy != nil)
                }
                if status.presentation == .paused {
                    Button(L("Возобновить")) { if !demo { store.resume() } }
                        .disabled(store.busy != nil)
                } else if [.connected, .lost].contains(status.presentation), !status.isProxySession {
                    Button(L("Приостановить")) { if !demo { store.pause() } }
                        .disabled(store.busy != nil)
                }
                if status.presentation == .needsLogin {
                    Button(L("Не подключаться")) { if !demo { store.disconnect() } }
                        .disabled(store.busy != nil)
                }
                if (store.busy != nil && store.cancelTitle != nil) || active || (!status.profiles.isEmpty && status.presentation != .missing) { mainButton }
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 420, maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            reconcileSelection()
            if !demo { store.refreshHelperState() }
        }
        .onChange(of: status.profiles) { _, _ in reconcileSelection() }
        .onChange(of: status.profile) { _, _ in reconcileSelection() }
        .onChange(of: status.presentation) { _, _ in reconcileSelection() }
        .onChange(of: store.busy) { _, _ in reconcileSelection() }
        .onChange(of: store.finishedActions) { _, _ in
            if !demo { store.refreshHelperState() }
        }
    }

    @ViewBuilder private var mainButton: some View {
        if store.busy != nil, store.cancelTitle != nil {
            Button(L("Отменить")) { if !demo { store.cancelCurrent() } }
        } else if active {
            Button(L("Отключить VPN")) { if !demo { store.disconnect() } }
                .disabled(store.busy == L("Отключаю…"))
        } else {
            Button(L("Подключить VPN")) {
                if !demo { store.connect(profile: selectedProfile, show: status.presentation == .needsLogin) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(store.busy != nil || selected == nil || status.presentation == .missing || (!demo && OCMacClient.shared.binary == nil))
        }
    }

    private func reconcileSelection() {
        guard store.busy == nil || selectedProfile.isEmpty else { return }
        if active, !status.profile.isEmpty {
            selectedProfile = status.profile
        } else if !status.profiles.contains(where: { $0.name == selectedProfile }) {
            let target = StateLook.targetName(status)
            selectedProfile = status.profiles.contains(where: { $0.name == target }) ? target : (status.profiles.first?.name ?? "")
        }
    }
}
