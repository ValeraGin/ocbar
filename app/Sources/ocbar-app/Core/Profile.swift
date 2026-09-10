import Foundation

// Профиль одним файлом (.ocbar). Формат не изобретается заново: он описан
// в etc/example.ocbar и разбирается в bin/ocbar (pf_get/pf_section), а
// пишется так же, как это делает `ocbar export`.
//
// Разбор повторяет bin/ocbar до мелочей, потому что расхождение здесь —
// это сохранение, которое молча меняет смысл файла: CRLF и BOM, первое
// значение при повторе ключа (pf_get выходит на первом совпадении), первое
// слово строки сети, строка DNS без «=». Всё, чего редактор не понимает, —
// комментарии, чужие ключи и секции, строки без «=», — записывается обратно.

struct ZoneLine: Identifiable, Hashable {
    var zone: String
    var resolver: String    // адрес или "vpn" — резолвер, который прислал шлюз
    var port: String        // пусто = 53
    var rest: String = ""   // хвост строки после порта (например, «# офис») — CLI его не читает, но терять нельзя
    let id = UUID()
}

struct ProfileDoc {
    var fileName = ""       // имя файла без .ocbar, оно же имя профиля
    var name = ""
    var descr = ""
    var url = ""
    var user = ""
    var userAgent = ""
    var csdWrapper = ""
    var auth = ""           // пусто = sso
    // Строки секции [Routes] как есть: сеть — первое слово (как `read -r n _`
    // в bin/ocbar), хвост и строки-комментарии сохраняются на своих местах.
    var routes: [String] = []
    var zones: [ZoneLine] = []
    var password = "auto"
    var passwordCommand = ""
    var totp = "auto"
    var totpCommand = ""
    // Параметры кода для секрета в связке ключей (RFC 6238). Пишутся в файл,
    // только если отличаются от умолчания: SHA1, 6 цифр, 30 с.
    var totpAlgorithm = "SHA1"
    var totpDigits = "6"
    var totpPeriod = "30"
    var keepassEntry = ""
    var keepassDb = ""
    var keepassKeychain = ""
    var keychainService = ""
    var idpHosts = ""
    var health = ""
    // Как пускать трафик: tunnel — интерфейс и маршруты, proxy — локальный
    // SOCKS через ocproxy (docs/09-proxy-mode.md).
    var mode = "tunnel"
    var proxyPort = "11080"
    // Значение SystemProxy как в файле. Системный SOCKS включается только при
    // «on» (так читает CLI); другое значение — yes, 1 — для CLI значит off, и
    // переписывать его молча на «on» нельзя: это поменяло бы смысл файла.
    var systemProxyValue = "off"
    var systemProxy: Bool {
        get { systemProxyValue == "on" }
        set { systemProxyValue = newValue ? "on" : "off" }
    }
    var hasProxySection = false   // [Proxy] была в файле — пишется обратно и в туннельном режиме
    var rulesFile = ""            // [Auth] Rules — общий файл правил (для тех, кто держит один на всех)
    // [Autofill] — правила автозаполнения формы входа в самом профиле:
    // форма портала — свойство подключения, и файл, отданный коллеге,
    // должен входить так же. Строки как есть: stop/fill/click <селектор>.
    var autofill: [String] = []
    var notifications = ""        // [Connection] Notifications = off выключает уведомления
    // Ключи, которых редактор не знает. Хранятся и записываются обратно:
    // молча потерять строку из чужого профиля — худшее, что может сделать
    // редактор конфигурации.
    var extras: [(section: String, key: String, value: String)] = []
    // Строки, которые ocbar не читает, — комментарии и строки без «=» — по
    // секциям, в исходном порядке. Секция "" — всё, что до первой секции.
    var kept: [(section: String, line: String)] = []
    // Порядок секций в исходном файле: незнакомые пишутся в нём же.
    var sectionOrder: [String] = []
    // Повторы известных ключей. Действует первое значение (как pf_get), повтор
    // при записи не пишется — о нём предупреждает проверка.
    var duplicates: [String] = []

    static let defaultUserAgent = "AnyConnect Windows 4.10.06079"

