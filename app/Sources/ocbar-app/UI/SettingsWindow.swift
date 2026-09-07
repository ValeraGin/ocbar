import SwiftUI

// Одно окно настройки вместо трёх пунктов в меню: меню — это состояние и
// действия, а не список окон. Переключатель свой, а не TabView: у него
// предсказуемый вид и он не спорит с размерами вложенных экранов.
struct SettingsWindow: View {
    enum Tab: Int, CaseIterable { case profiles, mode, about
        var title: String {
            switch self {
            case .profiles: return "Профили"
            case .mode: return "Режим"
            case .about: return "О программе"
            }
        }
    }

    @State private var tab: Tab = .profiles

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 340)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .profiles: ProfileEditorView()
            case .mode: ModeView()
            case .about:
                AboutView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 740, minHeight: 560)
    }
}
