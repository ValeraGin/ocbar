import Foundation

// Разбор `ocbar status --short`: построчно ключ=значение, повторяющиеся
// ключи — списки. Формат описан в README и стабилен: его же читает плагин
// SwiftBar.

struct RouteEntry: Identifiable, Hashable {
    let net: String        // 10.0.0.0/8
    let via: String?       // через какой интерфейс реально идёт; nil — никак
    let enabled: Bool      // включена ли в меню
    var id: String { net }
}

struct ZoneEntry: Identifiable, Hashable {
    let zone: String
    let dns: String        // адрес резолвера или "vpn"
    let applied: Bool      // лежит ли файл в /etc/resolver
    let enabled: Bool
    var id: String { zone }
}

struct ProfileEntry: Identifiable, Hashable {
    let name: String
    let title: String
    let auth: String       // пусто = sso; "password" — парольная группа
    let descr: String
    var url = ""
    var id: String { name }
    /// Адрес подключения без схемы: https://vpn.example.com/employees/ →
    /// vpn.example.com/employees. Группа (путь) различает профили одного шлюза.
    var address: String {
        var u = url.trimmingCharacters(in: .whitespaces)
        if let r = u.range(of: "://") { u = String(u[r.upperBound...]) }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
    /// Домен подключения без схемы и группы: vpn.example.com/employees → vpn.example.com.
    var host: String {
        var u = url
        if let r = u.range(of: "://") { u = String(u[r.upperBound...]) }
        return String(u.prefix { $0 != "/" && $0 != "?" })
    }
    var display: String { title.isEmpty ? name : title }
    var isPassword: Bool { auth == "password" }
}

enum TunnelState: String {
    case connected, paused, starting, down
}

// Что показывать. Состояния различаются не строкой, а всем видом меню.
enum Presentation {
    case connected      // туннель поднят, маршруты на месте
    case paused         // туннель жив, маршруты и зоны сняты
    case starting       // openconnect запускается
    case lost           // связи нет, openconnect восстанавливает сессию сам
    case needsLogin     // автоподключение остановлено: решает человек
    case down           // отключён
    case foreign        // работает чужой openconnect — не наш
    case missing        // самого ocbar на машине нет
}

struct Status {
    var paused = false
    var needsLogin = false
    var state: TunnelState = .down
    var profile = ""
    var tundev = ""
    var ip = ""
    var since: Date?
    var gateway = ""
    var dns: [String] = []
    var url = ""
    var mode = ""
    var foreign = false
    var supervisor = false
    var iface = ""
    var mtu = ""
    var profileMode = "tunnel"     // tunnel | proxy — режим выбранного профиля
    var proxyPort = ""
    var systemProxy = false
    // Живая прокси-сессия: mode=proxy, адрес SOCKS, отвечает ли он, на каких
    // сетевых сервисах включён системный SOCKS и почему не включился.
    var socks = ""                 // 127.0.0.1:11080
    var socksUp = true
    var systemSocksOn: [String] = []
    var systemSocksRefused = ""
    var wokeAfterConnect: Date?   // мак спал после подключения — повод проверить туннель
    var linkLostSince: Date?      // ставит супервизор, когда проба не проходит
    var access = ""               // ok | fail | unknown — проверка доступа супервизором
    var accessAt: Date?
    var routes: [RouteEntry] = []
    var zones: [ZoneEntry] = []
    var profiles: [ProfileEntry] = []
    var defaultProfile = ""
    var available = true          // нашёлся ли сам ocbar
    var error: String?            // что именно пошло не так

    var presentation: Presentation {
        if !available { return .missing }
        switch state {
        case .connected: return linkLostSince == nil ? .connected : .lost
        case .paused:    return .paused
        case .starting:  return .starting
        case .down:
            if needsLogin { return .needsLogin }
            if foreign { return .foreign }
            return .down
        }
    }

    var profileTitle: String {
        profiles.first { $0.name == profile }?.display ?? (profile.isEmpty ? "—" : profile)
    }
    /// Сессия поднята в прокси-режиме: интерфейса, маршрутов и зон нет.
    var isProxySession: Bool { mode == "proxy" && state != .down }

