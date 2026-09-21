import AppKit
import AVFoundation
import CoreImage
import CoreVideo

/// Чтение QR второго фактора камерой Mac — с экрана телефона. Экспорт Google
/// Authenticator («Перенос аккаунтов → Экспорт») показывает QR, а снимок
/// экрана телефон часто запрещает; камера его читает.
///
/// Кадры не сохраняются и никуда не уходят: из кадра берётся только строка
/// QR. Камера выключается сразу после совпадения, отмены или тайм-аута.
final class QRCameraScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ru.ocbar.qr-camera")
    private var last = Date.distantPast
    var onPayloads: (([String]) -> Void)?

    static func cameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types += [.external, .continuityCamera] } else { types.append(.externalUnknown) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    /// Встроенная камера — первой: камера iPhone (Continuity) не может снимать
    /// экран того же телефона, на котором открыт аутентификатор.
    static func preferred(_ list: [AVCaptureDevice]) -> AVCaptureDevice? {
        list.first { $0.deviceType == .builtInWideAngleCamera } ?? list.first
    }

    func start(_ device: AVCaptureDevice) throws {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        if session.outputs.isEmpty {
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
        }
        session.commitConfiguration()
        queue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Четыре кадра в секунду хватает: QR на экране телефона не убегает.
        guard Date().timeIntervalSince(last) > 0.25, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = Date()
        let found = Self.payloads(pixelBuffer: pb)
        if !found.isEmpty { DispatchQueue.main.async { self.onPayloads?(found) } }
    }

    /// Тот же путь, что у QR из файла. Проверяется без камеры — на кадре,
    /// собранном в памяти (ocbar-auth --learn-selftest).
    static func payloads(pixelBuffer: CVPixelBuffer) -> [String] {
        QRImport.payloads(in: CIImage(cvPixelBuffer: pixelBuffer))
    }
}

/// Окно камеры: предпросмотр, выбор камеры, подсказка и строка состояния.
/// Возвращает запись, которая даёт код, только что введённый человеком, —
/// из экспорта на несколько записей и страниц нужная находится сама.
final class QRCameraWindow: NSObject, NSWindowDelegate {
    private let code: String
    private let at: Date
    private let select: String?
    private let scanner = QRCameraScanner()
    private var window: NSWindow!
    private var status: NSTextField!
    private var picker: NSPopUpButton!
    private var devices: [AVCaptureDevice] = []
    private var result: QRImport.Entry?
    private var seen = Set<String>()
    private var running = false

    /// code — введённый при входе код: по нему находится нужная запись.
    /// Пустой — добавление с нуля: годится единственная запись TOTP в QR
    /// или та, что подходит под select.
    init(code: String, at: Date, select: String? = nil) {
        self.code = code
        self.at = at
        self.select = select
        super.init()
    }

    /// Что делать с записями одного QR: взять одну или сказать человеку,
    /// почему нет, и искать дальше. Молча брать первую из нескольких нельзя —
    /// так в связку ложится чужой секрет.
    static func decide(_ entries: [QRImport.Entry], code: String, at: Date,
                       select: String? = nil) -> (entry: QRImport.Entry?, status: String) {
        if !code.isEmpty {
            if let e = entries.first(where: { fits($0, code: code, at: at) }) { return (e, "") }
            return (nil, entries.count > 1
                ? L("в этом QR записей: %@, ни одна не даёт ваш код — покажите следующий QR экспорта", entries.count)
                : L("эта запись не даёт ваш код — выберите в экспорте учётку VPN"))
        }
        var candidates = entries.filter(\.isTOTP)
        if candidates.isEmpty {
            return (nil, L("это HOTP (код по счётчику) — ocbar его не ведёт"))
        }
        if let want = select?.lowercased(), !want.isEmpty {
            let all = candidates
            candidates = all.filter { $0.label.lowercased().contains(want) }
            if candidates.isEmpty {
                return (nil, L("в QR нет записи, похожей на «%@». Есть: %@", select!, all.map(\.label).joined(separator: ", ")))
            }
        }
        if candidates.count == 1 { return (candidates[0], "") }
        return (nil, L("в QR записей: %@ (%@) — экспортируйте одну учётку VPN", candidates.count, candidates.map(\.label).joined(separator: ", ")))
    }

    static func fits(_ e: QRImport.Entry, code: String, at: Date) -> Bool {
        // Без кода (добавление с нуля) подходит любая запись TOTP: сверять
        // не с чем, а человек сам показывает камере нужный QR.
        if code.isEmpty { return e.isTOTP }
        return TeachDialog.entryMatches(e, code: code, at: at)
    }

    private func build(withPreview: Bool) {
        let w: CGFloat = 560, h: CGFloat = 520
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let hint = NSTextField(wrappingLabelWithString: code.isEmpty
            ? L("Поднесите к камере QR второго фактора: тот, что показывает портал при настройке, или экспорт из Google Authenticator (⋮ → «Перенос аккаунтов» → «Экспорт») с одной учёткой VPN. Кадры никуда не сохраняются.")
            : L("На телефоне: Google Authenticator → ⋮ → «Перенос аккаунтов» → «Экспорт», выберите учётку VPN и поднесите QR к камере. Подойдёт только запись, которая даёт код, введённый вами при входе. Кадры никуда не сохраняются."))
        hint.font = .systemFont(ofSize: 12)
        hint.frame = NSRect(x: 16, y: h - 70, width: w - 32, height: 56)
        content.addSubview(hint)

        let preview = NSView(frame: NSRect(x: 16, y: 84, width: w - 32, height: h - 170))
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.layer?.cornerRadius = 8
        if withPreview {
            let layer = AVCaptureVideoPreviewLayer(session: scanner.session)
            layer.videoGravity = .resizeAspect
            layer.frame = preview.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            if let c = layer.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true            // как в зеркале: телефон легче навести
            }
            preview.layer?.addSublayer(layer)
        }
        content.addSubview(preview)