    // Строки User-Agent, которыми клиенты AnyConnect представляются шлюзу.
    // Шлюзы иногда придираются к этой строке, поэтому список под рукой, а
    // поле остаётся свободным для ввода.
    static let knownUserAgents = [
        "AnyConnect Windows 4.10.06079",
        "AnyConnect Windows 4.9.04053",
        "AnyConnect Darwin_i386 4.10.06079",
        "AnyConnect Linux_64 4.10.06079",
        "Cisco AnyConnect VPN Agent for Windows 4.10.06079",
        "Open AnyConnect VPN Agent v9.21",
    ]

    // sms — код приходит по SMS и вводится человеком (как off, но с причиной).
    static let totpAlgorithms = ["SHA1", "SHA256", "SHA512"]
    static let totpSources = ["auto", "keychain", "keepassxc", "command", "sms", "off"]
    // Источник пароля — один из нескольких, как и источник кода: связка
    // ключей, база KeePassXC, произвольная команда, «вводит человек».
    static let passwordSources = ["auto", "keychain", "keepassxc", "command", "ask"]

    // Ключи, которые редактор понимает, по секциям (в нижнем регистре).
    static let knownKeys: [String: Set<String>] = [
        "connection": ["name", "description", "url", "user", "useragent", "csdwrapper", "auth", "mode", "notifications"],
        "auth": ["password", "passwordcommand", "totp", "totpcommand", "totpalgorithm", "totpdigits", "totpperiod",
                 "keepassentry", "keepassdb", "keepasskeychain", "keychainservice", "idphosts", "rules"],
        "proxy": ["port", "systemproxy"],
        "health": ["check"],
    ]
    static let knownSections: Set<String> = ["connection", "routes", "dns", "auth", "proxy", "health", "autofill"]

    // --- разбор ----------------------------------------------------------

    /// Обрезка как у awk в bin/ocbar: слева пробелы и табуляции, справа ещё
    /// и \r. Не `trimmingCharacters(.whitespaces)`: тот срезал бы и то, что
    /// CLI оставляет в значении.
    static func cliTrim<S: StringProtocol>(_ s: S) -> String {
        var sub = Substring(s)
        while let f = sub.first, f == " " || f == "\t" { sub.removeFirst() }
        while let l = sub.last, l == " " || l == "\t" || l == "\r" { sub.removeLast() }
        return String(sub)
    }

    /// Слова, как их делит `read` в bash: по пробелам и табуляциям.
    static func words<S: StringProtocol>(_ s: S) -> [String] {
        String(s).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    static func isComment(_ line: String) -> Bool { line.hasPrefix("#") || line.hasPrefix(";") }

    /// Сеть из строки [Routes] так, как её видит bin/ocbar: pf_section
    /// превращает «k = v» в «k v», read берёт первое слово. Комментарий — nil.
    static func routeNet(_ line: String) -> String? {
        let l = cliTrim(line)
        if l.isEmpty || isComment(l) { return nil }
        var text = l
        if let eq = l.firstIndex(of: "=") {
            text = cliTrim(l[..<eq]) + " " + cliTrim(l[l.index(after: eq)...])
        }
        return words(text).first
    }
    var routeNets: [String] { routes.compactMap(Self.routeNet) }

    // Заголовок, который пишет сам редактор (и ocbar export): при повторной
    // записи он заменяется свежим, а не копится.
    private static func isGeneratedHeader(_ line: String) -> Bool {
        line.hasPrefix("# Профиль ocbar, записан") || line.hasPrefix("# Профиль ocbar, выгружен")
            || line.hasPrefix("# Секретов здесь нет")
    }

    static func parse(_ text: String, fileName: String) -> ProfileDoc {
        var d = ProfileDoc()
        d.fileName = fileName
        // В Swift «\r\n» — один символ, и split по «\n» его не делит: файл
        // с концами строк Windows читался одной строкой, то есть пустым.
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        var section = "", sectionName = ""
        var seen = Set<String>()
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = cliTrim(raw)
            if line.isEmpty { continue }
            // Заголовок секции — как в CLI: строка начинается с «[».
            if line.hasPrefix("[") {
                var n = Substring(line.dropFirst())
                if n.hasSuffix("]") { n = n.dropLast() }
                sectionName = String(n)
                section = sectionName.lowercased()
                if section == "proxy" { d.hasProxySection = true }
                if !d.sectionOrder.contains(where: { $0.lowercased() == section }) { d.sectionOrder.append(sectionName) }
                continue
            }
            switch section {
            case "routes":
                // Комментарии остаются между сетями, на своих местах.
                d.routes.append(line); continue
            case "autofill":
                // Селекторы содержат «=» (input[name=username]) — строка целиком;
                // заголовки окон («# шаг 1 — …») — часть правил.
                d.autofill.append(line); continue
            default: break
            }
            if isComment(line) {
                if section.isEmpty && isGeneratedHeader(line) { continue }
                d.kept.append((section: sectionName, line: line)); continue
            }
            if section == "dns" {
                // «зона = адрес [порт]» и «зона адрес [порт]» — CLI читает обе.
                var text = line
                if let eq = line.firstIndex(of: "=") {
                    text = cliTrim(line[..<eq]) + " " + cliTrim(line[line.index(after: eq)...])
                }
                let t = words(text)
                guard let zone = t.first else { continue }
                d.zones.append(ZoneLine(zone: zone, resolver: t.count > 1 ? t[1] : "",
                                        port: t.count > 2 ? t[2] : "",
                                        rest: t.dropFirst(3).joined(separator: " ")))
                continue
            }
            // Строку без «=» и ключ вне секции CLI не читает — храним как есть.
            guard let eq = line.firstIndex(of: "="), !section.isEmpty else {
                d.kept.append((section: sectionName, line: line)); continue
            }
            let rawKey = cliTrim(line[..<eq])
            let value = cliTrim(line[line.index(after: eq)...])
            let key = rawKey.lowercased()
            guard knownKeys[section]?.contains(key) == true else {
                d.extras.append((section: sectionName, key: rawKey, value: value)); continue
            }
            // pf_get берёт первое совпадение: второй Url в файле не действует.
            guard seen.insert(section + "." + key).inserted else {
                d.duplicates.append("[\(sectionName)] \(rawKey)"); continue
            }
            d.assign(section: section, key: key, value: value)
        }
        return d
    }

