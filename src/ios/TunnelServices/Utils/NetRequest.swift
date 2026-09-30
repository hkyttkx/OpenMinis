import Foundation
import NIOHTTP1

final class NetRequest {
    let host: String
    var port: Int
    var ssl: Bool

    init(_ head: HTTPRequestHead) {
        var resolvedHost = ""
        var resolvedPort = 80
        var resolvedSSL = false

        if head.method == .CONNECT {
            let endpoint = NetRequest.parseHostAndPort(from: head.uri, defaultPort: 443)
            resolvedHost = endpoint.host
            resolvedPort = endpoint.port
            resolvedSSL = true
        } else if let url = URL(string: head.uri), let urlHost = url.host {
            resolvedHost = urlHost
            resolvedSSL = (url.scheme?.lowercased() == "https")
            resolvedPort = url.port ?? (resolvedSSL ? 443 : 80)
        }

        if resolvedHost.isEmpty {
            let hostHeader = head.headers["Host"].first ?? ""
            let endpoint = NetRequest.parseHostAndPort(from: hostHeader, defaultPort: 80)
            resolvedHost = endpoint.host
            resolvedPort = endpoint.port
        }

        if resolvedHost.isEmpty {
            resolvedHost = "127.0.0.1"
        }

        host = resolvedHost
        port = resolvedPort
        ssl = resolvedSSL
    }

    static func removeProxyHead(heads: HTTPHeaders) -> HTTPHeaders {
        var sanitized = heads
        [
            "Proxy-Connection",
            "Proxy-Authenticate",
            "Proxy-Authorization",
            "Proxy-Authorization-Data",
            "Proxy-Features"
        ].forEach { sanitized.remove(name: $0) }
        return sanitized
    }

    private static func parseHostAndPort(from raw: String, defaultPort: Int) -> (host: String, port: Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("", defaultPort)
        }

        if let url = URL(string: trimmed), let host = url.host {
            return (host, url.port ?? defaultPort)
        }

        // Parse plain host[:port] and [IPv6]:port forms.
        let prefixed = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        if let components = URLComponents(string: prefixed), let host = components.host, !host.isEmpty {
            return (host, components.port ?? defaultPort)
        }

        return (trimmed, defaultPort)
    }
}
