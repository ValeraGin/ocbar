import SwiftUI

enum AppInfo {
    // Версия одна на всех — VERSION в bin/ocbar. make-app.sh кладёт её в
    // Info.plist, отсюда она и читается; вторую константу в коде заводить
    // незачем: они уже расходились.
    static let version: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (v?.isEmpty == false) ? v! : "из исходников (без бандла)"
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
                        Text("Клиент OpenConnect для macOS: SSO, split DNS, split tunneling")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("ValeraGin — Ignatkovich Valery · лицензия MIT")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                part("Приложение", AppInfo.version, Bundle.main.executablePath ?? "")
                part("Клиент ocbar", v["ocbar"], v["ocbar_path"])
                part("Хелпер (root)", helperVersion, v["helper_path"])
                part("openconnect", v["openconnect"], v["openconnect_path"])
                part("Копия для root", nil, v["openconnect_root"])
                part("Аутентификатор", "как ocbar", v["auth_path"])
            } header: {
                Text("Компоненты")
            } footer: {
                Footnote("Приложению права не нужны: всё привилегированное делает хелпер. "
                     + (GlobalHotkeys.shared.isRegistered("pause")
                        ? "Пауза — ⌥⌘P из любой программы." : "⌥⌘P занято другой программой: пауза только из меню."))
            }
            Section {
                HStack {
                    Button("Журналы") { openWindow(id: WindowID.logs) }
                    Button("Диагностика") { openWindow(id: WindowID.diagnostics) }
                    Spacer()
                }
                reveal("Каталог конфигурации", v["config_dir"] ?? OcbarClient.shared.configDir)
                reveal("Приложение", v["app_path"] ?? (Bundle.main.bundlePath))
                reveal("Журнал супервизора", v["supervisor_log"] ?? OcbarClient.shared.supervisorLog)
                reveal("Журнал openconnect", v["openconnect_log"] ?? OcbarClient.shared.openconnectLog)
                reveal("Журнал приложения", AppLog.path)
            } header: {
                Text("Где что лежит")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("О программе")
        .onAppear { load() }
    }

    private var helperVersion: String? {
        guard let version = v["helper"], !version.isEmpty else { return nil }
        return v["helper_nopasswd"] == "1" ? version : version + " · без NOPASSWD"
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
            .help("Показать в Finder")
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
