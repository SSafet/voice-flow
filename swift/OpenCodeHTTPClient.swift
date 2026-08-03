import Foundation

struct OpenCodeSession: Equatable {
    let id: String
}

struct OpenCodeMessageResult: Equatable {
    let text: String
    let usage: AgentUsage?

    init(text: String, usage: AgentUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

enum OpenCodeClientEvent {
    case textDelta(partID: String, delta: String)
    case activity(String)
    case permission(AgentPermissionRequest)
    case failed(AgentRuntimeFailure)
}

enum OpenCodeClientError: LocalizedError {
    case invalidResponse(String)
    case http(status: Int, message: String)
    case emptyFinal

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail): return "OpenCode returned an invalid response: \(detail)"
        case .http(let status, let message): return "OpenCode request failed (\(status)): \(message)"
        case .emptyFinal: return "OpenCode completed without an assistant response."
        }
    }
}

protocol OpenCodeClienting: AnyObject {
    func createSession(directory: URL, title: String) async throws -> OpenCodeSession
    func sessionExists(sessionID: String, directory: URL) async throws -> Bool
    func sendMessage(sessionID: String, directory: URL,
                     request: AgentTurnRequest,
                     onEvent: @escaping (OpenCodeClientEvent) -> Void) async throws -> OpenCodeMessageResult
    func abort(sessionID: String, directory: URL) async
    func respondPermission(sessionID: String, directory: URL,
                           permissionID: String,
                           response: AgentPermissionResponse) async throws
}

protocol OpenCodeClientFactory {
    func make(connection: OpenCodeConnection) -> any OpenCodeClienting
}

struct DefaultOpenCodeClientFactory: OpenCodeClientFactory {
    func make(connection: OpenCodeConnection) -> any OpenCodeClienting {
        OpenCodeHTTPClient(connection: connection)
    }
}

/// Reduces versioned SSE payloads into the small event vocabulary Voice Flow
/// owns. Part snapshots and deltas are deduplicated by semantic part id.
final class OpenCodeEventReducer {
    private let lock = NSLock()
    private var textByPart: [String: String] = [:]
    private var assistantMessageIDs: Set<String> = []

    func reduce(_ object: [String: Any], sessionID: String) -> [OpenCodeClientEvent] {
        lock.withLock {
            guard let type = object["type"] as? String,
                  let properties = object["properties"] as? [String: Any] else { return [] }
            switch type {
            case "message.updated":
                guard let info = properties["info"] as? [String: Any],
                      info["sessionID"] as? String == sessionID,
                      let messageID = info["id"] as? String else { return [] }
                if info["role"] as? String == "assistant" {
                    assistantMessageIDs.insert(messageID)
                } else {
                    assistantMessageIDs.remove(messageID)
                }
                return []
            case "message.part.updated":
                guard let part = properties["part"] as? [String: Any],
                      part["sessionID"] as? String == sessionID,
                      let partID = part["id"] as? String else { return [] }
                if part["type"] as? String == "text" {
                    guard let messageID = part["messageID"] as? String,
                          assistantMessageIDs.contains(messageID) else { return [] }
                    let previous = textByPart[partID] ?? ""
                    let full = part["text"] as? String ?? previous
                    let explicit = properties["delta"] as? String
                    let delta: String
                    if full == previous {
                        delta = ""
                    } else if full.hasPrefix(previous) {
                        delta = String(full.dropFirst(previous.count))
                    } else if previous.hasPrefix(full) {
                        // A stale snapshot after reconnect must not rewind the
                        // part or make a later snapshot duplicate old text.
                        return []
                    } else if let explicit, !explicit.isEmpty {
                        delta = explicit
                    } else {
                        delta = ""
                    }
                    textByPart[partID] = full
                    return delta.isEmpty ? [] : [.textDelta(partID: partID, delta: delta)]
                }
                if part["type"] as? String == "tool" {
                    let tool = part["tool"] as? String ?? "tool"
                    let state = part["state"] as? [String: Any]
                    let title = state?["title"] as? String ?? "Using \(tool)"
                    return [.activity(title)]
                }
                return []
            case "session.error":
                guard properties["sessionID"] as? String == sessionID else { return [] }
                let error = properties["error"] as? [String: Any]
                let message = error?["message"] as? String
                    ?? properties["message"] as? String
                    ?? "OpenCode session failed."
                return [.failed(AgentRuntimeFailure(
                    code: "opencode_session_error", message: message, retryable: true))]
            case "permission.asked", "permission.updated":
                guard properties["sessionID"] as? String == sessionID,
                      let id = properties["id"] as? String else { return [] }
                // Fields per the pinned 1.17 Permission type: `title` carries
                // the human-readable action (for bash, the command itself) and
                // `pattern` is the rule that matched, as a string or a list.
                // This previously read `permission` and `patterns`, neither of
                // which exists — so every prompt rendered as a bare
                // "Permission requested" with no detail to decide on.
                let type = properties["type"] as? String
                let title = properties["title"] as? String
                    ?? type.map { "\($0) requested" }
                    ?? "Permission requested"
                let patterns: [String]
                switch properties["pattern"] {
                case let single as String: patterns = [single]
                case let many as [String]: patterns = many
                default: patterns = []
                }
                let detail = patterns.isEmpty ? title : patterns.joined(separator: ", ")
                return [.permission(AgentPermissionRequest(id: id, title: title, detail: detail))]
            default:
                return []
            }
        }
    }
}

final class OpenCodeHTTPClient: OpenCodeClienting {
    private let connection: OpenCodeConnection
    private let session: URLSession

