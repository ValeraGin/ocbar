import SwiftUI
import AppKit

// Одна форма с вкладками: выбор раздела не отнимает колонку у полей.
struct SettingsWindow: View {
    static let width: CGFloat = 580
    static let height: CGFloat = 610
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
        .frame(width: Self.width, height: Self.height)
        .background(FixedSettingsWindow())
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

// Preferences stay a small utility window, including the title-bar zoom action.
private struct FixedSettingsWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.lockWindow() }

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.lockWindow() }
        }
        func lockWindow() {
            guard let window else { return }
            window.styleMask.remove(.resizable)
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
    }
}
