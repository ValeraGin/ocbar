import Foundation

/// Правила автозаполнения формы IdP.
///
/// Формат файла — по строке на правило, поля через пробелы:
///     stop   <селектор>              прервать заполнение, если элемент видим
///     fill   username|password|totp  <селектор>
///     fill   manual <селектор>       поле, которое вводит человек (капча и
///                                    прочее, чего ocbar не знает): не
///                                    заполняется, но пока пустое — кнопки
///                                    не жмутся
///     click  <селектор>              нажать — ТОЛЬКО если в этом же проходе что-то заполнили
///     click! <селектор>              нажать и без заполнения: экран без полей
///                                    («Остаться в системе?», «другой способ входа»)
///
/// Любая кнопка, и `click!` тоже, НЕ жмётся, пока на странице видно пустое
/// поле из правил `fill`: заполнить его нечем (пароль вводит человек, код уже
/// потрачен) — значит, форму отправлять рано, её увидит человек. Иначе
/// общая кнопка (у Microsoft одна на всех экранах) отправила бы пустой
/// пароль, а несколько таких подряд блокируют учётную запись.
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
    ///
    /// `allowed` — где можно заполнять (FillScope.jsAllowed): хост проверяется
    /// и здесь, в момент выполнения. Между проверкой в Swift и выполнением
    /// скрипта страница успевает смениться (редирект), и без этой проверки
    /// логин с паролем ушли бы на следующую. nil — без проверки (--dump-script
    /// без --fill-hosts). Скрипт выполняется в изолированном мире
    /// (WebAuth.world): страница не может подменить ни location, ни
    /// встроенные функции, которыми он сравнивает хост.
    static func script(rules: [AutofillRule], creds: Credentials, totpCode: String?,
                       allowed: [[String: Any]]? = nil) -> String {
        var body = "(function(){\n"
        if let allowed {
            let aj = String(data: (try? JSONSerialization.data(withJSONObject: allowed, options: [.sortedKeys])) ?? Data("[]".utf8),
                            encoding: .utf8) ?? "[]"
            body += "  var allowed = \(aj), here = String(location.hostname).toLowerCase();\n"
            body += "  var hostOK = location.protocol === 'https:' && allowed.some(function(a){ return here === a.h || (a.s && here.length > a.h.length && here.slice(-a.h.length - 1) === '.' + a.h); });\n"
            body += "  if (!hostOK) return {offHost: here, filled: []};\n"
        }
        body += "  var visible = function(e){ return e && e.offsetParent !== null; };\n"
        body += "  var filled = [];\n"
        // Все поля из правил fill — и те, которым нечем заполниться: видимое
        // пустое поле из этого списка запрещает любое нажатие.
        let known = rules.compactMap { r -> String? in if case .fill = r.action { return r.selector }; return nil }
        let knownJSON = String(data: (try? JSONSerialization.data(withJSONObject: known)) ?? Data("[]".utf8),
                               encoding: .utf8) ?? "[]"
        body += "  var known = \(knownJSON);\n"
        body += "  var emptyKnown = function(){ for (var i = 0; i < known.length; i++) { var k; try { k = document.querySelector(known[i]); } catch (x) { continue; } if (visible(k) && !k.value) return known[i]; } return null; };\n"
        for r in rules {
            let sel = jsString(r.selector)
            switch r.action {
            case .stop:
                // filled — и здесь: stop может стоять после fill, и подставленное
                // до него должно попасть в счётчики (AutofillGate).
                body += "  { var e = document.querySelector(\(sel)); if (visible(e)) return {stopped: (e.innerText||'').trim().slice(0,200), filled: filled}; }\n"
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
                      window.__ocbarFilledHere = true;
                    } }

                """
            case .click(let unconditional):
                // Жмём, если подставили в этой попытке или раньше на этой же
                // странице (__ocbarFilledHere живёт в изолированном мире до
                // смены документа): формы на Vue и React включают кнопку не
                // сразу после ввода. Неактивную не жмём — ждём следующей
                // попытки: нажатие в неактивную кнопку пропадало, а повторять
                // его на той же странице было нельзя.
                let cond = unconditional ? "visible(e) && !emptyKnown()"
                    : "visible(e) && (filled.length > 0 || window.__ocbarFilledHere) && !emptyKnown()"
                body += "  { var e = document.querySelector(\(sel)); if (\(cond)) { if (e.disabled || e.getAttribute('aria-disabled') === 'true') return {pending: \(sel), filled: filled}; e.click(); return {clicked: \(sel), filled: filled}; } }\n"
            }
        }
        // Что видит человек, если мы ничего не сделали: список видимых полей —
        // по нему в логе понятно, какую форму мы не распознали.
        body += "  var seen = []; document.querySelectorAll('input').forEach(function(i){ if (visible(i)) seen.push((i.type||'')+':'+(i.name||i.id||'')); });\n"
        body += "  return {filled: filled, inputs: seen, waiting: emptyKnown()};\n})()"
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

/// Где можно заполнять форму и куда пускать всплывающие окна — без WebKit,
/// чтобы проверять напрямую.
///
/// Только https: по http логин с паролем ушли бы открытым текстом.
///
/// С IdpHosts (--fill-hosts) — только эти хосты и их поддомены: человек
/// сказал явно.
///
/// Без IdpHosts — хосты цепочки входа, точным совпадением:
///  - хост шлюза (к нему проверен TLS, он выдал адрес входа);
///  - всё, куда уходит главный документ, пока он ещё не открыт или открыт
///    на хосте шлюза: адрес sso-v2-login, серверные перенаправления с него,
///    автоотправка SAML-формы со страницы шлюза (привязка HTTP-POST) и
///    перенаправления провайдера входа в этой же навигации. Эти адреса
///    выбирают шлюз и провайдер, которого назначил шлюз, а не случайная
///    страница;
///  - дальше — только туда, куда человек перешёл сам: навигация главного
///    документа в видимом окне в пределах нескольких секунд после
///    настоящего (isTrusted) щелчка или нажатия клавиши.
/// Переход, который страница провайдера сделала сама (скрипт, ссылка из
/// рекламы, window.open), цепочку не продлевает: там заполняет человек.
/// Раньше без IdpHosts заполнялось на любом хосте, куда уведёт страница, в
/// том числе в молчаливом режиме супервизора.
struct FillScope {
    let explicit: [String]
    let gatewayHosts: Set<String>
    private(set) var chain: Set<String>
    private(set) var documentHost: String?     // хост текущего главного документа

    init(explicit: [String], gatewayHosts: [String]) {
        self.explicit = explicit.map { $0.lowercased() }.filter { !$0.isEmpty }
        self.gatewayHosts = Set(gatewayHosts.map { $0.lowercased() }.filter { !$0.isEmpty })
        chain = self.gatewayHosts
    }

    static func host(_ url: URL?) -> String? {
        guard let h = url?.host?.lowercased(), !h.isEmpty else { return nil }
        return h
    }

    private static func https(_ url: URL?) -> Bool { url?.scheme?.lowercased() == "https" }

    private func explicitMatch(_ h: String) -> Bool {
        explicit.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Можно ли заполнять форму на этой странице.
    func allowsFill(_ url: URL?) -> Bool {
        guard Self.https(url), let h = Self.host(url) else { return false }
        return explicit.isEmpty ? chain.contains(h) : explicitMatch(h)
    }

    /// Можно ли увести главное окно входа на адрес из window.open или
    /// target=_blank. Без жеста человека WebKit такие окна не открывает
    /// вовсе (javaScriptCanOpenWindowsAutomatically = false), а с жестом —
    /// только на хост цепочки входа или из IdpHosts, по https.
    func allowsPopup(_ url: URL?) -> Bool {
        guard Self.https(url), let h = Self.host(url) else { return false }
        return chain.contains(h) || explicitMatch(h)
    }

    enum Reason: Equatable { case already, gatewayChain, human, refused }

    /// Главный документ уходит на url (и на каждое серверное
    /// перенаправление). humanRecent — только что был настоящий жест
    /// человека в видимом окне.
    mutating func navigation(to url: URL, humanRecent: Bool) -> Reason {
        guard Self.https(url), let h = Self.host(url) else { return .refused }
        if chain.contains(h) { return .already }
        if documentHost == nil || gatewayHosts.contains(documentHost ?? "") {
            chain.insert(h)
            return .gatewayChain
        }
        if humanRecent {
            chain.insert(h)
            return .human
        }
        return .refused
    }

    /// Главный документ открылся (didCommit).
    mutating func committed(_ url: URL?) {
        if let h = Self.host(url) { documentHost = h }
    }

    /// Список для проверки внутри скрипта (Autofill.script, allowed).
    var jsAllowed: [[String: Any]] {
        explicit.isEmpty ? chain.sorted().map { ["h": $0, "s": false] }
                         : explicit.map { ["h": $0, "s": true] }
    }
}

/// Решения цикла автозаполнения — без WebKit, чтобы проверять их напрямую
/// (`ocbar-auth --selftest`). Окно входа только спрашивает: можно ли
/// запускать скрипт, что ему дать и что делать с результатом.
///
/// Лимиты:
///  - код одноразовый — подставляется РОВНО один раз за вход: несколько
///    неверных кодов подряд блокируют учётную запись;
///  - пароль — не больше двух раз. Два, а не один: Microsoft прячет на
///    странице логина второе поле пароля для менеджеров паролей. Третий раз —
///    это уже неверный пароль по кругу, а порталы блокируют учётку после
///    трёх-пяти попыток;
///  - нажатий — не больше пяти за вход: у Microsoft с кодом и «Остаться в
///    системе?» выходит четыре;
///  - на неизменившейся странице после нажатия скрипт не повторяется —
///    иначе «Войти» жмётся в цикле на форме с ошибкой;
///  - на одной странице — не больше двенадцати попыток.
///
/// Счётчики пароля и кода считаются ДО любого раннего выхода. Раньше ветка
/// «ждём человека» (видно пустое поле `fill manual`) выходила раньше них, и
/// портал с капчей, перерисовывающий форму, получал пароль снова и снова.
struct AutofillGate {
    let maxClicks = 5
    let maxPasswordFills = 2
    let maxAttemptsPerPage = 12
    let reclickAfter: TimeInterval = 4
    private(set) var clicks = 0
    private(set) var passwordFills = 0
    private(set) var totpFills = 0
    private(set) var attempts = 0
    private(set) var lastClickSignature: String?
    private(set) var lastClickAt: Date?
    private(set) var reclicked = false
    private(set) var stopped: String?

    /// Что можно дать скрипту в этой попытке.
    struct Offer: Equatable { var password: Bool; var code: Bool }

    /// Что вернул скрипт (Autofill.script).
    struct Outcome {
        var filled: [String] = []
        var clicked: String? = nil
        var waiting: String? = nil
        var stopped: String? = nil
        var inputs: [String] = []
        var offHost: String? = nil
        var pending: String? = nil             // кнопка есть, но неактивна

        init(filled: [String] = [], clicked: String? = nil, waiting: String? = nil,
             stopped: String? = nil, inputs: [String] = [], offHost: String? = nil, pending: String? = nil) {
            self.filled = filled; self.clicked = clicked; self.waiting = waiting
            self.stopped = stopped; self.inputs = inputs; self.offHost = offHost; self.pending = pending
        }

        init(_ dict: [String: Any]) {
            filled = (dict["filled"] as? [String]) ?? []
            clicked = dict["clicked"] as? String
            waiting = dict["waiting"] as? String
            stopped = dict["stopped"] as? String
            inputs = (dict["inputs"] as? [String]) ?? []
            offHost = dict["offHost"] as? String
            pending = dict["pending"] as? String
        }
    }

    enum Next: Equatable {
        case keepGoing                 // ничего не случилось — следующая попытка по таймеру
        case clicked(String)           // нажали — ждём новую страницу
        case pendingClick(String)      // кнопка неактивна — жмём в следующей попытке
        case waitingHuman(String)      // видно пустое поле, заполнить нечем
        case unknownForm([String])     // поля есть, ни одно не узнано
        case offHost(String)           // страница не из разрешённых — заполняет человек
        case formError(String)         // правило stop: форма показала ошибку
        case clickLimit                // лимит нажатий — дальше только человек
    }

    struct Decision: Equatable {
        var next: Next
        var countedPassword = false
        var countedCode = false
        var passwordLimitReached = false
    }

    /// Новая страница: попытки и запрет повтора — заново, лимиты входа — нет.
    mutating func newPage() { attempts = 0; lastClickSignature = nil; lastClickAt = nil; reclicked = false }

    /// Можно ли запускать скрипт на странице с такой сигнатурой. После
    /// нажатия на той же странице — одно повторное, через reclickAfter
    /// секунд тишины (окно входа не зовёт скрипт, пока страница грузится):
    /// нажатие могло уйти в форму, которая ещё не была готова.
    func mayRun(signature: String, now: Date = Date()) -> Bool {
        guard stopped == nil, attempts < maxAttemptsPerPage else { return false }
        guard signature == lastClickSignature else { return true }
        guard !reclicked, let t = lastClickAt else { return false }
        return now.timeIntervalSince(t) >= reclickAfter
    }

    /// Попытка началась: что ей можно дать.
    mutating func begin() -> Offer {
        attempts += 1
        return Offer(password: passwordFills < maxPasswordFills, code: totpFills == 0)
    }

    /// Результат попытки. Первым делом — счётчики: что подставлено, то
    /// подставлено, как бы ни закончилась попытка.
    mutating func record(_ o: Outcome, signature: String, now: Date = Date()) -> Decision {
        var d = Decision(next: .keepGoing)
        if o.filled.contains("password") {
            passwordFills += 1
            d.countedPassword = true
            d.passwordLimitReached = passwordFills >= maxPasswordFills
        }
        if o.filled.contains("totp") {
            totpFills += 1
            d.countedCode = true
        }
        if let s = o.stopped {
            stopped = s
            d.next = .formError(s)
            return d
        }
        if let h = o.offHost {
            d.next = .offHost(h)
            return d
        }
        if let c = o.clicked {
            clicks += 1
            if signature == lastClickSignature { reclicked = true }
            lastClickSignature = signature
            lastClickAt = now
            if clicks >= maxClicks {
                stopped = "лимит автозаполнения"
                d.next = .clickLimit
            } else {
                d.next = .clicked(c)
            }
            return d
        }
        if let p = o.pending {
            d.next = .pendingClick(p)
            return d
        }
        if let w = o.waiting {
            d.next = .waitingHuman(w)
            return d
        }
        if o.filled.isEmpty && !o.inputs.isEmpty { d.next = .unknownForm(o.inputs) }
        return d
    }
}