        status = NSTextField(labelWithString: L("ищу QR…"))
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 16, y: 54, width: w - 32, height: 18)
        content.addSubview(status)

        picker = NSPopUpButton(frame: NSRect(x: 16, y: 14, width: 300, height: 26), pullsDown: false)
        picker.addItems(withTitles: devices.isEmpty ? [L("камера")] : devices.map(\.localizedName))
        picker.target = self
        picker.action = #selector(cameraChanged)
        picker.isHidden = devices.count < 2
        content.addSubview(picker)

        let cancel = NSButton(title: L("Отмена"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: w - 116, y: 12, width: 100, height: 30)
        content.addSubview(cancel)

        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = L("ocbar — QR второго фактора с камеры")
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
    }

    /// Показать окно и ждать записи. nil — отмена, нет камеры, нет доступа
    /// или тайм-аут; в note — что сказать человеку.
    func run(timeout: TimeInterval = 180) -> (entry: QRImport.Entry?, note: String) {
        // Кадры из файлов вместо камеры: весь путь «кадр → запись → ответ»
        // проверяется без человека, без камеры и без окна.
        if let frames = ProcessInfo.processInfo.environment["OCBAR_SELFTEST_CAMERA_FRAMES"], !frames.isEmpty {
            return fromFrames(frames.split(separator: ":").map(String.init))
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            var granted: Bool?
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { granted = ok } }
            let deadline = Date().addingTimeInterval(120)
            while granted == nil && Date() < deadline {
                RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.1))
            }
            if granted != true { return (nil, L("доступ к камере не дан — секрет можно вставить или выбрать файл QR")) }
        default:
            return (nil, L("доступ к камере запрещён: Системные настройки → Конфиденциальность и безопасность → Камера — разрешите ocbar или терминалу, из которого входите"))
        }
        devices = QRCameraScanner.cameras()
        guard let device = QRCameraScanner.preferred(devices) else { return (nil, L("камера не найдена")) }
        build(withPreview: true)
        if let i = devices.firstIndex(of: device) { picker.selectItem(at: i) }
        scanner.onPayloads = { [weak self] found in self?.handle(found) }
        do { try scanner.start(device) } catch { return (nil, L("камера не включилась: %@", error.localizedDescription)) }
        running = true
        Log.info("камера: включена (\(device.localizedName)), ищу QR второго фактора")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let t = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in self?.finish() }
        RunLoop.main.add(t, forMode: .modalPanel)
        NSApp.runModal(for: window)
        t.invalidate()
        scanner.stop()
        window.orderOut(nil)
        Log.info("камера: выключена" + (result == nil ? "" : ", запись найдена"))
        return (result, result != nil ? "" : lastStatus.isEmpty
            ? L("QR с камеры не прочитан — можно вставить секрет или выбрать файл QR") : lastStatus)
    }

    private func handle(_ payloads: [String]) {
        guard running else { return }
        if let e = consider(payloads) {
            result = e
            finish()
        }
    }

    /// Новые строки QR с кадра: запись, если она нашлась, иначе — почему нет,
    /// в строку состояния. Один путь у камеры и у кадров из файлов.
    private func consider(_ payloads: [String]) -> QRImport.Entry? {
        for p in payloads where !seen.contains(p) {
            seen.insert(p)
            guard let entries = try? QRImport.parse(p) else {
                setStatus(L("это не QR второго фактора — покажите экспорт из аутентификатора"))
                continue
            }
            let d = Self.decide(entries, code: code, at: at, select: select)
            if let e = d.entry { return e }
            setStatus(d.status)
        }
        return nil
    }

    private var lastStatus = ""
    private func setStatus(_ s: String) {
        lastStatus = s
        status?.stringValue = s
    }

    private func fromFrames(_ files: [String]) -> (entry: QRImport.Entry?, note: String) {
        for f in files {
            let found = (try? QRImport.decode(file: f)) ?? []
            if let e = consider(found) { return (e, "") }
        }
        return (nil, lastStatus.isEmpty ? L("QR с камеры не прочитан — можно вставить секрет или выбрать файл QR") : lastStatus)
    }

    @objc private func cameraChanged() {
        let i = picker.indexOfSelectedItem
        guard devices.indices.contains(i) else { return }
        try? scanner.start(devices[i])
    }

    @objc private func cancel() { finish() }

    func windowWillClose(_ notification: Notification) { finish() }

    private func finish() {
        guard running else { return }
        running = false
        scanner.stop()
        NSApp.stopModal()
    }

    /// Снимок окна без включения камеры — чтобы вид проверялся без человека
    /// (ocbar-auth --camera-window-shot файл.png).
    static func shot(to path: String, adding: Bool = false) -> Bool {
        let w = QRCameraWindow(code: adding ? "" : "123456", at: Date())
        w.devices = []
        w.build(withPreview: false)
        w.window.appearance = NSAppearance(named: .aqua)
        w.status.stringValue = adding
            ? L("в QR записей: %@ (%@) — экспортируйте одну учётку VPN", 2, "Mail/someone, VPN/alice")
            : L("в этом QR записей: %@, ни одна не даёт ваш код — покажите следующий QR экспорта", 3)
        guard let view = w.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
