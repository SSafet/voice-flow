import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Foundry Client (WebSocket + HTTP gateway)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class FoundryClient {
    var connectionState: ConnectionState = .disconnected
    var isAgentTyping: Bool = false

    var onMessage: ((FoundryMessage) -> Void)?
    var onStreamDelta: ((String, String) -> Void)?  // (streamId, content)
    var onStreamEnd: ((String) -> Void)?             // (streamId)
    var onSessionReset: (() -> Void)?
    var onConnectionStateChanged: ((ConnectionState) -> Void)?
    var onError: ((String) -> Void)?

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var sessionId: String?
    private var accessToken: String?
    private var pingTimer: Timer?

    enum ConnectionState: String {
        case disconnected, connecting, connected, subscribed
    }

    // MARK: - Connect

    func connect() {
        guard connectionState == .disconnected else {
            NSLog("[VF] Foundry connect() skipped — state is %@", connectionState.rawValue)
            return
        }
        connectionState = .connecting
        onConnectionStateChanged?(connectionState)

        Task {
            do {
                let config = UserSettings.shared.foundryConfig
                NSLog("[VF] Fetching Foundry auth token...")
                let token = try await fetchToken(config: config)
                self.accessToken = token
                NSLog("[VF] Got token: %@...", String(token.prefix(20)))

                let wsURL = URL(string: "ws://\(config.gatewayHost):\(config.gatewayWSPort)")!
                NSLog("[VF] Connecting WebSocket to %@", wsURL.absoluteString)
                urlSession = URLSession(configuration: .default)
                webSocket = urlSession?.webSocketTask(with: wsURL)
                webSocket?.resume()

                startReceiving()
                startPingTimer()

                // Send auth as first frame
                let authMsg: [String: Any] = [
                    "type": "auth",
                    "token": token
                ]
                send(authMsg)

                try await Task.sleep(nanoseconds: 500_000_000)

                DispatchQueue.main.async {
                    self.connectionState = .connected
                    self.onConnectionStateChanged?(self.connectionState)
                }
                subscribe()
            } catch {
                NSLog("[VF] Foundry connect error: %@", "\(error)")
                DispatchQueue.main.async {
                    self.connectionState = .disconnected
                    self.onConnectionStateChanged?(self.connectionState)
                    self.onError?(error.localizedDescription)
                }
            }
        }
    }

    private func fetchToken(config: FoundryGatewayConfig) async throws -> String {
        let url = URL(string: "http://\(config.gatewayHost):\(config.gatewayHTTPPort)")!
            .appendingPathComponent("auth/token")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.appId, forHTTPHeaderField: "X-Foundry-App-Id")
        request.setValue(config.userId, forHTTPHeaderField: "X-Foundry-User-Id")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "tenant_id": config.tenantId,
            "user_id": config.userId,
            "ttl_hours": 12
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FoundryError.authFailed(errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw FoundryError.authFailed("Invalid token response")
        }

        return token
    }

    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession = nil
        sessionId = nil
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
    }

    // MARK: - Subscribe

    private func subscribe() {
        let config = UserSettings.shared.foundryConfig
        NSLog(
            "[VF] subscribe() — tenant=%@ app=%@ user=%@ label=%@ agent_type=%@",
            config.tenantId,
            config.appId,
            config.userId,
            config.sessionLabel,
            config.agentType
        )
        let msg: [String: Any] = [
            "type": "subscribe",
            "session": [
                "label": config.sessionLabel,
                "agent_type": config.agentType,
                "app_id": config.appId,
                "runtime_scope_context": runtimeScopeContext(for: config),
            ]
        ]
        send(msg)
    }

    // MARK: - Send Message

    func sendMessage(_ content: String, attachments: [FoundryAttachment] = []) {
        guard let sessionId else {
            onError?("Not connected to a session")
            return
        }

        var msg: [String: Any] = [
            "type": "harness_message",
            "session_id": sessionId,
            "content": content,
            "continuity_decision": "continue",
        ]

        if !attachments.isEmpty {
            msg["attachments"] = attachments.map { $0.toDict() }
        }

        send(msg)
    }

    /// Upload an image to Foundry, then send a message referencing it
    func sendScreenCapture(_ imageData: Data, prompt: String) {
        Task {
            do {
                let attachment = try await uploadImage(imageData)
                DispatchQueue.main.async {
                    self.sendMessage(prompt, attachments: [attachment])
                }
            } catch {
                DispatchQueue.main.async {
                    self.onError?("Upload failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Upload Image

    func uploadImage(_ imageData: Data) async throws -> FoundryAttachment {
        guard let compressed = ImageUtils.compress(imageData) else {
            throw FoundryError.compressionFailed
        }
        NSLog("[VF] Compressed image: %d bytes", compressed.count)

        guard let accessToken else {
            throw FoundryError.notConnected
        }

        let config = UserSettings.shared.foundryConfig
        let url = URL(string: "http://\(config.gatewayHost):\(config.gatewayHTTPPort)")!
            .appendingPathComponent("api/upload")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.appId, forHTTPHeaderField: "X-Foundry-App-Id")
        request.setValue(config.userId, forHTTPHeaderField: "X-Foundry-User-Id")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"screenshot.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(compressed)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FoundryError.uploadFailed
        }

        let result = try JSONDecoder().decode(FoundryUploadResponse.self, from: data)
        NSLog("[VF] Upload OK: file_id=%@", result.file_id)
        return FoundryAttachment(fileId: result.file_id, mimeType: result.mime_type, filename: result.filename)
    }

    // MARK: - Delete Session

    func deleteSession() {
        guard let sessionId else { return }
        let config = UserSettings.shared.foundryConfig
        let msg: [String: Any] = [
            "type": "delete_session",
            "session_id": sessionId,
            "app_id": config.appId,
        ]
        send(msg)
        self.sessionId = nil
    }

    // MARK: - Receive Loop

    private func startReceiving() {
        webSocket?.receive { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        NSLog("[VF] Foundry received: %@", String(text.prefix(300)))
                    }
                    self?.handleWebSocketMessage(message)
                    self?.startReceiving()
                case .failure(let error):
                    NSLog("[VF] Foundry receive error: %@", "\(error)")
                    self?.connectionState = .disconnected
                    self?.onConnectionStateChanged?(self!.connectionState)
                    self?.onError?("WebSocket error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "subscribed":
            sessionId = json["session"] as? String
            connectionState = .subscribed
            onConnectionStateChanged?(connectionState)
            NSLog("[VF] Foundry subscribed! session_id: %@", sessionId ?? "nil")

            if let traceId = json["trace_id"] as? String, !traceId.isEmpty {
                sessionId = traceId
                NSLog("[VF] Using trace_id as session: %@", traceId)
            }

        case "agent_response":
            handleAgentResponse(json)

        case "stream_start":
            isAgentTyping = true
            if let streamId = json["stream_id"] as? String {
                onStreamDelta?(streamId, "")
            }

        case "stream_delta":
            if let streamId = json["stream_id"] as? String,
               let content = json["content"] as? String {
                onStreamDelta?(streamId, content)
            }

        case "stream_end":
            isAgentTyping = false
            if let streamId = json["stream_id"] as? String {
                onStreamEnd?(streamId)
            }

        case "quiescent":
            isAgentTyping = false

        case "message_received":
            break

        case "error":
            let errorMsg = json["error"] as? String ?? "Unknown error"
            onError?(errorMsg)

        case "session_deleted":
            NSLog("[VF] Foundry session deleted externally — re-subscribing")
            sessionId = nil
            connectionState = .connected
            onConnectionStateChanged?(connectionState)
            onSessionReset?()
            subscribe()

        case "continuity_check":
            if let sid = json["session_id"] as? String {
                let msg: [String: Any] = [
                    "type": "harness_message",
                    "session_id": sid,
                    "content": "",
                    "continuity_decision": "continue",
                ]
                send(msg)
            }

        case "pong":
            break

        default:
            break
        }
    }

    private func handleAgentResponse(_ json: [String: Any]) {
        guard let messageData = json["message"] as? [String: Any] else { return }

        let role = json["role"] as? String ?? "agent"
        let participant = json["participant"] as? String ?? ""
        let content = messageData["content"] as? String ?? ""
        let messageType = messageData["type"] as? String ?? ""
        let isReplay = json["replay"] as? Bool ?? false

        var inputTokens: Int?
        var outputTokens: Int?
        if let usage = json["context_usage"] as? [String: Any] {
            inputTokens = usage["input_tokens"] as? Int
            outputTokens = usage["output_tokens"] as? Int
        }

        let metadata = messageData["metadata"] as? [String: Any]
        let isInterrupt = metadata?["interrupt"] as? Bool ?? false

        let msg = FoundryMessage(
            role: role,
            participant: participant,
            content: content,
            messageType: messageType,
            isReplay: isReplay,
            isInterrupt: isInterrupt,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )

        if role == "agent" {
            isAgentTyping = false
        }

        onMessage?(msg)
    }

    // MARK: - Send raw JSON

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            NSLog("[VF] Failed to serialize Foundry message")
            return
        }
        NSLog("[VF] Foundry sending: %@", String(text.prefix(300)))
        webSocket?.send(.string(text)) { error in
            if let error {
                NSLog("[VF] Foundry send error: %@", "\(error)")
                DispatchQueue.main.async {
                    self.onError?("Send failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Keepalive

    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.webSocket?.send(.string("{\"type\":\"ping\"}")) { _ in }
        }
    }

    private func runtimeScopeContext(for config: FoundryGatewayConfig) -> [String: Any] {
        let identity: [String: String] = [
            "tenant_id": config.tenantId,
            "app_id": config.appId,
            "user_id": config.userId,
            "session_id": config.canonicalSessionId,
        ]

        return [
            "version": 1,
            "identity": identity,
            "scope_stack": [
                ["key": "session", "kind": "session", "id": config.canonicalSessionId, "ephemeral": true],
                ["key": "user", "kind": "user", "id": config.userId, "ephemeral": false],
                ["key": "app", "kind": "app", "id": config.appId, "ephemeral": false],
                ["key": "tenant", "kind": "tenant", "id": config.tenantId, "ephemeral": false],
            ],
            "artifacts": [:],
        ]
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Conversation Manager (display-only, Foundry owns state)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class ConversationManager {
    var displayMessages: [DisplayMessage] = []
    var isLoading: Bool = false
    var streamingContent: String = ""

    var onNewResponse: ((String) -> Void)?
    var onMessagesChanged: (() -> Void)?

    private var activeStreamId: String?

    func handleFoundryMessage(_ msg: FoundryMessage) {
        guard !msg.content.isEmpty else { return }
        if msg.role == "user" { return }
        if msg.messageType == "MSG_ACK" { return }

        // If we just finished streaming, skip the duplicate final agent_response
        if msg.role == "agent" && activeStreamId != nil {
            activeStreamId = nil
            return
        }

        let display = DisplayMessage(
            role: msg.role == "user" ? .user : .assistant,
            content: msg.content
        )
        displayMessages.append(display)
        onMessagesChanged?()

        if display.role == .assistant {
            onNewResponse?(msg.content)
        }
    }

    func handleStreamDelta(_ streamId: String, _ content: String) {
        isLoading = true

        if activeStreamId != streamId {
            activeStreamId = streamId
            streamingContent = content
            let msg = DisplayMessage(role: .assistant, content: content, isStreaming: true)
            displayMessages.append(msg)
        } else {
            streamingContent += content
            if let idx = displayMessages.lastIndex(where: { $0.isStreaming }) {
                displayMessages[idx] = DisplayMessage(
                    id: displayMessages[idx].id,
                    role: .assistant,
                    content: streamingContent,
                    isStreaming: true
                )
            }
        }
        onMessagesChanged?()
    }

    func handleStreamEnd(_ streamId: String) {
        isLoading = false

        if let idx = displayMessages.lastIndex(where: { $0.isStreaming }) {
            displayMessages[idx] = DisplayMessage(
                id: displayMessages[idx].id,
                role: .assistant,
                content: streamingContent,
                isStreaming: false
            )
        }
        let finalContent = streamingContent
        streamingContent = ""
        onMessagesChanged?()

        if !finalContent.isEmpty {
            onNewResponse?(finalContent)
        }
    }

    func addUserMessage(_ text: String, isPending: Bool = false) {
        displayMessages.append(DisplayMessage(role: .user, content: text, isPending: isPending))
        onMessagesChanged?()
    }

    func addCaptureMarker(isPending: Bool = false) {
        let label = isPending ? "[Screenshot captured — pending]" : "[Screen capture sent]"
        displayMessages.append(DisplayMessage(role: .user, content: label, isPending: isPending))
        onMessagesChanged?()
    }

    /// Mark all pending messages as "sending..."
    func markAllPendingSending() {
        for i in displayMessages.indices where displayMessages[i].isPending {
            displayMessages[i] = DisplayMessage(
                id: displayMessages[i].id,
                role: displayMessages[i].role,
                content: displayMessages[i].content.replacingOccurrences(of: "pending", with: "sending..."),
                isPending: true
            )
        }
        onMessagesChanged?()
    }

    /// Replace all pending items with the final combined message that was sent
    func replacePendingWithSent(_ combinedPrompt: String) {
        displayMessages.removeAll { $0.isPending }
        displayMessages.append(DisplayMessage(role: .user, content: combinedPrompt))
        onMessagesChanged?()
    }

    func addError(_ text: String) {
        displayMessages.append(DisplayMessage(role: .assistant, content: "Error: \(text)"))
        onMessagesChanged?()
    }

    func clear() {
        displayMessages.removeAll()
        streamingContent = ""
        activeStreamId = nil
        onMessagesChanged?()
    }
}

// MARK: - Types

struct FoundryMessage {
    let role: String
    let participant: String
    let content: String
    let messageType: String
    let isReplay: Bool
    let isInterrupt: Bool
    let inputTokens: Int?
    let outputTokens: Int?
}

struct FoundryAttachment {
    let fileId: String
    let mimeType: String
    let filename: String

    func toDict() -> [String: String] {
        ["file_id": fileId, "mime_type": mimeType, "filename": filename]
    }
}

private struct FoundryUploadResponse: Decodable {
    let file_id: String
    let mime_type: String
    let filename: String
}

enum MessageRole: String {
    case user, assistant
}

struct DisplayMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var isStreaming: Bool
    var isPending: Bool

    init(role: MessageRole, content: String, isStreaming: Bool = false, isPending: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isStreaming = isStreaming
        self.isPending = isPending
    }

    init(id: UUID, role: MessageRole, content: String, isStreaming: Bool = false, isPending: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isStreaming = isStreaming
        self.isPending = isPending
    }
}

enum FoundryError: LocalizedError {
    case compressionFailed
    case uploadFailed
    case notConnected
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .compressionFailed: return "Failed to compress image"
        case .uploadFailed: return "Failed to upload image to gateway"
        case .notConnected: return "Not connected to gateway"
        case .authFailed(let msg): return "Auth failed: \(msg)"
        }
    }
}
