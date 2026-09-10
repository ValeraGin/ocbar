import SwiftUI

// Окно диагностики: вывод `ocbar doctor` как есть, моноширинным, с кнопкой
// «повторить». Здесь же уборка — единственное действие, которое меняет
// систему, поэтому рядом написано, что именно она делает.
struct DiagnosticsView: View {
    @ObservedObject private var store = StatusStore.shared
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""
    @State private var running = false
    @State private var stamp: Date?
    @State private var cleanupPending = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                Text(text.isEmpty ? (running ? "проверяю…" : "—") : text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            cleanupBar
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { run() }
        // Результат уборки виден в повторной диагностике — когда уборка
        // закончится, а не через три секунды наугад.
        .onChange(of: store.finishedActions) { _ in
            if cleanupPending { cleanupPending = false; run() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("ocbar doctor").font(.system(size: 13, weight: .medium))
            Text("ничего не меняет — только проверяет")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            // Сеть и супервизор раньше жили строкой в меню; здесь им место.
            Text("· сеть \(store.status.iface.isEmpty ? "?" : store.status.iface) · "
                 + (store.status.supervisor ? "супервизор работает" : "супервизор не запущен"))
                .font(.system(size: 11))
                .foregroundStyle(store.status.supervisor ? Palette.tertiary : Palette.warn)
            Spacer()
            if let stamp {
                Text(Self.clock.string(from: stamp)).font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
            }
            Button("Журналы…") {
                openWindow(id: WindowID.logs)
                NSApp.activate(ignoringOtherApps: true)
            }
            Button {
                run()
            } label: {
                Label("Повторить", systemImage: "arrow.clockwise")
            }
            .disabled(running)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var cleanupBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Уборка следов прошлой сессии").font(.system(size: 12, weight: .medium))
                Text("Снимает то, что осталось после падения: наши зоны в /etc/resolver, наши маршруты, "
                     + "системный SOCKS без живого прокси. Системный DNS не трогает — ocbar его не ставит. "
                     + "Живой туннель и чужой openconnect не трогает. То же, что `ocbar cleanup`.")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = store.actionNote {
                    Text(note).font(.system(size: 11))
                        .foregroundStyle(store.actionFailed ? Palette.bad : Palette.ok)
                }
            }
            Spacer()
            Button("Убрать") {
                cleanupPending = true
                store.cleanup()
            }
            .disabled(store.busy != nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func run() {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            let out = OcbarClient.shared.doctor()
            DispatchQueue.main.async {
                text = out
                stamp = Date()
                running = false
            }
        }
    }
}
