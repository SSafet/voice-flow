import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private final class StubProtocol: URLProtocol {
    enum Mode {
        case status(Int, Data)
        case normal
        case stall
    }
    private static let lock = NSLock()
    private static var value: Mode = .normal
    private static var lastMessageBody: [String: Any] = [:]

    static func set(_ mode: Mode) { lock.withLock { value = mode } }
    private static func mode() -> Mode { lock.withLock { value } }
    static func sentMessageBody() -> [String: Any] { lock.withLock { lastMessageBody } }

    /// URLSession hands URLProtocol the body as a stream, not httpBody.
    private static func bodyObject(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/message"), let body = Self.bodyObject(of: request) {
            Self.lock.withLock { Self.lastMessageBody = body }
        }
        switch Self.mode() {
        case .stall:
            return
        case .status(let status, let body):
            send(status: status, body: body, contentType: "application/json")
        case .normal:
            if path == "/event" {
                let events: [[String: Any]] = [
                    ["type": "message.part.updated", "properties": ["part": [
                        "id": "part", "sessionID": "session-a", "messageID": "assistant-a",
                        "type": "text", "text": "prompt leak",
                    ]]],
                    ["type": "message.updated", "properties": ["info": [
                        "id": "assistant-a", "sessionID": "session-a", "role": "assistant",
                    ]]],
                    ["type": "message.part.updated", "properties": [
                        "delta": "Hi", "part": [
                            "id": "part", "sessionID": "session-a", "messageID": "assistant-a",
                            "type": "text", "text": "Hi",
                        ],
                    ]],
                    ["type": "message.part.updated", "properties": [
                        "delta": "Hi", "part": [
                            "id": "part", "sessionID": "session-a", "messageID": "assistant-a",
                            "type": "text", "text": "Hi",
                        ],
                    ]],
                    ["type": "message.part.updated", "properties": ["part": [
                        "id": "part", "sessionID": "session-a", "messageID": "assistant-a",
                        "type": "text", "text": "H",
                    ]]],
                    ["type": "session.error", "properties": [
                        "sessionID": "session-a", "message": "injected SSE failure",
                    ]],
                ]
                let body = events.compactMap { event -> String? in
                    guard let data = try? JSONSerialization.data(withJSONObject: event),
                          let text = String(data: data, encoding: .utf8) else { return nil }
                    return "data: \(text)\n\n"
                }.joined().data(using: .utf8)!
                send(status: 200, body: body, contentType: "text/event-stream")
            } else if path == "/session/status" {
                send(status: 200, body: Data("{}".utf8), contentType: "application/json")
            } else if path.hasSuffix("/message") {
                Thread.sleep(forTimeInterval: 0.2)
                let body = try! JSONSerialization.data(withJSONObject: [
                    "parts": [["type": "text", "text": "authoritative final"]],
                    "info": ["tokens": ["input": 3, "output": 2], "cost": 0.01],
                ])
                send(status: 200, body: body, contentType: "application/json")
            } else if path.contains("/permissions/") || path.hasSuffix("/abort") {
                send(status: 200, body: Data("{}".utf8), contentType: "application/json")
            } else if request.httpMethod == "GET", path.hasPrefix("/session/") {
                send(status: 404, body: Data("missing".utf8), contentType: "text/plain")
            } else {
                send(status: 200, body: Data("{\"id\":\"session-a\"}".utf8),
                     contentType: "application/json")
            }
        }
    }

    override func stopLoading() {}

    private func send(status: Int, body: Data, contentType: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType, "Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func makeClient() -> OpenCodeHTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return OpenCodeHTTPClient(
        connection: OpenCodeConnection(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            username: "voice-flow", password: "secret", version: "1.17.11"),
        session: URLSession(configuration: configuration))
}

let openCodeEnvironment = OpenCodeSupervisor.sanitizedEnvironment(source: [
    "PATH": "/usr/bin", "TMPDIR": "/tmp", "LANG": "en_US.UTF-8",
    "HOME": "/private/home", "OPENAI_API_KEY": "secret",
    "ANTHROPIC_API_KEY": "secret", "MCP_TOKEN": "secret",
])
expect(openCodeEnvironment == [
    "PATH": "/usr/bin", "TMPDIR": "/tmp", "LANG": "en_US.UTF-8",
], "OpenCode child inherited a non-allowlisted environment value")

