import SwiftUI
import MacControlCenterUI

// Пробное меню в духе модулей Wi‑Fi и Bluetooth на компонентах MacControlCenterUI:
// заголовок со свитчем, профили строками с круглым значком, сети и зоны —
// раскрытием на месте, команды внизу. Пока только витрина (--frame native-…),
// действия не подключены.
struct NativeMenuView: View {
    @EnvironmentObject var store: StatusStore
    @State private var networksExpanded = true
    @State private var zonesExpanded = false

    private var status: Status { store.status }
    private var up: Bool { status.state == .connected || status.state == .paused }

    var body: some View {
        MacControlCenterMenu(isPresented: .constant(true)) {
            MenuHeader("VPN") {
                Toggle("", isOn: .constant(up)).toggleStyle(.switch).labelsHidden()
            }
            MenuSection(divider: false) {
                ForEach(status.profiles) { profile in
                    let active = profile.name == status.profile && up
                    MenuToggle(isOn: .constant(active), image: Image(systemName: "lock.fill")) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.display)
                            if profile.name == status.profile {
                                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            MenuDisclosureSection(L("Сети в туннеле"), isExpanded: $networksExpanded) {
                ForEach(status.routes) { route in
                    MenuToggle(isOn: .constant(route.enabled), style: .checkmark()) {
                        Text(route.net).font(.system(size: 12).monospaced())
                    }
                }
            }
            MenuDisclosureSection(L("DNS-зоны"), isExpanded: $zonesExpanded) {
                ForEach(status.zones) { zone in
                    MenuToggle(isOn: .constant(zone.enabled), style: .checkmark()) {
                        HStack {
                            Text(zone.zone).font(.system(size: 12).monospaced())
                            Spacer()
                            Text(zone.dns).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            MenuCommand(status.paused ? L("Возобновить") : L("Приостановить")) {}
            MenuCommand(L("Настройки…")) {}
            MenuCommand(L("Диагностика и журналы…")) {}
            MenuCommand(L("Выйти из ocbar")) {}
        }
    }

    private var subtitle: String {
        switch status.state {
        case .connected: return L("Подключено")
        case .paused: return L("Приостановлено")
        case .starting: return L("Подключается…")
        case .down: return status.needsLogin ? L("Нужен вход") : L("Отключено")
        }
    }
}
