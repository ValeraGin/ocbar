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

/// То же с подстановками: «Всегда: %@».
func L(_ ru: String, _ args: CVarArg...) -> String {
    String(format: L(ru), arguments: args)
}
