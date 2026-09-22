import Foundation

/// Uses T3's supported browser cookie bootstrap. Never logs/serializes the
/// credential, shares URLSession cookie storage, or follows a redirect with it.
final class T3BrowserAuthentication: NSObject, URLSessionTaskDelegate {
    struct Session {
        fileprivate let cookie: HTTPCookie
        let expiresAt: Date
        let scopes: [String]

        func install(_ setCookie: (HTTPCookie) async -> Void) async {
            await setCookie(cookie)
        }
    }

    private let origin: T3ShellOrigin
    private let environmentId: String
    private var session: URLSession!

    init(origin: T3ShellOrigin, environmentId: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.origin = origin
        self.environmentId = environmentId
        super.init()
        // Copy even caller-provided configurations: tests can supply URLProtocol,
        // but no caller may accidentally enable ambient cookies or disk caching.
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// The app owns this object and calls shutdown when its environment handle
    /// is retired. Hiding the window does not retire that handle or its cookie.
    func shutdown() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func exchange(credential: String) async throws -> Session {
        guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credential.utf8.count <= 32_768 else { throw T3ShellError.refusedCredentials }
        let (descriptor, _) = try await request(path: ".well-known/t3/environment")
        guard descriptor["environmentId"] as? String == environmentId else { throw T3ShellError.wrongEnvironment }
        let (state, _) = try await request(path: "api/auth/session")
        guard let auth = state["auth"] as? [String: Any],
              let cookieName = auth["sessionCookieName"] as? String, !cookieName.isEmpty,
              (auth["sessionMethods"] as? [String])?.contains("browser-session-cookie") == true else {
            throw T3ShellError.invalidResponse
        }
        let (result, response) = try await request(path: "api/auth/browser-session", body: ["credential": credential])
        guard result["authenticated"] as? Bool == true,
              result["sessionMethod"] as? String == "browser-session-cookie",
              let expiration = result["expiresAt"] as? String,
              let expiresAt = Self.date(expiration), expiresAt > Date(),
              let scopes = result["scopes"] as? [String] else { throw T3ShellError.invalidResponse }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { output, entry in
            if let key = entry.key as? String { output[key] = String(describing: entry.value) }
        }
        // The official endpoint sets a host-only cookie. Reject Domain= rather
        // than trusting Foundation to preserve its host/subdomain distinction.
        guard let setCookie = response.value(forHTTPHeaderField: "Set-Cookie"),
              setCookie.range(of: "(?:^|;)\\s*domain\\s*=", options: [.regularExpression, .caseInsensitive]) == nil else {
            throw T3ShellError.invalidResponse
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: origin.url)
        guard let cookie = cookies.first(where: { $0.name == cookieName }),
              cookie.isHTTPOnly, cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == origin.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              cookie.path == "/", !cookie.value.isEmpty,
              let cookieExpiration = cookie.expiresDate, cookieExpiration > Date(),
              abs(cookieExpiration.timeIntervalSince(expiresAt)) < 2 else {
            throw T3ShellError.invalidResponse
        }
        // T3's current response omits Secure even on TLS. Narrow the local copy
        // before handing it to WebKit; never broaden a Domain cookie.
        guard var properties = cookie.properties else { throw T3ShellError.invalidResponse }
        properties[.secure] = origin.scheme == "https" ? "TRUE" : "FALSE"
        guard let narrowed = HTTPCookie(properties: properties) else { throw T3ShellError.invalidResponse }
        return Session(cookie: narrowed, expiresAt: expiresAt, scopes: scopes)
    }

    private func request(path: String, body: [String: String]? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        var request = URLRequest(url: origin.endpoint(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VoiceFlowNativeShell/1 (Macintosh; macOS)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let raw: URLResponse
        do { (data, raw) = try await session.data(for: request) }
        catch { throw T3ShellError.unavailable }
        guard let response = raw as? HTTPURLResponse,
              response.url.map(origin.contains) == true else { throw T3ShellError.invalidResponse }
        if [401, 403].contains(response.statusCode) { throw T3ShellError.refusedCredentials }
        guard response.statusCode == 200, data.count <= 65_536,
              response.mimeType == "application/json",
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw T3ShellError.invalidResponse
        }
        return (result, response)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
