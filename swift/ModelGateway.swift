import Foundation
import Darwin
import Security

struct ModelGatewayCredentialSnapshot {
    let apiKey: String?
    let upstreamBaseURL: URL
    let allowedModels: Set<String>
    let modelOutputTokenLimits: [String: Int]
    let fallbackMaxOutputTokens: Int
    let requestTimeout: TimeInterval
    let dailyBudgetUSD: Double?
    let estimatedRequestCostUSD: Double

    init(apiKey: String?, upstreamBaseURL: URL, allowedModels: Set<String>,
         modelOutputTokenLimits: [String: Int] = [:],
         fallbackMaxOutputTokens: Int = 32_000,
         requestTimeout: TimeInterval = 600,
         dailyBudgetUSD: Double? = 5.0,
         estimatedRequestCostUSD: Double = 0.25) {
        self.apiKey = apiKey
        self.upstreamBaseURL = upstreamBaseURL
        self.allowedModels = allowedModels
        self.modelOutputTokenLimits = modelOutputTokenLimits.mapValues {
            min(max($0, 256), 128_000)
        }
        self.fallbackMaxOutputTokens = min(max(fallbackMaxOutputTokens, 256), 128_000)
        self.requestTimeout = min(max(requestTimeout, 5), 3_600)
        self.dailyBudgetUSD = dailyBudgetUSD.map { min(max($0, 0), 10_000) }
        self.estimatedRequestCostUSD = min(max(estimatedRequestCostUSD, 0), 100)
    }
}

final class ModelGatewayUsageReporter {
    static let shared = ModelGatewayUsageReporter()
    private let lock = NSLock()
    private var handler: ((AgentUsage) -> Void)?
    func configure(_ value: ((AgentUsage) -> Void)?) { lock.withLock { handler = value } }
    func report(_ usage: AgentUsage) { lock.withLock { handler }?(usage) }
}

private final class ModelGatewayBudgetLedger {
    private let lock = NSLock()
    private let url: URL
    init(url: URL = VoiceFlowPaths.shared.file("agent-model-budget.json")) { self.url = url }

    func reserve(limit: Double?, estimate: Double, now: Date = Date()) -> Bool {
        guard let limit, limit > 0 else { return true }
        return lock.withLock {
            var state = load(now: now)
            guard state.cost + estimate <= limit else { return false }
            state.cost += estimate
            save(state)
            return true
        }
    }

    func settle(estimate: Double, actual: Double?, now: Date = Date()) {
        guard let actual else { return }
        lock.withLock {
            var state = load(now: now)
            state.cost = max(0, state.cost - estimate + max(0, actual))
            save(state)
        }
    }

    private struct State: Codable { var day: String; var cost: Double }
    private func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func load(now: Date) -> State {
        let today = day(now)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data),
              state.day == today else { return State(day: today, cost: 0) }
        return state
    }
    private func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Decouples the runtime process layer from Keychain/UserSettings so its
/// process and transport contracts remain testable without the full app.
final class ModelGatewayCredentials {
    static let shared = ModelGatewayCredentials()
    private let lock = NSLock()
    private var provider: () -> ModelGatewayCredentialSnapshot = {
        ModelGatewayCredentialSnapshot(
            apiKey: nil,
            upstreamBaseURL: URL(string: "https://openrouter.ai/api/v1")!,
            allowedModels: [])
    }

    func configure(_ provider: @escaping () -> ModelGatewayCredentialSnapshot) {
        lock.withLock { self.provider = provider }
    }

    func snapshot() -> ModelGatewayCredentialSnapshot {
        lock.withLock { provider() }
    }
}

struct ModelGatewayConnection {
    let baseURL: URL
    let token: String
}

enum ModelGatewayError: LocalizedError {
    case socket(String)
    case credentialGeneration

    var errorDescription: String? {
        switch self {
        case .socket(let detail): return "Model gateway could not start: \(detail)"
        case .credentialGeneration: return "Model gateway could not generate a process credential."
        }
    }
}

/// A loopback-only, token-protected streaming reverse proxy. OpenCode knows
/// only this revocable token; the long-lived provider key is read just in time
/// and replaced on the outbound request without ever entering runtime config.
final class ModelGatewayServer {
    private static let maxHeaderBytes = 64 * 1_024
    private static let maxBodyBytes = 5 * 1_024 * 1_024

