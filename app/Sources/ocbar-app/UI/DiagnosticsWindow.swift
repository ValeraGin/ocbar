import SwiftUI

// Окно диагностики: вывод `ocbar doctor` как есть, моноширинным, с кнопкой
// «повторить». Здесь же уборка — единственное действие, которое меняет
// систему, поэтому рядом написано, что именно она делает.
struct DiagnosticsView: View {
    @ObservedObject private var store = StatusStore.shared
    @State private var text = ""
    @State private var running = false
    @State private var stamp: Date?

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
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("ocbar doctor").font(.system(size: 13, weight: .medium))
            Text("ничего не меняет — только проверяет")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            Spacer()
            if let stamp {
                Text(Self.clock.string(from: stamp)).font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
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
                     + "системный SOCKS без живого прокси, DNS 127.0.0.1 на интерфейсах при мёртвом резолвере. "
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
                store.cleanup()
                // Результат уборки виден в повторной диагностике.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { run() }
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
