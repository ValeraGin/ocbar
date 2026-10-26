import Foundation
import Observation

/// Перевод строки интерфейса. Ключ — русский текст: он же и показывается,
/// когда перевода нет, поэтому пропущенная строка выглядит как раньше, а не
/// как «missing_key_42».
///
/// Почему не литералы SwiftUI: часть текста собирается из кусков и
/// подстановок, а такие строки SwiftUI не переводит вовсе. Явный вызов
/// работает везде одинаково, и его видно сборщику строк (tools/i18n-scan.py).
func L(_ ru: String) -> String {
    if selfTestInRussian { return ru }
    return AppLanguage.shared.translate(ru)
}

/// `--selftest` идёт на русском при любом языке системы: проверки сверяют
/// русский текст подсказок и сообщений (как `ocmac selftest` с OCMAC_LANG=ru).
/// Иначе на английской системе они падали бы, а на русской — проходили.
let selfTestInRussian = CommandLine.arguments.contains("--selftest")

/// То же с подстановками: «Всегда: %@». Значения любые: каждое становится
/// текстом и встаёт на место очередного %@. String(format:) здесь не годится —
/// число, переданное в %@, роняло приложение (так упало окно журналов).
func L(_ ru: String, _ args: Any...) -> String {
    var out = L(ru)
    for arg in args {
        guard let r = out.range(of: "%@") else { break }
        out.replaceSubrange(r, with: "\(arg)")
    }
    return out
}

/// Observation обновляет и окна, и NSHostingMenu при чтении L() из body.
@Observable
final class AppLanguage {
    static let shared = AppLanguage()
    @ObservationIgnored private let defaults: UserDefaults
    var selection: String {
        didSet { defaults.set(selection, forKey: "InterfaceLanguage") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: "InterfaceLanguage") ?? "system"
    }

    static func resolve(_ selection: String, environment: String? = nil,
                        preferred: [String] = Locale.preferredLanguages) -> String {
        if let environment, ["ru", "en"].contains(environment) { return environment }
        if ["ru", "en"].contains(selection) { return selection }
        return Bundle.preferredLocalizations(from: ["ru", "en"], forPreferences: preferred).first ?? "ru"
    }

    var current: String {
        Self.resolve(selection, environment: ProcessInfo.processInfo.environment["OCMAC_LANG"])
    }

    func translate(_ key: String) -> String {
        guard current == "en", let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
