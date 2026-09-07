import Foundation
import SwiftUI

// Состояние для интерфейса: опрос ocbar, счётчики трафика, выполнение
// действий. Всё, что долго, уходит на фоновую очередь; публикуется на
// главной.
@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var status = Status()
    @Published private(set) var samples: [TrafficSample] = []
    @Published private(set) var busy: String?          // что сейчас выполняется
    @Published private(set) var lastError: String?
    @Published private(set) var lastAction: String?    // короткий итог действия
    @Published var menuOpen = false { didSet { retune() } }
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
    init(preview: Status, samples: [TrafficSample] = [], latency: String? = nil) {
        self.status = preview
        self.samples = samples
        self.latency = latency
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

    func refresh() {
        guard !isPreview else { return }
        let client = self.client
        let wantLatency = detailsOpen
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
        let dev = status.tundev
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

    func perform(_ title: String, _ body: @escaping @Sendable () -> OcbarClient.ActionResult) {
        guard busy == nil, !isPreview else { return }
        busy = title
        lastAction = nil
        queue.async { [weak self] in
            let result = body()
            let fresh = OcbarClient.shared.status()
            Task { @MainActor in
                guard let self else { return }
                self.busy = nil
                switch result {
                case .ok:
                    self.lastError = nil
                case .needsLogin:
                    self.lastAction = "Нужен вход: молча войти не удалось"
                case .failed(_, let message):
                    self.lastError = message
                }
                self.apply(fresh)
                if case .failed = result { self.lastError = self.lastError ?? "не получилось" }
            }
        }
    }

    func connect(profile: String? = nil) {
        perform("Подключаюсь…") { OcbarClient.shared.connect(profile: profile) }
    }
    func disconnect() { perform("Отключаю…") { OcbarClient.shared.disconnect() } }
    func pause() { perform("Ставлю на паузу…") { OcbarClient.shared.pause() } }
    func resume() { perform("Возобновляю…") { OcbarClient.shared.resume() } }
    func toggleRoute(_ net: String) {
        perform("Переключаю \(net)…") { OcbarClient.shared.toggleRoute(net) }
    }
    func toggleZone(_ zone: String) {
        perform("Переключаю \(zone)…") { OcbarClient.shared.toggleZone(zone) }
    }
    func cleanup() { perform("Убираю следы…") { OcbarClient.shared.cleanup() } }
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
