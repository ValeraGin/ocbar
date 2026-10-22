import Foundation

struct ImportedProfiles: Decodable {
    let profiles: [String]
    static func parse(_ text: String) -> ImportedProfiles? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data), !value.profiles.isEmpty,
              value.profiles.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { return nil }
        return value
    }
}

struct ProfileSystemState: Decodable {
    var required: Bool
    var ready: Bool
    var name: String = ""
    var error: String?
    var needsSetup: Bool { required && !ready && error == nil }
    static func parse(_ text: String) -> Self? {
        text.data(using: .utf8).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
}

extension OcbarClient {
    func importProfiles(_ path: String) -> (ids: [String], error: String?) {
        guard let binary else { return ([], L("ocbar не найден")) }
        let result = Shell.run(binary, ["import", "--json", path], timeout: 30)
        guard result.ok, let imported = ImportedProfiles.parse(result.out) else {
            return ([], result.err.trimmed.isEmpty ? L("Не удалось получить список импортированных профилей") : result.err.trimmed)
        }
        return (imported.profiles, nil)
    }

    func checkResource(_ target: String, profile: String) -> Bool? {
        struct Reply: Decodable { let reachable: Bool? }
        guard let binary else { return nil }
        let result = Shell.run(binary, ["check-access", profile, target], timeout: 15)
        guard result.ok, let data = result.out.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.reachable
    }

    func profileSystemState(_ profile: String) -> ProfileSystemState {
        guard let binary else { return ProfileSystemState(required: true, ready: false, error: L("ocbar не найден")) }
        let result = Shell.run(binary, ["csd-status", profile], timeout: 15)
        if result.ok, let state = ProfileSystemState.parse(result.out) { return state }
        return ProfileSystemState(required: true, ready: false,
                                  error: result.err.trimmed.isEmpty ? L("Не удалось проверить системную часть профиля") : result.err.trimmed)
    }
}

enum ProfileSaveOutcome {
    case saved, changed
    case rejected(String), failed(String)
}

enum ProfileSaveService {
    // Validation can take 15 seconds. Both validation and disk writes run off
    // the UI queue; the second stamp check protects edits made while waiting.
    static func save(_ doc: ProfileDoc, expected: ProfileStore.DiskStamp,
                     validate: @escaping (ProfileDoc) -> String? = { OcbarClient.shared.profileRejection($0.render(), name: $0.fileName) },
                     completion: @escaping (ProfileSaveOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: ProfileSaveOutcome
            if let why = validate(doc) { outcome = .rejected(why) }
            else if ProfileStore.stamp(doc.fileName) != expected { outcome = .changed }
            else if let why = ProfileStore.save(doc) { outcome = .failed(why) }
            else { outcome = .saved }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
