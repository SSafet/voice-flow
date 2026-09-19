import Foundation

/// Waits until both loopback addresses accept a connection.
public func waitForListeners(port: Int, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if RawHTTP.accepts(address: "127.0.0.1", port: port), RawHTTP.accepts(address: "::1", port: port) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}

/// The checks that need no web view.
public func nativeChecks(port: Int, secret: String) -> [ProofRow] {
    var rows: [ProofRow] = []

    func row(_ name: String, _ passed: Bool, _ detail: String) {
        rows.append(ProofRow(kind: .check, name: name, passed: passed, detail: detail))
    }

    func status(address: String, request: String) -> (Int?, String) {
        do {
            let reply = try RawHTTP.send(address: address, port: port, request: request)
            return (reply.status, "\(reply.status)")
        } catch {
            return (nil, "\(error)")
        }
    }

    let goodHost = "Host: localhost:\(port)\r\n"
    let ourServerName = proofServerName()

    /// A status code alone would pass against whatever happens to hold the port,
    /// and these two checks are the ones that say the proof's own listeners are up.
    /// So the answer has to carry the `Server` header that names *this* process
    /// before its 200 counts; otherwise both listeners could be dead and the table
    /// would still say they answered.
    func answersOnLoopback(address: String) -> (Bool, String) {
        do {
            let reply = try RawHTTP.send(
                address: address,
                port: port,
                request: "GET / HTTP/1.1\r\n\(goodHost)Connection: close\r\n\r\n"
            )
            guard reply.raw.lowercased().contains("\r\nserver: \(ourServerName.lowercased())\r\n") else {
                return (false, "\(reply.status), but from another server: this program answers with "
                        + "\"Server: \(ourServerName)\" and that answer did not")
            }
            return (reply.status == 200, "\(reply.status)")
        } catch {
            return (false, "\(error)")
        }
    }

    let (v4, v4Detail) = answersOnLoopback(address: "127.0.0.1")
    row("listens_on_127_0_0_1", v4, "GET / over 127.0.0.1: \(v4Detail)")

    let (v6, v6Detail) = answersOnLoopback(address: "::1")
    row("listens_on_ipv6_loopback", v6, "GET / over [::1]: \(v6Detail)")

    let (withSecret, withSecretDetail) = status(
        address: "127.0.0.1",
        request: "GET /probe/guarded HTTP/1.1\r\n\(goodHost)x-loopback-secret: \(secret)\r\nConnection: close\r\n\r\n"
    )
    row("guarded_path_with_secret_accepted", withSecret == 200, "GET /probe/guarded with the header: \(withSecretDetail)")

    let (noSecret, noSecretDetail) = status(
        address: "127.0.0.1",
        request: "GET /probe/guarded HTTP/1.1\r\n\(goodHost)Connection: close\r\n\r\n"
    )
    row("guarded_path_without_secret_refused", noSecret == 401, "GET /probe/guarded without the header: \(noSecretDetail)")

    let (foreignOrigin, foreignOriginDetail) = status(
        address: "127.0.0.1",
        request: "GET /probe/guarded HTTP/1.1\r\n\(goodHost)Origin: http://evil.example\r\nx-loopback-secret: \(secret)\r\nConnection: close\r\n\r\n"
    )
    row("foreign_origin_refused", foreignOrigin == 403,
        "GET /probe/guarded with Origin: http://evil.example and the right secret: \(foreignOriginDetail)")

    let (wrongHost, wrongHostDetail) = status(
        address: "127.0.0.1",
        request: "GET /probe/guarded HTTP/1.1\r\nHost: evil.example\r\nx-loopback-secret: \(secret)\r\nConnection: close\r\n\r\n"
    )
    row("wrong_host_refused", wrongHost == 403, "GET /probe/guarded with Host: evil.example: \(wrongHostDetail)")

    let (preflight, preflightDetail) = status(
        address: "127.0.0.1",
        request: "OPTIONS /probe/guarded HTTP/1.1\r\n\(goodHost)Origin: http://evil.example\r\n"
            + "Access-Control-Request-Method: GET\r\nAccess-Control-Request-Headers: x-loopback-secret\r\nConnection: close\r\n\r\n"
    )
    /// Not "any status at or above 400": a server with no guard and no such path
    /// answers this request `404`, and a check that passes on that passes when the
    /// thing it tests is absent, which the Global Constraints forbid. The refusal
    /// this row is about is the one `HostOriginGuard` makes on a foreign `Origin`,
    /// and that refusal is a `403`.
    let preflightRefused = preflight == 403
    row("foreign_preflight_refused", preflightRefused,
        "OPTIONS /probe/guarded from http://evil.example: \(preflightDetail)")

    return rows
}
