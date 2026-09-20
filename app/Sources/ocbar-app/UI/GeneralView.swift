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
                Toggle(L("Запускать при входе в систему"), isOn: Binding(get: { autostart }, set: { set($0) }))
                    .disabled(busy)
            } footer: {
                footnote(L("Значок появится в строке меню сам; туннель при этом не поднимается."))
            }
            Section {
                Picker(L("Автоподключение"), selection: Binding(get: { policy }, set: { setPolicy($0) })) {
                    Text(L("Вручную")).tag("manual")
                    Text(L("Восстанавливать прошлое подключение")).tag("resume")
                    ForEach(store.status.profiles.filter { !$0.isPassword }) { p in
                        Text(L("Всегда: %@", p.display)).tag("always " + p.name)
                    }
                }
                .disabled(busy)
                Toggle(L("Не подключаться автоматически в этой сети"), isOn: Binding(get: { skipHere }, set: { setSkip($0) }))
                    .disabled(busy)
            } header: {
                Text(L("Подключение"))
            } footer: {
                footnote(L("Сеть определяется по маршрутизатору, без геолокации. Если сессия истекла, автоподключение остановится и меню покажет «Нужен вход»."))
            }
            Section {
                Toggle(L("Режим разработчика"), isOn: $developer)
            } footer: {
                footnote(L("Добавляет в меню «Выйти совсем (сброс входа)»: следующий вход пройдёт с формой."))
            }
            if let note {
                Section { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warn) }
            }
            Section {
                Label(L("Выход из приложения (⌘Q) не отключает VPN: туннелем управляет супервизор."),
                      systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("Общие"))
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
                if case .failed(_, let why) = r { note = L("не вышло: ") + why }
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
                if case .failed(_, let why) = r { note = L("не вышло: ") + why }
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
                if case .failed(_, let why) = r { note = L("не вышло: ") + why }
            }
        }
    }
}
