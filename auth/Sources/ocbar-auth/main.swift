import AppKit
import Foundation

// ocbar-auth — аутентификатор Cisco AnyConnect в режиме single-sign-on-v2.
// Автор: ValeraGin — Ignatkovich Valery. Лицензия MIT.
//
// Режимы и опции — в usage() ниже: справка там же, где разбор аргументов.
//
// Секреты — только через окружение: OCBAR_USERNAME, OCBAR_PASSWORD,
// OCBAR_TOTP_SECRET (base32) или OCBAR_TOTP_CODE (уже посчитанный).

struct Args {
    var url: String?
    var userAgent = "AnyConnect Windows 4.10.06079"
    var version = "4.10.06079"
    var deviceID = "mac-intel"
    var probe = false
    var dumpScript = false
    var selfTest = false
    var json = false
    var insecure = false
    var verbose = false
    var rulesFile: String?
    var timeout: TimeInterval = 300
    var showAfter: TimeInterval = 2
    var alwaysShow = false
    var noWindow = false
    var noAutofill = false
    var fillHosts: [String] = []
    var importQR: String?
    var printSecret = false
    var selectEntry: String?
    var listEntries = false
    var totpNow = false
    var learn = false
    var learnSelfTest = false
    var learnProbe = false
    var forgetSessions = false
    var teachOut: String?
    var printParams = false
    var teachDialogShot: String?
    var cameraWindowShot: String?
    var teachOn = false
    var outFile: String?
    var help = false
}

