import Foundation

// Свой журнал приложения. Нужен ровно для одного вопроса: «почему меню
// ничего не делает» — там видно, нашёлся ли ocbar, взялась ли горячая
// клавиша и чем закончилось действие. Ротация как у супервизора: файл
// никто не держит открытым, поэтому достаточно переименования.
enum AppLog {
    static let path = NSString(string: "~/Library/Logs/ocbar/app.log").expandingTildeInPath
    private static let maxBytes: Int64 = 256 * 1024
    private static let queue = DispatchQueue(label: "ru.ocbar.app.log")

    static func write(_ line: String) {
        queue.async {
            let fm = FileManager.default
            let dir = (path as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            rotateIfNeeded(fm)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: "T", with: " ")
                .replacingOccurrences(of: "Z", with: "")
            let text = "\(stamp) \(line)\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(text.utf8))
            } else {
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func rotateIfNeeded(_ fm: FileManager) {
        let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > maxBytes else { return }
        try? fm.removeItem(atPath: path + ".1")
        try? fm.moveItem(atPath: path, toPath: path + ".1")
    }
}
