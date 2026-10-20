import Foundation

/// Этап входа — для меню ocbar. Клиент передаёт путь в OCBAR_STAGE_FILE,
/// приложение читает его через `ocbar status` и показывает, на каком шаге
/// подключение. Запись — рядом и переименованием: читатель не застанет
/// половину слова.
enum Stage {
    static func set(_ name: String) {
        guard let path = ProcessInfo.processInfo.environment["OCBAR_STAGE_FILE"], !path.isEmpty else { return }
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: Data((name + "\n").utf8)) else { return }
        _ = rename(tmp, path)
    }
}
