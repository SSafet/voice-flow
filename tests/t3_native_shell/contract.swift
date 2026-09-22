import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "T3ShellTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

final class AuthFixture: URLProtocol {
    static var mutation = "valid"
    static var paths: [String] = []
    static let expiration = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 600)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            try require(request.value(forHTTPHeaderField: "Cookie") == nil, "native bootstrap must not send ambient cookies")
            try require(request.url?.query == nil, "credential must never enter URL")
            let path = request.url!.path
            Self.paths.append(path)
            var headers = ["Content-Type": "application/json"]
            var status = 200
            let output: [String: Any]
            switch path {
            case "/.well-known/t3/environment":
                output = ["environmentId": Self.mutation == "wrong-environment" ? "other" : "expected"]
            case "/api/auth/session":
                output = ["authenticated": false, "auth": ["sessionMethods": ["browser-session-cookie"], "sessionCookieName": "t3_session_28471"]]
            case "/api/auth/browser-session":
                try require(request.httpMethod == "POST", "upstream cookie exchange uses POST")
                let format = DateFormatter()
                format.locale = Locale(identifier: "en_US_POSIX")
                format.timeZone = TimeZone(secondsFromGMT: 0)
                format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                let expires = format.string(from: Self.expiration)
                let domain = Self.mutation == "wrong-domain" ? "; Domain=elsewhere.test" : ""
                let httpOnly = Self.mutation == "not-http-only" ? "" : "; HttpOnly"
                if Self.mutation != "missing-cookie" {
                    headers["Set-Cookie"] = "t3_session_28471=synthetic-private-cookie; Path=/; Expires=\(expires); SameSite=Lax\(domain)\(httpOnly)"
                }
                if Self.mutation == "redirect" { status = 302; headers["Location"] = "http://127.0.0.1:28472/leak" }
                if Self.mutation == "denied" { status = 401 }
                output = ["authenticated": true, "sessionMethod": Self.mutation == "wrong-method" ? "bearer-access-token" : "browser-session-cookie",
                          "scopes": ["orchestration:read"], "expiresAt": ISO8601DateFormatter().string(from: Self.expiration)]
            default: throw T3ShellError.invalidResponse
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: output))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@main
enum ShellContractTests {
    static func main() async throws {
        let origin = try T3ShellOrigin(URL(string: "http://127.0.0.1:28471")!)
        for bad in ["http://remote.example", "file:///tmp/app", "https://name:password@example.test", "https://example.test/path", "https://example.test?token=x"] {
            do { _ = try T3ShellOrigin(URL(string: bad)!); throw NSError(domain: "accepted unsafe origin", code: 1) }
            catch T3ShellError.invalidOrigin {} // A different error fails the test.
        }
        let canonical = try T3ShellOrigin(URL(string: "https://EXAMPLE.test:443/")!)
        try require(canonical.url.absoluteString == "https://example.test", "injected origin matches browser normalization")
        try require(origin.contains(URL(string: "http://127.0.0.1:28471/settings")!), "same origin is accepted")
        try require(!origin.contains(URL(string: "http://127.0.0.1:28472/settings")!), "alternate loopback port is not trusted")
        try require(origin.matchesSecurityOrigin(scheme: "http", host: "127.0.0.1", port: 28471), "WebKit security origin agrees with document origin")
        try require(!origin.matchesSecurityOrigin(scheme: "http", host: "127.0.0.1", port: 0), "default-port origin cannot claim a nondefault-port bridge")
        for path in ["/", "/settings/providers", "/draft/a", "/env/thread", "/projects/x"] {
            try require(origin.isAppDocument(origin.endpoint(path)), "T3 app route should load: \(path)")
        }
        for path in ["/api/assets/file", "/api/x", "/assets/a.html", "/.well-known/t3/environment", "/oauth/token", "/settings/evil"] {
            try require(!origin.isAppDocument(origin.endpoint(path)), "file/API must not become bridge-enabled document: \(path)")
        }
        let preview = origin.endpoint("api/assets/preview")
        try require(origin.permitsFrameResponse(url: preview, mimeType: "text/html", contentSecurityPolicy: "sandbox allow-scripts allow-forms"), "upstream opaque sandbox HTML preview works")
        try require(!origin.permitsFrameResponse(url: preview, mimeType: "text/html", contentSecurityPolicy: nil), "an HTML response to a .pdf URL remains untrusted")
        try require(!origin.permitsFrameResponse(url: preview, mimeType: "text/html", contentSecurityPolicy: "sandbox allow-scripts allow-same-origin"), "same-origin sandbox cannot access bridge")
        try require(origin.permitsFrameResponse(url: preview, mimeType: "application/pdf", contentSecurityPolicy: nil), "real PDF preview works")
        try require(!origin.permitsFrameResponse(url: URL(string: "http://127.0.0.1:28472/preview")!, mimeType: "text/html", contentSecurityPolicy: "sandbox"), "external frame refused")
        let rules = try JSONSerialization.jsonObject(with: Data(origin.cookieRulesJSON().utf8)) as! [[String: Any]]
        let pattern = (rules[1]["trigger"] as! [String: String])["url-filter"]!
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ input: String) -> Bool { regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil }
        try require(matches("http://127.0.0.1:28471/api/auth/session") && matches("ws://127.0.0.1:28471/"), "HTTP and WS cookies only for exact origin")
        try require(!matches("http://127.0.0.1:28472/") && !matches("http://127.0.0.1:284710/") && !matches("http://127.0.0.1:28471.evil.test/"), "cookie exception has strict origin boundary")
        var binding = ShellComposerBinding()
        let target = ShellComposerTarget(environmentId: "e", kind: .thread, id: "t", composerId: "mounted-a")
        try require(binding.publish(target, documentId: binding.documentId), "publish current composer")
        let frozen = binding.freeze()!
        let other = ShellComposerTarget(environmentId: "e", kind: .thread, id: "other", composerId: "mounted-b")
        _ = binding.publish(other, documentId: binding.documentId)
        try require(!binding.matches(frozen), "thread navigation never retargets delayed dictation")
        binding.invalidate()
        try require(!binding.publish(target, documentId: frozen.documentId), "old renderer target cannot claim new document")
        _ = binding.publish(target, documentId: binding.documentId)
        try require(!binding.matches(frozen), "same thread after renderer restart is a new destination")
        let input = ShellInput(deliveryId: "one", destination: binding.freeze()!, text: "kept", captureIds: [])
        let roundtrip = try ShellWire.decode(ShellInput.self, ShellWire.object(input))
        try require(roundtrip == input, "frozen delivery roundtrips through actual wire serializer")
        for mutation in ["valid", "wrong-environment", "not-http-only", "wrong-domain", "missing-cookie", "wrong-method", "redirect", "denied"] {
            AuthFixture.mutation = mutation
            AuthFixture.paths = []
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AuthFixture.self]
            let auth = T3BrowserAuthentication(origin: origin, environmentId: "expected", configuration: config)
            defer { auth.shutdown() }
            do {
                let session = try await auth.exchange(credential: "synthetic-bootstrap")
                try require(mutation == "valid", "malformed auth result rejected: \(mutation)")
                try require(session.scopes == ["orchestration:read"], "granted scopes preserved without expansion")
                await session.install { cookie in
                    assert(cookie.isHTTPOnly && cookie.name == "t3_session_28471" && cookie.path == "/")
                }
            } catch let error as T3ShellError {
                try require(mutation != "valid", "valid upstream cookie bootstrap succeeds: \(error.localizedDescription)")
            }
            if mutation == "wrong-environment" { try require(AuthFixture.paths.count == 1, "credential not disclosed to wrong environment identity") }
            try require(!AuthFixture.paths.contains("/leak"), "credential redirect is never followed")
        }
        let script = try VoiceFlowShellScript.source(origin: origin)
        if let path = ProcessInfo.processInfo.environment["SHELL_TEST_SCRIPT_OUTPUT"] { try Data(script.utf8).write(to: URL(fileURLWithPath: path)) }
        print("ok - T3 shell origin, cookie bootstrap, preview policy, frozen target and wire contract")
    }
}
