import Foundation

/// Всё служебное — в stderr. stdout оставлен под результат (JSON или probe),
/// чтобы вызывающий скрипт мог просто его прочитать.
enum Log {
    static var verbose = false

    static func info(_ s: String) { write("ocbar-auth: \(s)") }
    static func debug(_ s: String) { if verbose { write("ocbar-auth[debug]: \(s)") } }
    static func error(_ s: String) { write("ocbar-auth: ошибка: \(s)") }

    private static func write(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
