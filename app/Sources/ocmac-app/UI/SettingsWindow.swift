import SwiftUI

// Одна форма с вкладками: выбор раздела не отнимает колонку у полей.
struct SettingsWindow: View {
    enum Tab: Int, CaseIterable, Identifiable { case profiles, notifications, general, about
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .profiles: return L("Профили")
            case .notifications: return L("Уведомления")
            case .general: return L("Общие")
            case .about: return L("О программе")
            }
        }
    }

    // Витрина (--stage --screenshot settings --tab N) открывает нужный раздел.
    @State private var tab: Tab? = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--tab"), i + 1 < a.count, let n = Int(a[i + 1]), let t = Tab(rawValue: n) { return t }
        return .profiles
    }()

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("Настройки…"), selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.title).tag(Optional(t))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 580, maxWidth: 720, minHeight: 610)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Palette.control)
        .accentColor(Palette.control)
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
