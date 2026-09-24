import Foundation

// Протокол Cisco AnyConnect, режим single-sign-on-v2.
//
// 1. POST config-auth type="init"  → сервер отдаёт sso-v2-login и имя cookie с токеном
// 2. пользователь проходит SAML в webview, токен оседает в cookie на домене шлюза
// 3. POST config-auth type="auth-reply" с этим токеном → session-token и хеш сертификата
// 4. openconnect --cookie-on-stdin --servercert <хеш>
//
// Критично: элемент <opaque> из ответа шага 1 надо вернуть на шаге 3 ДОСЛОВНО.

struct AuthRequest {
    let loginURL: String
    let loginFinalURL: String
    let tokenCookieName: String
    let errorCookieName: String?
    let opaqueXML: String
    let message: String
    let error: String?
}

struct AuthComplete {
    let sessionToken: String
    let serverCertHash: String
}

enum ProtocolError: Error, CustomStringConvertible {
    case badXML(String)
    case missing(String)
    case serverError(String)
    case http(Int)

    var description: String {
        switch self {
        case .badXML(let s):     return "не удалось разобрать XML: \(s)"
        case .missing(let s):    return "в ответе сервера нет \(s)"
        case .serverError(let s):return "сервер вернул ошибку: \(s)"
        case .http(let c):       return "HTTP \(c)"
        }
    }
}

enum VPNProtocol {

