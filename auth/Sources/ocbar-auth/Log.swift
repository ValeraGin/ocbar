import Foundation

/// Всё служебное — в stderr. stdout оставлен под результат (JSON или probe),
/// чтобы вызывающий скрипт мог просто его прочитать.
enum Log {
    static var verbose = false

    static func info(_ s: String) { write("ocbar-auth: \(s)") }
    static func debug(_ s: String) { if verbose { write("ocbar-auth[debug]: \(s)") } }
    static func error(_ s: String) { write("ocbar-auth: ошибка: \(s)") }

    private static func write(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// Адрес для журнала: схема, хост, порт и путь — без query и fragment.
    /// В query у SAML и у порталов ходят RelayState, коды и одноразовые
    /// ссылки, а супервизор пишет весь вывод в журнал, живущий до ротации.
    static func redact(_ url: URL?) -> String {
        guard let url else { return "?" }
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "?" }
        let cut = c.query != nil || c.fragment != nil
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        return (c.string ?? url.host ?? "?") + (cut ? "?…" : "")
    }

    static func redact(_ s: String) -> String { redact(URL(string: s)) }
}

/// Прячет значения токенов в отладочной печати — ВСЕ вхождения, в том числе
/// с атрибутами у тега. Тело auth-reply содержит рабочий session-token, а
/// супервизор пишет весь вывод в журнал, который живёт до ротации.
func mask(_ s: String) -> String {
    let pattern = "<(session-token|sso-token|session-id)(\\s[^>]*)?>(.*?)</\\1\\s*>"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return s }
    var out = s
    let ns = s as NSString
    // С конца: замена меняет длину, и индексы следующих совпадений иначе
    // уехали бы.
    for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
        let inner = m.range(at: 3)
        guard inner.length > 0, let r = Range(inner, in: out) else { continue }
        out.replaceSubrange(r, with: "\(inner.length) символов скрыто")
    }
    return out
}
