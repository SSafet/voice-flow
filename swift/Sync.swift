import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Mobile sync server (ticket #7)
//  A tiny token-protected HTTP listener on port 8793, reachable over
//  Tailscale (binds all interfaces — every request requires the bearer
//  token in ~/.config/voice-flow/sync-token, auto-generated on first
//  start). One route: POST /sync. The phone pushes its unsynced
//  dictations + assistant chat; the Mac merges dictations into the
//  live DictationsView store (via a main-thread callback), archives
//  the chat to mobile-chat.json, and answers with its recent
//  dictation history plus settings parity (custom_vocabulary,
//  agent_model) so both devices converge.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class SyncServer {
    static let port: UInt16 = 8793

    /// Hops to main and inserts entries into the dictation store
    /// (oldest-first order in, so the newest ends on top).
    var onDictations: (([(text: String, time: String, destination: String)]) -> Void)?
    var onServerMessage: ((String) -> Void)?

    private let queue = DispatchQueue(label: "voiceflow.sync-server", qos: .utility)
    private let clientQueue = DispatchQueue(
        label: "voiceflow.sync-server.clients", qos: .utility, attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voice-flow")
    private static let tokenURL = configDir.appendingPathComponent("sync-token")
    private static let mobileChatURL = configDir.appendingPathComponent("mobile-chat.json")

    /// The shared secret the phone must present. Created on first use.
    static func token() -> String {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        let fresh = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? fresh.write(to: tokenURL, atomically: true, encoding: .utf8)
        return fresh
    }

    func start() {
        guard listenFD == -1 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { onServerMessage?("Sync server: socket failed."); return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(Self.port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY   // Tailscale interface included

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            onServerMessage?("Sync server bind/listen failed: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }
        listenFD = fd
        _ = Self.token()   // materialize the token file on first start

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptNextClient() }
        source.setCancelHandler { [weak self] in
            guard let self, self.listenFD >= 0 else { return }
            Darwin.close(self.listenFD)
            self.listenFD = -1
        }
        acceptSource = source
        source.resume()
        onServerMessage?("Sync server ready on port \(Self.port).")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
    }

    private func acceptNextClient() {
        var addr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFD = Darwin.accept(listenFD, &addr, &len)
        guard clientFD >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        clientQueue.async { [weak self] in self?.handleClient(fd: clientFD) }
    }

    private func handleClient(fd: Int32) {
        defer { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        guard let (head, body) = readRequest(fd: fd) else {
            write(fd: fd, status: 400, json: ["error": "bad request"]); return
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { write(fd: fd, status: 400, json: ["error": "bad request"]); return }
        let method = parts[0], path = parts[1]

        var auth = ""
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("authorization:") {
                auth = String(line.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard auth == "Bearer \(Self.token())" else {
            write(fd: fd, status: 401, json: ["error": "bad token"]); return
        }
        guard method == "POST", path == "/sync" else {
            write(fd: fd, status: 404, json: ["error": "unknown route"]); return
        }
        handleSync(body: body, fd: fd)
    }

    private func handleSync(body: Data, fd: Int32) {
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        // ── incoming dictations → the live store, deduped ──
        let existing = DictationsView.recentEntries(limit: 500)
        var seen = Set(existing.map { $0.time + "\u{1}" + $0.text })
        var fresh: [(text: String, time: String, destination: String)] = []
        for item in (payload["dictations"] as? [[String: Any]]) ?? [] {
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let time = item["time"] as? String ?? ""
            guard !text.isEmpty else { continue }
            let key = time + "\u{1}" + text
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            fresh.append((text: text, time: time, destination: item["kind"] as? String ?? "kept"))
        }
        if !fresh.isEmpty {
            let toAdd = fresh
            DispatchQueue.main.async { [weak self] in self?.onDictations?(toAdd) }
        }

        // ── incoming assistant chat → mobile-chat.json archive ──
        let incomingChat = (payload["chat"] as? [[String: Any]]) ?? []
        if !incomingChat.isEmpty { Self.mergeMobileChat(incomingChat) }

        // ── response: Mac history + settings parity ──
        let recent = DictationsView.recentEntries(limit: 200).map {
            ["text": $0.text, "time": $0.time,
             "destination": ($0.destination ?? .pasted).rawValue] as [String: Any]
        }
        let settings = UserSettings.shared
        let response: [String: Any] = [
            "ok": true,
            "dictations": recent,
            "vocabulary": settings.customVocabulary,
            "agent_model": settings.agentModel,
        ]
        write(fd: fd, status: 200, json: response)
        vflog("sync: +\(fresh.count) dictations, +\(incomingChat.count) chat msgs from phone")
    }

    private static func mergeMobileChat(_ incoming: [[String: Any]]) {
        var byId: [String: [String: Any]] = [:]
        if let data = try? Data(contentsOf: mobileChatURL),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for m in list { if let id = m["id"] as? String { byId[id] = m } }
        }
        for m in incoming {
            guard let id = m["id"] as? String else { continue }
            byId[id] = ["id": id,
                        "role": m["role"] as? String ?? "",
                        "text": m["text"] as? String ?? "",
                        "ts": m["ts"] as? Double ?? 0]
        }
        let merged = byId.values.sorted {
            (($0["ts"] as? Double) ?? 0) < (($1["ts"] as? Double) ?? 0)
        }.suffix(400)
        if let data = try? JSONSerialization.data(withJSONObject: Array(merged), options: [.prettyPrinted]) {
            try? data.write(to: mobileChatURL, options: .atomic)
        }
    }

    // ── HTTP plumbing ──

    private func readRequest(fd: Int32) -> (head: String, body: Data)? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var headerEnd: Range<Data.Index>?
        // Read until the blank line, then honor Content-Length (capped at 8 MB).
        while headerEnd == nil {
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 64_000, headerEnd == nil { return nil }
        }
        guard let headerEnd,
              let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var contentLength = 0
        for line in head.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard contentLength <= 8_000_000 else { return nil }
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < contentLength {
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            body.append(contentsOf: chunk[0..<n])
        }
        return (head, body)
    }

    private func write(fd: Int32, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : "Error"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        response.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}
