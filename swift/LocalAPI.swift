import Foundation
import Darwin
import MCP

struct TTSAPIUpdatePayload: Decodable {
    var text: String?
    var voice: String?
    var speed: Double?
    var instructions: String?
    var position: Double?
    var reveal: Bool?
}

struct LocalAPIResponse {
    let statusCode: Int
    let body: [String: Any]

    static func ok(_ body: [String: Any]) -> LocalAPIResponse {
        LocalAPIResponse(statusCode: 200, body: body)
    }

    static func accepted(_ body: [String: Any]) -> LocalAPIResponse {
        LocalAPIResponse(statusCode: 202, body: body)
    }

    static func error(_ statusCode: Int, _ message: String) -> LocalAPIResponse {
        LocalAPIResponse(statusCode: statusCode, body: ["ok": false, "error": message])
    }
}

private struct LocalHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

final class LocalAPIServer {
    static let host = "127.0.0.1"
    static let port: UInt16 = {
#if VOICE_FLOW_QA
        if let raw = ProcessInfo.processInfo.environment["VOICE_FLOW_QA_PORT"],
           let value = UInt16(raw), value > 0 { return value }
        return 18_792
#else
        return 8_792
#endif
    }()

    var onStatus: (() -> LocalAPIResponse)?
    var onSet: ((TTSAPIUpdatePayload) -> LocalAPIResponse)?
    var onSpeak: ((TTSAPIUpdatePayload) -> LocalAPIResponse)?
    var onSeek: ((TTSAPIUpdatePayload) -> LocalAPIResponse)?
    var onStop: (() -> LocalAPIResponse)?
    /// POST /api/panel/show {"tab": "inbox"|"agents"|"speech"} — open the
    /// ChatPanel for screenshot validation without a human click.
    var onPanelShow: ((String?) -> LocalAPIResponse)?
    /// Loopback-only equivalent of the menu bar's "Pair Phone" — opening the
    /// pair window from the Mac itself IS the consent (used by tests/automation).
    var onPairMode: (() -> LocalAPIResponse)?
    var onServerMessage: ((String) -> Void)?
    /// One SDK-backed JSON MCP route. TTS and other local routes stay unchanged.
    var onMCP: ((String, [String: String], Data) async -> HTTPResponse)?
#if VOICE_FLOW_QA
    var qaToken: String?
    var onQA: ((_ method: String, _ path: String, _ body: Data) -> LocalAPIResponse)?
#endif

    private let queue = DispatchQueue(label: "voiceflow.local-api", qos: .userInitiated)
    // Each connection is served on its own thread so one long-running MCP
    // tool call can't block TTS control or other MCP requests.
    private let clientQueue = DispatchQueue(
        label: "voiceflow.local-api.clients", qos: .userInitiated, attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    var baseURL: String {
        "http://\(Self.host):\(Self.port)"
    }

    func start() {
        guard listenFD == -1 else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            onServerMessage?("Local API failed to create socket.")
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(Self.port).bigEndian
        let hostCString = strdup(Self.host)
        inet_pton(AF_INET, hostCString, &addr.sin_addr)
        free(hostCString)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            onServerMessage?("Local API bind failed: \(message)")
            return
        }

        guard Darwin.listen(fd, SOMAXCONN) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            onServerMessage?("Local API listen failed: \(message)")
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptNextClient()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.listenFD >= 0 else { return }
            Darwin.close(self.listenFD)
            self.listenFD = -1
        }
        acceptSource = source
        source.resume()
        onServerMessage?("Local API ready at \(baseURL)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
    }

    private func acceptNextClient() {
        var addr = sockaddr()
        var addrLen: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFD = Darwin.accept(listenFD, &addr, &addrLen)
        guard clientFD >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        clientQueue.async { [weak self] in
            self?.handleClient(fd: clientFD)
        }
    }

    private func handleClient(fd: Int32) {
        defer {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }

        guard let request = readRequest(from: fd) else {
            writeResponse(LocalAPIResponse.error(400, "Invalid request."), to: fd)
            return
        }

        if request.path == "/mcp" {
            handleMCPRequest(request, fd: fd)
            return
        }

        let response = route(request)
        writeResponse(response, to: fd)
    }

    private func handleMCPRequest(_ request: LocalHTTPRequest, fd: Int32) {
        guard let onMCP else {
            writeRawResponse(status: 503, payload: nil, to: fd)
            return
        }
        // LocalAPI already dedicates a worker to each HTTP connection. Async SDK
        // dispatch yields while a question waits; no app main thread is blocked.
        let done = DispatchSemaphore(value: 0)
        var response: HTTPResponse = .error(statusCode: 503, .internalError("App unavailable"))
        let operation = Task {
            response = await onMCP(request.method, request.headers, request.body)
            done.signal()
        }
        // A disconnected/refreshed client cannot leave a question or inbox
        // listener parked for hours. This observes only this MCP connection.
        let disconnect = DispatchSource.makeReadSource(fileDescriptor: fd, queue: clientQueue)
        disconnect.setEventHandler {
            var byte: UInt8 = 0
            if Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0 { operation.cancel() }
        }
        disconnect.resume()
        done.wait()
        disconnect.cancel()
        // The selected SDK transport returns JSON only; it never supplies an SSE
        // stream. Do not silently discard a stream if the transport is changed.
        if case .stream = response {
            writeRawResponse(status: 500, payload: Data("{\"error\":\"Unsupported MCP streaming response\"}".utf8), to: fd)
            return
        }
        let headers = response.headers.filter { $0.key.lowercased() != "content-type" }
        writeRawResponse(status: response.statusCode, payload: response.bodyData, extraHeaders: headers, to: fd)
    }

