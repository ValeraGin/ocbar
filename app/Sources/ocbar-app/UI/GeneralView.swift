import SwiftUI

// Общие настройки приложения: автозапуск и режим разработчика. Автозапуск
// живёт в LaunchAgent, его ставит CLI, поэтому переключатель спрашивает и
// меняет состояние через `ocbar app autostart`.
struct GeneralView: View {
    @ObservedObject private var store = StatusStore.shared
    @State private var autostart = false
    @State private var busy = false
    @State private var note: String?
    @AppStorage("DeveloperMode") private var developer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Запускать при входе в систему").font(.system(size: 13))
                    Text("Значок ocbar появится в строке состояния сам. Туннель при этом не поднимается: подключение — ваше решение или супервизор.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Запускать при входе в систему", isOn: Binding(get: { autostart }, set: { set($0) }))
                    .toggleStyle(.switch).labelsHidden().tint(Palette.ok).disabled(busy)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Режим разработчика").font(.system(size: 13))
                    Text("Добавляет в меню «Выйти совсем (сброс входа)»: следующий вход пройдёт с формой. Нужен для проверок.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Режим разработчика", isOn: $developer)
                    .toggleStyle(.switch).labelsHidden().tint(Palette.ok)
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Закрыть меню и выйти из приложения (⌘Q) — не то же самое, что отключить VPN: туннель останется поднятым, им управляет супервизор.")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { refresh() }
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let on = OcbarClient.shared.autostart()
            DispatchQueue.main.async { autostart = on }
        }
    }

    private func set(_ on: Bool) {
        busy = true; note = nil
        autostart = on
        DispatchQueue.global(qos: .userInitiated).async {
            let r = OcbarClient.shared.setAutostart(on)
            let fresh = OcbarClient.shared.autostart()
            DispatchQueue.main.async {
                busy = false
                autostart = fresh
                if case .failed(_, let why) = r { note = "не вышло: " + why }
            }
        }
    }
}
