import Foundation
import SwiftUI

// Состояние для интерфейса: опрос ocbar, счётчики трафика, выполнение
// действий. Всё, что долго, уходит в фон; публикуется на главной.
//
// Опрос и действия живут на разных очередях. Раньше очередь была одна, и
// долгое действие — разметка до 30 минут, вход до 15 — держало опрос: значок
// показывал старое состояние, а «Отключить» было нечем нажать.
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
    // Долгое действие, которое можно отменить (вход, разметка): подпись для
    // строки отмены в меню и то, нужно ли после отмены отключаться.
    @Published private(set) var cancelTitle: String?
    @Published private(set) var cancelDisconnects = false
    // Сколько действий завершилось. Редактор профиля смотрит на него, чтобы
    // перечитать файл, который мог поменять ocbar (разметка, запоминание входа).
    @Published private(set) var finishedActions = 0

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
    // Откуда брать состояние и чем отключаться. Подменяются самопроверкой:
    // так видно, ждёт ли опрос долгого действия, без живого ocbar.
    private let statusSource: @Sendable () -> Status
    private let disconnectBody: @Sendable (CancelToken) -> OcbarClient.ActionResult
    private let pollQueue = DispatchQueue(label: "ru.ocbar.app.poll", qos: .utility)
    private let sampleQueue = DispatchQueue(label: "ru.ocbar.app.sample", qos: .utility)
    private let actionQueue = DispatchQueue(label: "ru.ocbar.app.action", qos: .userInitiated)
    private var polling = false            // опрос идёт — следующий тик пропускается
    private var sampling = false
    private var appliedStart = Date.distantPast   // начало опроса, чей итог сейчас на экране
    private var statusTimer: Timer?
    private var trafficTimer: Timer?
    private var previous: Traffic?
    private var isPreview = false
    private var latencyAt = Date.distantPast
    private var totals: (rx: UInt64, tx: UInt64) = (0, 0)
    private var currentToken: CancelToken?
    private var afterAction: (() -> Void)?

    var totalRx: UInt64 { totals.rx }
    var totalTx: UInt64 { totals.tx }
    var currentDown: Double { samples.last?.down ?? 0 }
    var currentUp: Double { samples.last?.up ?? 0 }

    // Живой опрос системы.
    init() {
        statusSource = { OcbarClient.shared.status() }
        disconnectBody = { OcbarClient.shared.disconnect(cancel: $0) }
        refresh()
        retune()
    }

    // Витрина (--stage): состояние подставлено, ничего не опрашивается.
    init(preview: Status, samples: [TrafficSample] = [], latency: String? = nil,
         busy: String? = nil, actionNote: String? = nil, helperWarning: String? = nil) {
        self.statusSource = { preview }
        self.disconnectBody = { _ in .ok("") }
        self.status = preview
        self.samples = samples
        self.latency = latency
        self.busy = busy
        self.actionNote = actionNote
        self.helperWarning = helperWarning
        self.totals = (7_632_631_260, 169_171_632)
        self.isPreview = true
    }

    // Самопроверка: состояние и отключение подставлены, таймеров нет.
    init(testSource: @escaping @Sendable () -> Status,
         disconnect: @escaping @Sendable () -> OcbarClient.ActionResult = { .ok("") }) {
        self.statusSource = testSource
        self.disconnectBody = { _ in disconnect() }
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
        // `version --all` бывает долгим (до 15 с) — не на очереди опроса.
        DispatchQueue.global(qos: .utility).async { [weak self] in
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
        // Прошлый опрос ещё идёт (ocbar status думает до 10 с) — этот тик
        // пропускаем: иначе вызовы копились бы в очереди один за другим.
        guard !polling else { return }
        polling = true
        let client = self.client
        let source = statusSource
        // Пинговать шлюз при каждом опросе (раз в две секунды) незачем:
        // цифра меняется медленнее, чем обновляется меню.
        let wantLatency = detailsOpen && Date().timeIntervalSince(latencyAt) > 10
        if wantLatency { latencyAt = Date() }
        let gateway = status.gateway
        let started = Date()
        pollQueue.async { [weak self] in
            let s = source()
            let ms = wantLatency ? client.latency(host: gateway) : nil
            Task { @MainActor in
                guard let self else { return }
                self.polling = false
                self.apply(s, started: started)
                if wantLatency { self.latency = ms }
            }
        }
    }

    // Итог опроса, начатого раньше уже показанного, — устаревший: его не
    // показываем, иначе состояние после действия откатилось бы назад.
    private func apply(_ s: Status, started: Date) {
        guard started >= appliedStart else { return }
        appliedStart = started
        let wasDevice = status.tundev
        status = s
        // Последний подключённый профиль — к нему ведёт «Подключить» в меню:
        // выбор профиля живёт в настройках, а не в меню.
        if !s.profile.isEmpty, !isPreview { UserDefaults.standard.set(s.profile, forKey: "LastProfile") }
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
        guard !sampling else { return }
        sampling = true
        sampleQueue.async { [weak self] in
            let t = Traffic.read(tundev: dev)
            Task { @MainActor in
                self?.sampling = false
                if let t { self?.addSample(t) }
            }
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

    /// Выполнить действие ocbar. Одно за раз: пока идёт одно, остальные
    /// строки меню недоступны. `cancel` — подпись строки отмены для долгого
    /// действия, которое ждёт человека (вход, разметка); `disconnects` —
    /// после отмены ещё и отключиться (подключение могло успеть подняться).
    func perform(_ title: String, cancel: String? = nil, disconnects: Bool = false,
                 _ body: @escaping @Sendable (CancelToken) -> OcbarClient.ActionResult,
                 completion: ((OcbarClient.ActionResult) -> Void)? = nil) {
        guard busy == nil, !isPreview else { return }
        busy = title
        actionNote = nil
        actionFailed = false
        let token = CancelToken()
        currentToken = token
        cancelTitle = cancel
        cancelDisconnects = disconnects
        let source = statusSource
        actionQueue.async { [weak self] in
            let result = body(token)
            let started = Date()
            let fresh = source()
            Task { @MainActor in
                guard let self else { return }
                self.busy = nil
                self.currentToken = nil
                self.cancelTitle = nil
                self.cancelDisconnects = false
                self.apply(fresh, started: started)
                self.pendingRoutes.removeAll()
                self.pendingZones.removeAll()
                switch result {
                case .ok(let text):
                    // Итог разметки стоит показать: правила лежат в файле, и
                    // без этой строки не понять, состоялась ли она.
                    if title.hasPrefix("Идёт разметка") { self.note(text, failed: false) }
                case .needsLogin:
                    self.note("Молча войти не удалось — нужен вход", failed: true)
                    AppLog.write("действие «\(title)»: нужен вход (код 5)")
                case .cancelled:
                    self.note("«\(title.trimmingCharacters(in: CharacterSet(charactersIn: "…")))» отменено", failed: false)
                    AppLog.write("действие «\(title)»: отменено")
                case .failed(let code, let message):
                    self.note(message.isEmpty ? "не получилось" : message, failed: true)
                    AppLog.write("действие «\(title)»: код \(code) — \(message)")
                }
                completion?(result)
                self.finishedActions += 1
                if let next = self.afterAction { self.afterAction = nil; next() }
            }
        }
    }

    /// Отменить текущее долгое действие: погасить запущенный ocbar (вместе с
    /// окном входа) и, если это было подключение, отключиться.
    func cancelCurrent() {
        guard busy != nil, cancelTitle != nil else { return }
        let thenDisconnect = cancelDisconnects
        currentToken?.cancel()
        if thenDisconnect { afterAction = { [weak self] in self?.runDisconnect() } }
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

    func connect(profile: String? = nil, show: Bool = false, teach: Bool = false) {
        perform(teach ? "Вход с запоминанием…" : "Подключаюсь…", cancel: "Отменить подключение", disconnects: true) {
            OcbarClient.shared.connect(profile: profile, show: show, teach: teach, cancel: $0)
        }
    }

    /// «Отключить» работает и посреди действия: долгое (вход) отменяется,
    /// короткое (переключатель сети) доделывается, и следом — отключение.
    func disconnect() {
        guard !isPreview else { return }
        if busy == nil { runDisconnect(); return }
        if cancelTitle != nil {
            currentToken?.cancel()
        }
        afterAction = { [weak self] in self?.runDisconnect() }
    }

    private func runDisconnect() {
        let body = disconnectBody
        perform("Отключаю…") { body($0) }
    }

    func pause() { perform("Ставлю на паузу…") { _ in OcbarClient.shared.pause() } }
    func resume() { perform("Возобновляю…") { _ in OcbarClient.shared.resume() } }
    func toggleRoute(_ net: String, to newValue: Bool) {
        guard busy == nil else { return }
        pendingRoutes[net] = newValue
        perform("Переключаю \(net)…") { _ in OcbarClient.shared.toggleRoute(net) }
    }
    func toggleZone(_ zone: String, to newValue: Bool) {
        guard busy == nil else { return }
        pendingZones[zone] = newValue
        perform("Переключаю \(zone)…") { _ in OcbarClient.shared.toggleZone(zone) }
    }

    // Разметка формы входа: окно ocbar-auth живёт, пока человек не нажмёт
    // «Готово», поэтому ждём долго; правила ложатся в сам профиль. Одна на
    // всё приложение — и из меню, и из редактора профиля идёт сюда.
    func learn(profile: String, completion: ((OcbarClient.ActionResult) -> Void)? = nil) {
        perform("Идёт разметка формы…", cancel: "Отменить разметку", {
            let r = OcbarClient.shared.learn(profile: profile, cancel: $0)
            if case .ok(let text) = r {
                return .ok(text.contains("отменена") ? "разметка отменена — профиль не тронут" : "правила записаны в профиль «\(profile)»")
            }
            return r
        }, completion: completion)
    }
    func routeIsOn(_ r: RouteEntry) -> Bool { pendingRoutes[r.net] ?? r.enabled }
    func zoneIsOn(_ z: ZoneEntry) -> Bool { pendingZones[z.zone] ?? z.enabled }
    func cleanup() { perform("Убираю следы…") { _ in OcbarClient.shared.cleanup() } }
    /// Выйти совсем (режим разработчика): отключиться и забыть сессии входа.
    func logout() { perform("Выхожу совсем…") { _ in OcbarClient.shared.logout() } }

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
        bytes(bytesPerSecond) + L("/с")
    }
    static func bytes(_ v: Double) -> String {
        let units = [L("Б"), L("КБ"), L("МБ"), L("ГБ"), L("ТБ")]
        var value = v, i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        let digits = (value < 10 && i > 0) ? 1 : 0
        // Запятая как разделитель — русская привычка; в английском точка.
        let out = String(format: "%.\(digits)f %@", value, units[i])
        return L(",") == "," ? out.replacingOccurrences(of: ".", with: ",") : out
    }
    static func bytes(_ v: UInt64) -> String { bytes(Double(v)) }
}
