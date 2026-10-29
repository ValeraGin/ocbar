import AppKit
import Foundation

/// Opens real menus without executing an item. Reports timings/counts, never profile data.
@MainActor
enum MenuLatencyProbe {
    static func run() async {
        let live = CommandLine.arguments.contains("--live")
        let status: Status
        if live {
            status = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: OCMacClient.shared.status())
                }
            }
        } else { status = Fixture.status(.connected) }
        let store = StatusStore(preview: status)
        let constructionStart = ProcessInfo.processInfo.systemUptime
        let prepared = !CommandLine.arguments.contains("--cold")
        let hosted = HostedMenu(store: store, prepare: prepared)
        hosted.image = MenuBarIcon.image(for: status)
        let constructionMS = (ProcessInfo.processInfo.systemUptime - constructionStart) * 1000
        try? await Task.sleep(for: .milliseconds(500))
        var samples: [[String: Any]] = []
        for index in 0..<8 {
            let start = ProcessInfo.processInfo.systemUptime
            var trackingMS: Double?
            var visibleMS: Double?
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                   object: hosted.menu, queue: nil) { _ in
                trackingMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            }
            let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if visibleMS == nil,
                   let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
                   windows.contains(where: { item in
                       guard (item[kCGWindowOwnerPID as String] as? Int32) == getpid(),
                             let bounds = item[kCGWindowBounds as String] as? [String: Any] else { return false }
                       return (bounds["Width"] as? Double ?? 0) > 150 && (bounds["Height"] as? Double ?? 0) > 100
                   }) { visibleMS = elapsed * 1000 }
                if elapsed > 0.4 { hosted.menu.cancelTracking() }
            }
            RunLoop.main.add(timer, forMode: .common)
            hosted.statusItem.button?.performClick(nil)
            timer.invalidate()
            NotificationCenter.default.removeObserver(observer)
            guard let trackingMS, let visibleMS else {
                fputs("Menu benchmark failed: real menu was not observed.\n", stderr)
                exit(2)
            }
            samples.append(["iteration": index, "trackingMS": trackingMS, "visibleMS": visibleMS])
            try? await Task.sleep(for: .milliseconds(150))
        }
        let report: [String: Any] = ["source": live ? "current-client-status" : "synthetic",
            "profileCount": status.profiles.count, "routeCount": status.routes.count,
            "zoneCount": status.zones.count, "prepared": prepared,
            "constructionMS": constructionMS, "samples": samples]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let output = String(data: data, encoding: .utf8) { print(output) }
        exit(0)
    }
}
