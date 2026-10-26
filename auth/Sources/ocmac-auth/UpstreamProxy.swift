import Foundation
import Network
import WebKit

/// One explicit route for URLSession, every WebKit window and CSD subprocesses.
/// Never allow an unavailable proxy to fall back to a direct connection.
struct UpstreamProxy {
    static var current: UpstreamProxy?
    let raw: String
    let host: String
    let port: UInt16
    let socks: Bool

    init?(_ raw: String) {
        let pattern = "\\A(http|socks5)://[A-Za-z0-9][A-Za-z0-9.-]{0,252}:[0-9]{1,5}\\z"
        guard raw.range(of: pattern, options: .regularExpression) != nil,
              let url = URLComponents(string: raw), let host = url.host,
              let port = url.port, (1...65535).contains(port) else { return nil }
        self.raw = raw; self.host = host; self.port = UInt16(port)
        socks = url.scheme == "socks5"
    }

    @available(macOS 14.0, *)
    var configuration: ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        var result = socks ? ProxyConfiguration(socksv5Proxy: endpoint) : ProxyConfiguration(httpCONNECTProxy: endpoint)
        result.allowFailover = false
        return result
    }

    static func apply(to config: URLSessionConfiguration) {
        if #available(macOS 14.0, *), let current { config.proxyConfigurations = [current.configuration] }
    }

    static func apply(to store: WKWebsiteDataStore) {
        if #available(macOS 14.0, *) {
            // Reset the shared persistent store when a later window has no proxy.
            store.proxyConfigurations = current.map { [$0.configuration] } ?? []
        }
    }

    static func apply(to environment: inout [String: String]) {
        guard let current else { return }
        for key in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            environment[key] = current.raw
        }
        environment["no_proxy"] = ""; environment["NO_PROXY"] = ""
    }
}