    private mutating func assign(section: String, key: String, value: String) {
        switch (section, key) {
        case ("connection", "name"): name = value
        case ("connection", "description"): descr = value
        case ("connection", "url"): url = value
        case ("connection", "user"): user = value
        case ("connection", "useragent"): userAgent = value
        case ("connection", "csdwrapper"): csdWrapper = value
        case ("connection", "auth"): auth = value
        case ("connection", "mode"): mode = value.isEmpty ? "tunnel" : value
        case ("connection", "notifications"): notifications = value
        case ("auth", "password"): password = value.isEmpty ? "auto" : value
        case ("auth", "passwordcommand"): passwordCommand = value
        case ("auth", "totp"): totp = value
        case ("auth", "totpcommand"): totpCommand = value
        case ("auth", "totpalgorithm"): totpAlgorithm = value.uppercased()
        case ("auth", "totpdigits"): totpDigits = value
        case ("auth", "totpperiod"): totpPeriod = value
        case ("auth", "keepassentry"): keepassEntry = value
        case ("auth", "keepassdb"): keepassDb = value
        case ("auth", "keepasskeychain"): keepassKeychain = value
        case ("auth", "keychainservice"): keychainService = value
        case ("auth", "idphosts"): idpHosts = value
        case ("auth", "rules"): rulesFile = value
        case ("proxy", "port"): proxyPort = value
        case ("proxy", "systemproxy"): systemProxyValue = value
        case ("health", "check"): health = value
        default: break
        }
    }

    // --- запись ----------------------------------------------------------
    // Порядок и отступы — как у `ocbar export`, чтобы файлы, написанные
    // приложением и командой, не отличались.