    private func route(_ request: LocalHTTPRequest) -> LocalAPIResponse {
#if VOICE_FLOW_QA
        if request.path.hasPrefix("/__qa/") {
            let prefix = "Bearer "
            let authorization = request.headers["authorization"] ?? ""
            let candidate = authorization.hasPrefix(prefix)
                ? String(authorization.dropFirst(prefix.count)) : ""
            guard let qaToken,
                  QAControlSecurity.matches(candidate, token: qaToken) else {
                return LocalAPIResponse.error(401, "QA capability required.")
            }
            return onQA?(request.method, request.path, request.body)
                ?? LocalAPIResponse.error(503, "QA control unavailable.")
        }
#endif
        switch (request.method, request.path) {
        case ("GET", "/api/tts/status"):
            return onStatus?() ?? LocalAPIResponse.error(503, "TTS status unavailable.")
        case ("POST", "/api/tts/set"):
            switch decodePayload(request.body) {
            case .success(let payload):
                return onSet?(payload) ?? LocalAPIResponse.error(503, "TTS controls unavailable.")
            case .failure(let error):
                return LocalAPIResponse.error(400, error.localizedDescription)
            }
        case ("POST", "/api/tts/speak"):
            switch decodePayload(request.body) {
            case .success(let payload):
                return onSpeak?(payload) ?? LocalAPIResponse.error(503, "TTS speak unavailable.")
            case .failure(let error):
                return LocalAPIResponse.error(400, error.localizedDescription)
            }
        case ("POST", "/api/tts/seek"):
            switch decodePayload(request.body) {
            case .success(let payload):
                return onSeek?(payload) ?? LocalAPIResponse.error(503, "TTS seek unavailable.")
            case .failure(let error):
                return LocalAPIResponse.error(400, error.localizedDescription)
            }
        case ("POST", "/api/tts/stop"):
            return onStop?() ?? LocalAPIResponse.error(503, "TTS stop unavailable.")
        case ("POST", "/api/pair-mode"):
            return onPairMode?() ?? LocalAPIResponse.error(503, "Pairing unavailable.")
        case ("POST", "/api/panel/show"):
            // Dev/validation hook: open the ChatPanel (optionally on a tab)
            // so agents can screenshot-verify the UI without a human click.
            let tab = (try? JSONDecoder().decode(PanelShowPayload.self, from: request.body))?.tab
            return onPanelShow?(tab) ?? LocalAPIResponse.error(503, "Panel unavailable.")
        default:
            return LocalAPIResponse.error(404, "Not found.")
        }
    }

    struct PanelShowPayload: Codable {
        var tab: String?
    }

    private func decodePayload(_ data: Data) -> Result<TTSAPIUpdatePayload, Error> {
        if data.isEmpty {
            return .success(TTSAPIUpdatePayload())
        }
        return Result {
            try JSONDecoder().decode(TTSAPIUpdatePayload.self, from: data)
        }
    }

    private func readRequest(from fd: Int32) -> LocalHTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headersEnd: Data.Index?
        var contentLength = 0

        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(chunk, count: count)

            if headersEnd == nil, let range = buffer.range(of: separator) {
                headersEnd = range.upperBound
                let headerData = Data(buffer[..<range.lowerBound])
                guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
                let parsedHeaders = parseHeaders(headerString)
                contentLength = Int(parsedHeaders["content-length"] ?? "0") ?? 0
            }

            if let headersEnd, buffer.count >= headersEnd + contentLength {
                break
            }
        }

        guard let request = parseRequest(buffer, contentLength: contentLength) else {
            return nil
        }
        return request
    }

    private func parseRequest(_ buffer: Data, contentLength: Int) -> LocalHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }
        let headerData = Data(buffer[..<range.lowerBound])
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let headers = parseHeaders(headerString)
        let rawPath = String(parts[1])
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let bodyStart = range.upperBound
        let bodyEnd = min(buffer.count, bodyStart + contentLength)
        let body = bodyStart < bodyEnd ? Data(buffer[bodyStart..<bodyEnd]) : Data()

        return LocalHTTPRequest(
            method: String(parts[0]),
            path: path,
            headers: headers,
            body: body
        )
    }

    private func parseHeaders(_ headerString: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in headerString.components(separatedBy: "\r\n").dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private func writeResponse(_ response: LocalAPIResponse, to fd: Int32) {
        let payloadData = (try? JSONSerialization.data(withJSONObject: response.body, options: [.prettyPrinted])) ?? Data("{}".utf8)
        writeRawResponse(status: response.statusCode, payload: payloadData, to: fd)
    }

    private func writeRawResponse(status: Int, payload: Data?, extraHeaders: [String: String] = [:], to fd: Int32) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 409: statusText = "Conflict"
        case 429: statusText = "Too Many Requests"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Error"
        }
        let payloadData = payload ?? Data()

        var lines = [
            "HTTP/1.1 \(status) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(payloadData.count)",
            "Connection: close",
        ]
        for (key, value) in extraHeaders {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        let header = lines.joined(separator: "\r\n")

        writeAll(fd: fd, data: Data(header.utf8))
        if !payloadData.isEmpty {
            writeAll(fd: fd, data: payloadData)
        }
    }

    private func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var totalSent = 0
            while totalSent < data.count {
                let sent = Darwin.write(fd, base.advanced(by: totalSent), data.count - totalSent)
                if sent <= 0 { return }
                totalSent += sent
            }
        }
    }
}