    static func initRequest(groupAccessURL: String, version: String, deviceID: String,
                            includeCertFail: Bool) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="init" aggregate-auth-version="2">
          <version who="vpn">\(esc(version))</version>
          <device-id>\(esc(deviceID))</device-id>
          <group-access>\(esc(groupAccessURL))</group-access>
          <capabilities>
            <auth-method>single-sign-on-v2</auth-method>
          </capabilities>
        """
        if includeCertFail { xml += "\n  <client-cert-fail/>" }
        xml += "\n</config-auth>\n"
        return Data(xml.utf8)
    }

    static func replyRequest(version: String, deviceID: String,
                             opaqueXML: String, ssoToken: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="auth-reply" aggregate-auth-version="2">
          <version who="vpn">\(esc(version))</version>
          <device-id>\(esc(deviceID))</device-id>
          <session-token/>
          <session-id/>
          \(opaqueXML)
          <auth>
            <sso-token>\(esc(ssoToken))</sso-token>
          </auth>
        </config-auth>
        """
        return Data(xml.utf8)
    }

    /// Требуется ли повторить init с <client-cert-fail/>.
    static func isCertRequest(_ data: Data) -> Bool {
        guard let doc = try? parse(data) else { return false }
        return !((try? doc.nodes(forXPath: "//client-cert-request")) ?? []).isEmpty
    }

    static func parseAuthRequest(_ data: Data) throws -> AuthRequest {
        let doc: XMLDocument
        do { doc = try parse(data) }
        catch { throw ProtocolError.badXML(error.localizedDescription) }

        if let err = text(doc, "//auth/error"), !err.isEmpty {
            throw ProtocolError.serverError(err)
        }
        guard let login = text(doc, "//auth/sso-v2-login"), !login.isEmpty else {
            // Самая частая причина — группа вообще не SSO: шлюз прислал форму
            // с username/password (и, возможно, ждёт OTP вторым шагом).
            // Это не лечится на стороне клиента: такой группе нужен голый
            // openconnect с --passwd-on-stdin. <auth-method> внутри <opaque>
            // при этом всё равно говорит single-sign-on-v2 — не верить ему.
            let inputs = ((try? doc.nodes(forXPath: "//auth/form/input")) ?? [])
                .compactMap { ($0 as? XMLElement)?.attribute(forName: "name")?.stringValue }
            if !inputs.isEmpty {
                throw ProtocolError.missing("sso-v2-login: группа использует форму \(inputs.joined(separator: "/")), а не SSO")
            }
            if let mode = text(doc, "//sso-v2-browser-mode") {
                throw ProtocolError.missing("sso-v2-login (browser-mode=\(mode))")
            }
            throw ProtocolError.missing("sso-v2-login")
        }
        guard let final = text(doc, "//auth/sso-v2-login-final") else {
            throw ProtocolError.missing("sso-v2-login-final")
        }
        guard let cookie = text(doc, "//auth/sso-v2-token-cookie-name") else {
            throw ProtocolError.missing("sso-v2-token-cookie-name")
        }
        // ASA в части конфигураций отдаёт несколько <opaque>; шлюзу нужен тот,
        // что помечен is-for="sg". Раньше брался первый в документе.
        let opaqueNode = (try? doc.nodes(forXPath: "//opaque[@is-for='sg']"))?.first
            ?? (try? doc.nodes(forXPath: "//opaque"))?.first
        guard let opaque = opaqueNode as? XMLElement else {
            throw ProtocolError.missing("opaque")
        }
        return AuthRequest(
            loginURL: login,
            loginFinalURL: final,
            tokenCookieName: cookie,
            errorCookieName: text(doc, "//auth/sso-v2-error-cookie-name"),
            opaqueXML: opaque.xmlString,
            message: text(doc, "//auth/message") ?? "",
            error: nil
        )
    }

    static func parseComplete(_ data: Data) throws -> AuthComplete {
        let doc: XMLDocument
        do { doc = try parse(data) }
        catch { throw ProtocolError.badXML(error.localizedDescription) }

        // Отказ бывает и в корне ответа, <config-auth><error>, а не только в
        // <auth>: так шлюз говорит, что группа требует проверку устройства
        // (Cisco Secure Desktop). Без этого человек видел «нет session-token».
        if let err = text(doc, "//auth/error") ?? text(doc, "/config-auth/error"), !err.isEmpty {
            throw ProtocolError.serverError(err)
        }
        guard let token = text(doc, "//session-token"), !token.isEmpty else {
            throw ProtocolError.missing("session-token")
        }
        guard let hash = text(doc, "//config/vpn-base-config/server-cert-hash")
                      ?? text(doc, "//server-cert-hash") else {
            throw ProtocolError.missing("server-cert-hash")
        }
        return AuthComplete(sessionToken: token, serverCertHash: hash)
    }

    /// <sso-v2-browser-mode>external</sso-v2-browser-mode> — если есть, шлюз
    /// готов к внешнему браузеру и webview не нужен.
    static func browserMode(_ data: Data) -> String? {
        guard let doc = try? parse(data) else { return nil }
        return text(doc, "//sso-v2-browser-mode")
    }

    /// Способы аутентификации, которые сервер согласился использовать.
    static func offeredAuthMethods(_ data: Data) -> [String] {
        guard let doc = try? parse(data),
              let nodes = try? doc.nodes(forXPath: "//auth-method") else { return [] }
        return nodes.compactMap { $0.stringValue }
    }

    /// Единственная точка разбора XML — и единственное место, где задаётся
    /// запрет внешних сущностей.
    ///
    /// Без него ответ шлюза вида `<!DOCTYPE r [<!ENTITY x SYSTEM "file:///…">]>`
    /// подставляет содержимое локального файла в элемент `<opaque>`, а тот по
    /// протоколу возвращается шлюзу следующим запросом. То есть любой файл,
    /// читаемый пользователем, уезжает на сервер. Проверено на этом коде.
    private static func parse(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    private static func text(_ doc: XMLDocument, _ xpath: String) -> String? {
        guard let n = (try? doc.nodes(forXPath: xpath))?.first,
              let s = n.stringValue else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func esc(_ s: String) -> String {
        // Значение приходит из cookie, то есть снаружи. Управляющие символы
        // в XML недопустимы: с ними запрос не парсится, и шлюз отвечает
        // невнятной ошибкой вместо понятной.
        let cleaned = String(s.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 })
        return cleaned.replacingOccurrences(of: "&", with: "&amp;")
                      .replacingOccurrences(of: "<", with: "&lt;")
                      .replacingOccurrences(of: ">", with: "&gt;")
                      .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
