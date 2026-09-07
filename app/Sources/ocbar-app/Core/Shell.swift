import Foundation

// Запуск внешних команд. Всё, что делает приложение, делается так: своих
// привилегий у него нет и быть не должно.
enum Shell {
    struct Result {
        let code: Int32
        let out: String
        let err: String
        var ok: Bool { code == 0 }
    }

    // Синхронный запуск, звать только с фоновой очереди.
    // Оба потока читаются параллельно: последовательное чтение stdout до
    // конца вешает процесс, когда он успел заполнить буфер stderr.
    @discardableResult
    static func run(_ path: String, _ args: [String] = [],
                    stdin input: String? = nil,
                    env extra: [String: String] = [:],
                    timeout: TimeInterval = 30) -> Result {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Result(code: 127, out: "", err: "нет такой программы: \(path)")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        // Свой PATH, а не пользовательский: из launchd и Finder он куцый.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LC_CTYPE"] = env["LC_CTYPE"] ?? "UTF-8"
        for (k, v) in extra { env[k] = v }
        task.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        if input != nil {
            let inPipe = Pipe()
            task.standardInput = inPipe
            let data = Data((input ?? "").utf8)
            DispatchQueue.global().async {
                inPipe.fileHandleForWriting.write(data)
                try? inPipe.fileHandleForWriting.close()
            }
        } else {
            task.standardInput = FileHandle.nullDevice
        }

        do { try task.run() } catch {
            return Result(code: 127, out: "", err: "\(error)")
        }

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }

        // Таймаут обязателен: status зовётся по таймеру, и один зависший
        // вызов иначе копил бы процессы до бесконечности.
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline { usleep(20_000) }
        if task.isRunning {
            task.terminate()
            _ = group.wait(timeout: .now() + 2)
            return Result(code: -1, out: String(decoding: outData, as: UTF8.self),
                          err: "команда не ответила за \(Int(timeout)) с")
        }
        task.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)
        return Result(code: task.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    // Первый существующий исполняемый файл из списка кандидатов.
    static func firstExecutable(_ candidates: [String]) -> String? {
        let fm = FileManager.default
        for c in candidates where !c.isEmpty {
            let path = (c as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
