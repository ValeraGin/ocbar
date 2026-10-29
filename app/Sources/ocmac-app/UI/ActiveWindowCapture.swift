import AppKit
import Foundation

/// Capture the production SwiftUI Window scene, with native chrome and materials.
/// Never substitute cacheDisplay: it loses active control colors and compositing.
@MainActor
enum ActiveWindowCapture {
    static var enabled: Bool {
        CommandLine.arguments.contains("--stage") && CommandLine.arguments.contains("--capture-active")
    }

    private static func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        return args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func run() async {
        guard let path = argument("--shot"), let screen = argument("--screenshot"),
              ["settings", "connection"].contains(screen) else { exit(2) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        WindowBridge.install()
        WindowBridge.open(screen == "settings" ? WindowID.settings : WindowID.connection)
        var target: NSWindow?
        for _ in 0..<40 {
            target = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
            if target != nil { break }
            await pause(0.1)
        }
        guard let window = target, let display = window.screen ?? NSScreen.main else { exit(2) }
        let requested = ScreenshotWindowSize.content(settings: screen == "settings")
        let visible = display.visibleFrame
        let chrome = window.frame.height - (window.contentView?.bounds.height ?? 0)
        window.setContentSize(NSSize(width: min(requested.width, visible.width),
                                     height: min(requested.height, visible.height - chrome)))
        window.setFrameTopLeftPoint(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.maxY))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await pause(screen == "settings" ? 4 : 1.5)
        if CommandLine.arguments.contains("--capture-scroll-bottom"), let root = window.contentView {
            scrollToBottom(root)
            await pause(0.3)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await pause(0.4)
        // A user switching apps must invalidate the shot, not silently gray it out.
        guard active(window) else {
            fputs("Capture failed: target window is not active. \(activationDescription(window))\n", stderr)
            exit(2)
        }
        let output = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: output)
        // The review runner owns Screen Recording permission. A LaunchServices
        // app has a separate permission identity, so it hands the window ID out
        // and stays alive/active until the runner acknowledges its screen capture.
        let ready = output.deletingPathExtension().appendingPathExtension("ready.json")
        let done = output.deletingPathExtension().appendingPathExtension("capture-done")
        try? FileManager.default.removeItem(at: done)
        let handoff: [String: Any] = ["windowID": window.windowNumber,
                                     "pid": ProcessInfo.processInfo.processIdentifier]
        do { try JSONSerialization.data(withJSONObject: handoff).write(to: ready, options: .atomic) }
        catch { exit(2) }
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: done.path) { break }
            await pause(0.1)
        }
        let captured = (try? String(contentsOf: done, encoding: .utf8)) == "ok"
        guard captured, FileManager.default.fileExists(atPath: path), active(window) else {
            try? FileManager.default.removeItem(at: output)
            fputs("Capture failed: external screen capture or window activation was lost. \(activationDescription(window))\n", stderr)
            exit(2)
        }
        let content = window.contentView?.bounds.size ?? .zero
        let metadata: [String: Any] = [
            "capture": "screencapture-window", "active": NSApp.isActive,
            "keyWindow": window.isKeyWindow, "mainWindow": window.isMainWindow,
            "windowID": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier,
            "requestedWidth": requested.width, "requestedHeight": requested.height,
            "contentWidth": content.width, "contentHeight": content.height,
            "appearance": window.effectiveAppearance.name.rawValue,
            "screen": screen, "syntheticData": true
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.deletingPathExtension().appendingPathExtension("json"))
        } catch { exit(2) }
        print("Captured active window: \(path)")
        exit(0)
    }

    private static func active(_ window: NSWindow) -> Bool {
        NSApp.isActive && window.isKeyWindow && window.isMainWindow && window.isVisible
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private static func activationDescription(_ window: NSWindow) -> String {
        "active=\(NSApp.isActive) key=\(window.isKeyWindow) main=\(window.isMainWindow) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) self=\(ProcessInfo.processInfo.processIdentifier)"
    }

    private static func scrollToBottom(_ view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height {
            let clip = scroll.contentView
            let y = document.isFlipped ? document.bounds.maxY - clip.bounds.height : document.bounds.minY
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
            return
        }
        for child in view.subviews { scrollToBottom(child) }
    }
}
