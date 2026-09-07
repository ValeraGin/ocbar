import SwiftUI
import AppKit

// Приложение меню-бара ocbar. Автор: ValeraGin — Ignatkovich Valery, MIT.
// Заменяет плагин SwiftBar: то же состояние из
// `ocbar status --short`, те же действия через `ocbar`, но с графиком,
// переключателями и своими окнами. Привилегий не требует.
@main
struct OcbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = StatusStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: store.status))
        }
        .menuBarExtraStyle(.window)

        Window("Настройка ocbar", id: WindowID.settings) { SettingsWindow() }
            .defaultSize(width: 880, height: 620)

        Window("Журналы ocbar", id: WindowID.logs) { LogsView() }
            .defaultSize(width: 880, height: 540)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var stageWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Только значок в меню-баре: ни в Dock, ни в переключателе приложений
        // ему делать нечего.
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--selftest") {
            var code = SelfTest.run()
            if CommandLine.arguments.contains("--live-actions") { code += SelfTest.liveActions() }
            exit(code)
        }
        OcbarClient.shared.preloadVersions()
        if CommandLine.arguments.contains("--stage") { openStage() }
        // --shot <файл>: снять витрину в PNG и выйти. Нужен, чтобы смотреть
        // на интерфейс, не открывая меню руками, — и чтобы разницу между
        // правками было видно, а не приходилось описывать словами.
        if let i = CommandLine.arguments.firstIndex(of: "--shot"),
           i + 1 < CommandLine.arguments.count {
            shoot(to: CommandLine.arguments[i + 1])
        }
    }

    // Витрина состояний для разработки: то же меню на подставленных данных,
    // все состояния сразу. Обычному запуску не мешает.
    private func openStage() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1450, height: 1240),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ocbar — витрина состояний"
        if CommandLine.arguments.contains("--light") {
            window.appearance = NSAppearance(named: .aqua)
        }
        if CommandLine.arguments.contains("--windows") {
            window.contentView = NSHostingView(rootView: StageWindowsView())
        } else if CommandLine.arguments.contains("--live") {
            window.contentView = NSHostingView(rootView: LiveStageView())
        } else {
            window.contentView = NSHostingView(rootView: StageView())
        }
        window.setFrameOrigin(NSPoint(x: 60, y: 60))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        stageWindow = window
    }

    private func shoot(to path: String) {
        if stageWindow == nil { openStage() }
        guard let view = stageWindow?.contentView else { exit(1) }
        // Дать SwiftUI разложить содержимое: снимок сразу после показа
        // получается пустым.
        // Живому состоянию нужно время: опрос ocbar и вторая точка счётчиков.
        let settle: TimeInterval = CommandLine.arguments.contains("--live") ? 8
            : (CommandLine.arguments.contains("--windows") ? 4 : 1.2)
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("снимок: \(path)")
        exit(0)
    }
}

// Значок состояния. Цвета те же, что у плагина SwiftBar, чтобы переход
// с него не сбивал с толку.
enum MenuBarIcon {
    static func image(for status: Status) -> NSImage {
        let (symbol, color): (String, NSColor)
        switch status.presentation {
        case .connected:  (symbol, color) = ("lock.shield.fill", .systemGreen)
        case .lost:       (symbol, color) = ("lock.shield.fill", .systemOrange)
        case .paused:     (symbol, color) = ("pause.circle.fill", .systemYellow)
        case .starting:   (symbol, color) = ("lock.shield", .systemOrange)
        case .needsLogin: (symbol, color) = ("lock.trianglebadge.exclamationmark.fill", .systemRed)
        case .foreign:    (symbol, color) = ("lock.shield", .systemGray)
        case .down:       (symbol, color) = ("lock.open", .systemGray)
        case .missing:    (symbol, color) = ("exclamationmark.triangle", .systemRed)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ocbar")?
            .withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "lock", accessibilityDescription: "ocbar")!
        image.isTemplate = false
        return image
    }
}
