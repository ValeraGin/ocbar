import SwiftUI

enum AppInfo {
    // Версия приложения идёт вслед за версией клиента: они выпускаются вместе.
    static let version = "0.1.0"
}

// Окно «о программе»: версии всех частей и где что лежит. Полезно не из
// вежливости — по этим строкам видно, что хелпер отстал от CLI или что
// openconnect обновился и манифест доверия разошёлся.
struct AboutView: View {
    @State private var v: [String: String] = [:]
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // Иконка приложения, если бандл собран с ней; иначе символ.
                if let icon = NSImage(named: NSImage.applicationIconName), icon.size.width > 0 {
                    Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                } else {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 30)).foregroundStyle(Palette.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ocbar").font(.system(size: 17, weight: .medium))
                    Text("Клиент OpenConnect для macOS: SSO, split DNS, split tunneling")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            VStack(spacing: 0) {
                part("Приложение", AppInfo.version, Bundle.main.executablePath ?? "")
                part("Клиент ocbar", v["ocbar"], v["ocbar_path"])
                part("Хелпер (root)", helperVersion, v["helper_path"])
                part("openconnect", v["openconnect"], v["openconnect_path"])
                part("Копия для root", nil, v["openconnect_root"])
                part("Аутентификатор", "как ocbar", v["auth_path"])
            }
            .padding(.horizontal, 18)

            VStack(alignment: .leading, spacing: 4) {
                Text("Приложению права не нужны: всё привилегированное делает хелпер, разрешённый через sudoers.")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(GlobalHotkeys.shared.isRegistered("pause")
                     ? "Пауза и возобновление — ⌥⌘P из любой программы."
                     : "Сочетание ⌥⌘P занято другой программой: пауза только из меню.")
                    .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("ValeraGin — Ignatkovich Valery").font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                    Text("· лицензия MIT").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                    Spacer()
                }
            }
            .padding(.horizontal, 18).padding(.top, 10)

            Divider().padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 6) {
                link("Журналы", "Супервизор и openconnect") { openWindow(id: WindowID.logs) }
                reveal("Каталог конфигурации", v["config_dir"] ?? OcbarClient.shared.configDir)
                reveal("Приложение", v["app_path"] ?? (Bundle.main.bundlePath))
                reveal("Журнал супервизора", v["supervisor_log"] ?? OcbarClient.shared.supervisorLog)
                reveal("Журнал openconnect", v["openconnect_log"] ?? OcbarClient.shared.openconnectLog)
            }
            .padding(.horizontal, 18).padding(.bottom, 16)
        }
        .frame(width: 460)
        .onAppear { load() }
    }

    private var helperVersion: String? {
        guard let version = v["helper"], !version.isEmpty else { return nil }
        return v["helper_nopasswd"] == "1" ? version : version + " · без NOPASSWD"
    }

    private func part(_ title: String, _ version: String?, _ path: String?) -> some View {
        Group {
            if let path, !path.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .frame(width: 118, alignment: .leading)
                    Text(version ?? "—").font(.ocMono).foregroundStyle(Palette.text)
                        .frame(width: 96, alignment: .leading)
                    Text(path).font(.ocMonoSmall).foregroundStyle(Palette.tertiary)
                        .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func link(_ title: String, _ note: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            }
        }
        .buttonStyle(.link)
    }

    private func reveal(_ title: String, _ path: String) -> some View {
        link(title, path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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
}
