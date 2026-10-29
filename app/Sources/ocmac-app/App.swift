import SwiftUI
import AppKit
import Combine

// Приложение меню-бара ocmac. Автор: ValeraGin — Ignatkovich Valery, MIT.
// Заменяет плагин SwiftBar: то же состояние из
// `ocmac status --short`, те же действия через `ocmac`, но с графиком,
// переключателями и своими окнами. Привилегий не требует.
@main
struct OCMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Меню — NSHostingMenu под своим значком (AppDelegate). Пустая скрытая
    // сцена остаётся, чтобы SwiftUI при запуске не открывал первое окно сам —
    // как у Maccy.
    @State private var placeholder = false

    var body: some Scene {
        MenuBarExtra("", isInserted: $placeholder) { EmptyView() }

        // Ссылки ocmac:// (уведомления от клиента, проверки) разбирает
        // AppDelegate. Без пустого handlesExternalEvents SwiftUI на каждую
        // ссылку открывал бы окно настроек.
        Window("OpenConnect for Mac", id: WindowID.connection) {
            ConnectionView(store: ActiveWindowCapture.enabled ? ConnectionScreenshotFixture.store : nil)
        }
            .defaultSize(width: 440, height: 240)
            .windowResizability(.contentMinSize)
            .handlesExternalEvents(matching: [])
        Window(L("Настройка OpenConnect for Mac"), id: WindowID.settings) { SettingsWindow() }
            .defaultSize(width: SettingsWindow.width, height: SettingsWindow.height)
            .windowResizability(.contentSize)
            .handlesExternalEvents(matching: [])
        Window(L("Открыть профиль OpenConnect for Mac"), id: WindowID.quickProfile) { QuickProfileView() }
            .windowResizability(.contentSize)
            .handlesExternalEvents(matching: [])
        Window(L("Первый запуск OpenConnect for Mac"), id: WindowID.setup) { SetupView() }
            .defaultSize(width: 740, height: 560)
            .handlesExternalEvents(matching: [])

        Window(L("Журналы OpenConnect for Mac"), id: WindowID.logs) { LogsView() }
            .defaultSize(width: 880, height: 540)
            .handlesExternalEvents(matching: [])

        Window(L("Диагностика OpenConnect for Mac"), id: WindowID.diagnostics) { DiagnosticsView() }
            .defaultSize(width: 760, height: 620)
            .handlesExternalEvents(matching: [])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var stageWindow: NSWindow?
    private var iconWatch: AnyCancellable?
    private var demoBackdrop: NSWindow?

    /// Меню в строке состояния — NSMenu из SwiftUI-описания (HostedMenu,
    /// NSHostingMenu): размер, место, клавиатура и закрытие — у системы,
    /// пункты обновляются на месте. MenuBarExtra(.window) не сжимался под
    /// содержимое (D71), своя панель и самописное NSMenu давали рывки.
    static private(set) var hosted: HostedMenu?

    @MainActor private func installMenu() {
        let store = StatusStore.shared
        WindowBridge.install()
        let hosted = HostedMenu(store: store)
        hosted.image = MenuBarIcon.image(for: store.status)
        Self.hosted = hosted
        iconWatch = store.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.showIcon(status) }
        // A profile imported by install.sh should lead straight to the username,
        // while an established setup keeps its quiet menu-bar launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !QuickProfileFlow.shared.presented else { return }
            let files = ProfileStore.list()
            if let id = files.first(where: { ProfileStore.load($0)?.user.trimmed.isEmpty == true }) {
                QuickProfileFlow.shared.openExisting(id)
            } else if files.isEmpty && !FileManager.default.fileExists(atPath: OCMacClient.shared.configDir + "/profiles.conf") {
                QuickProfileFlow.shared.show()
            }
        }
    }

    /// Демо-меню для кадров README: то же меню на вымышленных профилях.
    @MainActor private func installDemoMenu() {
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        WindowBridge.install()
        let hosted = HostedMenu(store: DemoMenu.store)
        // Меню строки состояния берёт тему системы, а не приложения: тему
        // кадра задаём самому меню.
        if CommandLine.arguments.contains("--light") { hosted.menu.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { hosted.menu.appearance = NSAppearance(named: .darkAqua) }
        Self.hosted = hosted
        DemoMenu.start()
        // Меню для кадров открывается не под значком, а в половине экрана без
        // указателя: под указателем система подсвечивает пункт. Под меню —
        // ровный фон своего окна: меню полупрозрачное, и без него в кадр
        // размытием попадало бы то, что лежит на экране.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            let left = NSEvent.mouseLocation.x > f.midX
            DemoMenu.anchor = NSPoint(x: left ? f.minX + 80 : f.maxX - 480, y: f.maxY - 40)
            if let i = CommandLine.arguments.firstIndex(of: "--backdrop"), i + 1 < CommandLine.arguments.count {
                let v = Int(CommandLine.arguments[i + 1].dropFirst(), radix: 16) ?? 0xEEF0EA
                let color = NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
                let rect = NSRect(x: DemoMenu.anchor.x - 60, y: max(f.minY, f.maxY - 1000),
                                  width: 560, height: min(1000, f.height))
                let backdrop = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                backdrop.backgroundColor = color
                backdrop.level = .floating
                backdrop.ignoresMouseEvents = true
                backdrop.isReleasedWhenClosed = false
                backdrop.orderFrontRegardless()
                demoBackdrop = backdrop
            }
        }
        iconWatch = DemoMenu.store.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.showIcon(status) }
    }

    @MainActor private func setIcon(_ image: NSImage) {
        Self.hosted?.image = image
    }

    // Пока идёт подключение, текущая часть значка мигает раз в полсекунды.
    private var blinkTimer: Timer?
    private var blinkOn = false
    private var iconStatus = Status()

    @MainActor private func showIcon(_ status: Status) {
        iconStatus = status
        let starting = status.presentation == .starting
        if starting, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.setIcon(MenuBarIcon.image(for: self.iconStatus, blink: self.blinkOn))
                }
            }
            RunLoop.main.add(blinkTimer!, forMode: .common)
        } else if !starting {
            blinkTimer?.invalidate(); blinkTimer = nil; blinkOn = false
        }
        setIcon(MenuBarIcon.image(for: status, blink: blinkOn))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !CommandLine.arguments.contains("--stage") {
            WindowBridge.open(WindowID.connection)
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Только значок в меню-баре: ни в Dock, ни в переключателе приложений
        // ему делать нечего.
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--installation-check") {
            let client = OCMacClient.shared
            let status = client.status()
            let version = client.binary.map { Shell.run($0, ["version"], timeout: 10) }
            let report: [String: Any] = [
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "clientPath": client.binary ?? "",
                "clientVersion": version?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                "clientAvailable": client.binary != nil && version?.code == 0 && status.available && status.error == nil,
                "profileCount": status.profiles.count
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text) }
            exit(report["clientAvailable"] as? Bool == true ? 0 : 1)
        }
        if CommandLine.arguments.contains("--selftest-menu") { exit(SelfTest.hostedMenu()) }
        if CommandLine.arguments.contains("--selftest") {
            var code = SelfTest.run()
            code += SelfTest.audit()
            code += SelfTest.editorProbe()
            code += SelfTest.hostedMenu()
            if CommandLine.arguments.contains("--live-actions") { code += SelfTest.liveActions() }
            // Итог по всем частям: строка «selftest: всё OK» выше — только
            // про разбор и правила, проба редактора идёт после неё.
            print(code == 0 ? "ocmac-app: всё OK" : "ocmac-app: провалов \(code)")
            exit(code)
        }
        // Витрина снимает окна для README: настоящие профили в кадр попасть
        // не должны, поэтому без явного OCMAC_CONFIG_DIR она читает
        // вымышленные из временного каталога.
        // Живая витрина (--live) показывает настоящее состояние — ей нужны
        // настоящие профили.
        if CommandLine.arguments.contains("--stage"), !CommandLine.arguments.contains("--live"),
           ProcessInfo.processInfo.environment["OCMAC_CONFIG_DIR"] == nil,
           let dir = Fixture.demoConfigDir() {
            setenv("OCMAC_CONFIG_DIR", dir, 1)
        }
        OCMacClient.shared.preloadVersions()
        if !CommandLine.arguments.contains("--stage") { Notifier.setup() }
        // Пауза и возобновление — единственное действие, которое стоит
        // глобальной клавиши: оно обратимо и не стоит второго фактора.
        // Витрина сочетание не занимает: иначе она отбирала бы его у живого
        // приложения, запущенного рядом.
        if !CommandLine.arguments.contains("--stage") {
            GlobalHotkeys.shared.register("pause", keyCode: HotkeyCode.p,
                                          modifiers: HotkeyCode.cmdOption) {
                StatusStore.shared.togglePause()
            }
        }
        if CommandLine.arguments.contains("--stage"), CommandLine.arguments.contains("--menu-benchmark") {
            Task { await MenuLatencyProbe.run() }
            return
        }
        if PassiveWindowCapture.enabled {
            Task { await PassiveWindowCapture.run() }
            return
        }
        if ActiveWindowCapture.enabled {
            Task { await ActiveWindowCapture.run() }
            return
        }
        if CommandLine.arguments.contains("--demo-menu") { installDemoMenu() }
        else if CommandLine.arguments.contains("--stage") { openStage() }
        else {
            installMenu()
            AppLog.write("запуск \(AppInfo.version); ocmac: "
                + (OCMacClient.shared.binary ?? "не найден — " + OCMacClient.shared.lookupNote)  // i18n: не интерфейс
                + "; ⌥⌘P: " + (GlobalHotkeys.shared.isRegistered("pause") ? "занята нами" : "не досталась"))  // i18n: не интерфейс
        }
        // --shot <файл>: снять витрину в PNG и выйти. Нужен, чтобы смотреть
        // на интерфейс, не открывая меню руками, — и чтобы разницу между
        // правками было видно, а не приходилось описывать словами.
        if let i = CommandLine.arguments.firstIndex(of: "--shot"),
           i + 1 < CommandLine.arguments.count {
            shoot(to: CommandLine.arguments[i + 1])
        }
    }

    // ocmac://notify?title=…&body=…&token=… — уведомление от клиента (см.
    // Notifier). Без своего токена не показывается — Notifier пишет в журнал.
    func application(_ application: NSApplication, open urls: [URL]) {
        let profiles = urls.filter(\.isFileURL)
        if !profiles.isEmpty { QuickProfileFlow.shared.open(profiles) }
        for url in urls where !url.isFileURL && !Notifier.handle(url) {
            if MenuProbe.handle(url) { continue }
            if AccessProbe.handle(url) { continue }
            AppLog.write("неизвестный URL: \(url.absoluteString)")
        }
    }

    // Витрина состояний для разработки: то же меню на подставленных данных,
    // все состояния сразу. Обычному запуску не мешает.
    @MainActor private func openStage() {
        // Снимок (--shot) — вне экрана и без активации: окно не должно
        // вспыхивать поверх чужой работы, значок в Dock не нужен.
        let offscreen = CommandLine.arguments.contains("--shot")
        if !offscreen { NSApp.setActivationPolicy(.regular) }
        // --screenshot menu|settings — кадр для README: только нужное, без подписей.
        let args = CommandLine.arguments
        let screenshot = args.firstIndex(of: "--screenshot").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        // Меню снимается с запасом по высоте, пустое поле снизу срезается
        // при съёмке: высота зависит от языка, замер SwiftUI её занижает.
        let contentSize = ScreenshotWindowSize.content(settings: screenshot == "settings")
        let size: NSSize = screenshot == "quick-profile" ? NSSize(width: 668, height: 620)
            : screenshot == "connection" || screenshot == "settings"
                ? NSSize(width: contentSize.width + 48, height: contentSize.height + 48)
            : screenshot == "setup" ? NSSize(width: 800, height: 660)
            : screenshot == "icons" ? NSSize(width: 980, height: 360) : NSSize(width: 1500, height: 2400)
        // Кадр README — в окне без рамки: окно с заголовком система подгоняет
        // под экран, и за его краем кадр обрезался по высоте.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                              styleMask: screenshot != nil ? [.borderless] : [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "OpenConnect for Mac — витрина состояний"  // i18n: не интерфейс
        if CommandLine.arguments.contains("--light") {
            window.appearance = NSAppearance(named: .aqua)
        } else if CommandLine.arguments.contains("--dark") {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        if screenshot == "quick-profile" {
            if let id = ProfileStore.list().first { QuickProfileFlow.shared.openExisting(id) }
            window.contentView = NSHostingView(rootView: QuickProfileView().padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if screenshot == "connection" {
            let host = NSHostingView(rootView: ScreenshotConnectionView())
            host.sizingOptions = []
            window.contentView = host
        } else if screenshot == "settings" {
            let host = NSHostingView(rootView: ScreenshotSettingsView())
            host.sizingOptions = []
            window.contentView = host
        } else if screenshot == "icons" {
            window.contentView = NSHostingView(rootView: ScreenshotIconsView())
        } else if screenshot == "setup" {
            window.contentView = NSHostingView(rootView: SetupView()
                .frame(width: 760, height: 620)
                .padding(20)
                .background(Color(nsColor: .underPageBackgroundColor)))
        } else {
            // Меню в витрине не рисуется: NSMenu снимается только с экрана —
            // демо-меню (--demo-menu) и tools/menu-shots.sh.
            window.contentView = NSHostingView(rootView: StageWindowsView())
        }
        window.delegate = self
        if offscreen {
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.orderFrontRegardless()
        } else {
            window.setFrameOrigin(NSPoint(x: 60, y: 60))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        stageWindow = window
    }

    // Витрина без значка в меню-баре: закрыли окно — процессу больше делать
    // нечего, иначе он остался бы жить невидимкой.
    func windowWillClose(_ notification: Notification) {
        if CommandLine.arguments.contains("--stage") { NSApp.terminate(nil) }
    }

    /// Срезать снизу поле цвета фона, оставив 24 точки — как сверху.
    static func trimBottom(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0, let bg = rep.colorAt(x: 0, y: h - 1) else { return rep }
        func same(_ c: NSColor?) -> Bool {
            guard let c else { return true }
            return abs(c.redComponent - bg.redComponent) < 0.02 && abs(c.greenComponent - bg.greenComponent) < 0.02
                && abs(c.blueComponent - bg.blueComponent) < 0.02
        }
        var last = h - 1
        scan: while last > 0 {
            for x in stride(from: 0, to: w, by: 2) where !same(rep.colorAt(x: x, y: last)) { break scan }
            last -= 1
        }
        let scale = CGFloat(w) / rep.size.width
        let keep = min(h, last + 1 + Int(24 * scale))
        guard keep < h, let cg = rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: w, height: keep)) else { return rep }
        let out = NSBitmapImageRep(cgImage: cg)
        out.size = NSSize(width: rep.size.width, height: CGFloat(keep) / scale)
        return out
    }

    @MainActor private func shoot(to path: String) {
        if stageWindow == nil { openStage() }
        guard let view = stageWindow?.contentView else { exit(1) }
        // Дать SwiftUI разложить содержимое: снимок сразу после показа
        // получается пустым.
        // Живому состоянию нужно время: опрос ocmac и вторая точка счётчиков.
        let settle: TimeInterval = CommandLine.arguments.contains("--live") ? 8
            : (CommandLine.arguments.contains("--windows") || CommandLine.arguments.contains("settings") || CommandLine.arguments.contains("setup") ? 4 : 1.2)
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = CommandLine.arguments.contains("--screenshot") ? Self.trimBottom(rep) : rep
        guard let png = out.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("снимок: \(path)")
        exit(0)
    }
}

// Компактный свитч в строке меню. Цвета сохраняют смысл состояний,
// пауза дополнительно обозначена двумя штрихами.
enum MenuBarIcon {
    /// Значок: вход слева, развилка на две ветки. Пока идёт подключение,
    /// схема заполняется слева направо по шагам (ConnectStep): пройденное —
    /// цветом, текущая часть мигает (`blink`), остальное приглушено.
    static func image(for status: Status, blink: Bool = false) -> NSImage {
        let color: NSColor
        var paused = false
        switch status.presentation {
        case .connected:  color = .systemGreen
        case .lost:       color = .systemOrange
        case .paused:     color = .systemYellow; paused = true
        case .starting:   color = .systemOrange
        case .needsLogin: color = .systemRed
        case .foreign:    color = .systemGray
        case .down:       color = .systemGray
        case .missing:    color = .systemRed
        }
        let dim = status.presentation == .down || status.presentation == .foreign
        // Части схемы по ходу подключения: точка входа, линия до развилки,
        // верхняя ветка, нижняя ветка.
        let step = ConnectStep.of(status)
        let size = NSSize(width: 26, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            for part in 0..<4 {
                let tint: NSColor
                if let step {
                    if part < step.index - 1 { tint = color }
                    else if part == step.index - 1 { tint = color.withAlphaComponent(blink ? 0.35 : 1) }
                    else { tint = NSColor.systemGray.withAlphaComponent(0.45) }
                } else {
                    tint = color.withAlphaComponent(dim ? 0.75 : 1)
                }
                tint.set()
                draw(part: part)
            }
            if paused {
                color.set()
                for x in [3.0, 7.0] {
                    NSBezierPath(roundedRect: NSRect(x: x, y: 13, width: 2, height: 4), xRadius: 0.8, yRadius: 0.8).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = step.map { "OpenConnect for Mac: \($0.title)" } ?? "OpenConnect for Mac"
        return image
    }

    private static func draw(part: Int) {
        func line(_ points: [NSPoint]) {
            let path = NSBezierPath()
            path.move(to: points[0])
            for p in points.dropFirst() { path.line(to: p) }
            path.lineWidth = 1.8; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.stroke()
        }
        func dot(_ x: CGFloat, _ y: CGFloat) {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 4, height: 4), xRadius: 1, yRadius: 1).fill()
        }
        switch part {
        case 0: dot(2, 7)
        case 1: line([NSPoint(x: 4, y: 9), NSPoint(x: 11, y: 9)])
        case 2: line([NSPoint(x: 11, y: 9), NSPoint(x: 18, y: 15), NSPoint(x: 22, y: 15)]); dot(20, 13)
        default: line([NSPoint(x: 11, y: 9), NSPoint(x: 18, y: 3), NSPoint(x: 22, y: 3)]); dot(20, 1)
        }
    }
}
