import SwiftUI

// Одно окно настройки, как «Системные настройки»: слева разделы со значками,
// справа содержимое. У «Профилей» своя средняя колонка — список профилей, —
// а у редактора части «Подключение / Режим / Сети и DNS».
struct SettingsWindow: View {
    enum Tab: Int, CaseIterable, Identifiable { case profiles, notifications, general, about
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .profiles: return "Профили"
            case .notifications: return "Уведомления"
            case .general: return "Общие"
            case .about: return "О программе"
            }
        }
        var symbol: String {
            switch self {
            case .profiles: return "list.bullet"
            case .notifications: return "bell.badge.fill"
            case .general: return "gearshape.fill"
            case .about: return "info"
            }
        }
        var color: Color {
            switch self {
            case .profiles: return Palette.accent
            case .notifications: return Palette.bad
            case .general: return .gray
            case .about: return Palette.violet
            }
        }
    }

    @ObservedObject private var store = StatusStore.shared
    // Витрина (--stage --screenshot settings --tab N) открывает нужный раздел.
    @State private var tab: Tab? = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--tab"), i + 1 < a.count, let n = Int(a[i + 1]), let t = Tab(rawValue: n) { return t }
        return .profiles
    }()

    var body: some View {
        // Не NavigationSplitView: он ставит в заголовок кнопку «скрыть боковую
        // панель», а убрать её можно только с macOS 14. Панель здесь не
        // прячется — она и есть навигация.
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 600)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
            AppMark(size: 30)
            Text("ocbar").font(.system(size: 15, weight: .semibold))
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
        List(selection: $tab) {
            ForEach(Tab.allCases) { t in
                Label {
                    Text(t.title)
                } icon: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.color))
                }
                .tag(t)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        connectionLine
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    // Внизу боковой панели — состояние подключения: видно, что правишь,
    // не открывая меню.
    private var connectionLine: some View {
        let look = StateLook.of(store.status)
        return HStack(spacing: 8) {
            StateDot(color: look.color, pulsing: look.pulsing)
            Text(look.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var detail: some View {
        switch tab ?? .profiles {
        case .profiles: ProfileEditorView()
        case .notifications: NotificationsView()
        case .general: GeneralView()
        case .about: AboutView()
        }
    }
}
