import SwiftUI

// Какие уведомления показывать (D69). Решает bin/ocbar — он читает эти же
// ключи из настроек ru.ocbar.app в момент отправки, поэтому переключатель
// действует сразу, без перезапуска супервизора.
struct NotificationsView: View {
    @AppStorage("NotifyLogin") private var login = true
    @AppStorage("NotifyProblems") private var problems = true
    @AppStorage("NotifyEvents") private var events = false
    @ObservedObject private var system = NotifyState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !system.allowed {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash").foregroundStyle(Palette.warn)
                    Text("Система не показывает уведомления ocbar — переключатели ниже ни на что не влияют.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Разрешить…") { Notifier.openSettings() }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.warn.opacity(0.12)))
            }
            row($login, "Нужен вход",
                "Сессия истекла и молча войти не удалось; автоподключение остановлено из-за лимита входов.")
            row($problems, "Проблемы со связью и доступом",
                "Связь потеряна и не восстановилась, подключиться не удаётся, туннель поднят, но проверка доступа не проходит, системный SOCKS не включён.")
            row($events, "Восстановление и переподключения",
                "Связь восстановилась сама, супервизор подключил заново, пауза и возобновление, прокси перезапущен. Всё это видно и в меню.")
            Text("Одно и то же уведомление приходит не чаще раза в 10 минут. «Подключено» после вашего нажатия не приходит — итог видно в меню. Стиль и звук — в Системных настройках.")
                .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Проверить уведомление") {
                    Notifier.show(title: "Проверка", body: "Так выглядят уведомления ocbar.")
                }
                Button("Системные настройки…") { Notifier.openSettings() }
                Spacer()
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { Notifier.refreshAllowed() }
    }

    private func row(_ on: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: on).toggleStyle(.switch).labelsHidden().tint(Palette.ok)
        }
    }
}
