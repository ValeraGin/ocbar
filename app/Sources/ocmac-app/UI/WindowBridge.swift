import AppKit
import SwiftUI

// Окна приложения — сцены SwiftUI, а открыть их умеет только openWindow из
// окружения SwiftUI. Скрытый вид один раз отдаёт его AppKit-меню.
@MainActor
enum WindowBridge {
    private static var openWindow: OpenWindowAction?
    private static var holder: NSWindow?
    private static var pending: [String] = []

    static func install() {
        guard holder == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1, height: 1),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.alphaValue = 0
        w.contentView = NSHostingView(rootView: Catcher())
        w.orderFrontRegardless()
        holder = w
    }

    static func open(_ id: String) {
        guard let openWindow else {
            if !pending.contains(id) { pending.append(id) }
            return
        }
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private struct Catcher: View {
        @Environment(\.openWindow) private var openWindow
        var body: some View {
            Color.clear.frame(width: 1, height: 1)
                .onAppear {
                    WindowBridge.openWindow = openWindow
                    let queued = WindowBridge.pending
                    WindowBridge.pending.removeAll()
                    for id in queued { WindowBridge.open(id) }
                    // Окно-носитель больше не нужно на экране.
                    DispatchQueue.main.async { WindowBridge.holder?.orderOut(nil) }
                }
        }
    }
}
