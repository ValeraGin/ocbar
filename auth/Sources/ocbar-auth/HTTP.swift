import Foundation
import Security
import CryptoKit

/// URLSession сам превращает POST в GET при 302 и теряет тело.
/// Шлюзы Cisco за балансировщиком отвечают редиректом именно на POST,
/// поэтому редиректы обрабатываем вручную и повторяем POST на новый адрес.
final class HTTPClient: NSObject, URLSessionTaskDelegate, URLSessionDelegate {
    private var session: URLSession!
    private let userAgent: String
    private let insecure: Bool
    private let maxRedirects = 5
    private var hostScanCookie: (host: String, token: String)?

    /// Отпечаток сертификата сервера (SHA-256 DER, hex) — для диагностики.
    private(set) var serverCertSHA256: String?
    private(set) var serverPublicKeyPin: String?
    private(set) var serverCertMD5: String?

    init(userAgent: String, insecure: Bool) {
        self.userAgent = userAgent
        self.insecure = insecure
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // не следуем автоматически
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            let der = SecCertificateCopyData(leaf) as Data
            serverCertSHA256 = TOTP.sha256hex(der)
            serverPublicKeyPin = Self.publicKeyPin(der)
            serverCertMD5 = Insecure.MD5.hash(data: der).map { String(format: "%02X", $0) }.joined()
        }
        if insecure {
            Log.debug("TLS: сертификат принят без проверки (--insecure)")
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// cURL --pinnedpubkey ждёт SHA-256 от DER SubjectPublicKeyInfo, а не
    /// отпечаток всего сертификата. У openconnect CSD_SHA256 — именно этот pin.
    static func publicKeyPin(_ certificate: Data) -> String? {
        let bytes = [UInt8](certificate)
        func element(_ offset: inout Int) -> (tag: UInt8, start: Int, content: Int, end: Int)? {
            guard offset + 2 <= bytes.count else { return nil }
            let start = offset
            let tag = bytes[offset]
            offset += 1
            let lengthByte = Int(bytes[offset]); offset += 1
            var length = lengthByte
            if lengthByte & 0x80 != 0 {
                let count = lengthByte & 0x7f
                guard (1...4).contains(count), offset + count <= bytes.count else { return nil }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[offset]); offset += 1 }
            }
            guard length <= bytes.count - offset else { return nil }
            let result = (tag, start, offset, offset + length)
            offset += length
            return result
        }
        var pos = 0
        guard let cert = element(&pos), cert.tag == 0x30 else { return nil }
        pos = cert.content
        guard let tbs = element(&pos), tbs.tag == 0x30 else { return nil }
        pos = tbs.content
        guard pos < bytes.count else { return nil }
        if bytes[pos] == 0xa0 { guard element(&pos) != nil else { return nil } }
        for _ in 0..<5 { guard element(&pos) != nil else { return nil } } // serial, signature, issuer, validity, subject
        guard let spki = element(&pos), spki.tag == 0x30, spki.end <= tbs.end else { return nil }
        let digest = SHA256.hash(data: Data(bytes[spki.start..<spki.end]))
        return Data(digest).base64EncodedString()
    }

    struct Reply {
        let status: Int
        let body: Data
        let location: String?
        let finalURL: URL
    }

    private func once(_ req: URLRequest) throws -> Reply {
        var out: Result<Reply, Error>!
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { out = .failure(err); return }
            guard let http = resp as? HTTPURLResponse else {
                out = .failure(ProtocolError.badXML("нет HTTP-ответа")); return
            }
            out = .success(Reply(status: http.statusCode,
                                 body: data ?? Data(),
                                 location: http.value(forHTTPHeaderField: "Location"),
                                 finalURL: http.url ?? req.url!))
        }
        task.resume()
        sem.wait()
        return try out.get()
    }

    private func requireSecure(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw ProtocolError.badXML("редирект на незащищённый адрес \(url.scheme ?? "?")://\(url.host ?? "?") — отказываюсь")
        }
    }

    private func headers(_ req: inout URLRequest) {
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("1", forHTTPHeaderField: "X-Aggregate-Auth")
        req.setValue("1", forHTTPHeaderField: "X-Transcend-Version")
        req.setValue("true", forHTTPHeaderField: "X-Support-HTTP-Auth")
        if let c = hostScanCookie, req.url?.host == c.host {
            req.setValue("sdesktop=\(c.token)", forHTTPHeaderField: "Cookie")
        }
    }

    /// Шаг 1 протокола: GET, чтобы балансировщик увёл на конкретный узел.
    /// Возвращает адрес, на котором дальше вести POST, и цепочку редиректов.
    func resolve(_ url: URL) throws -> (URL, [String]) {
        var target = url
        var hops: [String] = []
        for _ in 0...maxRedirects {
            var req = URLRequest(url: target)
            req.httpMethod = "GET"
            headers(&req)
            let r = try once(req)
            Log.debug("GET \(Log.redact(target)) → \(r.status)\(r.location.map { " Location: \(Log.redact($0))" } ?? "")")
            if (301...308).contains(r.status), let loc = r.location,
               let next = URL(string: loc, relativeTo: target)?.absoluteURL {
                try requireSecure(next)
                hops.append("\(r.status) → \(next.absoluteString)")
                target = next
                continue
            }
            return (target, hops)
        }
        throw ProtocolError.badXML("слишком много редиректов на GET")
    }

    /// После обёртки шлюз считает отчёт через wait URI. Openconnect шлёт
    /// Cookie: sdesktop=<host-scan-token>, ждёт завершения и заново делает init.
    func waitForHostScan(_ postURL: URL, uri: String, token: String) throws {
        guard postURL.scheme == "https", let host = postURL.host,
              uri.hasPrefix("/"), !uri.hasPrefix("//"),
              let waitURL = URL(string: uri, relativeTo: postURL)?.absoluteURL,
              waitURL.host == host, waitURL.scheme == "https" else {
            throw ProtocolError.badXML("неверный host-scan-wait-uri")
        }
        hostScanCookie = (host, token)
        for _ in 0..<30 {
            var req = URLRequest(url: waitURL)
            req.httpMethod = "GET"
            headers(&req)
            let r = try once(req)
            Log.debug("GET HostScan wait → \(r.status)")
            if (300...399).contains(r.status) { return }
            guard r.status == 200 else { throw ProtocolError.http(r.status) }
            let body = String(decoding: r.body, as: UTF8.self)
            if body.hasPrefix("<?xml") { return }
            guard body.range(of: "http-equiv=[\"']refresh", options: [.caseInsensitive, .regularExpression]) != nil else {
                throw ProtocolError.badXML("HostScan wait: неизвестный ответ шлюза")
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw ProtocolError.badXML("HostScan wait: время ожидания истекло")
    }

    /// POST с ручной обработкой редиректов. Возвращает тело и адрес, на котором
    /// разговор в итоге состоялся — дальше общаться надо именно с ним.
    func post(_ url: URL, body: Data) throws -> (Data, URL) {
        var target = url
        for _ in 0...maxRedirects {
            var req = URLRequest(url: target)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            headers(&req)

            let r = try once(req)
            Log.debug("POST \(Log.redact(target)) → \(r.status), \(r.body.count) байт")
            if (301...308).contains(r.status), let loc = r.location,
               let next = URL(string: loc, relativeTo: target)?.absoluteURL {
                // Тело этого POST содержит sso-token. Уйти по редиректу на
                // http:// значит отдать его открытым текстом, причём проверка
                // сертификата к такому запросу уже неприменима.
                try requireSecure(next)
                target = next
                continue
            }
            guard r.status == 200 else {
                if let s = String(data: r.body, encoding: .utf8), !s.isEmpty {
                    // Сначала mask, потом обрезка: обрезанный тег с токеном
                    // mask уже не узнал бы.
                    Log.debug("тело ответа: \(mask(s).prefix(600))")
                }
                throw ProtocolError.http(r.status)
            }
            return (r.body, target)
        }
        throw ProtocolError.badXML("слишком много редиректов")
    }
}
