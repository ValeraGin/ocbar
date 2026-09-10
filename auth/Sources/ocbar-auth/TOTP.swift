import Foundation
import CryptoKit

enum TOTP {
    /// RFC 6238. По умолчанию HMAC-SHA1, 6 цифр, шаг 30 секунд — то, что
    /// используют Google Authenticator и большинство IdP; стандарт допускает
    /// ещё SHA256 и SHA512, другое число цифр и другой период.
    static func code(secretBase32: String, at date: Date = Date(),
                     digits: Int = 6, period: TimeInterval = 30, algorithm: String = "SHA1") -> String? {
        guard let key = base32Decode(secretBase32), (1...9).contains(digits), period > 0 else { return nil }
        var counter = UInt64(date.timeIntervalSince1970 / period).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let k = SymmetricKey(data: key)
        let h: [UInt8]
        switch algorithm.uppercased() {
        case "SHA1", "": h = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: k))
        case "SHA256": h = Array(HMAC<SHA256>.authenticationCode(for: msg, using: k))
        case "SHA512": h = Array(HMAC<SHA512>.authenticationCode(for: msg, using: k))
        default: return nil
        }
        let offset = Int(h[h.count - 1] & 0x0f)
        let bin = (UInt32(h[offset] & 0x7f) << 24)
                | (UInt32(h[offset + 1]) << 16)
                | (UInt32(h[offset + 2]) << 8)
                |  UInt32(h[offset + 3])
        let mod = UInt32(pow(10.0, Double(digits)))
        return String(format: "%0\(digits)u", bin % mod)
    }

    static func base32Decode(_ s: String) -> Data? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits = 0, value = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" && !ch.isWhitespace && ch != "-" {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | alphabet.distance(from: alphabet.startIndex, to: idx)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// Параметры кода для секрета (RFC 6238): алгоритм, число цифр, период. В
/// связке ключей лежит только секрет — параметры живут в профиле
/// (TotpAlgorithm, TotpDigits, TotpPeriod) и приходят через окружение.
struct TOTPParams: Equatable {
    var algorithm = "SHA1"
    var digits = 6
    var period = 30
    static let algorithms = ["SHA1", "SHA256", "SHA512"]

    var isDefault: Bool { self == TOTPParams() }
    var isSupported: Bool { Self.algorithms.contains(algorithm) && (6...8).contains(digits) && (10...300).contains(period) }
    var label: String { "\(algorithm), \(digits) цифр, \(period) с" }

    static func fromEnvironment() -> TOTPParams {
        let e = ProcessInfo.processInfo.environment
        var p = TOTPParams()
        if let a = e["OCBAR_TOTP_ALGORITHM"], !a.isEmpty { p.algorithm = a.uppercased() }
        if let d = e["OCBAR_TOTP_DIGITS"].flatMap({ Int($0) }) { p.digits = d }
        if let s = e["OCBAR_TOTP_PERIOD"].flatMap({ Int($0) }) { p.period = s }
        return p
    }
}

extension TOTP {
    static func code(secretBase32: String, at date: Date = Date(), params p: TOTPParams) -> String? {
        guard p.isSupported else { return nil }
        return code(secretBase32: secretBase32, at: date, digits: p.digits, period: TimeInterval(p.period), algorithm: p.algorithm)
    }

    /// Контрольные векторы RFC 6238, приложение B, для HMAC-SHA256 и
    /// HMAC-SHA512 (8 цифр). Сверены независимым расчётом 2026-09-10.
    static func selfTestAlgorithms() -> [(alg: String, t: Int, want: String, got: String, ok: Bool)] {
        let seeds = ["SHA256": "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA",
                     "SHA512": "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNA"]
        let vectors: [(Int, String, String)] = [
            (59, "46119246", "90693936"), (1111111109, "68084774", "25091201"),
            (1111111111, "67062674", "99943326"), (1234567890, "91819424", "93441116"),
            (2000000000, "90698825", "38618901"), (20000000000, "77737706", "47863826"),
        ]
        var out: [(alg: String, t: Int, want: String, got: String, ok: Bool)] = []
        for (t, w256, w512) in vectors {
            for (alg, want) in [("SHA256", w256), ("SHA512", w512)] {
                let got = code(secretBase32: seeds[alg]!, at: Date(timeIntervalSince1970: TimeInterval(t)),
                               digits: 8, algorithm: alg) ?? "?"
                out.append((alg, t, want, got, got == want))
            }
        }
        return out
    }
}

extension QRImport.Entry {
    var params: TOTPParams { TOTPParams(algorithm: algorithm, digits: digits, period: period) }
}

extension TOTP {
    static func sha256hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Контрольные векторы RFC 6238, приложение B (HMAC-SHA1, секрет
    /// "12345678901234567890"). Там коды 8-значные; проверяем и 8, и 6
    /// (6-значный — младшие цифры того же числа).
    static func selfTest() -> [(t: Int, want: String, got: String, ok: Bool)] {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"   // base32("12345678901234567890")
        let vectors: [(Int, String)] = [
            (59, "94287082"), (1111111109, "07081804"), (1111111111, "14050471"),
            (1234567890, "89005924"), (2000000000, "69279037"), (20000000000, "65353130"),
        ]
        var out: [(t: Int, want: String, got: String, ok: Bool)] = []
        for (t, want) in vectors {
            let got8 = code(secretBase32: secret, at: Date(timeIntervalSince1970: TimeInterval(t)), digits: 8) ?? "?"
            let got6 = code(secretBase32: secret, at: Date(timeIntervalSince1970: TimeInterval(t)), digits: 6) ?? "?"
            out.append((t, want, got8, got8 == want))
            out.append((t, String(want.suffix(6)), got6, got6 == String(want.suffix(6))))
        }
        return out
    }
}