    init(connection: OpenCodeConnection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    func createSession(directory: URL, title: String) async throws -> OpenCodeSession {
        let body: [String: Any] = ["title": title]
        let data = try await request(
            method: "POST", path: "session", directory: directory, body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else {
            throw OpenCodeClientError.invalidResponse("session id is missing")
        }
        return OpenCodeSession(id: id)
    }

    func sessionExists(sessionID: String, directory: URL) async throws -> Bool {
        do {
            _ = try await request(
                method: "GET", path: "session/\(sessionID)",
                directory: directory, body: nil)
            return true
        } catch OpenCodeClientError.http(let status, _) where status == 404 {
            return false
        }
    }

    func sendMessage(sessionID: String, directory: URL,
                     request turn: AgentTurnRequest,
                     onEvent: @escaping (OpenCodeClientEvent) -> Void) async throws -> OpenCodeMessageResult {
        try await waitUntilIdle(sessionID: sessionID, directory: directory)
        let reducer = OpenCodeEventReducer()
        let eventTask = Task { [connection, session] in
            var request = URLRequest(url: connection.baseURL.appendingPathComponent("event"))
            request.timeoutInterval = 3_600
            request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
            request.setValue(directory.path, forHTTPHeaderField: "x-opencode-directory")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    if Task.isCancelled { return }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = payload.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    reducer.reduce(object, sessionID: sessionID).forEach(onEvent)
                }
            } catch is CancellationError {
                return
            } catch {
                // The authoritative POST result can still complete if the SSE
                // stream reconnects or disappears; callers reconcile there.
                return
            }
        }
        defer { eventTask.cancel() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        var parts: [[String: Any]] = [["type": "text", "text": turn.prompt]]
        for (index, image) in turn.screenshots.enumerated() {
            let attachment = Self.imageAttachmentMetadata(for: image, index: index)
            parts.append([
                "type": "file",
                "mime": attachment.mime,
                "filename": attachment.filename,
                "url": "data:\(attachment.mime);base64,\(image.base64EncodedString())",
            ])
        }
        var body: [String: Any] = ["parts": parts]
        if let model = turn.model {
            body["model"] = ["providerID": model.provider, "modelID": model.model]
        }
        let data = try await request(
            method: "POST", path: "session/\(sessionID)/message",
            directory: directory, body: body, timeout: 3_600)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseParts = object["parts"] as? [[String: Any]] else {
            throw OpenCodeClientError.invalidResponse("message parts are missing")
        }
        let text = responseParts.compactMap { part -> String? in
            guard part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }.joined()
        guard !text.isEmpty else { throw OpenCodeClientError.emptyFinal }
        let info = object["info"] as? [String: Any]
        let tokens = info?["tokens"] as? [String: Any]
        let inputTokens = (tokens?["input"] as? NSNumber)?.intValue
        let outputTokens = (tokens?["output"] as? NSNumber)?.intValue
        let cost = (info?["cost"] as? NSNumber).map { Decimal($0.doubleValue) }
        let usage: AgentUsage? = (inputTokens != nil || outputTokens != nil || cost != nil)
            ? AgentUsage(inputTokens: inputTokens, outputTokens: outputTokens, costUSD: cost)
            : nil
        return OpenCodeMessageResult(text: text, usage: usage)
    }

    private static func imageAttachmentMetadata(
        for data: Data, index: Int
    ) -> (mime: String, filename: String) {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8,
           bytes[0...7].elementsEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            return ("image/png", "voice-flow-\(index + 1).png")
        }
        if bytes.count >= 3, bytes[0] == 0xff, bytes[1] == 0xd8, bytes[2] == 0xff {
            return ("image/jpeg", "voice-flow-\(index + 1).jpg")
        }
        // CaptureStore emits JPEG, so keep the product default while allowing
        // deterministic PNG fixtures and future capture encoders to retain an
        // honest content type.
        return ("image/jpeg", "voice-flow-\(index + 1).jpg")
    }

    private func waitUntilIdle(sessionID: String, directory: URL) async throws {
        for _ in 0..<100 {
            let data = try await request(
                method: "GET", path: "session/status",
                directory: directory, body: nil, timeout: 3)
            guard let statuses = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw OpenCodeClientError.invalidResponse("session status JSON is malformed")
            }
            guard let raw = statuses[sessionID] as? [String: Any] else { return }
            let type = raw["type"] as? String ?? "idle"
            if type == "idle" { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw OpenCodeClientError.invalidResponse("session stayed busy after the prior turn")
    }

    func abort(sessionID: String, directory: URL) async {
        _ = try? await request(
            method: "POST", path: "session/\(sessionID)/abort",
            directory: directory, body: [:])
    }

    func respondPermission(sessionID: String, directory: URL,
                           permissionID: String,
                           response: AgentPermissionResponse) async throws {
        _ = try await request(
            method: "POST",
            path: "session/\(sessionID)/permissions/\(permissionID)",
            directory: directory,
            body: ["response": response.rawValue, "remember": false])
    }

    private func request(method: String, path: String, directory: URL,
                         body: [String: Any]?, timeout: TimeInterval = 30) async throws -> Data {
        var request = URLRequest(url: connection.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(directory.path, forHTTPHeaderField: "x-opencode-directory")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeClientError.invalidResponse("HTTP metadata is missing")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data.prefix(4_096), encoding: .utf8) ?? "no response body"
            throw OpenCodeClientError.http(status: http.statusCode, message: message)
        }
        return data
    }
}
