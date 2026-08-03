import Foundation
import Darwin
import Security

/// Where the agent's network traffic actually leaves (ticket VF-59).
///
/// The sandbox denies the runtime every non-loopback connection, so this proxy
/// is the only route out. Well-behaved clients find it by themselves —
/// `HTTPS_PROXY` / `HTTP_PROXY` are already on the runtime's environment
/// allowlist, and curl, git, pip, OpenCode's fetch and MCP's HTTP client all
/// honour them. Anything that ignores the proxy (which is what injected code
/// would do) hits EPERM at the socket instead.
///
/// It reads the destination host from the CONNECT line and stops there — no
/// certificate interception, no payload inspection. Knowing *where* data went
/// is what makes exfiltration visible; reading it is not ours to do.
struct EgressProxyConnection: Equatable {
    let host: String
    let port: UInt16
    /// The value `HTTPS_PROXY` / `HTTP_PROXY` are set to.
    var proxyURL: String { "http://\(host):\(port)" }
}

struct EgressDecision: Equatable {
    let allowed: Bool
    let reason: String
}

/// Host policy. An empty allowlist means log-everything-allow-everything: the
/// user sees every destination without being blocked, which is the useful
/// default when the real control is that secrets are unreadable.
struct EgressPolicy: Equatable {
    var allowedHosts: [String] = []
    var blockedHosts: [String] = []

    func decide(host: String) -> EgressDecision {
        let target = host.lowercased()
        if blockedHosts.contains(where: { Self.matches(target, rule: $0) }) {
            return EgressDecision(allowed: false, reason: "blocked")
        }
        guard !allowedHosts.isEmpty else {
            return EgressDecision(allowed: true, reason: "log-only")
        }
        let permitted = allowedHosts.contains { Self.matches(target, rule: $0) }
        return EgressDecision(allowed: permitted,
                              reason: permitted ? "allowlisted" : "not-allowlisted")
    }

    /// Suffix match on label boundaries, so `notion.com` covers
    /// `api.notion.com` but never `evil-notion.com`.
    static func matches(_ host: String, rule: String) -> Bool {
        let rule = rule.lowercased().trimmingCharacters(in: .whitespaces)
        guard !rule.isEmpty else { return false }
        if rule == "*" { return true }
        return host == rule || host.hasSuffix("." + rule)
    }
}

final class EgressLog {
    private let url: URL
    private let lock = NSLock()
    private static let maxBytes = 1_024 * 1_024

    init(url: URL = VoiceFlowPaths.shared.file("agent-egress.jsonl")) {
        self.url = url
    }