func usage() -> String {
    """
    ocbar-auth --url https://host/group [опции]

    Без режима — вход: init у шлюза, окно SSO, auth-reply; в stdout JSON
    {session_token, server_cert_hash, url, post_url, host}.

    Режимы:
      --probe               шаги init без окна: что предлагает шлюз (с --json — JSON)
      --dump-script         напечатать JS автозаполнения по --rules или встроенному
                            набору (данные — плейсхолдеры); с --fill-hosts —
                            вместе с проверкой хоста
      --selftest            самопроверка без WebKit и сети: TOTP (RFC 6238),
                            разбор XML, лимиты автозаполнения, журнал, QR, хосты
                            и cookie, пароль при записи входа
      --learn-selftest      самопроверка разметки, записи входа и движка на
                            странице-образце в WebView вне экрана; окон не открывает
      --import-qr FILE      прочитать TOTP-секрет из QR (в том числе экспорт
                            Google Authenticator); печатает метаданные и код
                            для сверки, сам секрет — только с --print-secret
        --list              показать все записи в QR и выйти
        --select ПОДСТРОКА  выбрать запись по issuer/имени; подходит несколько —
                            отказ (код 1). Без --select при нескольких записях
                            TOTP — тоже отказ: молча брать первую нельзя
        --print-secret      вывести секрет в stdout (для ocbar secret import)
        --print-params      вывести «TOTP|HOTP алгоритм цифры период» записи —
                            решить, годится ли она, до того как класть секрет
      --totp-now            напечатать текущий код из OCBAR_TOTP_SECRET с
                            параметрами OCBAR_TOTP_*; OCBAR_TOTP_AT — момент (unix)
      --learn               разметка: открыть форму входа и показать мышью, где
                            логин, пароль, код и кнопка, — правила составятся
                            сами; форма в несколько окон проходится кнопкой
                            «Пройти шаг»
        --out FILE          куда записать правила (иначе — в stdout)
      --learn-probe         открыть форму входа без окна и напечатать, что
                            предзаполнение разметки узнало бы; ничего не жмёт
      --forget-sessions     стереть сессии провайдеров входа (cookie и данные
                            сайтов окна входа): следующий вход — с формой
      --teach-dialog-shot FILE   снимок окна «Запомнить для следующего входа?»
                            в PNG, без показа и без записи в связку ключей
      --camera-window-shot FILE  снимок окна камеры в PNG; камера не включается
      -h, --help            эта справка

    Опции входа:
      --teach-out FILE      показать галочку «Запомнить, как я вхожу»; после входа
                            предложить сохранить правила, пароль и источник кода,
                            итог (без секретов) — в FILE
      --teach-on            галочка включена сразу
      --rules FILE          правила автозаполнения; формат —
                            etc/autofill.rules.example; без файла — встроенный набор
      --no-autofill         не заполнять форму
      --fill-hosts a,b      заполнять только на этих хостах и их поддоменах
                            (IdpHosts). Без него — только на хостах цепочки
                            входа: шлюз, куда он перенаправил при старте входа,
                            и куда человек перешёл сам. Всегда только по https
      --device-id ID        значение <device-id> (по умолчанию mac-intel)
      --useragent UA        User-Agent (по умолчанию AnyConnect Windows 4.10.06079)
      --version V           версия клиента в <version> (по умолчанию 4.10.06079)
      --timeout SEC         сколько ждать SSO (300)
      --show-after SEC      показать окно, если за SEC секунд не прошло молча (2)
      --always-show         показать окно сразу
      --no-window           никогда не показывать окно: если вход требует
                            человека, выйти с кодом 5, ничего не показав
      --insecure            не проверять TLS-сертификат шлюза — только хоста
                            шлюза; страницы провайдера входа, где вводится
                            пароль, проверяются всегда
      --json                --probe в JSON
      --verbose, -v         подробный журнал в stderr (токены скрыты, адреса
                            страниц — без query)

    Окружение: OCBAR_USERNAME, OCBAR_PASSWORD, OCBAR_TOTP_SECRET | OCBAR_TOTP_CODE;
    параметры кода для секрета — OCBAR_TOTP_ALGORITHM (SHA1|SHA256|SHA512),
    OCBAR_TOTP_DIGITS (6–8), OCBAR_TOTP_PERIOD (10–300 с);
    для --learn ещё OCBAR_TOTP_COMMAND — команда, печатающая свежий код
    (им заполняет поле кода кнопка «Пройти шаг»).
    Коды выхода: 0 ок, 1 протокол/HTTP, 2 тайм-аут, 3 отменено, 4 аргументы,
    5 нужен человек (только с --no-window).
    """
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func next(_ flag: String) -> String {
        guard let v = it.next() else {
            FileHandle.standardError.write(Data("ocbar-auth: \(flag) требует значение\n".utf8)); exit(4)
        }
        return v
    }
    while let arg = it.next() {
        switch arg {
        case "--url": a.url = next(arg)
        case "--useragent": a.userAgent = next(arg)
        case "--version": a.version = next(arg)
        case "--device-id": a.deviceID = next(arg)
        case "--rules": a.rulesFile = next(arg)
        case "--timeout": a.timeout = TimeInterval(next(arg)) ?? 300
        case "--show-after": a.showAfter = TimeInterval(next(arg)) ?? 2
        case "--always-show": a.alwaysShow = true
        case "--no-window": a.noWindow = true
        case "--no-autofill": a.noAutofill = true
        case "--fill-hosts": a.fillHosts = next(arg).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "--probe": a.probe = true
        case "--dump-script": a.dumpScript = true
        case "--selftest": a.selfTest = true
        case "--import-qr": a.importQR = next(arg)
        case "--print-secret": a.printSecret = true
        case "--print-params": a.printParams = true
        case "--list": a.listEntries = true
        case "--totp-now": a.totpNow = true
        case "--learn": a.learn = true
        case "--learn-selftest": a.learnSelfTest = true
        case "--learn-probe": a.learnProbe = true
        case "--forget-sessions": a.forgetSessions = true
        case "--teach-out": a.teachOut = next(arg)
        case "--teach-on": a.teachOn = true
        case "--teach-dialog-shot": a.teachDialogShot = next(arg)
        case "--camera-window-shot": a.cameraWindowShot = next(arg)
        case "--out": a.outFile = next(arg)
        case "--select": a.selectEntry = next(arg)
        case "--json": a.json = true
        case "--insecure": a.insecure = true
        case "--verbose", "-v": a.verbose = true
        case "-h", "--help": a.help = true
        default:
            FileHandle.standardError.write(Data("ocbar-auth: неизвестный аргумент \(arg)\n\(usage())\n".utf8)); exit(4)
        }
    }
    return a
}

func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

