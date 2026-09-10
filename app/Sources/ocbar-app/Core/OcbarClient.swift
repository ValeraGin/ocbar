import Foundation

// Единственная связь с системой: запуск `ocbar` и чтение счётчиков.
// Ничего привилегированного здесь нет — всё, что требует root, живёт
// в libexec/ocbar-helper и вызывается самим ocbar.
final class OcbarClient: @unchecked Sendable {
    static let shared = OcbarClient()

    let binary: String?
    /// Где искали клиента — чтобы сообщение «не найден» говорило по делу,
    /// а не общими словами.
    private(set) var lookupNote = ""

    private let versionsLock = NSLock()
    private var versionsCache: [String: String]?
    private var versionsStamp = Date.distantPast

    // Где искать ocbar. Приложение может лежать и в дереве проекта, и в
    // Homebrew, поэтому кандидатов несколько; путь можно задать явно
    // переменной OCBAR_BIN.
    init() {
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath().deletingLastPathComponent()
        // Заданный явно путь — главнее всех: если человек указал OCBAR_BIN,
        // молча взять другой ocbar значит скрыть его ошибку.
        if let explicit = ProcessInfo.processInfo.environment["OCBAR_BIN"], !explicit.isEmpty {
            binary = Shell.firstExecutable([explicit])
            lookupNote = binary == nil
                ? "Переменная OCBAR_BIN указывает на \(explicit) — там нет исполняемого файла."
                : ""
            return
        }
        var candidates: [String] = []
        // Идём вверх от самого себя и ищем bin/ocbar: раскладок несколько —
        // дерево проекта, бандл внутри дерева (app/.build/ocbar.app) и
        // бандл в каталоге Homebrew (prefix/ocbar.app рядом с prefix/bin).
        // Считать «сколько точек вверх» руками уже приводило к тому, что
        // бандл из репозитория молча звал ocbar из tap — то есть чужой,
        // отстающий код.
        var dir = exe
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("bin/ocbar").standardizedFileURL.path)
            dir = dir.deletingLastPathComponent()
        }
        candidates += ["/opt/homebrew/bin/ocbar", "/usr/local/bin/ocbar"]
        binary = Shell.firstExecutable(candidates)
        if binary == nil {
            lookupNote = "Искал в /opt/homebrew/bin, /usr/local/bin и рядом с приложением. Путь можно задать переменной OCBAR_BIN."
        }
    }

    var configDir: String {
        ProcessInfo.processInfo.environment["OCBAR_CONFIG_DIR"]
            ?? NSString(string: "~/.config/ocbar").expandingTildeInPath
    }
    var profileDir: String { configDir + "/profiles" }
    var supervisorLog: String {
        NSString(string: "~/Library/Logs/ocbar/supervisor.log").expandingTildeInPath
    }
    let openconnectLog = "/usr/local/var/ocbar/openconnect.log"
    var proxyLog: String {
        NSString(string: "~/Library/Logs/ocbar/openconnect-proxy.log").expandingTildeInPath
    }

    // --- состояние -------------------------------------------------------

    func status() -> Status {
        guard let binary else {
            var s = Status()
            s.available = false
            s.error = nil
            return s
        }
        let r = Shell.run(binary, ["status", "--short"], timeout: 10)
        guard r.code == 0 else {
            var s = Status()
            s.error = r.err.isEmpty ? "ocbar status вернул \(r.code)" : r.err.trimmed
            return s
        }
        var s = Status.parse(r.out)
        // MTU в `status --short` нет, а показать его хочется: берём из той
        // же строки netstat, что и счётчики, лишнего процесса не заводим.
        if let t = Traffic.read(tundev: s.tundev) { s.mtu = t.mtu }
        return s
    }

    // --- действия --------------------------------------------------------

    enum ActionResult {
        case ok(String)
        case needsLogin          // код 5: решает человек, это не ошибка
        case failed(Int32, String)
    }

    func action(_ args: [String], timeout: TimeInterval = 60) -> ActionResult {
        guard let binary else { return .failed(127, "ocbar не найден") }
        let r = Shell.run(binary, args, timeout: timeout)
        if r.code == 0 { return .ok(r.out.trimmed) }
        if r.code == 5 { return .needsLogin }
        let message = r.err.trimmed.isEmpty ? r.out.trimmed : r.err.trimmed
        return .failed(r.code, message.isEmpty ? "код возврата \(r.code)" : message)
    }

    // Вход может занять минуты: у ocbar-auth своё ожидание человека — 300 с,
    // и приложение не должно обрывать его раньше, иначе медленный вход
    // заканчивается «не ответила за 180 с» посреди формы. Отсюда 360.
    // --show: окно входа сразу, а не после пробы молчаливого прохода —
    // когда человек сам нажал «Войти», ждать две секунды незачем.
    // teach: войти руками, а ocbar запомнит форму и после входа предложит
    // сохранить правила, пароль и источник кода (ocbar connect --teach).
    // Тайм-аут шире: после входа ещё окно «что сохранить», до трёх минут.
    func connect(profile: String?, show: Bool = false, teach: Bool = false) -> ActionResult {
        action(["connect"] + (profile.map { [$0] } ?? []) + (show ? ["--show"] : []) + (teach ? ["--teach"] : []),
               timeout: teach ? 600 : 360)
    }
    func disconnect() -> ActionResult { action(["disconnect"], timeout: 40) }
    func pause() -> ActionResult { action(["pause"], timeout: 40) }
    func resume() -> ActionResult { action(["resume"], timeout: 60) }
    func toggleRoute(_ cidr: String) -> ActionResult { action(["routes", "toggle", cidr], timeout: 30) }
    func toggleZone(_ zone: String) -> ActionResult { action(["dns", "toggle", zone], timeout: 30) }
    func cleanup() -> ActionResult { action(["cleanup"], timeout: 60) }

    // Диагностика: doctor ничего не меняет, поэтому вывод целиком, как есть.
    func doctor() -> String {
        guard let binary else { return "ocbar не найден" }
        let r = Shell.run(binary, ["doctor"], timeout: 60)
        let text = (r.out + (r.err.isEmpty ? "" : "\n" + r.err)).trimmed
        return text.isEmpty ? "ocbar doctor ничего не напечатал (код \(r.code))" : text
    }

    // --- версии для окна «о программе» -----------------------------------

    func version(_ path: String, _ args: [String]) -> String {
        let r = Shell.run(path, args, timeout: 8)
        let text = (r.out + " " + r.err).trimmed
        return text.isEmpty ? "—" : text.split(separator: "\n").first.map(String.init) ?? "—"
    }
}

