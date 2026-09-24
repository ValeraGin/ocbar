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
            snap.problem = L("файла нет: %@", path)
            return snap
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            snap.problem = L("нет доступа на чтение: %@", path)
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
            snap.problem = needle.isEmpty ? L("журнал пуст") : L("ни одной строки с «%@»", filter)
        }
        snap.lines = lines
        return snap
    }
}

// Общая лента: хвосты нескольких журналов одним списком по времени, с меткой
// источника — как `ocbar logs`. Строка без времени встаёт сразу за
// предыдущей строкой своего файла.
extension LogReader {
    static func merged(_ sources: [(tag: String, path: String)], filter: String) -> Snapshot {
        var snap = Snapshot()
        let needle = filter.trimmed.lowercased()
        var rows: [(ts: String, order: Int, tag: String, text: String)] = []
        var order = 0
        for src in sources {
            let one = read(path: src.path, filter: "")
            snap.size += one.size
            var last = ""
            for line in one.lines {
                var text = line.text
                if let (ts, rest) = splitTime(text) { last = ts; text = rest }
                for pre in ["ocbar-auth: ", "ocbar-helper: ", "ocbar: "] where text.hasPrefix(pre) {
                    text = String(text.dropFirst(pre.count)); break
                }
                guard !text.trimmed.isEmpty else { continue }
                if !needle.isEmpty, !text.lowercased().contains(needle), !src.tag.lowercased().contains(needle) { continue }
                rows.append((last, order, src.tag, text))
                order += 1
            }
        }
        rows.sort { ($0.ts, $0.order) < ($1.ts, $1.order) }
        if rows.count > maxLines { rows.removeFirst(rows.count - maxLines) }
        let width = sources.map(\.tag.count).max() ?? 0
        var day = ""
        var lines: [Line] = []
        for r in rows {
            let parts = r.ts.split(separator: " ")
            if parts.count == 2, String(parts[0]) != day {
                day = String(parts[0])
                lines.append(Line(id: lines.count, text: "── \(day) ──"))
            }
            let time = parts.count == 2 ? String(parts[1]) : "--:--:--"
            let tag = r.tag.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append(Line(id: lines.count, text: "\(time)  \(tag)  \(r.text)"))
        }
        if lines.isEmpty { snap.problem = needle.isEmpty ? L("журналы пусты") : L("ни одной строки с «%@»", filter) }
        snap.lines = lines
        return snap
    }

    /// «2026-09-19 20:58:19 …» или «[2026-09-19 20:58:19] …» → время и остаток.
    static func splitTime(_ s: String) -> (String, String)? {
        var t = Substring(s)
        let bracket = t.hasPrefix("[")
        if bracket { t = t.dropFirst() }
        guard t.count >= 19 else { return nil }
        let head = t.prefix(19)
        let ok = head.enumerated().allSatisfy { i, c in
            switch i {
            case 4, 7: return c == "-"
            case 10: return c == " " || c == "T"
            case 13, 16: return c == ":"
            default: return c.isNumber
            }
        }
        guard ok else { return nil }
        var rest = t.dropFirst(19)
        if bracket { guard rest.hasPrefix("]") else { return nil }; rest = rest.dropFirst() }
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return (head.replacingOccurrences(of: "T", with: " "), String(rest))
    }
}
