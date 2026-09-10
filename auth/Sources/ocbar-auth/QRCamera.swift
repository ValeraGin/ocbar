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
    private let scanner = QRCameraScanner()
    private var window: NSWindow!
    private var status: NSTextField!
    private var picker: NSPopUpButton!
    private var devices: [AVCaptureDevice] = []
    private var result: QRImport.Entry?
    private var seen = Set<String>()
    private var running = false

    init(code: String, at: Date) {
        self.code = code
        self.at = at
        super.init()
    }

    static func fits(_ e: QRImport.Entry, code: String, at: Date) -> Bool {
        e.isTOTP && e.algorithm == "SHA1" && e.period == 30 && e.digits == code.count
            && TeachDialog.secretMatches(e.secretBase32, code: code, at: at)
    }

    private func build(withPreview: Bool) {
        let w: CGFloat = 560, h: CGFloat = 520
        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let hint = NSTextField(wrappingLabelWithString:
            "На телефоне: Google Authenticator → ⋮ → «Перенос аккаунтов» → «Экспорт», выберите учётку VPN и поднесите QR к камере. Подойдёт только запись, которая даёт код, введённый вами при входе. Кадры никуда не сохраняются.")
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

        status = NSTextField(labelWithString: "ищу QR…")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 16, y: 54, width: w - 32, height: 18)
        content.addSubview(status)

        picker = NSPopUpButton(frame: NSRect(x: 16, y: 14, width: 300, height: 26), pullsDown: false)
        picker.addItems(withTitles: devices.isEmpty ? ["камера"] : devices.map(\.localizedName))
        picker.target = self
        picker.action = #selector(cameraChanged)
        picker.isHidden = devices.count < 2
        content.addSubview(picker)

        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: w - 116, y: 12, width: 100, height: 30)
        content.addSubview(cancel)

        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "ocbar — QR второго фактора с камеры"
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
    }

    /// Показать окно и ждать записи. nil — отмена, нет камеры, нет доступа
    /// или тайм-аут; в note — что сказать человеку.
    func run(timeout: TimeInterval = 180) -> (entry: QRImport.Entry?, note: String) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            var granted: Bool?
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { granted = ok } }
            let deadline = Date().addingTimeInterval(120)
            while granted == nil && Date() < deadline {
                RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.1))
            }
            if granted != true { return (nil, "доступ к камере не дан — секрет можно вставить или выбрать файл QR") }
        default:
            return (nil, "доступ к камере запрещён: Системные настройки → Конфиденциальность и безопасность → Камера — разрешите ocbar или терминалу, из которого входите")
        }
        devices = QRCameraScanner.cameras()
        guard let device = QRCameraScanner.preferred(devices) else { return (nil, "камера не найдена") }
        build(withPreview: true)
        if let i = devices.firstIndex(of: device) { picker.selectItem(at: i) }
        scanner.onPayloads = { [weak self] found in self?.handle(found) }
        do { try scanner.start(device) } catch { return (nil, "камера не включилась: \(error.localizedDescription)") }
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
        return (result, result == nil ? "QR с камеры не прочитан — можно вставить секрет или выбрать файл QR" : "")
    }

    private func handle(_ payloads: [String]) {
        guard running else { return }
        for p in payloads where !seen.contains(p) {
            seen.insert(p)
            guard let entries = try? QRImport.parse(p) else {
                status.stringValue = "это не QR второго фактора — покажите экспорт из аутентификатора"
                continue
            }
            if let e = entries.first(where: { Self.fits($0, code: code, at: at) }) {
                result = e
                finish()
                return
            }
            status.stringValue = entries.count > 1
                ? "в этом QR записей: \(entries.count), ни одна не даёт ваш код — покажите следующий QR экспорта"
                : "эта запись не даёт ваш код — выберите в экспорте учётку VPN"
        }
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
    static func shot(to path: String) -> Bool {
        let w = QRCameraWindow(code: "123456", at: Date())
        w.devices = []
        w.build(withPreview: false)
        w.window.appearance = NSAppearance(named: .aqua)
        w.status.stringValue = "в этом QR записей: 3, ни одна не даёт ваш код — покажите следующий QR экспорта"
        guard let view = w.window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
