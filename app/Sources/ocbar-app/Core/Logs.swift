import Foundation

// Чтение журналов. Файлы читаются с конца: журнал openconnect за долгую
// сессию — мегабайты, целиком он не нужен и в память не просится.
// Прав на чтение не требуется: журнал супервизора — свой, журнал
// openconnect лежит с правом чтения для всех.
struct LogSource: Identifiable, Hashable {
    let id: String
    let title: String
    let path: String
}

enum LogReader {
    static let tailBytes = 256 * 1024
    static let maxLines = 3000

    struct Snapshot {
        var lines: [Line] = []
        var problem: String?
        var size: Int64 = 0
    }

    struct Line: Identifiable, Hashable {
        let id: Int
        let text: String
        var kind: Kind {
            let l = text.lowercased()
            if l.contains("не удалось") || l.contains("ошибк") || l.contains("failed")
                || l.contains("error") || l.contains("потеряна") { return .bad }
            if l.contains("событие:") || l.contains("подключён") || l.contains("восстановил") { return .good }
            return .plain
        }
        enum Kind { case plain, good, bad }
    }

    static func read(path: String, filter: String) -> Snapshot {
        var snap = Snapshot()
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            snap.problem = "файла нет: \(path)"
            return snap
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            snap.problem = "нет доступа на чтение: \(path)"
            return snap
        }
        defer { try? handle.close() }
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        snap.size = size
        let from = max(0, size - Int64(tailBytes))
        try? handle.seek(toOffset: UInt64(from))
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        // Первая строка после произвольного сдвига почти всегда обрезана.
        if from > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        let needle = filter.trimmed.lowercased()
        var lines: [Line] = []
        var i = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw)
            if !needle.isEmpty, !s.lowercased().contains(needle) { continue }
            if s.isEmpty && needle.isEmpty && raw.isEmpty { continue }
            lines.append(Line(id: i, text: s))
            i += 1
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        if lines.isEmpty {
            snap.problem = needle.isEmpty ? "журнал пуст" : "ни одной строки с «\(filter)»"
        }
        snap.lines = lines
        return snap
    }
}
