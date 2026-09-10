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
                    timeout: TimeInterval = 30,
                    cancel: CancelToken? = nil) -> Result {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Result(code: 127, out: "", err: "нет такой программы: \(path)")
        }
        if cancel?.isCancelled == true { return Result(code: cancelledCode, out: "", err: "отменено") }
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
        // Отмена — тем же путём: человек нажал «Отключить» посреди входа, и
        // ждать конца срока (до 15 минут) незачем.
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline && cancel?.isCancelled != true { usleep(20_000) }
        if task.isRunning {
            let cancelled = cancel?.isCancelled == true
            terminateTree(task)
            _ = group.wait(timeout: .now() + 2)
            return Result(code: cancelled ? cancelledCode : -1, out: String(decoding: outData, as: UTF8.self),
                          err: cancelled ? "отменено" : "команда не ответила за \(Int(timeout)) с")
        }
        task.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)
        return Result(code: task.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    /// Код возврата отменённой команды.
    static let cancelledCode: Int32 = -2

    // Погасить команду вместе с потомками. Своей группы процессов у запуска
    // через Process нет (она общая с приложением), поэтому потомков ищем по
    // родителю: ocbar connect держит ocbar-auth с окном входа, и одно
    // terminate() оставляло бы окно висеть сиротой. Сначала TERM всем —
    // bash успевает убрать за собой, — через две секунды KILL оставшимся.
    // Процессы root (хелпер под sudo) нам не подвластны: их гасит сам sudo,
    // получив сигнал.
    static func terminateTree(_ task: Process) {
        let root = task.processIdentifier
        let all = descendants(of: root) + [root]
        for pid in all { kill(pid, SIGTERM) }
        let until = Date().addingTimeInterval(2)
        while task.isRunning && Date() < until { usleep(20_000) }
        for pid in all where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    static func descendants(of root: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for p in procs.prefix(size / stride) {
            children[p.kp_eproc.e_ppid, default: []].append(p.kp_proc.p_pid)
        }
        var out: [pid_t] = [], stack = [root]
        while let p = stack.popLast() {
            for c in children[p] ?? [] where c != p && !out.contains(c) { out.append(c); stack.append(c) }
        }
        return out
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

/// Флаг отмены для долгой команды: ставится с главного потока, читается
/// циклом ожидания в Shell.run.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