func jsonString(_ obj: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Нормализует адрес: "host/group" → "https://host/group".
func normalize(_ raw: String) -> URL? {
    var s = raw
    if !s.contains("://") { s = "https://" + s }
    return URL(string: s)
}

// MARK: - шаги 1–3

struct InitResult {
    let groupURL: URL          // как задано (после нормализации)
    let postURL: URL           // куда реально ходит POST после редиректов
    let hops: [String]
    let raw: Data
    let request: AuthRequest
    let methods: [String]
    let browserMode: String?
    let certSHA256: String?
}

func runInit(_ a: Args, http: HTTPClient) throws -> InitResult {
    guard let raw = a.url, let groupURL = normalize(raw) else {
        throw ProtocolError.badXML("не задан --url")
    }
    let (resolved, hops) = try http.resolve(groupURL)
    var body = VPNProtocol.initRequest(groupAccessURL: groupURL.absoluteString, version: a.version,
                                       deviceID: a.deviceID, includeCertFail: false)
    var (data, postURL) = try http.post(resolved, body: body)
    if VPNProtocol.isCertRequest(data) {
        Log.info("шлюз просит клиентский сертификат — повторяю с <client-cert-fail/>")
        body = VPNProtocol.initRequest(groupAccessURL: groupURL.absoluteString, version: a.version,
                                       deviceID: a.deviceID, includeCertFail: true)
        (data, postURL) = try http.post(postURL, body: body)
    }
    if a.verbose, let s = String(data: data, encoding: .utf8) {
        Log.debug("ответ init:\n\(mask(s))")
    }
    let req = try VPNProtocol.parseAuthRequest(data)
    return InitResult(groupURL: groupURL, postURL: postURL, hops: hops, raw: data, request: req,
                      methods: VPNProtocol.offeredAuthMethods(data),
                      browserMode: VPNProtocol.browserMode(data),
                      certSHA256: http.serverCertSHA256)
}

// MARK: - main

let args = parseArgs()
Log.verbose = args.verbose
if args.help { out(usage()); exit(0) }

if args.totpNow {
    // Код из OCBAR_TOTP_SECRET с параметрами профиля — для проверки того,
    // что лежит в Keychain. OCBAR_TOTP_AT — момент времени для самопроверки.
    let env = ProcessInfo.processInfo.environment
    let at = env["OCBAR_TOTP_AT"].flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) } ?? Date()
    guard let secret = env["OCBAR_TOTP_SECRET"], !secret.isEmpty,
          let code = TOTP.code(secretBase32: secret, at: at, params: TOTPParams.fromEnvironment()) else {
        Log.error("OCBAR_TOTP_SECRET пуст или не base32, либо параметры кода не поддерживаются")
        exit(1)
    }
    out(code)
    exit(0)
}

