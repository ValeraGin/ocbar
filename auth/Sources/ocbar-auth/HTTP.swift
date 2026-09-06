import Foundation
import Security

/// URLSession сам превращает POST в GET при 302 и теряет тело.
/// Шлюзы Cisco за балансировщиком отвечают редиректом именно на POST,
/// поэтому редиректы обрабатываем вручную и повторяем POST на новый адрес.
final class HTTPClient: NSObject, URLSessionTaskDelegate, URLSessionDelegate {
    private var session: URLSession!
    private let userAgent: String
    private let insecure: Bool
    private let maxRedirects = 5

    /// Отпечаток сертификата сервера (SHA-256 DER, hex) — для диагностики.
    private(set) var serverCertSHA256: String?

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
        }
        if insecure {
            Log.debug("TLS: сертификат принят без проверки (--insecure)")
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
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

    private func headers(_ req: inout URLRequest) {
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.setValue("1", forHTTPHeaderField: "X-Aggregate-Auth")
        req.setValue("1", forHTTPHeaderField: "X-Transcend-Version")
        req.setValue("true", forHTTPHeaderField: "X-Support-HTTP-Auth")
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
            Log.debug("GET \(target.absoluteString) → \(r.status)\(r.location.map { " Location: \($0)" } ?? "")")
            if (301...308).contains(r.status), let loc = r.location,
               let next = URL(string: loc, relativeTo: target)?.absoluteURL {
                hops.append("\(r.status) → \(next.absoluteString)")
                target = next
                continue
            }
            return (target, hops)
        }
        throw ProtocolError.badXML("слишком много редиректов на GET")
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
            Log.debug("POST \(target.absoluteString) → \(r.status), \(r.body.count) байт")
            if (301...308).contains(r.status), let loc = r.location,
               let next = URL(string: loc, relativeTo: target)?.absoluteURL {
                target = next
                continue
            }
            guard r.status == 200 else {
                if let s = String(data: r.body, encoding: .utf8), !s.isEmpty {
                    Log.debug("тело ответа: \(s.prefix(600))")
                }
                throw ProtocolError.http(r.status)
            }
            return (r.body, target)
        }
        throw ProtocolError.badXML("слишком много редиректов")
    }
}
