import AppKit
import Combine

enum ProfileOpening {
    static let maximumBytes = 2 * 1024 * 1024

    static func sameConfiguration(_ left: Data, _ right: Data) -> Bool {
        guard let a = String(data: left, encoding: .utf8), let b = String(data: right, encoding: .utf8) else { return false }
        var lhs = ProfileDoc.parse(a, fileName: "compare")
        var rhs = ProfileDoc.parse(b, fileName: "compare")
        lhs.user = ""; rhs.user = ""
        let date = Date(timeIntervalSince1970: 0)
        return lhs.render(dated: date) == rhs.render(dated: date)
    }

    static func identifier(_ filename: String, occupied: Set<String>) -> String {
        let ascii = filename.lowercased().replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        let base = ascii.isEmpty ? "team" : String(ascii.prefix(64))
        var name = base
        var n = 2
        while occupied.contains(name) { name = "\(base)-\(n)"; n += 1 }
        return name
    }

    // Read a bounded snapshot: validation and import must see the same bytes.
    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    static func setupScript(binary: String, resultPath: String) -> String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "#!/bin/bash\n/usr/bin/sudo -- \(quote(binary)) install\nresult=$?\nprintf '%s\\n' \"$result\" > \(quote(resultPath))\nprintf '\\n'\nexit \"$result\"\n"
    }
}

@MainActor
final class QuickProfileFlow: ObservableObject {
    static let shared = QuickProfileFlow()
    @Published private(set) var doc: ProfileDoc?
    @Published private(set) var ids: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var checking = false
    @Published private(set) var system: ProfileSystemState?
    @Published private(set) var helperReady = false
    @Published private(set) var waitingForSetup = false
    @Published var user = ""
    @Published var note: String?
    private(set) var presented = false
    private var stamp: ProfileStore.DiskStamp?
    private var generation = UUID()
    private var freshIDs: Set<String> = []
    private var setupDeadline: Date?
    private var setupDirectory: URL?
    private let connectProfile: @MainActor (String) -> Void
    private let readSystem: (ProfileDoc) -> (ProfileSystemState, Bool)
    init(connect: (@MainActor (String) -> Void)? = nil,
         readiness: @escaping (ProfileDoc) -> (ProfileSystemState, Bool) = QuickProfileFlow.systemReadiness) {
        connectProfile = connect ?? { StatusStore.shared.connect(profile: $0, show: true) }; readSystem = readiness
    }

    nonisolated static func systemReadiness(_ doc: ProfileDoc) -> (ProfileSystemState, Bool) {
        let state = OCMacClient.shared.profileSystemState(doc.fileName)
        let versions = doc.mode == "proxy" ? [:] : OCMacClient.shared.versions(maxAge: 0)
        let helper = doc.mode == "proxy" || (versions["helper_path"] == "/usr/local/libexec/ocmac-helper" && versions["helper_nopasswd"] == "1")
        return (state, helper)
    }
    private var setupResult: Int? {
        guard let directory = setupDirectory,
              let text = try? String(contentsOf: directory.appendingPathComponent("result"), encoding: .utf8) else { return nil }
        return Int(text.trimmed)
    }
    var ready: Bool { system?.ready == true && helperReady }

    func show() {
        presented = true
        WindowBridge.open(WindowID.quickProfile)
    }

    func chooseFile() {
        guard !busy && !waitingForSetup && StatusStore.shared.busy == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L("Выберите полученный профиль .ocmac или Cisco .xml")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open([url])
    }

