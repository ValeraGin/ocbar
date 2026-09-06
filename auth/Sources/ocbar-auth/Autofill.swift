import Foundation

/// Правила автозаполнения формы IdP.
///
/// Формат файла — по строке на правило, поля через пробелы:
///     stop   <селектор>              прервать заполнение, если элемент видим
///     fill   username|password|totp  <селектор>
///     click  <селектор>              нажать — ТОЛЬКО если в этом же проходе что-то заполнили
///     click! <селектор>              нажать безусловно (навигация: «другой способ входа»)
///
/// Порядок важен: правила применяются сверху вниз. Правила `stop` идут первыми,
/// чтобы не вводить пароль в форму, на которой уже показана ошибка.
///
/// Почему `click` условный: форма IdP меняется (сегодня TOTP, завтра SMS), и
/// нажать «Войти» на странице, которую мы не распознали, — значит отправить
/// пустое или чужое поле. Не уверены — не жмём, показываем окно человеку.
struct AutofillRule {
    enum Action { case stop, fill(String), click(unconditional: Bool) }
    let action: Action
    let selector: String
}

struct Credentials {
    var username: String?
    var password: String?
    var totpSecret: String?

    /// Секреты приходят через окружение, а не через argv: argv виден в `ps`.
    static func fromEnvironment() -> Credentials {
        let e = ProcessInfo.processInfo.environment
        return Credentials(username: e["OCBAR_USERNAME"],
                           password: e["OCBAR_PASSWORD"],
                           totpSecret: e["OCBAR_TOTP_SECRET"])
    }
}

enum Autofill {
    static func parse(file: String) -> [AutofillRule] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return parse(text: text)
    }

    static func parse(text: String) -> [AutofillRule] {
        var rules: [AutofillRule] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 2,
                                   omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "stop":
                rules.append(AutofillRule(action: .stop, selector: parts[1...].joined(separator: " ")))
            case "click":
                rules.append(AutofillRule(action: .click(unconditional: false), selector: parts[1...].joined(separator: " ")))
            case "click!":
                rules.append(AutofillRule(action: .click(unconditional: true), selector: parts[1...].joined(separator: " ")))
            case "fill":
                guard parts.count == 3 else { continue }
                rules.append(AutofillRule(action: .fill(parts[1]), selector: parts[2]))
            default:
                continue
            }
        }
        return rules
    }

    /// Собирает JS для одной попытки заполнения.
    ///
    /// Проверка `offsetParent !== null` обязательна: на странице IdP обычно висят
    /// скрытые поля прошлых шагов, и без неё пароль уедет не в тот input.
    static func script(rules: [AutofillRule], creds: Credentials, totpCode: String?) -> String {
        var body = "(function(){\n"
        body += "  var visible = function(e){ return e && e.offsetParent !== null; };\n"
        body += "  var filled = [];\n"
        for r in rules {
            let sel = jsString(r.selector)
            switch r.action {
            case .stop:
                body += "  { var e = document.querySelector(\(sel)); if (visible(e)) return {stopped: (e.innerText||'').trim().slice(0,200)}; }\n"
            case .fill(let what):
                let value: String?
                switch what {
                case "username": value = creds.username
                case "password": value = creds.password
                case "totp":     value = totpCode
                default:         value = nil
                }
                guard let v = value else { continue }
                body += """
                  { var e = document.querySelector(\(sel));
                    if (visible(e) && !e.value) {
                      var setter = Object.getOwnPropertyDescriptor(e.constructor.prototype, 'value').set;
                      setter.call(e, \(jsString(v)));
                      e.dispatchEvent(new Event('input', {bubbles: true}));
                      e.dispatchEvent(new Event('change', {bubbles: true}));
                      filled.push(\(jsString(what)));
                    } }

                """
            case .click(let unconditional):
                let cond = unconditional ? "visible(e)" : "visible(e) && filled.length > 0"
                body += "  { var e = document.querySelector(\(sel)); if (\(cond)) { e.click(); return {clicked: \(sel), filled: filled}; } }\n"
            }
        }
        // Что видит человек, если мы ничего не сделали: список видимых полей —
        // по нему в логе понятно, какую форму мы не распознали.
        body += "  var seen = []; document.querySelectorAll('input').forEach(function(i){ if (visible(i)) seen.push((i.type||'')+':'+(i.name||i.id||'')); });\n"
        body += "  return {filled: filled, inputs: seen};\n})()"
        return body
    }

    private static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = String(data: data, encoding: .utf8)!
        return String(arr.dropFirst().dropLast())
    }
}

extension Autofill {
    /// Встроенный generic-набор (Keycloak, Microsoft, типовые формы) — на случай,
    /// если файл правил не передан. Корпоративная специфика — в файле профиля.
    static let defaultRules: [AutofillRule] = parse(text: """
    stop  div[id=passwordError]
    stop  div.alert-error
    stop  span.kc-feedback-text
    fill  username input[type=email]
    fill  username input[name=username]
    fill  username input[id=username]
    fill  username input[name=login]
    fill  username input[name=user]
    fill  username input[id=login]
    fill  username input[id=email]
    fill  username input[autocomplete=username]
    fill  password input[id=password]
    fill  password input[name=password]
    fill  password input[name=passwd]
    fill  password input[type=password]
    fill  password input[autocomplete=current-password]
    click input[data-report-event=Signin_Submit]
    click div[data-value=PhoneAppOTP]
    click a[id=signInAnotherWay]
    fill  totp input[id=idTxtBx_SAOTCC_OTC]
    fill  totp input[name=otp]
    fill  totp input[name=totp]
    fill  totp input[id=otp]
    fill  totp input[name=otpCode]
    fill  totp input[id=totp]
    fill  totp input[autocomplete=one-time-code]
    fill  totp input[type=tel][maxlength='6']
    click input[id=kc-login]
    click button[id=kc-login]
    click input[name=login]
    click input[type=submit]
    click button[type=submit]
    click input[id=idSIButton9]
    click input[id=idSubmit_SAOTCC_Continue]
    """)
}
