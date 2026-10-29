import AppKit
import SwiftUI

/// A review-only host on the built-in display. Keyboard/mouse input stays with
/// the user's app. Native controls remain inactive; this is not an active-window capture.
@MainActor
enum PassiveWindowCapture {
    static var enabled: Bool {
        CommandLine.arguments.contains("--stage") && CommandLine.arguments.contains("--capture-passive")
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        return args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func run() async {
        guard let path = argument("--shot"), let screen = argument("--screenshot"),
              ["settings", "connection", "setup"].contains(screen) else { exit(2) }
        // Never fall back onto the external work monitor, including in mirror mode.
        guard let display = NSScreen.screens.first(where: {
            CGDisplayIsBuiltin(displayID($0)) != 0 && CGDisplayIsInMirrorSet(displayID($0)) == 0
        }) else {
            fputs("Passive capture requires an available, non-mirrored built-in display.\n", stderr)
            exit(2)
        }
        guard !NSApp.isActive else {
            fputs("Passive capture must be launched in the background (open -g).\n", stderr)
            exit(2)
        }
        var activated = false
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                               object: NSApp, queue: .main) { _ in activated = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        let foregroundBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let requested = ScreenshotWindowSize.content(settings: screen == "settings")
        let size = screen == "settings" ? NSSize(width: SettingsWindow.width, height: SettingsWindow.height)
            : screen == "setup" ? NSSize(width: 740, height: 560) : requested
        let panel = Panel(contentRect: NSRect(origin: display.visibleFrame.origin, size: size),
                          styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.title = screen == "settings" ? L("Настройка OpenConnect for Mac") : "OpenConnect for Mac"
        let content: AnyView
        switch screen {
        case "settings": content = AnyView(SettingsWindow())
        case "setup": content = AnyView(SetupView())
        default: content = AnyView(ConnectionView(store: ConnectionScreenshotFixture.store))
        }
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.minSize]
        panel.contentViewController = controller
        let host = controller.view
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(NSPoint(x: display.visibleFrame.midX - panel.frame.width / 2,
                                          y: display.visibleFrame.maxY))
        guard display.visibleFrame.contains(panel.frame) else {
            fputs("Passive capture does not fit the built-in display.\n", stderr)
            exit(2)
        }
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try? await Task.sleep(for: .seconds(4))
        if screen == "connection" {
            // Match the production scene's content minimum: warnings/details may
            // need a taller window than the requested default.
            host.layoutSubtreeIfNeeded()
            let minimum = controller.sizeThatFits(in: NSSize(width: size.width, height: 0))
            let height = max(size.height, minimum.height, panel.contentMinSize.height)
            panel.setContentSize(NSSize(width: size.width, height: height))
            panel.setFrameTopLeftPoint(NSPoint(x: display.visibleFrame.midX - panel.frame.width / 2,
                                              y: display.visibleFrame.maxY))
            try? await Task.sleep(for: .milliseconds(200))
        }
        if CommandLine.arguments.contains("--capture-scroll-bottom") {
            ActiveWindowCapture.scrollToBottom(host)
            try? await Task.sleep(for: .milliseconds(300))
        }
        func valid() -> Bool {
            !activated && !NSApp.isActive && !panel.isKeyWindow && !panel.isMainWindow && panel.isVisible
                && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid()
                && panel.screen.map(displayID) == displayID(display)
                && display.visibleFrame.contains(panel.frame)
        }
        guard valid() else { exit(2) }
        let output = URL(fileURLWithPath: path)
        let ready = output.deletingPathExtension().appendingPathExtension("ready.json")
        let done = output.deletingPathExtension().appendingPathExtension("capture-done")
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: done)
        let handoff: [String: Any] = ["windowID": panel.windowNumber, "pid": getpid()]
        do { try JSONSerialization.data(withJSONObject: handoff).write(to: ready, options: .atomic) }
        catch { exit(2) }
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: done.path) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard (try? String(contentsOf: done, encoding: .utf8)) == "ok",
              FileManager.default.fileExists(atPath: path), valid() else {
            try? FileManager.default.removeItem(at: output)
            fputs("Passive capture failed its focus/display/capture check.\n", stderr)
            exit(2)
        }
        let metadata: [String: Any] = [
            "capture": "screencapture-passive-window", "active": NSApp.isActive,
            "keyWindow": panel.isKeyWindow, "mainWindow": panel.isMainWindow,
            "appearanceMode": "inactive", "focusPreserved": !activated,
            "builtInDisplay": true, "displayID": displayID(display), "displayName": display.localizedName,
            "foregroundBefore": foregroundBefore,
            "foregroundAfter": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "windowID": panel.windowNumber, "pid": getpid(), "screen": screen,
            "contentWidth": host.bounds.width, "contentHeight": host.bounds.height,
            "appearance": panel.effectiveAppearance.name.rawValue, "syntheticData": true
        ]
        do {
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.deletingPathExtension().appendingPathExtension("json"))
        } catch { exit(2) }
        print("Captured passive review panel on the built-in display: \(path)")
        exit(0)
    }
}
