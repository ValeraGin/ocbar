import Foundation
import CoreImage
import Vision

/// Импорт TOTP-секрета из QR-кода: обычный `otpauth://totp/...` и формат
/// экспорта Google Authenticator `otpauth-migration://offline?data=<base64>`.
///
/// Секрет наружу печатается ТОЛЬКО по явному флагу и предназначен для того,
/// чтобы вызывающий скрипт сразу положил его в Keychain. По умолчанию видно
/// лишь метаданные и текущий код — по нему человек сверяется с приложением.
enum QRImport {

    struct Entry {
        var secretBase32: String
        var name: String
        var issuer: String
        var digits: Int
        var algorithm: String
        var isTOTP: Bool
        var period: Int
    }

    enum ImportError: Error, CustomStringConvertible {
        case noImage(String), noQR, badPayload(String), empty
        var description: String {
            switch self {
            case .noImage(let p): return "не удалось прочитать изображение: \(p)"
            case .noQR:           return "в изображении нет QR-кода (или он нечитаем — попробуйте кадр покрупнее)"
            case .badPayload(let s): return "QR прочитан, но это не otpauth: \(s)"
            case .empty:          return "в QR нет ни одной записи TOTP"
            }
        }
    }

    // MARK: - чтение QR

    static func decode(file: String) throws -> [String] {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard let ci = CIImage(contentsOf: url) else { throw ImportError.noImage(url.path) }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        try handler.perform([request])
        let payloads = (request.results ?? []).compactMap { $0.payloadStringValue }
        if !payloads.isEmpty { return payloads }

        // Vision иногда пасует на скриншотах с тёмной рамкой — пробуем CoreImage.
        let ctx = CIContext()
        let det = CIDetector(ofType: CIDetectorTypeQRCode, context: ctx,
                             options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let found = (det?.features(in: ci) as? [CIQRCodeFeature])?.compactMap { $0.messageString } ?? []
        if found.isEmpty { throw ImportError.noQR }
        return found
    }

    // MARK: - разбор otpauth

    static func parse(_ payload: String) throws -> [Entry] {
        if payload.hasPrefix("otpauth-migration://") { return try parseMigration(payload) }
        if payload.hasPrefix("otpauth://") { return [try parseSingle(payload)] }
        throw ImportError.badPayload(String(payload.prefix(40)))
    }

    private static func parseSingle(_ s: String) throws -> Entry {
        guard let comps = URLComponents(string: s), let items = comps.queryItems,
              let secret = items.first(where: { $0.name == "secret" })?.value else {
            throw ImportError.badPayload("нет параметра secret")
        }
        let label = comps.path.hasPrefix("/") ? String(comps.path.dropFirst()) : comps.path
        let issuer = items.first(where: { $0.name == "issuer" })?.value
            ?? label.split(separator: ":").first.map(String.init) ?? ""
        return Entry(secretBase32: secret.uppercased(),
                     name: label.split(separator: ":").last.map(String.init) ?? label,
                     issuer: issuer,
                     digits: Int(items.first(where: { $0.name == "digits" })?.value ?? "6") ?? 6,
                     algorithm: (items.first(where: { $0.name == "algorithm" })?.value ?? "SHA1").uppercased(),
                     isTOTP: comps.host?.lowercased() != "hotp",
                     period: Int(items.first(where: { $0.name == "period" })?.value ?? "30") ?? 30)
    }

    /// Google Authenticator export: protobuf в base64 внутри параметра `data`.
    /// Схема (MigrationPayload → OtpParameters):
    ///   1 bytes secret · 2 string name · 3 string issuer
    ///   4 enum algorithm (1=SHA1 2=SHA256 3=SHA512) · 5 enum digits (1=6 2=8)
    ///   6 enum type (1=HOTP 2=TOTP)
    private static func parseMigration(_ s: String) throws -> [Entry] {
        guard let comps = URLComponents(string: s),
              let raw = comps.queryItems?.first(where: { $0.name == "data" })?.value else {
            throw ImportError.badPayload("нет параметра data")
        }
        // Значение уже раскодировано из percent-encoding, осталось base64.
        var b64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { throw ImportError.badPayload("data не base64") }

        var entries: [Entry] = []
        for field in ProtoReader(data).fields() where field.number == 1 {
            guard case .bytes(let sub) = field.value else { continue }
            var secret = Data(); var name = ""; var issuer = ""
            var algo = 1, digits = 1, type = 2
            for f in ProtoReader(sub).fields() {
                switch (f.number, f.value) {
                case (1, .bytes(let d)): secret = d
                case (2, .bytes(let d)): name = String(data: d, encoding: .utf8) ?? ""
                case (3, .bytes(let d)): issuer = String(data: d, encoding: .utf8) ?? ""
                case (4, .varint(let v)): algo = Int(clamping: v)
                case (5, .varint(let v)): digits = Int(clamping: v)
                case (6, .varint(let v)): type = Int(clamping: v)
                default: break
                }
            }
            guard !secret.isEmpty else { continue }
            entries.append(Entry(secretBase32: base32Encode(secret),
                                 name: name, issuer: issuer,
                                 digits: digits == 2 ? 8 : 6,
                                 algorithm: ["", "SHA1", "SHA256", "SHA512", "MD5"][min(max(algo, 1), 4)],
                                 isTOTP: type != 1,
                                 period: 30))
        }
        if entries.isEmpty { throw ImportError.empty }
        return entries
    }

    static func base32Encode(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", bits = 0, value = 0
        for byte in data {
            value = (value << 8) | Int(byte); bits += 8
            while bits >= 5 { out.append(alphabet[(value >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out
    }
}

/// Минимальный читатель protobuf: столько, сколько нужно для одного формата.
private struct ProtoReader {
    enum Value { case varint(UInt64), bytes(Data), fixed(UInt64) }
    struct Field { let number: Int; let value: Value }

    let data: Data
    init(_ d: Data) { data = d }

    func fields() -> [Field] {
        var out: [Field] = []
        var i = data.startIndex
        while i < data.endIndex {
            guard let (key, next) = varint(at: i) else { break }
            i = next
            let number = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0:
                guard let (v, n) = varint(at: i) else { return out }
                out.append(Field(number: number, value: .varint(v))); i = n
            case 2:
                guard let (len, n) = varint(at: i) else { return out }
                // Длина приходит из QR, то есть из чужой картинки. Int(len)
                // на огромном значении не возвращает ошибку, а аварийно
                // завершает процесс — проверено на подготовленном коде.
                guard len <= UInt64(data.count) else { return out }
                let start = n, end = data.index(start, offsetBy: Int(len), limitedBy: data.endIndex) ?? data.endIndex
                out.append(Field(number: number, value: .bytes(Data(data[start..<end])))); i = end
            case 5: i = data.index(i, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
            case 1: i = data.index(i, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
            default: return out
            }
        }
        return out
    }

    private func varint(at index: Data.Index) -> (UInt64, Data.Index)? {
        var value: UInt64 = 0, shift: UInt64 = 0, i = index
        while i < data.endIndex {
            let byte = data[i]; i = data.index(after: i)
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (value, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
