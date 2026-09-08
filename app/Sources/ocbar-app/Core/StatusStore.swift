import Foundation
import SwiftUI

// Состояние для интерфейса: опрос ocbar, счётчики трафика, выполнение
// действий. Всё, что долго, уходит на фоновую очередь; публикуется на
// главной.
@MainActor
final class StatusStore: ObservableObject {
    // Один живой экземпляр на приложение: к нему обращаются и меню, и
    // глобальная горячая клавиша, которой до иерархии представлений не
    // дотянуться. Витрина создаёт свои, с подставленным состоянием.
    static let shared = StatusStore()

    @Published private(set) var status = Status()
    @Published private(set) var samples: [TrafficSample] = []
    @Published private(set) var busy: String?          // что сейчас выполняется
    @Published private(set) var lastError: String?     // беда, о которой сказал сам ocbar status
    // Итог последнего действия живёт отдельно от ошибки состояния: раньше
    // ответ ocbar затирался ближайшим опросом через пару секунд, и человек
    // просто не успевал его прочитать.
    @Published private(set) var actionNote: String?
    @Published private(set) var actionFailed = false
    // Переключатель должен щёлкать сразу, а не через опрос: пока действие
    // идёт, показываем то, что человек попросил.
    @Published private(set) var pendingRoutes: [String: Bool] = [:]
    @Published private(set) var pendingZones: [String: Bool] = [:]
    @Published var menuOpen = false { didSet { retune(); if menuOpen { refreshHelperState() } } }
    // Беда, о которой status не расскажет: без NOPASSWD хелпер спросит
    // пароль в терминале, которого у меню нет, и действие просто не пройдёт.
    @Published private(set) var helperWarning: String?
    @Published var detailsOpen = false
    @Published private(set) var latency: String?

    struct TrafficSample: Identifiable {
        let id = UUID()
        let at: Date
        let down: Double      // байт в секунду
        let up: Double
    }

    // Окно графика — минута. Точка раз в две секунды: netstat дёшев,
    // а рисовать чаще незачем.
    private let sampleInterval: TimeInterval = 2
    private let sampleWindow = 30

    private let client = OcbarClient.shared
    private let queue = DispatchQueue(label: "ru.ocbar.app.poll", qos: .utility)
    private var statusTimer: Timer?
    private var trafficTimer: Timer?
    private var previous: Traffic?
    private var isPreview = false
    private var latencyAt = Date.distantPast
    private var totals: (rx: UInt64, tx: UInt64) = (0, 0)

    var totalRx: UInt64 { totals.rx }
    var totalTx: UInt64 { totals.tx }
    var currentDown: Double { samples.last?.down ?? 0 }
    var currentUp: Double { samples.last?.up ?? 0 }

    // Живой опрос системы.
    init() {
        refresh()
        retune()
    }

    // Витрина (--stage): состояние подставлено, ничего не опрашивается.
    init(preview: Status, samples: [TrafficSample] = [], latency: String? = nil,
         busy: String? = nil, actionNote: String? = nil, helperWarning: String? = nil) {
        self.status = preview
        self.samples = samples
        self.latency = latency
        self.busy = busy
        self.actionNote = actionNote
        self.helperWarning = helperWarning
        self.totals = (7_632_631_260, 169_171_632)
        self.isPreview = true
    }