let directory = FileManager.default.temporaryDirectory
for status in [401, 409, 429, 500] {
    StubProtocol.set(.status(status, Data("fault-\(status)".utf8)))
    do {
        _ = try await makeClient().createSession(directory: directory, title: "fault")
        expect(false, "OpenCode HTTP \(status) was accepted")
    } catch OpenCodeClientError.http(let actual, let message) {
        expect(actual == status && message.contains("fault-\(status)"),
               "OpenCode HTTP \(status) lost typed status/body")
    } catch { expect(false, "OpenCode HTTP \(status) produced wrong error \(error)") }
}

StubProtocol.set(.status(200, Data("not-json".utf8)))
do {
    _ = try await makeClient().createSession(directory: directory, title: "invalid")
    expect(false, "invalid OpenCode session JSON was accepted")
} catch OpenCodeClientError.invalidResponse { }
catch { expect(false, "invalid session JSON produced wrong error \(error)") }

StubProtocol.set(.normal)
let client = makeClient()
let missingExists = try await client.sessionExists(sessionID: "missing", directory: directory)
expect(missingExists == false,
       "OpenCode 404 session was not treated as stale")
try await client.respondPermission(
    sessionID: "session-a", directory: directory,
    permissionID: "permission-a", response: .once)
var deltas: [String] = []
var failures: [String] = []
let request = AgentTurnRequest(
    turnID: UUID(), conversationID: "conversation-a", assistant: nil,
    priorMessages: [], prompt: "task", screenshots: [],
    workingDirectory: directory, extraWritableRoots: [], trustProfile: .workspace,
    model: AgentModelSelection(provider: "test", model: "model"))
let result = try await client.sendMessage(
    sessionID: "session-a", directory: directory, request: request) { event in
        switch event {
        case .textDelta(_, let delta): deltas.append(delta)
        case .failed(let failure): failures.append(failure.message)
        case .activity, .permission: break
        }
    }
expect(result.text == "authoritative final",
       "SSE provisional events changed the authoritative final")
expect(result.usage?.inputTokens == 3 && result.usage?.outputTokens == 2,
       "OpenCode authoritative usage was not decoded")
expect(deltas == ["Hi"],
       "duplicate, reordered, or prompt SSE parts were not reduced exactly once: \(deltas)")
expect(failures == ["injected SSE failure"],
       "OpenCode SSE session failure was not normalized")
let plainBody = StubProtocol.sentMessageBody()
expect((plainBody["model"] as? [String: Any])?["modelID"] as? String == "model",
       "the model selection was not sent to OpenCode")
expect(plainBody["variant"] == nil,
       "an unset reasoning effort must not be sent as a variant")

// Reasoning effort travels as OpenCode's per-message model variant.
let effortRequest = AgentTurnRequest(
    turnID: UUID(), conversationID: "conversation-a", assistant: nil,
    priorMessages: [], prompt: "task", screenshots: [],
    workingDirectory: directory, extraWritableRoots: [], trustProfile: .workspace,
    model: AgentModelSelection(
        provider: "test", model: "model", reasoningEffort: "low"))
_ = try await client.sendMessage(
    sessionID: "session-a", directory: directory, request: effortRequest) { _ in }
expect(StubProtocol.sentMessageBody()["variant"] as? String == "low",
       "the shared reasoning-effort config should reach OpenCode as the model variant")

StubProtocol.set(.stall)
let stalledClient = makeClient()
let stalled = Task {
    try await stalledClient.createSession(directory: directory, title: "stall")
}
try await Task.sleep(nanoseconds: 50_000_000)
stalled.cancel()
do {
    _ = try await stalled.value
    expect(false, "cancelled stalled OpenCode request returned a session")
} catch { }

print("opencode HTTP failure tests passed")
