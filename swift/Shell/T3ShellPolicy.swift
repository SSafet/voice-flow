import Foundation

struct T3ShellOrigin: Equatable {
    let url: URL
    let scheme: String
    let host: String
    let port: Int
    var isLoopback: Bool { ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host) }

    init(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host)),
              (1...65535).contains(parts.port ?? (scheme == "https" ? 443 : 80)) else {
            throw T3ShellError.invalidOrigin
        }
        self.scheme = scheme
        self.host = host
        self.port = parts.port ?? (scheme == "https" ? 443 : 80)
        var normalized = parts
        normalized.scheme = scheme
        normalized.host = host
        if self.port == (scheme == "https" ? 443 : 80) { normalized.port = nil }
        normalized.path = ""
        self.url = normalized.url!
    }

    func contains(_ candidate: URL) -> Bool {
        guard let parts = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { return false }
        return parts.scheme?.lowercased() == scheme && parts.host?.lowercased() == host
            && (parts.port ?? (scheme == "https" ? 443 : 80)) == port
    }

    func matchesSecurityOrigin(scheme: String, host: String, port: Int) -> Bool {
        let actualPort = port == 0 ? (scheme == "https" ? 443 : 80) : port
        let brackets = CharacterSet(charactersIn: "[]")
        return self.scheme == scheme && self.host.trimmingCharacters(in: brackets) == host.trimmingCharacters(in: brackets)
            && self.port == actualPort
    }

    func endpoint(_ path: String) -> URL { url.appendingPathComponent(path) }

    /// Match the selected T3 router, not its authenticated file/API paths.
    func isAppDocument(_ candidate: URL) -> Bool {
        guard contains(candidate), !candidate.path.contains("\\"),
              !candidate.pathComponents.contains("..") else { return false }
        let segments = candidate.path.split(separator: "/").map(String.init)
        if segments.isEmpty { return true }
        if segments.count == 1 {
            return ["welcome", "usage", "settings", "pair", "connect", "pull-requests"].contains(segments[0])
        }
        guard segments.count == 2 else { return false }
        if segments[0] == "settings" {
            return ["storage", "source-control", "snap-shot", "providers", "projects", "open-source-licenses",
                    "keybindings", "integrations", "general", "diagnostics", "connections", "archived", "appearance"].contains(segments[1])
        }
        if segments[0] == "projects" || segments[0] == "draft" { return true }
        return !["api", "oauth", ".well-known", "assets", "client", "resource-monitor"].contains(segments[0])
            && !segments.contains(where: { $0.hasPrefix(".") })
    }

    func permitsFrameResponse(url: URL, mimeType: String?, contentSecurityPolicy: String?) -> Bool {
        guard contains(url) || url.scheme == "blob" && URL(string: String(url.absoluteString.dropFirst(5))).map(contains) == true else { return false }
        if mimeType?.lowercased() == "application/pdf" { return true }
        guard mimeType?.lowercased() == "text/html", let policy = contentSecurityPolicy else { return false }
        return Self.hasOpaqueSandbox(policy)
    }

    static func hasOpaqueSandbox(_ policy: String) -> Bool {
        policy.lowercased().split(separator: ";").contains { directive in
            let words = directive.split(whereSeparator: \.isWhitespace)
            return words.first == "sandbox" && !words.contains("allow-same-origin")
        }
    }

    /// Cookies are not port-scoped. Strip them from ALL other destinations,
    /// including preview images/fetches to another server on the same hostname.
    /// Keep WS handshakes for this origin authenticated too. Compile before load.
    func cookieRulesJSON() throws -> String {
        let hosts = NSRegularExpression.escapedPattern(for: host)
        let schemes = scheme == "https" ? ["https", "wss"] : ["http", "ws"]
        let defaultPort = scheme == "https" ? 443 : 80
        let ports = port == defaultPort ? ["", ":\(port)"] : [":\(port)"]
        // WebKit content blockers reject regexp disjunctions. Each exact
        // scheme/port gets its own exception after the universal cookie block.
        var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block-cookies"]]]
        for allowedScheme in schemes {
            for allowedPort in ports {
                rules.append(["trigger": ["url-filter": "^\(allowedScheme)://\(hosts)\(allowedPort)/"],
                              "action": ["type": "ignore-previous-rules"]])
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
    }
}

enum T3ShellError: Error, LocalizedError {
    case invalidOrigin, unavailable, invalidResponse, wrongEnvironment, refusedCredentials
    var errorDescription: String? {
        switch self {
        case .invalidOrigin: return "The environment address is not a supported secure origin."
        case .unavailable: return "The environment could not be reached."
        case .invalidResponse: return "The environment returned an unsupported authentication response."
        case .wrongEnvironment: return "The environment identity does not match this connection."
        case .refusedCredentials: return "The environment did not accept this credential."
        }
    }
}
