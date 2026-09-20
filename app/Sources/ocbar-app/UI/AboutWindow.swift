import SwiftUI

enum AppInfo {
    // Версия одна на всех — VERSION в bin/ocbar. make-app.sh кладёт её в
    // Info.plist, отсюда она и читается; вторую константу в коде заводить
    // незачем: они уже расходились.
    static let version: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (v?.isEmpty == false) ? v! : L("из исходников (без бандла)")
    }()
}

// Окно «о программе»: версии всех частей и где что лежит. Полезно не из
// вежливости — по этим строкам видно, что хелпер отстал от CLI или что
// openconnect обновился и манифест доверия разошёлся.
struct AboutView: View {
    @State private var v: [String: String] = [:]
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppMark(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ocbar").font(.system(size: 20, weight: .semibold))
                        Text(L("Клиент OpenConnect для macOS: SSO, split DNS, split tunneling"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(L("ValeraGin — Ignatkovich Valery · лицензия MIT"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                part(L("Приложение"), AppInfo.version, Bundle.main.executablePath ?? "")
                part(L("Клиент ocbar"), v["ocbar"], v["ocbar_path"])
                part(L("Хелпер (root)"), helperVersion, v["helper_path"])
                part("openconnect", v["openconnect"], v["openconnect_path"])
                part(L("Копия для root"), nil, v["openconnect_root"])
                part(L("Аутентификатор"), L("как ocbar"), v["auth_path"])
            } header: {
                Text(L("Компоненты"))
            } footer: {
                Footnote(L("Приложению права не нужны: всё привилегированное делает хелпер. ")
                     + (GlobalHotkeys.shared.isRegistered("pause")
                        ? L("Пауза — ⌥⌘P из любой программы.") : L("⌥⌘P занято другой программой: пауза только из меню.")))
            }
            Section {
                HStack {
                    Button(L("Журналы")) { openWindow(id: WindowID.logs) }
                    Button(L("Диагностика")) { openWindow(id: WindowID.diagnostics) }
                    Spacer()
                }
                reveal(L("Каталог конфигурации"), v["config_dir"] ?? OcbarClient.shared.configDir)
                reveal(L("Приложение"), v["app_path"] ?? (Bundle.main.bundlePath))
                reveal(L("Журнал супервизора"), v["supervisor_log"] ?? OcbarClient.shared.supervisorLog)
                reveal(L("Журнал openconnect"), v["openconnect_log"] ?? OcbarClient.shared.openconnectLog)
                reveal(L("Журнал приложения"), AppLog.path)
            } header: {
                Text(L("Где что лежит"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L("О программе"))
        .onAppear { load() }
    }

    private var helperVersion: String? {
        guard let version = v["helper"], !version.isEmpty else { return nil }
        return v["helper_nopasswd"] == "1" ? version : version + L(" · без NOPASSWD")
    }

    private func part(_ title: String, _ version: String?, _ path: String?) -> some View {
        Group {
            if let path, !path.isEmpty {
                LabeledContent {
                    Text(version ?? "—").font(.system(size: 12, design: .monospaced))
                } label: {
                    Text(title)
                    Text(Self.short(path)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                }
            }
        }
    }

    /// Путь с «~» вместо домашнего каталога: короче и не светит имя учётной записи.
    static func short(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func reveal(_ title: String, _ path: String) -> some View {
        LabeledContent(title) {
            Button(Self.short(path)) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .buttonStyle(.link).lineLimit(1).truncationMode(.head)
            .help(L("Показать в Finder"))
        }
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let map = OcbarClient.shared.versions(maxAge: 5)
            DispatchQueue.main.async { v = map }
        }
    }
}

enum WindowID {
    static let settings = "settings"
    static let logs = "logs"
    static let diagnostics = "diagnostics"
    static let setup = "setup"
}