    func render(dated: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var out = "# Профиль ocbar, записан \(df.string(from: dated))\n"
        out += "# Секретов здесь нет и быть не должно — только ссылки на хранилище.\n"
        out += keptLines("")
        out += "\n[Connection]\n"
        out += keptLines("Connection")
        out += kv("Name", 11, name)
        if !descr.isEmpty { out += kv("Description", 11, descr) }
        out += kv("Url", 11, url)
        if !user.isEmpty { out += kv("User", 11, user) }
        out += kv("UserAgent", 11, userAgent.isEmpty ? Self.defaultUserAgent : userAgent)
        if !csdWrapper.isEmpty { out += kv("CsdWrapper", 11, csdWrapper) }
        if !auth.isEmpty && auth != "sso" { out += kv("Auth", 11, auth) }
        if mode != "tunnel" { out += kv("Mode", 11, mode) }
        if !notifications.isEmpty { out += kv("Notifications", 11, notifications) }
        out += extra("Connection", 11)

        out += "\n[Routes]\n" + keptLines("Routes")
        for r in routes where !Self.cliTrim(r).isEmpty { out += Self.cliTrim(r) + "\n" }

        out += "\n[DNS]\n" + keptLines("DNS")
        for z in zones where !z.zone.trimmed.isEmpty {
            let port = z.port.trimmed, rest = z.rest.trimmed
            var value = z.resolver.trimmed
            // Хвост после порта требует порта на месте: иначе CLI прочтёт
            // «# офис» как номер порта.
            if !rest.isEmpty { value += " " + (port.isEmpty ? "53" : port) + " " + rest }
            else if !port.isEmpty && port != "53" { value += " " + port }
            out += kv(z.zone.trimmed, 24, value)
        }

        out += "\n[Auth]\n" + keptLines("Auth")
        if password != "auto" && !password.isEmpty { out += kv("Password", 15, password) }
        if !passwordCommand.isEmpty { out += kv("PasswordCommand", 15, passwordCommand) }
        out += kv("Totp", 15, totp.isEmpty ? "auto" : totp)
        if !totpCommand.isEmpty { out += kv("TotpCommand", 15, totpCommand) }
        if !totpAlgorithm.isEmpty && totpAlgorithm.uppercased() != "SHA1" { out += kv("TotpAlgorithm", 15, totpAlgorithm.uppercased()) }
        if !totpDigits.trimmed.isEmpty && totpDigits.trimmed != "6" { out += kv("TotpDigits", 15, totpDigits.trimmed) }
        if !totpPeriod.trimmed.isEmpty && totpPeriod.trimmed != "30" { out += kv("TotpPeriod", 15, totpPeriod.trimmed) }
        if !keepassEntry.isEmpty { out += kv("KeepassEntry", 15, keepassEntry) }
        if !keepassDb.isEmpty { out += kv("KeepassDb", 15, keepassDb) }
        if !keepassKeychain.isEmpty { out += kv("KeepassKeychain", 15, keepassKeychain) }
        if !keychainService.isEmpty { out += kv("KeychainService", 15, keychainService) }
        if !idpHosts.isEmpty { out += kv("IdpHosts", 15, idpHosts) }
        if !rulesFile.isEmpty { out += kv("Rules", 15, rulesFile) }
        out += extra("Auth", 15)

        let rules = autofill.map { Self.cliTrim($0) }.filter { !$0.isEmpty }
        if !rules.isEmpty { out += "\n[Autofill]\n" + rules.joined(separator: "\n") + "\n" }

        // [Proxy] пишется, если она что-то значит или была в файле: порт,
        // заданный в туннельном режиме, — тоже настройка, терять её нельзя.
        let sysValue = systemProxyValue.trimmed.isEmpty ? "off" : systemProxyValue.trimmed
        let port = proxyPort.trimmed.isEmpty ? "11080" : proxyPort.trimmed
        if mode != "tunnel" || sysValue != "off" || port != "11080" || hasProxySection
            || hasExtra("Proxy") || !keptLines("Proxy").isEmpty {
            out += "\n[Proxy]\n" + keptLines("Proxy")
            out += kv("Port", 12, port)
            out += kv("SystemProxy", 12, sysValue)
            out += extra("Proxy", 12)
        }
        if !health.isEmpty || hasExtra("Health") || !keptLines("Health").isEmpty {
            out += "\n[Health]\n" + keptLines("Health")
            if !health.isEmpty { out += "Check = \(health)\n" }
            out += extra("Health", 5)
        }
        // Секции, о которых редактор не знает вовсе, дописываются как есть.
        for section in otherSections {
            out += "\n[\(section)]\n" + keptLines(section) + extra(section, 12)
        }
        return out
    }

