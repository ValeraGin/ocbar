import Foundation

/// Перевод строк окон ocbar-auth. Ключ — русский текст, как в приложении
/// (app/…/Localization.swift): пропущенный перевод показывается по-русски, а
/// не ключом. Бандла у ocbar-auth нет — это голый файл в libexec, — поэтому
/// перевод лежит в коде (Translations.swift), а язык выбирается тем же
/// правилом, что у приложения: первый из ru/en в языках системы, иначе ru.
/// OCBAR_LANG=ru|en — явно (самопроверки, снимки окон).
///
/// Журнал и ответы для ocbar (Log.*, out) не переводятся: их читает клиент
/// и сверяет самопроверка.
enum Lang {
    static var current: String = {
        if let forced = ProcessInfo.processInfo.environment["OCBAR_LANG"], ["ru", "en"].contains(forced) { return forced }
        return Bundle.preferredLocalizations(from: ["ru", "en"], forPreferences: Locale.preferredLanguages).first ?? "ru"
    }()
}

func L(_ ru: String) -> String {
    Lang.current == "en" ? (Translations.en[ru] ?? ru) : ru
}

/// С подстановками: каждое значение текстом встаёт на место очередного %@.
func L(_ ru: String, _ args: Any...) -> String {
    var out = L(ru)
    for arg in args {
        guard let r = out.range(of: "%@") else { break }
        out.replaceSubrange(r, with: "\(arg)")
    }
    return out
}
