import SwiftUI

// Общие настройки приложения: автозапуск и режим разработчика. Автозапуск
// живёт в LaunchAgent, его ставит CLI, поэтому переключатель спрашивает и
// меняет состояние через `ocbar app autostart`.
struct GeneralView: View {
    @ObservedObject private var store = StatusStore.shared
    @State private var autostart = false
    @State private var policy = "resume"
    @State private var skipHere = false
    @State private var busy = false
    @State private var note: String?
    @AppStorage("DeveloperMode") private var developer = false

    var body: some View {
        Form {
            Section {
                Toggle("Запускать при входе в систему", isOn: Binding(get: { autostart }, set: { set($0) }))
                    .disabled(busy)
            } footer: {
                footnote("Значок появится в строке меню сам; туннель при этом не поднимается.")
            }
            Section {
                Picker("Автоподключение", selection: Binding(get: { policy }, set: { setPolicy($0) })) {
                    Text("Вручную").tag("manual")
                    Text("Как в прошлый раз").tag("resume")
                    ForEach(store.status.profiles.filter { !$0.isPassword }) { p in
                        Text("Всегда: \(p.display)").tag("always " + p.name)
                    }
                }
                .disabled(busy)
                Toggle("Не подключаться в этой сети", isOn: Binding(get: { skipHere }, set: { setSkip($0) }))
                    .disabled(busy)
            } header: {
                Text("Подключение")
            } footer: {
                footnote("Сеть узнаётся по маршрутизатору, без геопозиции. Если сессия истекла, супервизор остановится и скажет «нужен вход».")
            }
            Section {
                Toggle("Режим разработчика", isOn: $developer)
            } footer: {
                footnote("Добавляет в меню «Выйти совсем (сброс входа)»: следующий вход пройдёт с формой.")
            }
            if let note {
                Section { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warn) }
            }
            Section {
                Label("Выход из приложения (⌘Q) не отключает VPN: туннелем управляет супервизор.",
                      systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Общие")
        .onAppear { refresh() }
    }

    private func footnote(_ text: String) -> some View { Footnote(text) }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let on = OcbarClient.shared.autostart()
            let p = OcbarClient.shared.autoconnect()
            let skip = OcbarClient.shared.skipHere()
            DispatchQueue.main.async { autostart = on; policy = p; skipHere = skip }
        }
    }

    private func setSkip(_ on: Bool) {
        busy = true; note = nil
        skipHere = on
        DispatchQueue.global(qos: .userInitiated).async {
            let r = OcbarClient.shared.setAutoconnect([on ? "skip-here" : "unskip-here"])
            let fresh = OcbarClient.shared.skipHere()
            DispatchQueue.main.async {
                busy = false
                skipHere = fresh
                if case .failed(_, let why) = r { note = "не вышло: " + why }
            }
        }
    }

    private func setPolicy(_ value: String) {
        busy = true; note = nil
        policy = value
        DispatchQueue.global(qos: .userInitiated).async {
            let r = OcbarClient.shared.setAutoconnect(value.split(separator: " ").map(String.init))
            let fresh = OcbarClient.shared.autoconnect()
            DispatchQueue.main.async {
                busy = false
                policy = fresh
                if case .failed(_, let why) = r { note = "не вышло: " + why }
            }
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
