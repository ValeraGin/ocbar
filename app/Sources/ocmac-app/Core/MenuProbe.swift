import AppKit
import AVFoundation
import SwiftUI

// Проверка живого меню без человека: меню собирается из живого состояния —
// пункты есть, у текущего профиля вторая строка. Размер, место и закрытие —
// у системы (NSHostingMenu), мерить нечего; меню на экране не открывается.
//
//   open "ocmac://debug-menu?token=<токен уведомлений>"
enum MenuProbe {
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "ocmac", url.host == "debug-menu" else { return false }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "token" }?.value
        guard let token, let expected = Notifier.expectedToken, !expected.isEmpty,
              token == expected else {
            AppLog.write("debug-menu: чужой токен — пропускаю")
            return true
        }
        DispatchQueue.main.async { run() }
        return true
    }

    @MainActor private static func run() {
        guard let hosted = AppDelegate.hosted else { AppLog.write("проверка меню: ИТОГ ПЛОХО — меню нет"); return }
        hosted.menu.update()
        let items = hosted.menu.items
        let subtitles = items.compactMap { $0.subtitle }.filter { !$0.isEmpty }
        AppLog.write(items.count > 3 && !subtitles.isEmpty
                     ? "проверка меню: ИТОГ ОК — меню NSHostingMenu, пунктов \(items.count)"
                     : "проверка меню: ИТОГ ПЛОХО — пунктов \(items.count), подзаголовков \(subtitles.count)")
    }
}

// Права без человека: видит ли ocmac-auth, запущенный через ocmac (как у
// кнопок «Снять QR с экрана…» и «Камерой…»), те же права, что само
// приложение. Если нет — подсказка про право будет врать.
//
//   open "ocmac://debug-access?token=<токен уведомлений>"
//   итог — строка «проверка прав: ИТОГ» в app.log
enum AccessProbe {
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "ocmac", url.host == "debug-access" else { return false }
        let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "token" }?.value
        guard let token, let expected = Notifier.expectedToken, !expected.isEmpty, token == expected else {
            AppLog.write("debug-access: чужой токен — пропускаю")
            return true
        }
        DispatchQueue.global(qos: .utility).async { run() }
        return true
    }

    static func own() -> (screen: String, camera: String) {
        let screen = CGPreflightScreenCaptureAccess() ? "granted" : "denied"
        let camera: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = "authorized"
        case .denied: camera = "denied"
        case .restricted: camera = "restricted"
        case .notDetermined: camera = "not-determined"
        @unknown default: camera = "unknown"
        }
        return (screen, camera)
    }

    /// «screen=granted camera=authorized» → поля.
    static func parse(_ line: String) -> [String: String] {
        var d: [String: String] = [:]
        for part in line.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { d[kv[0]] = kv[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return d
    }

    private static func run() {
        let mine = own()
        guard let binary = OCMacClient.shared.binary else { AppLog.write("проверка прав: ИТОГ ПЛОХО — ocmac не найден"); return }
        let r = Shell.run(binary, ["secret", "access"], timeout: 20)
        let theirs = parse(r.out)
        AppLog.write("проверка прав: приложение screen=\(mine.screen) camera=\(mine.camera); через ocmac \(r.out.trimmed)")
        let same = theirs["screen"] == mine.screen && theirs["camera"] == mine.camera
        AppLog.write(same ? "проверка прав: ИТОГ ОК — совпадает"
                          : "проверка прав: ИТОГ ПЛОХО — расходится (код \(r.code)\(r.err.isEmpty ? "" : ", " + r.err.trimmed))")
    }
}