    private var otherSections: [String] {
        var seen: [String] = []
        let candidates = sectionOrder + extras.map(\.section) + kept.map(\.section)
        for s in candidates where !s.isEmpty && !Self.knownSections.contains(s.lowercased())
            && !seen.contains(where: { $0.lowercased() == s.lowercased() }) {
            seen.append(s)
        }
        return seen.filter { hasExtra($0) || !keptLines($0).isEmpty }
    }

    private func hasExtra(_ section: String) -> Bool {
        extras.contains { $0.section.lowercased() == section.lowercased() }
    }

    private func keptLines(_ section: String) -> String {
        kept.filter { $0.section.lowercased() == section.lowercased() }.map { $0.line + "\n" }.joined()
    }

    private func extra(_ section: String, _ width: Int) -> String {
        extras.filter { $0.section.lowercased() == section.lowercased() }
              .map { kv($0.key, width, $0.value) }
              .joined()
    }

    private func kv(_ key: String, _ width: Int, _ value: String) -> String {
        let pad = String(repeating: " ", count: max(1, width - key.count))
        return "\(key)\(pad)= \(value)\n"
    }
}

// --- проверка перед сохранением ------------------------------------------
// Правила те же, что в bin/ocbar (valid_cidr, valid_zone, valid_ip,
// check_totp_params, valid_rule) и в libexec/ocbar-helper (valid_ua,
// valid_port): файл, который не пройдёт там, не должен сохраняться здесь.

struct Issue: Identifiable {
    enum Level { case error, warning }
    let level: Level
    let text: String
    let id = UUID()
}