    func record(host: String, port: UInt16, method: String, decision: EgressDecision) {
        lock.withLock {
            let entry: [String: Any] = [
                "time": ISO8601DateFormatter().string(from: Date()),
                "host": host, "port": Int(port), "method": method,
                "allowed": decision.allowed, "reason": decision.reason,
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: entry, options: [.sortedKeys]) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            // Truncation keeps the newest half; an unbounded log on a daily
            // driver is a slow disk leak.
            if let size = try? FileManager.default.attributesOfItem(
                atPath: url.path)[.size] as? Int, size > Self.maxBytes,
               let existing = try? Data(contentsOf: url) {
                try? existing.suffix(Self.maxBytes / 2).write(to: url, options: .atomic)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }
}

enum EgressProxyError: LocalizedError {
    case socket(String)

    var errorDescription: String? {
        switch self {
        case .socket(let detail): return "Egress proxy could not start: \(detail)"
        }
    }
}

final class EgressProxyServer {
    private static let maxHeaderBytes = 32 * 1_024

    private let policy: () -> EgressPolicy
    private let log: EgressLog
    private let queue = DispatchQueue(label: "voiceflow.egress-proxy", qos: .userInitiated)
    private let clients = DispatchQueue(
        label: "voiceflow.egress-proxy.clients", qos: .userInitiated, attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private(set) var connection: EgressProxyConnection?

    init(policy: @escaping () -> EgressPolicy = { EgressPolicy() },
         log: EgressLog = EgressLog()) {
        self.policy = policy
        self.log = log
    }

    func start() throws -> EgressProxyConnection {
        if let connection { return connection }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EgressProxyError.socket(String(cString: strerror(errno))) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 32) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw EgressProxyError.socket(message)
        }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw EgressProxyError.socket(String(cString: strerror(errno)))
        }
        let value = EgressProxyConnection(
            host: "127.0.0.1", port: UInt16(bigEndian: resolved.sin_port))
        listenFD = fd
        connection = value
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptNext() }
        source.setCancelHandler { [weak self] in
            Darwin.close(fd)
            if self?.listenFD == fd { self?.listenFD = -1 }
        }
        self.source = source
        source.resume()
        return value
    }

    func stop() {
        connection = nil
        source?.cancel()
        source = nil
    }

    private func acceptNext() {
        var address = sockaddr()
        var length = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFD = Darwin.accept(listenFD, &address, &length)
        guard clientFD >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                   socklen_t(MemoryLayout<Int32>.size))
        clients.async { [weak self] in
            guard let self else { Darwin.close(clientFD); return }
            self.handleClient(clientFD)
            Darwin.shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        guard let head = Self.readHead(fd) else { return }
        let parts = head.requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            Self.write(fd, Self.response(502, "malformed proxy request"))
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])

        // CONNECT host:port — the HTTPS path, and effectively all API traffic.
        // Plain HTTP arrives in absolute form (GET http://host/path) instead.
        let destination: (host: String, port: UInt16)?
        if method == "CONNECT" {
            destination = Self.splitAuthority(target, defaultPort: 443)
        } else if let range = target.range(of: "://") {
            let rest = target[range.upperBound...]
            let authority = rest.prefix(while: { $0 != "/" })
            destination = Self.splitAuthority(String(authority), defaultPort: 80)
        } else {
            destination = nil
        }
        guard let destination else {
            Self.write(fd, Self.response(502, "proxy requires an absolute target"))
            return
        }

        let decision = policy().decide(host: destination.host)
        log.record(host: destination.host, port: destination.port,
                   method: method, decision: decision)
        guard decision.allowed else {
            Self.write(fd, Self.response(
                403, "Voice Flow blocked egress to \(destination.host)"))
            return
        }
        guard let upstream = Self.connect(host: destination.host, port: destination.port) else {
            Self.write(fd, Self.response(502, "could not reach \(destination.host)"))
            return
        }
        defer { Darwin.shutdown(upstream, SHUT_RDWR); Darwin.close(upstream) }

        if method == "CONNECT" {
            guard Self.write(fd, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else { return }
        } else {
            // Rewrite absolute-form to origin-form, which is what an origin
            // server expects, then replay the headers we already consumed.
            var line = head.requestLine
            if let schemeRange = line.range(of: "://"),
               let pathStart = line[schemeRange.upperBound...].firstIndex(of: "/") {
                let methodPart = line[line.startIndex..<line.firstIndex(of: " ")!]
                let remainder = line[pathStart...]
                line = "\(methodPart) \(remainder)"
            }
            var rebuilt = Data("\(line)\r\n".utf8)
            rebuilt.append(head.headerBlock)
            rebuilt.append(Data("\r\n".utf8))
            rebuilt.append(head.overflow)
            guard Self.write(upstream, rebuilt) else { return }
        }
        Self.pump(a: fd, b: upstream)
    }

    // MARK: - transport

    private struct Head {
        let requestLine: String
        /// Raw header lines, CRLF-terminated, without the blank separator.
        let headerBlock: Data
        /// Bytes already read past the header terminator.
        let overflow: Data
    }

    private static func readHead(_ fd: Int32) -> Head? {
        var buffer = Data()
        var terminator: Range<Data.Index>?
        while terminator == nil && buffer.count <= maxHeaderBytes {
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes.prefix(count))
            terminator = buffer.range(of: Data("\r\n\r\n".utf8))
        }
        guard let terminator,
              let text = String(data: buffer[..<terminator.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let headerText = lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
        return Head(requestLine: requestLine,
                    headerBlock: Data(headerText.utf8),
                    overflow: Data(buffer[terminator.upperBound...]))
    }

    static func splitAuthority(_ value: String, defaultPort: UInt16) -> (String, UInt16)? {
        guard !value.isEmpty else { return nil }
        // IPv6 literals arrive bracketed: [::1]:443
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            let port = rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? defaultPort : defaultPort
            return host.isEmpty ? nil : (host, port)
        }
        let pieces = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(pieces[0])
        guard !host.isEmpty else { return nil }
        let port = pieces.count > 1 ? (UInt16(pieces[1]) ?? defaultPort) : defaultPort
        return (host, port)
    }

    private static func connect(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let head = result else {
            return nil
        }
        defer { freeaddrinfo(head) }
        var candidate: UnsafeMutablePointer<addrinfo>? = head
        while let entry = candidate {
            let fd = socket(entry.pointee.ai_family, entry.pointee.ai_socktype,
                            entry.pointee.ai_protocol)
            if fd >= 0 {
                var noSigPipe: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                           socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 20, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                           socklen_t(MemoryLayout<timeval>.size))
                if Darwin.connect(fd, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0 {
                    return fd
                }
                Darwin.close(fd)
            }
            candidate = entry.pointee.ai_next
        }
        return nil
    }

    /// Streams both directions until either side closes.
    private static func pump(a: Int32, b: Int32) {
        let group = DispatchGroup()
        for (from, to) in [(a, b), (b, a)] {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = Darwin.recv(from, &bytes, bytes.count, 0)
                    guard count > 0 else { break }
                    if !write(to, Data(bytes.prefix(count))) { break }
                }
                // Half-close so the peer's pump observes EOF and finishes.
                Darwin.shutdown(to, SHUT_WR)
            }
        }
        group.wait()
    }

    @discardableResult
    private static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if count <= 0 { return false }
                sent += count
            }
            return true
        }
    }

    private static func response(_ status: Int, _ message: String) -> Data {
        let body = Data(message.utf8)
        let header = """
        HTTP/1.1 \(status) \(status == 403 ? "Forbidden" : "Bad Gateway")\r
        Content-Type: text/plain\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        return Data(header.utf8) + body
    }
}
