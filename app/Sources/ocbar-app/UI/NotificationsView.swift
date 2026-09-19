import SwiftUI

// Какие уведомления показывать. Решает bin/ocbar — он читает эти же
// ключи из настроек ru.ocbar.app в момент отправки, поэтому переключатель
// действует сразу, без перезапуска супервизора.
struct NotificationsView: View {
    @AppStorage("NotifyLogin") private var login = true
    @AppStorage("NotifyProblems") private var problems = true
    @AppStorage("NotifyEvents") private var events = false
    @ObservedObject private var system = NotifyState.shared

    var body: some View {
        Form {
            if !system.allowed {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.slash.fill").foregroundStyle(Palette.warn)
                        Text("Система не показывает уведомления ocbar.")
                        Spacer()
                        Button("Разрешить…") { Notifier.openSettings() }
                    }
                }
            }
            Section {
                row($login, "Нужен вход", "Сессия истекла, молча войти не удалось")
                row($problems, "Проблемы со связью и доступом", "Связь потеряна, доступ не проходит, SOCKS не включён")
                row($events, "Восстановление соединения", "Связь вернулась, пауза и возобновление, перезапуск прокси")
            } header: {
                Text("Показывать")
            } footer: {
                Footnote("Одно и то же уведомление — не чаще раза в 10 минут. Стиль и звук — в Системных настройках.")
            }
            Section {
                HStack {
                    Button("Проверить уведомление") {
                        Notifier.show(title: "Проверка", body: "Так выглядят уведомления ocbar.")
                    }
                    Spacer()
                    Button("Системные настройки…") { Notifier.openSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Уведомления")
        .onAppear { Notifier.refreshAllowed() }
    }

    private func row(_ on: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