    private let credentials: () -> ModelGatewayCredentialSnapshot
    private let queue = DispatchQueue(label: "voiceflow.model-gateway", qos: .userInitiated)
    private let clients = DispatchQueue(
        label: "voiceflow.model-gateway.clients", qos: .userInitiated, attributes: .concurrent)
    private let admission = DispatchSemaphore(value: 3)
    private let budget = ModelGatewayBudgetLedger()
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private(set) var connection: ModelGatewayConnection?

    init(credentials: @escaping () -> ModelGatewayCredentialSnapshot = {
        ModelGatewayCredentials.shared.snapshot()
    }) {
        self.credentials = credentials
    }

    func start() throws -> ModelGatewayConnection {
        if let connection { return connection }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ModelGatewayError.socket(String(cString: strerror(errno))) }
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
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ModelGatewayError.socket(message)
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
            throw ModelGatewayError.socket(String(cString: strerror(errno)))
        }
        let token = try Self.randomSecret()
        let port = UInt16(bigEndian: resolved.sin_port)
        let value = ModelGatewayConnection(
            baseURL: URL(string: "http://127.0.0.1:\(port)/v1")!, token: token)
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
        connection = nil  // revokes the only accepted bearer immediately
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
            Task {
                await self.handleClient(clientFD)
                Darwin.shutdown(clientFD, SHUT_RDWR)
                Darwin.close(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) async {
        guard let request = Self.readRequest(fd) else {
            Self.writeJSON(fd, status: 400, message: "invalid request")
            return
        }
        guard request.method == "POST", request.path.hasSuffix("/chat/completions") else {
            Self.writeJSON(fd, status: 404, message: "unsupported model gateway route")
            return
        }
        guard let activeToken = connection?.token,
              let supplied = request.headers["authorization"]?.dropPrefix("Bearer "),
              Self.constantTimeEqual(String(supplied), activeToken) else {
            Self.writeJSON(fd, status: 401, message: "invalid model gateway capability")
            return
        }
        let snapshot = credentials()
        guard let apiKey = snapshot.apiKey, !apiKey.isEmpty else {
            Self.writeJSON(fd, status: 503, message: "OpenRouter key is not configured in Voice Flow")
            return
        }
        guard var json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let model = json["model"] as? String, !model.isEmpty else {
            Self.writeJSON(fd, status: 400, message: "request model is missing")
            return
        }
        if !snapshot.allowedModels.isEmpty, !snapshot.allowedModels.contains(model) {
            Self.writeJSON(fd, status: 403, message: "model is not allowed by Voice Flow")
            return
        }
        let estimate = snapshot.estimatedRequestCostUSD
        guard budget.reserve(limit: snapshot.dailyBudgetUSD, estimate: estimate) else {
            Self.writeJSON(fd, status: 429, message: "Voice Flow daily model budget reached")
            return
        }
        var reservationSettled = false
        defer {
            if !reservationSettled {
                // Keep the conservative reservation after an interrupted or
                // cost-less request. It is the only safe upper bound available.
            }
        }
        guard admission.wait(timeout: .now() + 5) == .success else {
            budget.settle(estimate: estimate, actual: 0)
            reservationSettled = true
            Self.writeJSON(fd, status: 429, message: "Voice Flow model concurrency limit reached")
            return
        }
        defer { admission.signal() }

        let modelMax = snapshot.modelOutputTokenLimits[model]
            ?? snapshot.fallbackMaxOutputTokens
        let existingMax = (json["max_tokens"] as? NSNumber)?.intValue
            ?? (json["max_completion_tokens"] as? NSNumber)?.intValue
            ?? modelMax
        json["max_tokens"] = min(max(1, existingMax), modelMax)
        json.removeValue(forKey: "max_completion_tokens")
        guard let forwardBody = try? JSONSerialization.data(withJSONObject: json) else {
            budget.settle(estimate: estimate, actual: 0)
            reservationSettled = true
            Self.writeJSON(fd, status: 400, message: "request body could not be normalized")
            return
        }

        let endpoint = snapshot.upstreamBaseURL
            .appendingPathComponent("chat/completions")
        var upstream = URLRequest(url: endpoint)
        upstream.httpMethod = "POST"
        upstream.timeoutInterval = snapshot.requestTimeout
        upstream.httpBody = forwardBody
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        upstream.setValue("https://voiceflow.local", forHTTPHeaderField: "HTTP-Referer")
        upstream.setValue("Voice Flow", forHTTPHeaderField: "X-Title")

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: upstream)
            guard let http = response as? HTTPURLResponse else {
                Self.writeJSON(fd, status: 502, message: "provider returned no HTTP response")
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")
                ?? "application/octet-stream"
            guard Self.writeChunkedHeaders(
                fd, status: http.statusCode, contentType: contentType) else { return }
            var chunk = Data()
            var usageCapture = Data()
            chunk.reserveCapacity(8_192)
            for try await byte in bytes {
                chunk.append(byte)
                if usageCapture.count < 1_048_576 { usageCapture.append(byte) }
                if chunk.count >= 8_192 {
                    guard Self.writeChunk(fd, chunk) else { return }
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { _ = Self.writeChunk(fd, chunk) }
            _ = Self.writeAll(fd, Data("0\r\n\r\n".utf8))
            let usage = Self.extractUsage(from: usageCapture)
            let actual = (200..<300).contains(http.statusCode)
                ? usage?.costUSD.map { NSDecimalNumber(decimal: $0).doubleValue }
                : 0
            budget.settle(estimate: estimate, actual: actual)
            reservationSettled = true
            if let usage { ModelGatewayUsageReporter.shared.report(usage) }
        } catch {
            Self.writeJSON(fd, status: 502, message: "provider request failed")
        }
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func readRequest(_ fd: Int32) -> Request? {
        var buffer = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil && buffer.count <= maxHeaderBytes {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes.prefix(count))
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headerEnd,
              let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard let lengthText = headers["content-length"], let contentLength = Int(lengthText),
              contentLength >= 0, contentLength <= maxBodyBytes else { return nil }
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < contentLength {
            var bytes = [UInt8](repeating: 0, count: min(16_384, contentLength - body.count))
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { return nil }
            body.append(contentsOf: bytes.prefix(count))
        }
        if body.count > contentLength { body = Data(body.prefix(contentLength)) }
        return Request(
            method: String(requestLine[0]), path: String(requestLine[1]),
            headers: headers, body: body)
    }

    private static func extractUsage(from data: Data) -> AgentUsage? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var latest: AgentUsage?
        for line in text.components(separatedBy: .newlines) {
            let payload: String
            if line.hasPrefix("data:") {
                payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else {
                payload = line.trimmingCharacters(in: .whitespaces)
            }
            guard payload.hasPrefix("{"),
                  let raw = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let usage = object["usage"] as? [String: Any] else { continue }
            let input = (usage["prompt_tokens"] as? NSNumber)?.intValue
                ?? (usage["input_tokens"] as? NSNumber)?.intValue
            let output = (usage["completion_tokens"] as? NSNumber)?.intValue
                ?? (usage["output_tokens"] as? NSNumber)?.intValue
            let cost = (usage["cost"] as? NSNumber).map {
                Decimal($0.doubleValue)
            }
            latest = AgentUsage(inputTokens: input, outputTokens: output, costUSD: cost)
        }
        return latest
    }

    @discardableResult
    private static func writeChunkedHeaders(_ fd: Int32, status: Int, contentType: String) -> Bool {
        let header = """
        HTTP/1.1 \(status) \(reason(status))\r
        Content-Type: \(contentType)\r
        Transfer-Encoding: chunked\r
        Connection: close\r
        \r

        """
        return writeAll(fd, Data(header.utf8))
    }

    @discardableResult
    private static func writeChunk(_ fd: Int32, _ data: Data) -> Bool {
        var framed = Data(String(data.count, radix: 16).utf8)
        framed.append(Data("\r\n".utf8))
        framed.append(data)
        framed.append(Data("\r\n".utf8))
        return writeAll(fd, framed)
    }

    private static func writeJSON(_ fd: Int32, status: Int, message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "error": ["message": message, "type": "voice_flow_gateway"],
        ])) ?? Data("{}".utf8)
        let header = """
        HTTP/1.1 \(status) \(reason(status))\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        _ = writeAll(fd, Data(header.utf8) + body)
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
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

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Response"
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }

    private static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ModelGatewayError.credentialGeneration
        }
        return Data(bytes).base64EncodedString()
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
    }
}
