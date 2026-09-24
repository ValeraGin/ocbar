import Foundation

/// Проверка соответствия устройства (Cisco Secure Desktop / HostScan).
///
/// Некоторые группы шлюза требуют её перед входом: в ответе init приходит
/// <host-scan> с ticket и token, а вход завершается отказом
/// «Cisco Secure Desktop not installed on the client», пока клиент не отдаст
/// отчёт о состоянии машины.
///
/// ocbar-auth здесь только ЗАПУСКАЕТ пользовательский скрипт-обёртку — ровно
/// как openconnect вызывает `--csd-wrapper`. Сам отчёт формирует и отправляет
/// скрипт (например `csd-post.sh` из поставки openconnect), его приносит
/// человек. ocbar-auth ничего не подделывает и на шлюз посты не шлёт.
///
/// Контракт вызова — как у openconnect, чтобы штатные скрипты работали без
/// правок: окружение CSD_HOSTNAME, CSD_TOKEN, CSD_SHA256; аргументы
/// `<stub> -ticket <ticket> -stub 0 -group <tunnel-group> -certhash <hash>
///  -url https://<host><host-scan-base-uri> -langselen en-US`.
enum CSD {
    struct Params {
        let wrapper: String        // путь к скрипту (профиль CsdWrapper)
        let host: String           // хост шлюза (CSD_HOSTNAME)
        let ticket: String
        let token: String
        let group: String          // tunnel-group, если известна
        let certHash: String?      // MD5 сертификата шлюза и клиента для -certhash
        let pinSHA256: String?     // pin публичного ключа для CSD_SHA256
        let timeout: TimeInterval  // сколько ждём скрипт
        let startURI: String
    }

    enum Result {
        case ok
        case failed(String)
    }

    /// Запустить обёртку. Скрипт должен существовать и быть исполняемым;
    /// код возврата 0 — успех. Секреты (ticket/token) в журнал не пишем.
    static func run(_ p: Params) -> Result {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p.wrapper, isDirectory: &isDir), !isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: p.wrapper) else {
            return .failed("нет исполняемого скрипта CSD: \(p.wrapper)")
        }
        guard p.wrapper.hasPrefix("/") else { return .failed("путь к скрипту CSD должен быть абсолютным") }
        guard p.startURI.hasPrefix("/"), !p.startURI.hasPrefix("//"),
              !p.startURI.contains("\\") else { return .failed("неверный host-scan-base-uri") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: p.wrapper)
        proc.arguments = [
            "", // openconnect передаёт первым argv путь к загруженному stub; csd-post.sh делает shift
            "-ticket", p.ticket,
            "-stub", "0",
            "-group", p.group,
            "-certhash", p.certHash ?? "",
            "-url", "https://\(p.host)\(p.startURI)",
            "-langselen", "en-US",
        ]
        var env = ProcessInfo.processInfo.environment
        // CLI ограничивает PATH системными каталогами; штатному скрипту нужен
        // xmlstarlet из Homebrew для чтения data.xml.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["CSD_HOSTNAME"] = p.host
        env["CSD_TOKEN"] = p.token
        if let h = p.pinSHA256 { env["CSD_SHA256"] = h } else { env.removeValue(forKey: "CSD_SHA256") }
        proc.environment = env
        // Файл 0600 не блокирует дочерний процесс, когда отчёт и диагностика
        // превышают размер pipe; после чтения он сразу удаляется.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocbar-csd-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let logFile = try? FileHandle(forWritingTo: logURL) else {
            return .failed("не удалось открыть временный журнал CSD")
        }
        defer { try? logFile.close(); try? FileManager.default.removeItem(at: logURL) }
        proc.standardOutput = logFile
        proc.standardError = logFile
        do { try proc.run() } catch {
            return .failed("не удалось запустить \(p.wrapper): \(error.localizedDescription)")
        }
        // Сторож по времени: повисший скрипт не должен держать вход.
        let deadline = Date().addingTimeInterval(p.timeout)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if proc.isRunning {
            proc.terminate()
            return .failed("скрипт CSD не завершился за \(Int(p.timeout)) с — прерван")
        }
        try? logFile.synchronize()
        let readFile = try? FileHandle(forReadingFrom: logURL)
        let outData = readFile?.readData(ofLength: 8192) ?? Data()
        try? readFile?.close()
        let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty {
            let safe = out.replacingOccurrences(of: p.ticket, with: "[ticket]")
                .replacingOccurrences(of: p.token, with: "[token]")
            Log.debug("CSD-скрипт: \(safe.prefix(4096).replacingOccurrences(of: "\n", with: " · "))")
        }
        return proc.terminationStatus == 0
            ? .ok
            : .failed("скрипт CSD вернул код \(proc.terminationStatus)")
    }
}
