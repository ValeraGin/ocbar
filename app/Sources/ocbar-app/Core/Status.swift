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
    var id: String { name }
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
    var linkLostSince: Date?      // ставит супервизор, когда проба не проходит
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

    var routesOn: [RouteEntry] { routes.filter { $0.enabled } }
    var zonesApplied: [ZoneEntry] { zones.filter { $0.applied } }

    static func parse(_ text: String) -> Status {
        var s = Status()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "paused":      s.paused = value == "1"
            case "needs_login": s.needsLogin = value == "1"
            case "state":       s.state = TunnelState(rawValue: value) ?? .down
            case "profile":     s.profile = value
            case "tundev":      s.tundev = value
            case "ip":          s.ip = value
            case "since":       s.since = unixDate(value)
            case "gateway":     s.gateway = value
            case "dns":         s.dns = value.split(separator: " ").map(String.init)
            case "url":         s.url = value
            case "mode":        s.mode = value
            case "mtu":         s.mtu = value
            case "profile_mode": s.profileMode = value.isEmpty ? "tunnel" : value
            case "proxy_port":  s.proxyPort = value
            case "system_proxy": s.systemProxy = value == "on"
            case "foreign":     s.foreign = value == "1"
            case "supervisor":  s.supervisor = value == "1"
            case "iface":       s.iface = value
            case "link_lost":   s.linkLostSince = unixDate(value)
            case "default":     s.defaultProfile = value
            case "route":
                // "10.0.0.0/8 utun5 on"; вместо пустого интерфейса — "-",
                // иначе поле схлопывается и признак "on" читается как утун.
                let f = value.split(separator: " ").map(String.init)
                guard f.count >= 3 else { continue }
                s.routes.append(RouteEntry(net: f[0], via: f[1] == "-" ? nil : f[1],
                                           enabled: f[2] == "on"))
            case "zone":
                let f = value.split(separator: " ").map(String.init)
                guard f.count >= 4 else { continue }
                s.zones.append(ZoneEntry(zone: f[0], dns: f[1],
                                         applied: f[2] == "applied", enabled: f[3] == "on"))
            case "profile_list":
                let f = value.components(separatedBy: "|")
                guard !f.isEmpty, !f[0].isEmpty else { continue }
                s.profiles.append(ProfileEntry(name: f[0],
                                               title: f.count > 1 ? f[1] : "",
                                               auth:  f.count > 2 ? f[2] : "",
                                               descr: f.count > 3 ? f[3] : ""))
            default: break
            }
        }
        return s
    }

    private static func unixDate(_ v: String) -> Date? {
        guard let t = TimeInterval(v), t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
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
