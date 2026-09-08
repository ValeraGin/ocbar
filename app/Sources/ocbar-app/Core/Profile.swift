import Foundation

// Профиль одним файлом (.ocbar). Формат не изобретается заново: он описан
// в etc/example.ocbar и разбирается в bin/ocbar (pf_get/pf_section), а
// пишется ровно так, как это делает `ocbar export`.

struct ZoneLine: Identifiable, Hashable {
    var zone: String
    var resolver: String    // адрес или "vpn" — резолвер, который прислал шлюз
    var port: String        // пусто = 53
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
    var routes: [String] = []
    var zones: [ZoneLine] = []
    var password = "auto"
    var passwordCommand = ""
    var totp = "auto"
    var totpCommand = ""
    var keepassEntry = ""
    var keepassDb = ""
    var keepassKeychain = ""
    var keychainService = ""
    var idpHosts = ""
    var health = ""
    // Как пускать трафик. Ключ разбирается и клиентом (bin/ocbar), но сам
    // прокси-режим ещё не реализован: профиль с Mode = proxy подключаться
    // откажется — намеренно, чтобы интерфейс не обещал того, чего нет.
    var mode = "tunnel"
    var proxyPort = "11080"
    var systemProxy = false
    var rulesFile = ""            // [Auth] Rules — правила автозаполнения формы
    var notifications = ""        // [Connection] Notifications = off выключает уведомления
    // Ключи, которых редактор не знает. Хранятся и записываются обратно:
    // молча потерять строку из чужого профиля — худшее, что может сделать
    // редактор конфигурации.
    var extras: [(section: String, key: String, value: String)] = []

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

    static let totpSources = ["auto", "keychain", "keepassxc", "command", "off"]
    // Источник пароля — один из нескольких, как и источник кода: связка
    // ключей, база KeePassXC, произвольная команда, «вводит человек».
    static let passwordSources = ["auto", "keychain", "keepassxc", "command", "ask"]

    // --- разбор ----------------------------------------------------------