    var routesOn: [RouteEntry] { routes.filter { $0.enabled } }
    var zonesApplied: [ZoneEntry] { zones.filter { $0.applied } }

    /// Разбор `ocbar status --json`. Раньше приложение читало `--short`
    /// построчно: «|» в названии профиля сдвигал поля, а каждое новое поле
    /// приходилось прятать в отдельную строку. Теперь типы приходят от
    /// клиента, а формат один на всех.
    static func parse(json data: Data) -> Status? {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        var s = Status()
        s.paused = w.paused ?? false
        s.needsLogin = w.needs_login ?? false
        s.state = TunnelState(rawValue: w.state ?? "") ?? .down
        s.profile = w.profile ?? ""
        s.tundev = w.tundev ?? ""
        s.ip = w.ip ?? ""
        s.since = date(w.since)
        s.gateway = w.gateway ?? ""
        s.dns = w.dns ?? []
        s.url = w.url ?? ""
        s.mode = w.mode ?? ""
        s.profileMode = (w.profile_mode?.isEmpty == false) ? w.profile_mode! : "tunnel"
        s.proxyPort = w.proxy_port.map(String.init) ?? ""
        s.systemProxy = w.system_proxy == "on"
        s.socks = w.socks ?? ""
        s.socksUp = w.socks_up ?? true
        s.systemSocksOn = w.system_socks ?? []
        s.systemSocksRefused = w.system_socks_refused ?? ""
        s.wokeAfterConnect = date(w.woke_after_connect)
        s.linkLostSince = date(w.link_lost)
        s.foreign = w.foreign ?? false
        s.supervisor = w.supervisor ?? false
        s.iface = w.iface ?? ""
        s.access = w.access ?? ""
        s.accessAt = date(w.access_at)
        s.defaultProfile = w.default ?? ""
        s.routes = (w.routes ?? []).map { RouteEntry(net: $0.net, via: $0.via, enabled: $0.on) }
        s.zones = (w.zones ?? []).map { ZoneEntry(zone: $0.zone, dns: $0.dns, applied: $0.applied, enabled: $0.on) }
        s.profiles = (w.profiles ?? []).map {
            // Парольная группа — только ровно password: всё прочее — sso.
            ProfileEntry(name: $0.name, title: $0.title ?? "",
                         auth: $0.auth == "password" ? "password" : "",
                         descr: $0.descr ?? "", url: $0.url ?? "")
        }
        return s
    }

    static func parse(json text: String) -> Status? {
        parse(json: Data(text.utf8))
    }

    private static func date(_ seconds: Int?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Как приходит JSON от клиента: все поля необязательные — состояние
    /// без туннеля половины из них не содержит.
    private struct Wire: Decodable {
        var state: String?
        var profile: String?
        var paused: Bool?
        var needs_login: Bool?
        var tundev: String?
        var ip: String?
        var since: Int?
        var gateway: String?
        var dns: [String]?
        var url: String?
        var mode: String?
        var profile_mode: String?
        var proxy_port: Int?
        var system_proxy: String?
        var socks: String?
        var socks_up: Bool?
        var system_socks: [String]?
        var system_socks_refused: String?
        var woke_after_connect: Int?
        var link_lost: Int?
        var foreign: Bool?
        var supervisor: Bool?
        var iface: String?
        var access: String?
        var access_at: Int?
        var `default`: String?
        var routes: [RouteWire]?
        var zones: [ZoneWire]?
        var profiles: [ProfileWire]?

        struct RouteWire: Decodable { var net: String; var via: String?; var on: Bool }
        struct ZoneWire: Decodable { var zone: String; var dns: String; var applied: Bool; var on: Bool }
        struct ProfileWire: Decodable {
            var name: String
            var title: String?
            var auth: String?
            var descr: String?
            var url: String?
        }
    }

}

// "2ч 14м" — как в CLI и в песочнице.
func humanSince(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "—" }
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s >= 3600 { return "\(s / 3600)ч \((s % 3600) / 60)м" }
    if s >= 60 { return "\(s / 60)м" }
    return "\(s)с"
}
