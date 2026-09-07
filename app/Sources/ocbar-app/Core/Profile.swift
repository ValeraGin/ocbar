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
    var totp = "auto"
    var totpCommand = ""
    var keepassEntry = ""
    var keepassDb = ""
    var keepassKeychain = ""
    var keychainService = ""
    var idpHosts = ""
    var health = ""

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

    // --- разбор ----------------------------------------------------------

    static func parse(_ text: String, fileName: String) -> ProfileDoc {
        var d = ProfileDoc()
        d.fileName = fileName
        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmed
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
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
                default: break
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
                case "totp": d.totp = value
                case "totpcommand": d.totpCommand = value
                case "keepassentry": d.keepassEntry = value
                case "keepassdb": d.keepassDb = value
                case "keepasskeychain": d.keepassKeychain = value
                case "keychainservice": d.keychainService = value
                case "idphosts": d.idpHosts = value
                default: break
                }
            case "health":
                if key == "check" { d.health = value }
            default: break
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
        out += kv("Totp", 15, totp.isEmpty ? "auto" : totp)
        if !totpCommand.isEmpty { out += kv("TotpCommand", 15, totpCommand) }
        if !keepassEntry.isEmpty { out += kv("KeepassEntry", 15, keepassEntry) }
        if !keepassDb.isEmpty { out += kv("KeepassDb", 15, keepassDb) }
        if !keepassKeychain.isEmpty { out += kv("KeepassKeychain", 15, keepassKeychain) }
        if !keychainService.isEmpty { out += kv("KeychainService", 15, keychainService) }
        if !idpHosts.isEmpty { out += kv("IdpHosts", 15, idpHosts) }

        if !health.isEmpty { out += "\n[Health]\nCheck = \(health)\n" }
        return out
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