    static func parse(_ text: String, fileName: String) -> ProfileDoc {
        var d = ProfileDoc()
        d.fileName = fileName
        var section = "", sectionName = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmed
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                sectionName = String(line.dropFirst().dropLast())
                section = sectionName.lowercased()
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmed }
            let key = parts.first?.lowercased() ?? ""
            let value = parts.count > 1 ? parts[1] : ""
            switch section {
            case "connection":
                switch key {
                case "name": d.name = value
                case "description": d.descr = value
                case "url": d.url = value
                case "user": d.user = value
                case "useragent": d.userAgent = value
                case "csdwrapper": d.csdWrapper = value
                case "auth": d.auth = value
                case "mode": d.mode = value.isEmpty ? "tunnel" : value
                case "notifications": d.notifications = value
                default: d.extras.append((section: "Connection", key: parts[0], value: value))
                }
            case "routes":
                if parts.count == 1 { d.routes.append(line) }
            case "dns":
                guard parts.count > 1 else { continue }
                let rhs = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                d.zones.append(ZoneLine(zone: parts[0], resolver: rhs.first ?? "",
                                        port: rhs.count > 1 ? rhs[1] : ""))
            case "auth":
                switch key {
                case "password": d.password = value.isEmpty ? "auto" : value
                case "passwordcommand": d.passwordCommand = value
                case "totp": d.totp = value
                case "totpcommand": d.totpCommand = value
                case "keepassentry": d.keepassEntry = value
                case "keepassdb": d.keepassDb = value
                case "keepasskeychain": d.keepassKeychain = value
                case "keychainservice": d.keychainService = value
                case "idphosts": d.idpHosts = value
                case "rules": d.rulesFile = value
                default: d.extras.append((section: "Auth", key: parts[0], value: value))
                }
            case "proxy":
                switch key {
                case "port": d.proxyPort = value
                case "systemproxy": d.systemProxy = ["on", "1", "yes", "true"].contains(value.lowercased())
                default: d.extras.append((section: "Proxy", key: parts[0], value: value))
                }
            case "health":
                if key == "check" { d.health = value }
                else { d.extras.append((section: "Health", key: parts[0], value: value)) }
            default:
                guard parts.count > 1, !section.isEmpty else { continue }
                d.extras.append((section: sectionName, key: parts[0], value: value))
            }
        }
        return d
    }

    // --- запись ----------------------------------------------------------
    // Порядок и отступы — как у `ocbar export`, чтобы файлы, написанные
    // приложением и командой, не отличались.

    func render(dated: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var out = "# Профиль ocbar, записан \(df.string(from: dated))\n"
        out += "# Секретов здесь нет и быть не должно — только ссылки на хранилище.\n\n"
        out += "[Connection]\n"
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

        out += "\n[Routes]\n"
        for r in routes where !r.trimmed.isEmpty { out += r.trimmed + "\n" }

        out += "\n[DNS]\n"
        for z in zones where !z.zone.trimmed.isEmpty {
            let value = z.port.trimmed.isEmpty || z.port.trimmed == "53"
                ? z.resolver.trimmed
                : "\(z.resolver.trimmed) \(z.port.trimmed)"
            out += kv(z.zone.trimmed, 24, value)
        }

        out += "\n[Auth]\n"
        if password != "auto" && !password.isEmpty { out += kv("Password", 15, password) }
        if !passwordCommand.isEmpty { out += kv("PasswordCommand", 15, passwordCommand) }
        out += kv("Totp", 15, totp.isEmpty ? "auto" : totp)
        if !totpCommand.isEmpty { out += kv("TotpCommand", 15, totpCommand) }
        if !keepassEntry.isEmpty { out += kv("KeepassEntry", 15, keepassEntry) }
        if !keepassDb.isEmpty { out += kv("KeepassDb", 15, keepassDb) }
        if !keepassKeychain.isEmpty { out += kv("KeepassKeychain", 15, keepassKeychain) }
        if !keychainService.isEmpty { out += kv("KeychainService", 15, keychainService) }
        if !idpHosts.isEmpty { out += kv("IdpHosts", 15, idpHosts) }
        if !rulesFile.isEmpty { out += kv("Rules", 15, rulesFile) }
        out += extra("Auth", 15)

        if mode != "tunnel" || systemProxy {
            out += "\n[Proxy]\n"
            out += kv("Port", 12, proxyPort.isEmpty ? "11080" : proxyPort)
            out += kv("SystemProxy", 12, systemProxy ? "on" : "off")
            out += extra("Proxy", 12)
        }
        if !health.isEmpty { out += "\n[Health]\nCheck = \(health)\n" + extra("Health", 5) }
        // Секции, о которых редактор не знает вовсе, дописываются как есть.
        let known = ["connection", "routes", "dns", "auth", "proxy", "health"]
        for section in orderedExtraSections where !known.contains(section.lowercased()) {
            out += "\n[\(section)]\n" + extra(section, 12)
        }
        return out
    }

    private var orderedExtraSections: [String] {
        var seen: [String] = []
        for e in extras where !seen.contains(e.section) { seen.append(e.section) }
        return seen
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
// Правила те же, что в bin/ocbar (valid_cidr, valid_zone, valid_ip) и в
// libexec/ocbar-helper (valid_ua): файл, который не пройдёт там, не должен
// сохраняться здесь.

struct Issue: Identifiable {
    enum Level { case error, warning }
    let level: Level
    let text: String
    let id = UUID()
}

enum ProfileCheck {
    static func validIP(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard p.count >= 1, p.count <= 3, p.allSatisfy(\.isNumber), let v = Int(p) else { return false }
            return v <= 255
        }
    }

    static func validCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, validIP(String(parts[0])),
              let len = Int(parts[1]), parts[1].allSatisfy(\.isNumber), len <= 32 else { return false }
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

        var seenRoutes = Set<String>()
        for r in d.routes.map({ $0.trimmed }) where !r.isEmpty {
            if !validCIDR(r) { err("сеть «\(r)» — не CIDR вида 10.0.0.0/8"); continue }
            if !seenRoutes.insert(r).inserted { warn("сеть \(r) указана дважды") }
            if let len = prefixLength(r), len < 8 {
                warn("сеть \(r) уводит в туннель почти весь трафик — интернет пойдёт через шлюз")
            }
        }
        if d.routes.allSatisfy({ $0.trimmed.isEmpty }) {
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
            if !z.port.trimmed.isEmpty, Int(z.port.trimmed) == nil {
                err("у зоны \(zone) порт «\(z.port)» — не число")
            }
        }

        switch d.totp {
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
            if let n = Int(port), port.allSatisfy(\.isNumber) {
                if n < 1024 || n > 65535 { err("порт SOCKS \(n) вне диапазона 1024-65535") }
                if n == 10808 { warn("порт 10808 занят сторонним SOCKS на этой машине — возьмите другой") }
            } else {
                err("порт SOCKS «\(port)» — не число")
            }
        }
        if d.systemProxy && d.mode != "proxy" {
            warn("системный SOCKS имеет смысл только в прокси-режиме")
        }
        if !d.csdWrapper.isEmpty, d.csdWrapper.contains(" ") {
            warn("путь CsdWrapper с пробелом — хелпер берёт только имя файла из своего каталога")
        }
        return issues
    }
}

// --- файлы профилей ------------------------------------------------------

enum ProfileStore {
    static func list() -> [String] {
        let dir = OcbarClient.shared.profileDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".ocbar") }
            .map { String($0.dropLast(".ocbar".count)) }
            .sorted()
    }

    static func path(_ name: String) -> String {
        OcbarClient.shared.profileDir + "/" + name + ".ocbar"
    }

    static func load(_ name: String) -> ProfileDoc? {
        guard let text = try? String(contentsOfFile: path(name), encoding: .utf8) else { return nil }
        return ProfileDoc.parse(text, fileName: name)
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
