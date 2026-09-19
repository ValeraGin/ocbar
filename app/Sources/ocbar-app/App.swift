import SwiftUI
import AppKit

// Приложение меню-бара ocbar. Автор: ValeraGin — Ignatkovich Valery, MIT.
// Заменяет плагин SwiftBar: то же состояние из
// `ocbar status --short`, те же действия через `ocbar`, но с графиком,
// переключателями и своими окнами. Привилегий не требует.
@main
struct OcbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = StatusStore.shared
    // Витрина показывает окно и значок в меню-баре не заводит: иначе рядом с
    // живым приложением появлялся бы второй такой же значок.
    @State private var inMenuBar = !CommandLine.arguments.contains("--stage")

    var body: some Scene {
        MenuBarExtra(isInserted: $inMenuBar) {
            MenuView().environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: store.status))
        }
        .menuBarExtraStyle(.window)

        Window("Настройка ocbar", id: WindowID.settings) { SettingsWindow() }
        Window("Первый запуск ocbar", id: WindowID.setup) { SetupView() }
            .defaultSize(width: 880, height: 620)

        Window("Журналы ocbar", id: WindowID.logs) { LogsView() }
            .defaultSize(width: 880, height: 540)

        Window("Диагностика ocbar", id: WindowID.diagnostics) { DiagnosticsView() }
            .defaultSize(width: 760, height: 620)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var stageWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Только значок в меню-баре: ни в Dock, ни в переключателе приложений
        // ему делать нечего.
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--selftest") {
            var code = SelfTest.run()
            code += SelfTest.audit()
            code += SelfTest.editorProbe()
            if CommandLine.arguments.contains("--live-actions") { code += SelfTest.liveActions() }
            // Итог по всем частям: строка «selftest: всё OK» выше — только
            // про разбор и правила, проба редактора идёт после неё.
            print(code == 0 ? "ocbar-app: всё OK" : "ocbar-app: провалов \(code)")
            exit(code)
        }
        // Витрина снимает окна для README: настоящие профили в кадр попасть
        // не должны, поэтому без явного OCBAR_CONFIG_DIR она читает
        // вымышленные из временного каталога.
        // Живая витрина (--live) показывает настоящее состояние — ей нужны
        // настоящие профили.
        if CommandLine.arguments.contains("--stage"), !CommandLine.arguments.contains("--live"),
           ProcessInfo.processInfo.environment["OCBAR_CONFIG_DIR"] == nil,
           let dir = Fixture.demoConfigDir() {
            setenv("OCBAR_CONFIG_DIR", dir, 1)
        }
        OcbarClient.shared.preloadVersions()
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
        if CommandLine.arguments.contains("--stage") { openStage() }
        else {
            AppLog.write("запуск \(AppInfo.version); ocbar: "
                + (OcbarClient.shared.binary ?? "не найден — " + OcbarClient.shared.lookupNote)
                + "; ⌥⌘P: " + (GlobalHotkeys.shared.isRegistered("pause") ? "занята нами" : "не досталась"))
        }
        // --shot <файл>: снять витрину в PNG и выйти. Нужен, чтобы смотреть
        // на интерфейс, не открывая меню руками, — и чтобы разницу между
        // правками было видно, а не приходилось описывать словами.
        if let i = CommandLine.arguments.firstIndex(of: "--shot"),
           i + 1 < CommandLine.arguments.count {
            shoot(to: CommandLine.arguments[i + 1])
        }
    }

    // ocbar://notify?title=…&body=…&token=… — уведомление от клиента (см.
    // Notifier). Без своего токена не показывается — Notifier пишет в журнал.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where !Notifier.handle(url) {
            AppLog.write("неизвестный URL: \(url.absoluteString)")
        }
    }

    // Витрина состояний для разработки: то же меню на подставленных данных,
    // все состояния сразу. Обычному запуску не мешает.
    private func openStage() {
        // Снимок (--shot) — вне экрана и без активации: окно не должно
        // вспыхивать поверх чужой работы, значок в Dock не нужен.
        let offscreen = CommandLine.arguments.contains("--shot")
        if !offscreen { NSApp.setActivationPolicy(.regular) }
        // --screenshot menu|settings — кадр для README: только нужное, без подписей.
        let args = CommandLine.arguments
        let screenshot = args.firstIndex(of: "--screenshot").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let size: NSSize = screenshot == "menu" ? NSSize(width: 780, height: 700)
            : screenshot == "settings" ? NSSize(width: 1048, height: 708)
            : screenshot == "setup" ? NSSize(width: 700, height: 660) : NSSize(width: 1500, height: 2400)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ocbar — витрина состояний"
        if CommandLine.arguments.contains("--light") {
            window.appearance = NSAppearance(named: .aqua)
        }
        if screenshot == "menu" {
            window.contentView = NSHostingView(rootView: ScreenshotMenuView())
        } else if screenshot == "settings" {
            window.contentView = NSHostingView(rootView: ScreenshotSettingsView())
        } else if screenshot == "setup" {
            window.contentView = NSHostingView(rootView: SetupView()
                .frame(width: 660, height: 620)
                .padding(20)
                .background(Color(nsColor: .underPageBackgroundColor)))
        } else if CommandLine.arguments.contains("--windows") {
            window.contentView = NSHostingView(rootView: StageWindowsView())
        } else if CommandLine.arguments.contains("--live") {
            window.contentView = NSHostingView(rootView: LiveStageView())
        } else {
            window.contentView = NSHostingView(rootView: StageView())
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

    private func shoot(to path: String) {
        if stageWindow == nil { openStage() }
        guard let view = stageWindow?.contentView else { exit(1) }
        // Дать SwiftUI разложить содержимое: снимок сразу после показа
        // получается пустым.
        // Живому состоянию нужно время: опрос ocbar и вторая точка счётчиков.
        let settle: TimeInterval = CommandLine.arguments.contains("--live") ? 8
            : (CommandLine.arguments.contains("--windows") || CommandLine.arguments.contains("settings") || CommandLine.arguments.contains("setup") ? 4 : 1.2)
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("снимок: \(path)")
        exit(0)
    }
}

// Значок в строке состояния: монограмма «oc», чтобы значок читался как ocbar,
// а не как «какая-то зелёная фигура». Состояние — цветом букв (те же цвета,
// что в меню): зелёный подключено, оранжевый связь восстанавливается или
// запуск, жёлтый пауза, красный нужен вход или клиента нет, серый отключено.
// Пауза дополнительно помечена двумя штрихами вместо точки над буквами —
// цвет один не всем различим.
enum MenuBarIcon {
    static func image(for status: Status) -> NSImage {
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
        let size = NSSize(width: 26, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let base = NSFont.systemFont(ofSize: 15.5, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 15.5) } ?? base
            let text = NSAttributedString(string: "oc", attributes: [
                .font: font, .foregroundColor: color.withAlphaComponent(dim ? 0.75 : 1), .kern: -0.8,
            ])
            let s = text.size()
            text.draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2 - 0.5))
            if paused {
                color.set()
                for x in [rect.width / 2 - 3.5, rect.width / 2 + 0.5] {
                    NSBezierPath(roundedRect: NSRect(x: x, y: rect.height - 3.5, width: 3, height: 3), xRadius: 0.8, yRadius: 0.8).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "ocbar"
        return image
    }
}