    // Пока меню открыто, опрашиваем чаще: человек видит цифры и ждёт, что
    // они живые. Закрытое меню довольствуется частотой плагина SwiftBar.
    private func retune() {
        guard !isPreview else { return }
        statusTimer?.invalidate()
        trafficTimer?.invalidate()
        let period: TimeInterval = menuOpen ? 2 : 6
        statusTimer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        trafficTimer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleTraffic() }
        }
    }

    private func refreshHelperState() {
        guard !isPreview else { return }
        queue.async { [weak self] in
            let v = OcbarClient.shared.versions(maxAge: 300)
            let warning: String?
            if v.isEmpty {
                warning = nil
            } else if v["helper_path"] == nil {
                warning = "Хелпер не установлен: действия из меню не сработают — sudo ocbar install"
            } else if v["helper_nopasswd"] != "1" {
                warning = "Хелпер без NOPASSWD: sudo спросит пароль, а терминала у меню нет — sudo ocbar install"
            } else {
                warning = nil
            }
            Task { @MainActor in self?.helperWarning = warning }
        }
    }

    func refresh() {
        guard !isPreview else { return }
        let client = self.client
        // Пинговать шлюз при каждом опросе (раз в две секунды) незачем:
        // цифра меняется медленнее, чем обновляется меню.
        let wantLatency = detailsOpen && Date().timeIntervalSince(latencyAt) > 10
        if wantLatency { latencyAt = Date() }
        let gateway = status.gateway
        queue.async { [weak self] in
            let s = client.status()
            let ms = wantLatency ? client.latency(host: gateway) : nil
            Task { @MainActor in
                self?.apply(s)
                if wantLatency { self?.latency = ms }
            }
        }
    }

    private func apply(_ s: Status) {
        let wasDevice = status.tundev
        status = s
        lastError = s.error
        // Туннель пересоздан — счётчики начинаются заново, старую разницу
        // считать нельзя: получится всплеск в гигабайты.
        if wasDevice != s.tundev { previous = nil; samples.removeAll(); totals = (0, 0) }
    }

    private func sampleTraffic() {
        // В прокси-режиме интерфейса нет, а с ним и счётчиков — график не
        // рисуется вовсе, а не показывает нули.
        let dev = status.isProxySession ? "" : status.tundev
        guard !dev.isEmpty else {
            if !samples.isEmpty { samples.removeAll(); previous = nil }
            return
        }
        queue.async { [weak self] in
            guard let t = Traffic.read(tundev: dev) else { return }
            Task { @MainActor in self?.addSample(t) }
        }
    }

    private func addSample(_ t: Traffic) {
        totals = (t.rx, t.tx)
        defer { previous = t }
        guard let p = previous else { return }
        let dt = t.at.timeIntervalSince(p.at)
        guard dt > 0.3 else { return }
        // Счётчик может уехать назад при пересоздании интерфейса — такую
        // разницу считаем нулём, иначе на графике появится отрицательный пик.
        let down = t.rx >= p.rx ? Double(t.rx - p.rx) / dt : 0
        let up = t.tx >= p.tx ? Double(t.tx - p.tx) / dt : 0
        samples.append(TrafficSample(at: t.at, down: down, up: up))
        if samples.count > sampleWindow { samples.removeFirst(samples.count - sampleWindow) }
    }

    // --- действия --------------------------------------------------------

    private var noteTimer: Timer?

    func perform(_ title: String, _ body: @escaping @Sendable () -> OcbarClient.ActionResult) {
        guard busy == nil, !isPreview else { return }
        busy = title
        actionNote = nil
        actionFailed = false
        queue.async { [weak self] in
            let result = body()
            let fresh = OcbarClient.shared.status()
            Task { @MainActor in
                guard let self else { return }
                self.busy = nil
                self.apply(fresh)
                self.pendingRoutes.removeAll()
                self.pendingZones.removeAll()
                switch result {
                case .ok:
                    break
                case .needsLogin:
                    self.note("Молча войти не удалось — нужен вход", failed: true)
                    AppLog.write("действие «\(title)»: нужен вход (код 5)")
                case .failed(let code, let message):
                    self.note(message.isEmpty ? "не получилось" : message, failed: true)
                    AppLog.write("действие «\(title)»: код \(code) — \(message)")
                }
            }
        }
    }

    // Сообщение об итоге держится на экране заметное время и уходит само:
    // строка, исчезающая через два секунды вместе с опросом, бесполезна.
    private func note(_ text: String, failed: Bool) {
        actionNote = text
        actionFailed = failed
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.actionNote = nil }
        }
    }

    func dismissNote() {
        noteTimer?.invalidate()
        actionNote = nil
    }

    func connect(profile: String? = nil, show: Bool = false) {
        perform("Подключаюсь…") { OcbarClient.shared.connect(profile: profile, show: show) }
    }
    func disconnect() { perform("Отключаю…") { OcbarClient.shared.disconnect() } }
    func pause() { perform("Ставлю на паузу…") { OcbarClient.shared.pause() } }
    func resume() { perform("Возобновляю…") { OcbarClient.shared.resume() } }
    func toggleRoute(_ net: String, to newValue: Bool) {
        guard busy == nil else { return }
        pendingRoutes[net] = newValue
        perform("Переключаю \(net)…") { OcbarClient.shared.toggleRoute(net) }
    }
    func toggleZone(_ zone: String, to newValue: Bool) {
        guard busy == nil else { return }
        pendingZones[zone] = newValue
        perform("Переключаю \(zone)…") { OcbarClient.shared.toggleZone(zone) }
    }

    func routeIsOn(_ r: RouteEntry) -> Bool { pendingRoutes[r.net] ?? r.enabled }
    func zoneIsOn(_ z: ZoneEntry) -> Bool { pendingZones[z.zone] ?? z.enabled }
    func cleanup() { perform("Убираю следы…") { OcbarClient.shared.cleanup() } }

    /// Пауза и возобновление одной клавишей: смысл действия зависит от того,
    /// что сейчас. Отключение сюда не входит намеренно — случайное нажатие
    /// стоило бы нового входа со вторым фактором.
    func togglePause() {
        switch status.presentation {
        case .connected, .lost: pause()
        case .paused: resume()
        default: NSSound.beep()
        }
    }
}

// Человеческие размеры: 1,2 МБ/с, 7,2 ГБ. Разделитель — запятая, как везде
// в русском интерфейсе.
enum Size {
    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/с"
    }
    static func bytes(_ v: Double) -> String {
        let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var value = v, i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        let digits = (value < 10 && i > 0) ? 1 : 0
        return String(format: "%.\(digits)f %@", value, units[i])
            .replacingOccurrences(of: ".", with: ",")
    }
    static func bytes(_ v: UInt64) -> String { bytes(Double(v)) }
}