    func open(_ urls: [URL]) {
        show()
        guard !busy && !waitingForSetup && StatusStore.shared.busy == nil else {
            note = L("Дождитесь завершения текущего действия и откройте файл ещё раз."); return
        }
        guard urls.count == 1, let url = urls.first, url.isFileURL,
              ["ocmac", "ocbar", "xml"].contains(url.pathExtension.lowercased()) else {
            note = L("Откройте один файл профиля .ocmac или Cisco .xml."); return
        }
        busy = true; note = nil; doc = nil; system = nil; ids = []
        let existingAtOpen = Set(ProfileStore.list())
        let request = UUID(); generation = request
        DispatchQueue.global(qos: .userInitiated).async {
            let result: (ids: [String], error: String?)
            do {
                let data = try ProfileOpening.read(url)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let snapshot = directory.appendingPathComponent("profile." + url.pathExtension.lowercased())
                try data.write(to: snapshot, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
                let existing = ProfileStore.list()
                if ["ocmac", "ocbar"].contains(url.pathExtension.lowercased()) {
                    guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                    if let why = OCMacClient.shared.profileRejection(text, name: "profile") {
                        result = ([], why)
                    } else if let same = existing.first(where: {
                        guard let local = try? ProfileOpening.read(URL(fileURLWithPath: ProfileStore.path($0))) else { return false }
                        return ProfileOpening.sameConfiguration(local, data)
                    }) {
                        result = ([same], nil)
                    } else {
                        let name = ProfileOpening.identifier(url.deletingPathExtension().lastPathComponent, occupied: Set(existing))
                        // Parsing never runs CSD or credential commands; importing only extracts data.
                        result = OCMacClient.shared.importProfiles(snapshot.path, name: name)
                    }
                } else {
                    result = OCMacClient.shared.importProfiles(snapshot.path)
                }
            } catch { result = ([], L("Не удалось открыть профиль: %@", error.localizedDescription)) }
            DispatchQueue.main.async {
                guard self.generation == request else { return }
                self.busy = false
                if let error = result.error { self.note = error; return }
                self.ids = result.ids
                self.freshIDs = Set(result.ids.filter {
                    !existingAtOpen.contains($0) || url.standardizedFileURL != URL(fileURLWithPath: ProfileStore.path($0)).standardizedFileURL
                })
                if let first = result.ids.first { self.select(first) }
                StatusStore.shared.refresh()
            }
        }
    }

    func openExisting(_ id: String) {
        guard !busy && !waitingForSetup && StatusStore.shared.busy == nil else { return }
        ids = [id]; freshIDs = []; note = nil
        select(id); show()
    }

    func select(_ id: String) {
        guard !busy && !waitingForSetup else { return }
        generation = UUID()
        stamp = ProfileStore.stamp(id)
        doc = ProfileStore.load(id)
        user = freshIDs.contains(id) ? "" : (doc?.user ?? "")
        system = nil; helperReady = false; note = nil
        check()
    }

    func check(then: (() -> Void)? = nil) {
        guard let doc, !checking else { return }
        let request = generation
        let read = readSystem
        checking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let (state, helper) = read(doc)
            DispatchQueue.main.async {
                self.checking = false
                guard self.generation == request else { self.check(); return }
                self.system = state; self.helperReady = helper
                then?()
                if self.waitingForSetup && self.ready && self.setupResult == 0 {
                    self.stopWaiting()
                    self.startConnection()
                }
            }
        }
    }

    func connect() {
        guard var draft = doc, let stamp, !busy && !checking && !waitingForSetup,
              StatusStore.shared.busy == nil else { return }
        guard !user.trimmed.isEmpty, !user.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            note = L("Введите свой корпоративный логин."); return
        }
        draft.user = user.trimmed
        busy = true; note = nil
        ProfileSaveService.save(draft, expected: stamp) { outcome in
            self.busy = false
            switch outcome {
            case .saved:
                self.doc = draft; self.stamp = ProfileStore.stamp(draft.fileName)
                self.freshIDs.remove(draft.fileName)
                self.check {
                    if self.ready { self.startConnection() }
                    else if let error = self.system?.error { self.note = error }
                    else { self.prepare() }
                }
            case .changed: self.note = L("Профиль изменился. Откройте его заново, чтобы сохранить актуальные настройки.")
            case .rejected(let why), .failed(let why): self.note = why
            }
        }
    }

    private func startConnection() {
        guard let doc, ready else { return }
        connectProfile(doc.fileName)
    }

    private func prepare() {
        // A test/custom state directory must never trigger a real system install.
        guard ProcessInfo.processInfo.environment["OCMAC_STATE_DIR"] == nil,
              OCMacClient.shared.configDir == NSString(string: "~/.config/ocmac").expandingTildeInPath,
              let binary = OCMacClient.shared.binary else {
            note = L("В нестандартном окружении подготовьте системную часть вручную: sudo ocmac install"); return
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            setupDirectory = directory
            let script = directory.appendingPathComponent("ocmac-setup.command")
            try ProfileOpening.setupScript(binary: binary, resultPath: directory.appendingPathComponent("result").path)
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            waitingForSetup = true; setupDeadline = Date().addingTimeInterval(600)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                stopWaiting(); note = L("Не удалось открыть Терминал. Выполните sudo ocmac install и повторите подключение."); return
            }
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    guard self.setupDirectory == directory else { return }
                    self.stopWaiting()
                    self.note = L("Не удалось открыть Терминал. Выполните sudo ocmac install и повторите подключение.")
                }
            }
        } catch { stopWaiting(); note = error.localizedDescription }
    }

    func pollSetup() {
        guard waitingForSetup else { return }
        if let deadline = setupDeadline, Date() > deadline {
            stopWaiting(); note = L("Подготовка не завершена. Повторите подключение после установки системной части.")
        } else if let result = setupResult {
            if result == 0 { check() }
            else { stopWaiting(); note = L("Подготовка отменена или завершилась ошибкой. Повторите подключение, чтобы попробовать снова.") }
        }
    }

    func stopWaiting() {
        waitingForSetup = false; setupDeadline = nil
        // The command may still be open in Terminal: only remove it after the wait.
        if let directory = setupDirectory { try? FileManager.default.removeItem(at: directory) }
        setupDirectory = nil
    }
}