// Счётчики интерфейса. Разбирать с конца строки: колонки адреса у utun
// нет, и позиционный разбор смещается — принято $(NF-4), отправлено $(NF-1).
struct Traffic {
    let rx: UInt64
    let tx: UInt64
    let mtu: String
    let at: Date

    static func read(tundev: String) -> Traffic? {
        guard !tundev.isEmpty else { return nil }
        let r = Shell.run("/usr/sbin/netstat", ["-ib", "-I", tundev], timeout: 5)
        guard r.code == 0 else { return nil }
        let lines = r.out.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let f = lines[1].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 5,
              let rx = UInt64(f[f.count - 5]),
              let tx = UInt64(f[f.count - 2]) else { return nil }
        return Traffic(rx: rx, tx: tx, mtu: f.count > 1 ? f[1] : "", at: Date())
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension StringProtocol {
    var trimmed: String { String(self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension OcbarClient {
    // Задержка до шлюза. Считается только когда открыты подробности: лишний
    // ping раз в две секунды в фоне никому не нужен.
    func latency(host: String) -> String? {
        guard !host.isEmpty else { return nil }
        let r = Shell.run("/sbin/ping", ["-c", "1", "-W", "900", host], timeout: 3)
        guard r.code == 0 else { return nil }
        guard let range = r.out.range(of: "time=") else { return nil }
        let tail = r.out[range.upperBound...]
        let number = tail.prefix { $0.isNumber || $0 == "." }
        guard let ms = Double(number) else { return nil }
        return "\(Int(ms.rounded())) мс"
    }
}

// Версии и пути всех частей: `ocbar version --all`. Поиск бинарников живёт
// в CLI, приложение его не повторяет — иначе они разойдутся.
extension OcbarClient {
    func versions(maxAge: TimeInterval = 60) -> [String: String] {
        versionsLock.lock()
        if let cached = versionsCache, Date().timeIntervalSince(versionsStamp) < maxAge {
            versionsLock.unlock()
            return cached
        }
        versionsLock.unlock()
        var map: [String: String] = [:]
        if let binary {
            let r = Shell.run(binary, ["version", "--all"], timeout: 15)
            for line in r.out.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                map[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        versionsLock.lock()
        versionsCache = map
        versionsStamp = Date()
        versionsLock.unlock()
        return map
    }

    func preloadVersions() {
        DispatchQueue.global(qos: .utility).async { _ = self.versions() }
    }
}