if args.selfTest {
    var failed = 0
    out("TOTP, RFC 6238 приложение B (HMAC-SHA1):")
    for v in TOTP.selfTest() {
        out("  T=\(v.t)  ожидалось \(v.want)  получено \(v.got)  \(v.ok ? "OK" : "FAIL")")
        if !v.ok { failed += 1 }
    }
    out("TOTP, RFC 6238 приложение B (HMAC-SHA256, HMAC-SHA512, 8 цифр):")
    for v in TOTP.selfTestAlgorithms() {
        out("  \(v.alg) T=\(v.t)  ожидалось \(v.want)  получено \(v.got)  \(v.ok ? "OK" : "FAIL")")
        if !v.ok { failed += 1 }
    }
    out("Разбор XML init-ответа (образец):")
    let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <config-auth client="vpn" type="auth-request" aggregate-auth-version="2">
      <opaque is-for="sg"><tunnel-group>TG-EXAMPLE</tunnel-group><auth-method>single-sign-on-v2</auth-method><config-hash>1</config-hash></opaque>
      <auth id="main"><title>Login</title><message>Please complete the authentication process in the AnyConnect Login window.</message>
        <sso-v2-login>https://vpn.example.com/+CSCOE+/saml/sp/login?tgname=TG-EXAMPLE&amp;acsamlcap=v2</sso-v2-login>
        <sso-v2-login-final>https://vpn.example.com/+CSCOE+/saml_ac_login.html</sso-v2-login-final>
        <sso-v2-token-cookie-name>acSamlv2Token</sso-v2-token-cookie-name>
        <sso-v2-error-cookie-name>acSamlv2Error</sso-v2-error-cookie-name>
        <form><input type="sso" name="sso-token"></input></form></auth>
    </config-auth>
    """
    do {
        let r = try VPNProtocol.parseAuthRequest(Data(sample.utf8))
        let ok = r.tokenCookieName == "acSamlv2Token" && r.errorCookieName == "acSamlv2Error"
            && r.loginURL.hasSuffix("acsamlcap=v2") && r.opaqueXML.contains("<tunnel-group>TG-EXAMPLE</tunnel-group>")
        out("  cookie=\(r.tokenCookieName) final=\(r.loginFinalURL) opaque=\(r.opaqueXML.count) байт  \(ok ? "OK" : "FAIL")")
        if !ok { failed += 1 }
        let reply = VPNProtocol.replyRequest(version: "1", deviceID: "mac-intel", opaqueXML: r.opaqueXML, ssoToken: "T<&>")
        let replyOK = String(data: reply, encoding: .utf8)!.contains("<sso-token>T&lt;&amp;&gt;</sso-token>")
        out("  auth-reply экранирует токен и несёт <opaque> дословно  \(replyOK ? "OK" : "FAIL")")
        if !replyOK { failed += 1 }
    } catch {
        out("  FAIL: \(error)"); failed += 1
    }
    let complete = """
    <config-auth client="vpn" type="complete" aggregate-auth-version="2">
      <session-id>1</session-id><session-token>ABC123</session-token>
      <auth id="success"><message>ok</message></auth>
      <config client="vpn" type="private"><vpn-base-config><server-cert-hash>DEADBEEF</server-cert-hash></vpn-base-config></config>
    </config-auth>
    """
    do {
        let c = try VPNProtocol.parseComplete(Data(complete.utf8))
        let ok = c.sessionToken == "ABC123" && c.serverCertHash == "DEADBEEF"
        out("  разбор complete: token=\(c.sessionToken) hash=\(c.serverCertHash)  \(ok ? "OK" : "FAIL")")
        if !ok { failed += 1 }
    } catch { out("  FAIL: \(error)"); failed += 1 }
    failed += AuthSelfTest.run()
    // Справка: каждый флаг из parseArgs описан, и описан правдиво. Новый
    // флаг — сюда же.
    out("Справка --help:")
    let help = usage()
    let flags = ["--url", "--useragent", "--version", "--device-id", "--rules", "--timeout", "--show-after",
                 "--always-show", "--no-window", "--no-autofill", "--fill-hosts", "--probe", "--dump-script",
                 "--selftest", "--import-qr", "--print-secret", "--print-params", "--list", "--totp-now",
                 "--learn", "--learn-selftest", "--learn-probe", "--teach-out", "--teach-on",
                 "--teach-dialog-shot", "--camera-window-shot", "--out", "--select", "--json", "--insecure",
                 "--verbose", "-v", "--help", "-h"]
    let missing = flags.filter { f in
        help.range(of: "(^|[\\s,])" + NSRegularExpression.escapedPattern(for: f) + "($|[\\s,])", options: .regularExpression) == nil
    }
    let helpOK = missing.isEmpty
        && help.contains("etc/autofill.rules.example")
        && help.contains("подходит несколько")
        && !help.contains("иначе — первая TOTP") && !help.contains("иначе — на любом")
        && help.contains("только хоста")
    out("  все флаги описаны, --select отказывает при нескольких, --rules → etc/autofill.rules.example  \(helpOK ? "OK" : "FAIL \(missing)")")
    if !helpOK { failed += 1 }
    out(failed == 0 ? "selftest: всё OK" : "selftest: провалов \(failed)")
    exit(failed == 0 ? 0 : 1)
}

if let qr = args.importQR {
    do {
        var entries: [QRImport.Entry] = []
        for payload in try QRImport.decode(file: qr) {
            entries.append(contentsOf: (try? QRImport.parse(payload)) ?? [])
        }
        func label(_ e: QRImport.Entry) -> String {
            let i = e.issuer.isEmpty ? "" : e.issuer + "/"
            return i + (e.name.isEmpty ? "(без имени)" : e.name)
        }
        if args.listEntries {
            out("записей в QR: \(entries.count)")
            for (i, e) in entries.enumerated() {
                out("  \(i + 1). \(label(e))  [\(e.isTOTP ? "TOTP" : "HOTP"), \(e.algorithm), \(e.digits) цифр]")
            }
            exit(0)
        }
        let candidates = entries.filter { $0.isTOTP }
        var chosen: QRImport.Entry?
        if let want = args.selectEntry?.lowercased(), !want.isEmpty {
            let matched = candidates.filter { label($0).lowercased().contains(want) }
            if matched.count > 1 {
                Log.error("под «\(args.selectEntry!)» подходит несколько записей: \(matched.map(label).joined(separator: ", ")) — уточните")
                exit(1)
            }
            guard let m = matched.first else {
                Log.error("в QR нет записи, похожей на «\(args.selectEntry!)». Есть: \(candidates.map(label).joined(separator: ", "))")
                exit(1)
            }
            chosen = m
        } else if candidates.count > 1 {
            // Молча взять первую из нескольких — верный способ записать чужой
            // секрет и потом долго не понимать, почему код не подходит.
            Log.error("в QR \(candidates.count) записи: \(candidates.map(label).joined(separator: ", "))")
            Log.error("укажите нужную: --select <часть имени> (у ocbar: secret import-qr <файл> --select <часть имени>)")
            exit(1)
        } else {
            chosen = candidates.first ?? entries.first
        }
        guard let e = chosen else { throw QRImport.ImportError.empty }
        Log.info("запись: \(e.issuer.isEmpty ? "(без issuer)" : e.issuer) / \(e.name), \(e.algorithm), \(e.digits) цифр, период \(e.period) с")
        if !e.isTOTP {
            Log.info("ВНИМАНИЕ: это HOTP (код по счётчику) — ocbar его не ведёт: счётчик живёт в приложении")
        } else if !e.params.isSupported {
            Log.info("ВНИМАНИЕ: параметры кода \(e.params.label) не поддерживаются")
        } else if !e.params.isDefault {
            Log.info("параметры кода: \(e.params.label) — ocbar запишет их в профиль")
        }
        if args.printParams {
            // Для ocbar: решить, годится ли запись, до того как класть секрет.
            out("\(e.isTOTP ? "TOTP" : "HOTP") \(e.algorithm) \(e.digits) \(e.period)")
        } else if args.printSecret {
            out(e.secretBase32)              // ← только для пайпа в security
        } else {
            let code = e.isTOTP ? (TOTP.code(secretBase32: e.secretBase32, params: e.params) ?? "??????") : "—"
            out("код сейчас: \(code)  (сверьте с приложением; секрет не печатается)")
        }
        exit(0)
    } catch {
        Log.error("\(error)")
        exit(1)
    }
}

if args.dumpScript {
    let rules: [AutofillRule] = args.rulesFile.map { Autofill.parse(file: $0) } ?? Autofill.defaultRules
    let creds = Credentials(username: "USERNAME", password: "PASSWORD", totpSecret: nil)
    let allowed = args.fillHosts.isEmpty ? nil : FillScope(explicit: args.fillHosts, gatewayHosts: []).jsAllowed
    out(Autofill.script(rules: rules, creds: creds, totpCode: "TOTP", allowed: allowed))
    exit(0)
}

let http = HTTPClient(userAgent: args.userAgent, insecure: args.insecure)

if args.probe {
    do {
        let r = try runInit(args, http: http)
        if args.json {
            out(jsonString([
                "url": r.groupURL.absoluteString,
                "post_url": r.postURL.absoluteString,
                "redirects": r.hops,
                "auth_methods": r.methods,
                "browser_mode": r.browserMode ?? "",
                "sso_v2_login": r.request.loginURL,
                "sso_v2_login_final": r.request.loginFinalURL,
                "token_cookie": r.request.tokenCookieName,
                "error_cookie": r.request.errorCookieName ?? "",
                "opaque_bytes": r.request.opaqueXML.count,
                "message": r.request.message,
                "server_cert_sha256": r.certSHA256 ?? "",
            ]))
        } else {
            out("url:                 \(r.groupURL.absoluteString)")
            for h in r.hops { out("redirect:            \(h)") }
            out("post-url:            \(r.postURL.absoluteString)")
            out("auth-method:         \(r.methods.joined(separator: ", "))")
            out("browser-mode:        \(r.browserMode ?? "(нет — значит встроенный webview)")")
            out("sso-v2-login:        \(r.request.loginURL)")
            out("sso-v2-login-final:  \(r.request.loginFinalURL)")
            out("token-cookie:        \(r.request.tokenCookieName)")
            out("error-cookie:        \(r.request.errorCookieName ?? "-")")
            out("opaque:              \(r.request.opaqueXML.count) байт")
            out("message:             \(r.request.message)")
            out("server-cert-sha256:  \(r.certSHA256 ?? "?")")
        }
        exit(0)
    } catch {
        Log.error("\(error)")
        exit(1)
    }
}

// Проверка разметки без человека: селекторы по странице-образцу.
if args.learnSelfTest {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    out("ocbar-auth learn-selftest")
    var check: LearnCheck?
    DispatchQueue.main.async {
        check = LearnCheck { code in exit(code) }
        check?.start()
    }
    app.run()
}

// Снимок окна «Запомнить для следующего входа?» — вид без человека.
if let shotPath = args.teachDialogShot {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        let ok = TeachDialog.shot(to: shotPath)
        out(ok ? "снимок: \(shotPath)" : "снимок не получился")
        exit(ok ? 0 : 1)
    }
    app.run()
}

// Снимок окна камеры — вид без человека и без включения камеры.
if let shotPath = args.cameraWindowShot {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        let ok = QRCameraWindow.shot(to: shotPath)
        out(ok ? "снимок: \(shotPath)" : "снимок не получился")
        exit(ok ? 0 : 1)
    }
    app.run()
}

// Пробник предзаполнения: та же страница, что у разметки, но без окна.
if args.forgetSessions {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    DispatchQueue.main.async {
        WebAuth.forgetSessions { n in
            out("сессии окна входа стёрты (записей сайтов: \(n))")
            exit(0)
        }
    }
    app.run()
}

if args.learnProbe {
    guard let raw = args.url, let groupURL = normalize(raw) else {
        FileHandle.standardError.write(Data("ocbar-auth: --learn-probe требует --url\n".utf8)); exit(4)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    var probe: LearnProbe?
    DispatchQueue.global().async {
        var target = groupURL
        do {
            let r = try runInit(args, http: http)
            if let u = URL(string: r.request.loginURL) { target = u }
        } catch {
            Log.info("шлюз не ответил (\(error)) — открываю адрес как есть")
        }
        DispatchQueue.main.async {
            probe = LearnProbe(url: target) { code in exit(code) }
            probe?.start()
        }
    }
    app.run()
}

// Режим обучения: открыть форму входа и записать, что человек покажет мышью.
if args.learn {
    guard let raw = args.url, let groupURL = normalize(raw) else {
        FileHandle.standardError.write(Data("ocbar-auth: --learn требует --url\n".utf8)); exit(4)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    var session: LearnSession?
    DispatchQueue.global().async {
        // Открываем ровно ту страницу, которую человек увидит при настоящем
        // входе: её отдаёт шлюз в sso-v2-login. Если шлюз недоступен, берём
        // адрес как есть — размечать можно и по своей копии страницы.
        var target = groupURL
        do {
            let r = try runInit(args, http: http)
            if let u = URL(string: r.request.loginURL) { target = u }
        } catch {
            Log.info("шлюз не ответил (\(error)) — открываю адрес как есть")
        }
        DispatchQueue.main.async {
            // Источники данных для «Пройти шаг» — те же, что у входа: ocbar
            // learn кладёт их в окружение. OCBAR_TOTP_COMMAND печатает свежий
            // код — он нужен в момент нажатия, а не при запуске окна.
            let env = ProcessInfo.processInfo.environment
            session = LearnSession(startURL: target, outFile: args.outFile,
                                   creds: Credentials.fromEnvironment(),
                                   totpSecret: env["OCBAR_TOTP_SECRET"], totpCode: env["OCBAR_TOTP_CODE"],
                                   totpCommand: env["OCBAR_TOTP_COMMAND"]) { code in exit(code) }
            session?.start()
        }
    }
    app.run()
}

// Полный проход: init → окно → auth-reply → JSON.

guard args.url != nil else {
    FileHandle.standardError.write(Data((usage() + "\n").utf8)); exit(4)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // без иконки в Dock, пока окно не понадобилось

var webAuth: WebAuth?

DispatchQueue.global().async {
    do {
        let r = try runInit(args, http: http)
        Log.info("шлюз: \(r.methods.joined(separator: ", ")), cookie \(r.request.tokenCookieName)")
        var opts = WebAuth.Options()
        opts.showAfter = args.showAfter
        opts.alwaysShow = args.alwaysShow
        opts.noWindow = args.noWindow
        opts.timeout = args.timeout
        opts.insecure = args.insecure
        opts.autofill = !args.noAutofill
        opts.rules = args.rulesFile.map { Autofill.parse(file: $0) } ?? Autofill.defaultRules
        opts.creds = Credentials.fromEnvironment()
        opts.totpParams = TOTPParams.fromEnvironment()
        let env = ProcessInfo.processInfo.environment
        if let code = env["OCBAR_TOTP_CODE"], !code.isEmpty {
            opts.totpCode = code            // готовый код из внешней базы
        } else if let secret = opts.creds.totpSecret, !secret.isEmpty {
            if TOTP.code(secretBase32: secret, params: opts.totpParams) == nil {
                Log.info("OCBAR_TOTP_SECRET не разобрался как base32 или параметры кода не поддерживаются — код вводит человек")
            } else {
                opts.totpSecret = secret    // считаем в момент заполнения
            }
        }
        opts.gatewayHosts = [r.postURL.host, r.groupURL.host].compactMap { $0 }
        if let cmd = env["OCBAR_TOTP_COMMAND"], !cmd.isEmpty { opts.totpCommand = cmd }
        opts.fillHosts = args.fillHosts
        opts.teach = args.teachOut != nil && !args.noWindow
        opts.teachOn = args.teachOn
        if !opts.fillHosts.isEmpty { Log.debug("автозаполнение разрешено на: \(opts.fillHosts.joined(separator: ", "))") }
        DispatchQueue.main.async {
            webAuth = WebAuth(request: r.request, options: opts) { result in
                switch result {
                case .failure(let e):
                    Log.error("\(e)")
                    switch e {
                    case .timeout: exit(args.noWindow ? 5 : 2)
                    case .cancelled: exit(3)
                    case .needsHuman: exit(5)
                    case .network: exit(6)
                    default: exit(1)
                    }
                case .success(let token):
                    DispatchQueue.global().async {
                        do {
                            let body = VPNProtocol.replyRequest(version: args.version, deviceID: args.deviceID,
                                                                opaqueXML: r.request.opaqueXML, ssoToken: token)
                            let (data, _) = try http.post(r.postURL, body: body)
                            if args.verbose, let s = String(data: data, encoding: .utf8) { Log.debug("ответ auth-reply:\n\(mask(s))") }
                            let c = try VPNProtocol.parseComplete(data)
                            Log.info("сессия получена, server-cert-hash \(c.serverCertHash)")
                            out(jsonString([
                                "session_token": c.sessionToken,
                                "server_cert_hash": c.serverCertHash,
                                "url": r.groupURL.absoluteString,
                                "post_url": r.postURL.absoluteString,
                                "host": r.postURL.host ?? "",
                            ]))
                            // Вход прошёл и сессия уже у клиента — теперь можно
                            // спросить, что сохранить на следующий раз. Токен
                            // сессии живёт минуты, а не секунды: спрашиваем
                            // после auth-reply, не до.
                            DispatchQueue.main.async {
                                if let path = args.teachOut, let rec = webAuth?.teachOutcome {
                                    TeachFlow.finish(recorder: rec, outFile: path,
                                                     portal: r.groupURL.host ?? "")
                                }
                                exit(0)
                            }
                        } catch {
                            Log.error("\(error)")
                            exit(1)
                        }
                    }
                }
            }
            webAuth?.start()
        }
    } catch {
        Log.error("\(error)")
        exit(1)
    }
}

app.run()
