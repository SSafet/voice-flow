import Foundation
import Darwin
import Security

struct AgentToolServerConnection {
    let endpoint: URL
    let token: String
}

enum AgentToolServerError: LocalizedError {
    case socket(String)
    case credential

    var errorDescription: String? {
        switch self {
        case .socket(let detail): return "Agent tool server could not start: \(detail)"
        case .credential: return "Agent tool server could not create a capability token."
        }
    }
}

/// Private embedded-runtime capability endpoint. It is deliberately separate
/// from public MCP: calls here never create MCP sessions, picker slots, pushes,
/// or external overlay ownership.
final class AgentToolServer {
    private static let maxRequestBytes = 96 * 1_024
    private let queue = DispatchQueue(label: "voiceflow.agent-tools", qos: .userInitiated)
    private let clients = DispatchQueue(
        label: "voiceflow.agent-tools.clients", qos: .userInitiated, attributes: .concurrent)
    private let audit: AgentSecurityAudit
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private(set) var connection: AgentToolServerConnection?

    init(audit: AgentSecurityAudit = AgentSecurityAudit()) {
        self.audit = audit
    }

    func start() throws -> AgentToolServerConnection {
        if let connection { return connection }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentToolServerError.socket(String(cString: strerror(errno))) }
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
            let detail = String(cString: strerror(errno))
            Darwin.close(fd)
            throw AgentToolServerError.socket(detail)
        }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &resolved, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }) == 0 else {
            Darwin.close(fd)
            throw AgentToolServerError.socket(String(cString: strerror(errno)))
        }
        let token = try Self.randomSecret()
        let port = UInt16(bigEndian: resolved.sin_port)
        let value = AgentToolServerConnection(
            endpoint: URL(string: "http://127.0.0.1:\(port)/internal/tools")!,
            token: token)
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
        let fd = Darwin.accept(listenFD, &address, &length)
        guard fd >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                   socklen_t(MemoryLayout<Int32>.size))
        clients.async { [weak self] in
            guard let self else { Darwin.close(fd); return }
            Task {
                await self.handle(fd)
                Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
        }
    }

    private func handle(_ fd: Int32) async {
        guard let request = Self.readRequest(fd) else {
            Self.writeError(fd, status: 400, code: "invalid_request", message: "Malformed request.")
            return
        }
        guard request.path == "/internal/tools", request.method == "POST" else {
            Self.writeError(fd, status: 404, code: "not_found", message: "Unknown private route.")
            return
        }
        guard let active = connection?.token,
              let supplied = request.authorization,
              Self.constantTimeEqual(supplied, active) else {
            Self.writeError(fd, status: 401, code: "invalid_capability", message: "Invalid tool capability.")
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let tool = object["tool"] as? String,
              let arguments = object["arguments"] as? [String: Any],
              let runtimeSessionID = object["session_id"] as? String,
              let runtimeMessageID = object["message_id"] as? String,
              let directoryText = object["directory"] as? String,
              NSString(string: directoryText).isAbsolutePath else {
            Self.writeError(fd, status: 400, code: "invalid_arguments", message: "Tool envelope is incomplete.")
            return
        }
        do {
            let session = try AgentToolSessionRegistry.shared.authorize(
                runtimeSessionID: runtimeSessionID,
                runtimeMessageID: runtimeMessageID,
                directory: URL(fileURLWithPath: directoryText))
            let output = try await AgentToolDispatcher.execute(
                tool: tool, arguments: arguments, session: session)
            audit.append(
                conversationID: session.conversationID,
                runID: session.runID.uuidString,
                action: tool, decision: .allow,
                detail: "runtime_session=\(runtimeSessionID)")
            Self.write(fd, status: 200, body: Data(output.json().utf8))
        } catch let error as AgentToolError {
            let status: Int
            switch error {
            case .unauthorized: status = 403
            case .invalidArguments, .unknownTool: status = 400
            case .denied: status = 403
            case .unavailable: status = 503
            }
            audit.append(
                conversationID: "rejected", runID: runtimeMessageID,
                action: tool, decision: .deny,
                detail: error.localizedDescription)
            Self.writeError(
                fd, status: status, code: "tool_\(status)",
                message: error.localizedDescription)
        } catch {
            Self.writeError(
                fd, status: 500, code: "tool_failed",
                message: AgentSecretPolicy.redacted(error.localizedDescription))
        }
    }

    private struct Request {
        let method: String
        let path: String
        let authorization: String?
        let body: Data
    }

    private static func readRequest(_ fd: Int32) -> Request? {
        var buffer = Data()
        var marker: Range<Data.Index>?
        while marker == nil, buffer.count <= maxRequestBytes {
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes.prefix(count))
            marker = buffer.range(of: Data("\r\n\r\n".utf8))
        }
        guard let marker,
              let headers = String(data: buffer[..<marker.lowerBound], encoding: .utf8) else { return nil }
        let lines = headers.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            values[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard let lengthText = values["content-length"],
              let length = Int(lengthText), length >= 0,
              length <= maxRequestBytes else { return nil }
        var body = Data(buffer[marker.upperBound...])
        while body.count < length {
            var bytes = [UInt8](repeating: 0, count: min(8_192, length - body.count))
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { return nil }
            body.append(contentsOf: bytes.prefix(count))
        }
        let auth = values["authorization"].flatMap { value -> String? in
            guard value.hasPrefix("Bearer ") else { return nil }
            return String(value.dropFirst(7))
        }
        return Request(
            method: String(requestLine[0]), path: String(requestLine[1]),
            authorization: auth, body: Data(body.prefix(length)))
    }

    private static func writeError(_ fd: Int32, status: Int, code: String, message: String) {
        let data = (try? JSONSerialization.data(withJSONObject: [
            "ok": false, "code": code,
            "message": String(AgentSecretPolicy.redacted(message).prefix(2_048)),
        ], options: [.sortedKeys])) ?? Data("{}".utf8)
        write(fd, status: status, body: data)
    }

    private static func write(_ fd: Int32, status: Int, body: Data) {
        let reason = status == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        _ = writeAll(fd, Data(header.utf8) + body)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        for index in 0..<max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0)
                ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }

    private static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AgentToolServerError.credential
        }
        return Data(bytes).base64EncodedString()
    }
}
