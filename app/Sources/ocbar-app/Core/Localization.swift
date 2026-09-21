import Foundation

/// Перевод строки интерфейса. Ключ — русский текст: он же и показывается,
/// когда перевода нет, поэтому пропущенная строка выглядит как раньше, а не
/// как «missing_key_42».
///
/// Почему не литералы SwiftUI: часть текста собирается из кусков и
/// подстановок, а такие строки SwiftUI не переводит вовсе. Явный вызов
/// работает везде одинаково, и его видно сборщику строк (tools/i18n-scan.py).
func L(_ ru: String) -> String {
    Bundle.main.localizedString(forKey: ru, value: ru, table: nil)
}

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
