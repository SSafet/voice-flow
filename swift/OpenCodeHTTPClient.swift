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

/// V2 has explicit text deltas and durable full-text boundaries. The global
/// event stream is volatile, so final results always come from the transcript.
final class OpenCodeEventReducer {
    private let lock = NSLock()
    private var textByPart: [String: String] = [:]
    private var seenEventIDs: Set<String> = []
    private var seenPermissions: Set<String> = []
    private var connected = false
    private var streamError: String?

    var isConnected: Bool { lock.withLock { connected } }
    var connectionFailure: String? { lock.withLock { streamError } }
    func streamFailed(_ detail: String) { lock.withLock { streamError = detail } }

    func reduce(_ object: [String: Any], sessionID: String) -> [OpenCodeClientEvent] {
        lock.withLock {
            guard let type = object["type"] as? String else { return [] }
            if type == "server.connected" { connected = true; return [] }
            guard let data = object["data"] as? [String: Any],
                  data["sessionID"] as? String == sessionID else { return [] }
            if let id = object["id"] as? String, !seenEventIDs.insert(id).inserted { return [] }
            switch type {
            case "session.text.delta", "session.text.ended":
                guard let messageID = data["assistantMessageID"] as? String,
                      let ordinal = data["ordinal"] as? Int else { return [] }
                let partID = "\(messageID):\(ordinal)"
                let previous = textByPart[partID] ?? ""
                if type == "session.text.delta", let delta = data["delta"] as? String {
                    textByPart[partID] = previous + delta
                    return delta.isEmpty ? [] : [.textDelta(partID: partID, delta: delta)]
                }
                guard let full = data["text"] as? String,
                      full.hasPrefix(previous) else { return [] }
                textByPart[partID] = full
                let delta = String(full.dropFirst(previous.count))
                return delta.isEmpty ? [] : [.textDelta(partID: partID, delta: delta)]
            case "session.tool.input.started":
                return [.activity("Using \(data["name"] as? String ?? "tool")")]
            case "session.tool.progress":
                let metadata = data["metadata"] as? [String: Any]
                return metadata?["title"].map { [.activity(String(describing: $0))] } ?? []
            case "session.execution.failed":
                let error = data["error"] as? [String: Any]
                return [.failed(AgentRuntimeFailure(
                    code: "opencode_session_error",
                    message: error?["message"] as? String ?? "OpenCode session failed.",
                    retryable: true))]
            case "permission.asked":
                guard let id = data["id"] as? String,
                      seenPermissions.insert(id).inserted else { return [] }
                let action = data["action"] as? String ?? "Permission"
                let resources = data["resources"] as? [String] ?? []
                return [.permission(AgentPermissionRequest(
                    id: id, title: "\(action) requested",
                    detail: resources.isEmpty ? action : resources.joined(separator: ", ")))]
            default: return []
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
        let body: [String: Any] = ["title": title, "location": ["directory": directory.path]]
        let data = try await request(
            method: "POST", path: "session", directory: directory, body: body)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["data"] as? [String: Any],
              let id = value["id"] as? String, !id.isEmpty else {
            throw OpenCodeClientError.invalidResponse("session id is missing")
        }
        return OpenCodeSession(id: id)
    }

    func sessionExists(sessionID: String, directory: URL) async throws -> Bool {
        do {
            let response = try object(await request(
                method: "GET", path: "session/\(sessionID)",
                directory: directory, body: nil))
            guard let info = response["data"] as? [String: Any],
                  let location = info["location"] as? [String: Any],
                  let path = location["directory"] as? String else {
                throw OpenCodeClientError.invalidResponse("session location is missing")
            }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                == directory.resolvingSymlinksInPath().standardizedFileURL
        } catch OpenCodeClientError.http(let status, _) where status == 404 {
            return false
        }
    }

    func sendMessage(sessionID: String, directory: URL,
                     request turn: AgentTurnRequest,
                     onEvent: @escaping (OpenCodeClientEvent) -> Void) async throws -> OpenCodeMessageResult {
        try await waitUntilIdle(sessionID: sessionID, directory: directory)
        defer {
            if connection.toolEndpoint != nil {
                Task { try? await self.request(method: "POST", path: "rpc/voiceflow/skills",
                    directory: directory,
                    body: ["input": ["sessionID": sessionID, "generation": turn.turnID.uuidString,
                                     "remove": true, "skills": []]],
                    query: [URLQueryItem(name: "location[directory]", value: directory.path)]) }
            }
        }
        if connection.toolEndpoint != nil {
            try await prepareNativePlugin(sessionID: sessionID, directory: directory, turn: turn)
        }
        if let model = turn.model {
            var reference: [String: Any] = ["providerID": model.provider, "id": model.model]
            // V2 rejects missing variants instead of falling back itself.
            // The catalog can lag plugin activation, so wait for this exact
            // configured model before resolving the optional effort preference.
            var available: [String: Any]?
            for _ in 0..<100 {
                let catalog = try object(await request(method: "GET", path: "model",
                    directory: directory, body: nil,
                    query: [URLQueryItem(name: "location[directory]", value: directory.path)]))
                available = (catalog["data"] as? [[String: Any]])?.first {
                    $0["providerID"] as? String == model.provider && $0["id"] as? String == model.model
                }
                if available != nil { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let available else {
                throw OpenCodeClientError.invalidResponse("selected model did not become available")
            }
            if let effort = model.reasoningEffort, !effort.isEmpty {
                let variants = available["variants"] as? [[String: Any]] ?? []
                if variants.contains(where: { $0["id"] as? String == effort }) {
                    reference["variant"] = effort
                } else {
                    onEvent(.activity("\(AgentReasoningEffort.label(for: effort)) reasoning is unavailable for this model; using provider default"))
                }
            }
            _ = try await request(method: "POST", path: "session/\(sessionID)/model",
                                  directory: directory, body: ["model": reference])
        }
        // V2 instructions are durable session entries, separate from user
        // prompts. Replace even an empty value so a later turn cannot retain
        // an earlier persona or access instruction accidentally.
        _ = try await request(method: "PUT",
            path: "experimental/session/\(sessionID)/instructions/entries/voiceflow",
            directory: directory, body: ["value": turn.instructions])

        let reducer = OpenCodeEventReducer()
        let eventTask = Task { [connection, session] in
            var request = URLRequest(url: connection.baseURL.appendingPathComponent("api/event"))
            request.timeoutInterval = 3_600
            request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    reducer.streamFailed("event subscription was refused")
                    return
                }
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    if Task.isCancelled { return }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = payload.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    reducer.reduce(object, sessionID: sessionID).forEach(onEvent)
                }
                reducer.streamFailed("event stream closed")
            } catch {
                if !Task.isCancelled { reducer.streamFailed(error.localizedDescription) }
            }
        }
        defer { eventTask.cancel() }
        // Wait for the server's subscription receipt rather than guessing
        // that a fixed sleep was enough to receive the first events.
        for _ in 0..<100 {
            if reducer.isConnected { break }
            if let error = reducer.connectionFailure {
                throw OpenCodeClientError.invalidResponse(error)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard reducer.isConnected else {
            throw OpenCodeClientError.invalidResponse("event subscription did not become ready")
        }

        var body: [String: Any] = ["text": turn.prompt]
        if !turn.screenshots.isEmpty {
            body["files"] = turn.screenshots.enumerated().map { index, image in
                let attachment = Self.imageAttachmentMetadata(for: image, index: index)
                return ["name": attachment.filename,
                        "uri": "data:\(attachment.mime);base64,\(image.base64EncodedString())"]
            }
        }
        let admitted = try object(await request(method: "POST", path: "session/\(sessionID)/prompt",
            directory: directory, body: body, timeout: 3_600))
        guard let input = admitted["data"] as? [String: Any], let promptID = input["id"] as? String else {
            throw OpenCodeClientError.invalidResponse("prompt admission id is missing")
        }
        // The SSE contract explicitly allows missed events. Poll pending
        // permissions while waiting, so disconnects can never hide an approval.
        let permissionTask = Task {
            while !Task.isCancelled {
                do {
                    let pending = try self.object(await self.request(method: "GET",
                        path: "session/\(sessionID)/permission", directory: directory, body: nil))
                    for permission in pending["data"] as? [[String: Any]] ?? [] {
                        reducer.reduce(["type": "permission.asked", "data": permission],
                                       sessionID: sessionID).forEach(onEvent)
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        defer { permissionTask.cancel() }
        _ = try await request(method: "POST", path: "experimental/session/\(sessionID)/wait",
                              directory: directory, body: nil, timeout: 3_600)
        let sessionInfo = try object(await request(method: "GET", path: "session/\(sessionID)",
                                                   directory: directory, body: nil))
        let outcome = (sessionInfo["data"] as? [String: Any])?["outcome"] as? String
        if outcome == "interrupted" { throw CancellationError() }
        guard outcome == "succeeded" else {
            throw OpenCodeClientError.invalidResponse("session execution \(outcome ?? "did not finish")")
        }
        return try await finalResult(sessionID: sessionID, promptID: promptID, directory: directory)
    }

    private func prepareNativePlugin(sessionID: String, directory: URL, turn: AgentTurnRequest) async throws {
        let location = [URLQueryItem(name: "location[directory]", value: directory.path)]
        var ready = false
        for _ in 0..<200 {
            let result = try object(await request(method: "GET", path: "plugin", directory: directory,
                                                   body: nil, query: location))
            let plugins = result["data"] as? [[String: Any]] ?? []
            let required = ["voiceflow.native-tools", "opencode.config.provider"]
            ready = required.allSatisfy { id in
                plugins.contains { $0["id"] as? String == id
                    && ($0["state"] as? [String: Any])?["status"] as? String == "active" }
            }
            if ready { break }
            if let failed = plugins.first(where: { $0["id"] as? String == "voiceflow.native-tools"
                && ($0["state"] as? [String: Any])?["status"] as? String == "failed" }) {
                let state = failed["state"] as? [String: Any]
                throw OpenCodeClientError.invalidResponse("native tools failed: \(state?["error"] ?? "unknown error")")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard ready else { throw OpenCodeClientError.invalidResponse("native tools did not become ready") }
        let skills = try turn.assistant.map { try AgentSkillStore.loadSelected(for: $0) } ?? []
        let selected: [[String: Any]] = skills.map { skill in
            ["id": "\(sessionID)/\(skill.name)", "name": skill.name, "description": skill.description,
             "path": skill.sourceURL.path, "content": skill.contents]
        }
        _ = try await request(method: "POST", path: "rpc/voiceflow/skills", directory: directory,
            body: ["input": ["sessionID": sessionID, "generation": turn.turnID.uuidString, "skills": selected]], query: location)
        // Skill IDs are scoped to this session. Concurrent sessions sharing a
        // project can never broaden each other's model-visible skill catalog.
        let existing = try object(await request(method: "GET", path: "session/\(sessionID)",
                                                directory: directory, body: nil))
        let previous = (existing["data"] as? [String: Any])?["permissions"] as? [[String: Any]] ?? []
        let permissions: [[String: Any]] = previous.filter { $0["action"] as? String != "skill" }
            + [["action": "skill", "resource": "*", "effect": "deny"]]
            + selected.map { ["action": "skill", "resource": $0["id"]!, "effect": "allow"] }
        _ = try await request(method: "PATCH", path: "session/\(sessionID)", directory: directory,
                              body: ["permissions": permissions])
    }

    private func finalResult(sessionID: String, promptID: String, directory: URL) async throws -> OpenCodeMessageResult {
        var cursor: String?
        var messages: [[String: Any]] = []
        var foundPrompt = false
        var seenCursors: Set<String> = []
        repeat {
            let query = [URLQueryItem(name: "limit", value: "200")]
                + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] }
                   ?? [URLQueryItem(name: "order", value: "desc")])
            let page = try object(await request(method: "GET", path: "session/\(sessionID)/message",
                                                directory: directory, body: nil, query: query))
            guard let entries = page["data"] as? [[String: Any]] else {
                throw OpenCodeClientError.invalidResponse("message list is missing")
            }
            for entry in entries {
                if entry["id"] as? String == promptID { foundPrompt = true; break }
                if entry["type"] as? String == "assistant" { messages.append(entry) }
            }
            cursor = (page["cursor"] as? [String: Any])?["next"] as? String
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw OpenCodeClientError.invalidResponse("message pagination repeated its cursor")
            }
        } while !foundPrompt && cursor != nil
        guard foundPrompt else {
            throw OpenCodeClientError.invalidResponse("completed prompt is missing from the transcript")
        }
        let text = messages.reversed().flatMap { message in
            (message["content"] as? [[String: Any]] ?? []).compactMap { part -> String? in
                part["type"] as? String == "text" ? part["text"] as? String : nil
            }
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { throw OpenCodeClientError.emptyFinal }
        let tokenEntries = messages.compactMap { $0["tokens"] as? [String: Any] }
        let costs = messages.compactMap { ($0["cost"] as? NSNumber)?.doubleValue }
        let usage: AgentUsage? = tokenEntries.isEmpty && costs.isEmpty ? nil : AgentUsage(
            inputTokens: tokenEntries.reduce(0) { $0 + (($1["input"] as? NSNumber)?.intValue ?? 0) },
            outputTokens: tokenEntries.reduce(0) { $0 + (($1["output"] as? NSNumber)?.intValue ?? 0) },
            costUSD: costs.isEmpty ? nil : Decimal(costs.reduce(0, +)),
            contextUsage: tokenEntries.first.flatMap(AgentContextUsage.openCode))
        return OpenCodeMessageResult(text: text, usage: usage)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeClientError.invalidResponse("expected a JSON object")
        }
        return result
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
                method: "GET", path: "session/active",
                directory: directory, body: nil, timeout: 3)
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let statuses = envelope["data"] as? [String: Any]
            else {
                throw OpenCodeClientError.invalidResponse("session status JSON is malformed")
            }
            guard let raw = statuses[sessionID] else { return }
            guard let status = raw as? [String: Any],
                  let type = status["type"] as? String, !type.isEmpty else {
                throw OpenCodeClientError.invalidResponse("session status entry is malformed")
            }
            if type == "idle" { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw OpenCodeClientError.invalidResponse("session stayed busy after the prior turn")
    }

    func abort(sessionID: String, directory: URL) async {
        _ = try? await request(
            method: "POST", path: "session/\(sessionID)/interrupt",
            directory: directory, body: [:])
    }

    func respondPermission(sessionID: String, directory: URL,
                           permissionID: String,
                           response: AgentPermissionResponse) async throws {
        _ = try await request(
            method: "POST",
            path: "session/\(sessionID)/permission/\(permissionID)/reply",
            directory: directory,
            body: ["decision": response.rawValue])
    }

    private func request(method: String, path: String, directory: URL,
                         body: [String: Any]?, timeout: TimeInterval = 30,
                         query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: connection.baseURL.appendingPathComponent("api/" + path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
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