enum ProfileCheck {
    /// Только цифры ASCII: `Int("+30")` в Swift — 30, а CLI такого не примет.
    static func digits<S: StringProtocol>(_ s: S, _ range: ClosedRange<Int>) -> Bool {
        !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) } && s.count >= range.lowerBound && s.count <= range.upperBound
    }

    static func validIP(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in digits(p, 1...3) && (Int(p) ?? 999) <= 255 }
    }

    // Как valid_cidr: маска — одна-две цифры, не больше 32.
    static func validCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, validIP(String(parts[0])), digits(parts[1], 1...2),
              let len = Int(parts[1]), len <= 32 else { return false }
        return true
    }

    static func prefixLength(_ cidr: String) -> Int? {
        guard let slash = cidr.firstIndex(of: "/") else { return nil }
        return Int(cidr[cidr.index(after: slash)...])
    }

    static func validZone(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("."), !s.contains("/"), !s.contains(" "), !s.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let first = s.first, let last = s.last else { return false }
        return first.isLetter || first.isNumber ? (last.isLetter || last.isNumber) : false
    }

    // Порт зоны — как valid_port у хелпера: до пяти цифр, 1–65535.
    static func validPort(_ s: String) -> Bool {
        digits(s, 1...5) && (1...65535).contains(Int(s) ?? 0)
    }

    static func validUserAgent(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 120 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._()/;:,-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func validFileName(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func check(_ d: ProfileDoc) -> [Issue] {
        var issues: [Issue] = []
        func err(_ t: String) { issues.append(Issue(level: .error, text: t)) }
        func warn(_ t: String) { issues.append(Issue(level: .warning, text: t)) }

        if !validFileName(d.fileName) {
            err("имя файла «\(d.fileName)»: буквы, цифры, точка, дефис и подчёркивание, начинается с буквы или цифры")
        }
        if d.url.trimmed.isEmpty { err("не задан Url — без него профиль не подключится") }
        else if d.url.contains(" ") { err("в Url есть пробел: \(d.url)") }
        else if !d.url.contains("/") {
            warn("в Url нет группы (host/group) — шлюз обычно её ждёт")
        }
        if d.name.trimmed.isEmpty { warn("не задано Name — в меню будет имя файла") }
        let ua = d.userAgent.trimmed
        if !ua.isEmpty, !validUserAgent(ua) {
            err("User-Agent содержит недопустимые символы — хелпер такой не пропустит")
        }
        for dup in d.duplicates {
            warn("ключ \(dup) указан дважды — действует первое значение, повтор при сохранении уберётся")
        }

        var seenRoutes = Set<String>()
        for r in d.routeNets {
            if !validCIDR(r) { err("сеть «\(r)» — не CIDR вида 10.0.0.0/8"); continue }
            if !seenRoutes.insert(r).inserted { warn("сеть \(r) указана дважды") }
            if let len = prefixLength(r), len < 8 {
                warn("сеть \(r) уводит в туннель почти весь трафик — интернет пойдёт через шлюз")
            }
        }
        if d.routeNets.isEmpty {
            warn("ни одной сети: в туннель не пойдёт ничего")
        }

        var seenZones = Set<String>()
        for z in d.zones where !z.zone.trimmed.isEmpty {
            let zone = z.zone.trimmed, resolver = z.resolver.trimmed
            if !validZone(zone) { err("зона «\(zone)» — недопустимое имя") }
            else if !seenZones.insert(zone).inserted { warn("зона \(zone) указана дважды") }
            if resolver.isEmpty { err("у зоны \(zone) не указан резолвер (адрес или vpn)") }
            else if resolver != "vpn", !validIP(resolver) {
                err("у зоны \(zone) резолвер «\(resolver)» — нужен адрес IPv4 или слово vpn")
            }
            if !z.port.trimmed.isEmpty, !validPort(z.port.trimmed) {
                err("у зоны \(zone) порт «\(z.port)» — число от 1 до 65535")
            }
        }

        let alg = d.totpAlgorithm.uppercased()
        if !ProfileDoc.totpAlgorithms.contains(alg) {
            err("алгоритм кода «\(d.totpAlgorithm)» — бывает SHA1, SHA256 или SHA512")
        }
        if !["6", "7", "8"].contains(d.totpDigits.trimmed) {
            err("цифр в коде «\(d.totpDigits)» — бывает 6, 7 или 8")
        }
        // Как check_totp_params: только цифры, 10–300. «+30» CLI не примет.
        let period = d.totpPeriod.trimmed
        if !(digits(period, 1...3) && (10...300).contains(Int(period) ?? 0)) {
            err("период кода «\(d.totpPeriod)» — число секунд от 10 до 300")
        }
        let customCode = alg != "SHA1" || d.totpDigits.trimmed != "6" || d.totpPeriod.trimmed != "30"
        if customCode && ["keepassxc", "command", "off", "sms"].contains(d.totp) {
            warn("параметры кода нужны только секрету в связке ключей — KeePassXC и команда отдают готовый код")
        }
        switch d.totp {
        case "sms":
            warn("код приходит по SMS и вводится руками — молчаливое переподключение работать не будет")
        case "command" where d.totpCommand.trimmed.isEmpty:
            err("Totp = command, но TotpCommand пуст")
        case "keepassxc" where d.keepassEntry.trimmed.isEmpty:
            err("Totp = keepassxc, но не указана запись KeepassEntry")
        default: break
        }
        switch d.password {
        case "command" where d.passwordCommand.trimmed.isEmpty:
            err("Password = command, но PasswordCommand пуст")
        case "keepassxc" where d.keepassEntry.trimmed.isEmpty:
            err("Password = keepassxc, но не указана запись KeepassEntry")
        case "ask":
            warn("пароль вводит человек: молчаливое переподключение работать не будет")
        default: break
        }
        if !ProfileDoc.passwordSources.contains(d.password) {
            err("источник пароля «\(d.password)» — бывает " + ProfileDoc.passwordSources.joined(separator: ", "))
        }
        if d.mode != "tunnel" && d.mode != "proxy" {
            err("режим «\(d.mode)» — бывает tunnel или proxy")
        }
        if d.mode == "proxy" {
            warn("прокси-режим: нужен ocproxy (brew install ocproxy); маршруты и зоны из профиля не применяются, ходят только программы, которым указан SOCKS")
        }
        let port = d.proxyPort.trimmed
        if !port.isEmpty {
            if digits(port, 1...5), let n = Int(port) {
                if n < 1024 || n > 65535 { err("порт SOCKS \(n) вне диапазона 1024-65535") }
                if n == 10808 { warn("порт 10808 занят сторонним SOCKS на этой машине — возьмите другой") }
            } else {
                err("порт SOCKS «\(port)» — не число")
            }
        }
        let sys = d.systemProxyValue.trimmed
        if !sys.isEmpty, sys != "on", sys != "off" {
            warn("SystemProxy = «\(sys)» — ocbar включает системный SOCKS только при on, так что сейчас это off")
        }
        if d.systemProxy && d.mode != "proxy" {
            warn("системный SOCKS имеет смысл только в прокси-режиме")
        }
        if !d.csdWrapper.isEmpty, d.csdWrapper.contains(" ") {
            warn("путь CsdWrapper с пробелом — хелпер берёт только имя файла из своего каталога")
        }
        for rule in d.autofill.map({ ProfileDoc.cliTrim($0) }) where !rule.isEmpty && !ProfileDoc.isComment(rule) {
            if !validRule(rule) { err("правило «\(rule)» — бывает stop <сел>, fill username|password|totp|manual <сел>, click <сел>, click! <сел>") }
        }
        if !d.autofill.isEmpty, !d.rulesFile.trimmed.isEmpty {
            warn("в профиле есть [Autofill] — файл из Rules при этом не читается")
        }
        return issues
    }
}

// --- файлы профилей ------------------------------------------------------

extension ProfileCheck {
    // Та же грамматика, что у valid_rule в bin/ocbar и у ocbar-auth:
    // `read -r kind field sel` — у fill селектор забирает весь остаток строки.
    static func validRule(_ rule: String) -> Bool {
        let f = ProfileDoc.words(rule)
        guard let kind = f.first else { return false }
        switch kind {
        case "stop", "click", "click!": return f.count == 2
        case "fill": return f.count >= 3 && ["username", "password", "totp", "manual"].contains(f[1])
        default: return false
        }
    }
}

enum ProfileStore {
    static func list() -> [String] {
        let dir = OcbarClient.shared.profileDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let names = files.filter { $0.hasSuffix(".ocbar") }
            .map { String($0.dropLast(".ocbar".count)) }
            .sorted()
        let text = (try? String(contentsOfFile: OcbarClient.shared.configDir + "/profiles.order", encoding: .utf8)) ?? ""
        return ordered(names, by: text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Порядок, который расставил человек (profiles.order, как в bin/ocbar):
    /// кого там нет — следом, в прежнем порядке.
    static func ordered(_ names: [String], by order: [String]) -> [String] {
        var rank: [String: Int] = [:]
        for (i, n) in order.enumerated() where !n.isEmpty && rank[n] == nil { rank[n] = i }
        return names.enumerated()
            .sorted { (rank[$0.element] ?? 100_000 + $0.offset) < (rank[$1.element] ?? 100_000 + $1.offset) }
            .map { $0.element }
    }

    static func path(_ name: String) -> String {
        OcbarClient.shared.profileDir + "/" + name + ".ocbar"
    }

    static func load(_ name: String) -> ProfileDoc? {
        guard let text = read(name) else { return nil }
        return ProfileDoc.parse(text, fileName: name)
    }

    // Текст файла. Байты не в UTF-8 не повод считать файл пустым: иначе
    // редактор открыл бы чистую форму и сохранение затёрло бы профиль.
    static func read(_ name: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path(name)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Что лежит на диске: текст и время изменения. Редактор запоминает его
    /// при открытии и перед записью сверяет — файл мог записать ocbar
    /// (разметка, «Запомнить, как я вхожу», ocbar rules). Равенство — по
    /// тексту: время само по себе меняет и touch.
    struct DiskStamp: Equatable {
        let mtime: Date?
        let text: String?
        static func == (a: DiskStamp, b: DiskStamp) -> Bool { a.text == b.text }
    }

    static func mtime(_ name: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path(name)))?[.modificationDate] as? Date
    }

    static func stamp(_ name: String) -> DiskStamp {
        DiskStamp(mtime: mtime(name), text: read(name))
    }

    // Пишем во временный файл рядом и переименовываем: оборванная запись не
    // должна оставить профиль в половинном виде. Прошлую версию сохраняем
    // рядом с суффиксом .bak — правку руками отменить иначе нечем.
    static func save(_ doc: ProfileDoc) -> String? {
        let fm = FileManager.default
        let dir = OcbarClient.shared.profileDir
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let target = path(doc.fileName)
            if fm.fileExists(atPath: target) {
                let backup = target + ".bak"
                try? fm.removeItem(atPath: backup)
                try fm.copyItem(atPath: target, toPath: backup)
            }
            let tmp = target + ".tmp"
            try doc.render().write(toFile: tmp, atomically: false, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: tmp))
            return nil
        } catch {
            return "\(error.localizedDescription)"
        }
    }
}
