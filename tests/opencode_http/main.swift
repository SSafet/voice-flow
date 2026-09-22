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
    private static var messageRequests = 0
    private static var instructionBody: [String: Any] = [:]
    private static var modelBody: [String: Any] = [:]
    static func instructions() -> [String: Any] { lock.withLock { instructionBody } }
    static func model() -> [String: Any] { lock.withLock { modelBody } }

    static func set(_ mode: Mode) { lock.withLock { value = mode } }
    private static func mode() -> Mode { lock.withLock { value } }
    static func sentMessageBody() -> [String: Any] { lock.withLock { lastMessageBody } }
    static func sentMessageCount() -> Int { lock.withLock { messageRequests } }

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
        if path.hasSuffix("/prompt"), let body = Self.bodyObject(of: request) {
            Self.lock.withLock {
                Self.lastMessageBody = body
                Self.messageRequests += 1
            }
        }
        if path.hasSuffix("/entries/voiceflow"), let body = Self.bodyObject(of: request) {
            Self.lock.withLock { Self.instructionBody = body }
        }
        if path.hasSuffix("/model"), let body = Self.bodyObject(of: request) {
            Self.lock.withLock { Self.modelBody = body }
        }
        switch Self.mode() {
        case .stall:
            return
        case .status(let status, let body):
            send(status: status, body: body, contentType: "application/json")
        case .normal:
            if path == "/api/event" {
                let events: [[String: Any]] = [
                    ["type": "server.connected", "data": [:]],
                    ["id": "delta-a", "type": "session.text.delta", "data": [
                        "sessionID": "session-a", "assistantMessageID": "assistant-a", "ordinal": 0, "delta": "Hi"]],
                    ["id": "delta-a", "type": "session.text.delta", "data": [
                        "sessionID": "session-a", "assistantMessageID": "assistant-a", "ordinal": 0, "delta": "Hi"]],
                    ["id": "end-a", "type": "session.text.ended", "data": [
                        "sessionID": "session-a", "assistantMessageID": "assistant-a", "ordinal": 0, "text": "Hi"]],
                    ["type": "session.execution.failed", "data": [
                        "sessionID": "session-a", "error": ["message": "injected SSE failure"]]],
                ]
                let body = events.compactMap { event -> String? in
                    guard let data = try? JSONSerialization.data(withJSONObject: event),
                          let text = String(data: data, encoding: .utf8) else { return nil }
                    return "data: \(text)\n\n"
                }.joined().data(using: .utf8)!
                send(status: 200, body: body, contentType: "text/event-stream")
            } else if path == "/api/model" {
                send(status: 200, body: Data(#"{"data":[{"providerID":"test","id":"model","variants":[{"id":"low"}]}]}"#.utf8), contentType: "application/json")
            } else if path == "/api/session/active" {
                send(status: 200, body: Data("{\"data\":{}}".utf8), contentType: "application/json")
            } else if path.hasSuffix("/prompt") {
                send(status: 200, body: Data("{\"data\":{\"id\":\"msg_prompt\"}}".utf8), contentType: "application/json")
            } else if path.hasSuffix("/permission") {
                send(status: 200, body: Data(#"{"data":[{"id":"missed-approval","sessionID":"session-a","action":"shell","resources":["echo pending"]}]}"#.utf8), contentType: "application/json")
            } else if path.hasSuffix("/message") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let after = query.first { $0.name == "cursor" }?.value
                let page: [String: Any]
                if after == "older" {
                    expect(!query.contains { $0.name == "order" }, "cursor page resent initial order")
                    page = ["data": [
                        ["id": "msg_prompt", "type": "user", "text": "task"],
                        ["id": "prior_answer", "type": "assistant", "content": [["type": "text", "text": "wrong prior turn"]]],
                    ], "cursor": [:]]
                } else {
                    page = ["data": [
                        ["id": "msg_assistant", "type": "assistant",
                         "content": [["type": "text", "text": "authoritative final"]],
                         "tokens": ["input": 3, "output": 2, "reasoning": 500,
                                    "cache": ["read": 90_000, "write": 5_000]], "cost": 0.01],
                    ], "cursor": ["next": "older"]]
                }
                let body = try! JSONSerialization.data(withJSONObject: page)
                send(status: 200, body: body, contentType: "application/json")
            } else if path == "/api/session/session-a", request.httpMethod == "GET" {
                send(status: 200, body: Data("{\"data\":{\"id\":\"session-a\",\"outcome\":\"succeeded\"}}".utf8), contentType: "application/json")
            } else if path == "/api/session/missing" {
                send(status: 404, body: Data("missing".utf8), contentType: "text/plain")
            } else if path.hasSuffix("/wait") {
                Thread.sleep(forTimeInterval: 0.2)
                send(status: 204, body: Data(), contentType: "application/json")
            } else {
                send(status: 200, body: Data("{\"data\":{\"id\":\"session-a\"}}".utf8),
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
            username: "opencode", password: "secret", version: "2.0.12"),
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
// Fields from the pinned runtime's PermissionRequest / permission.asked
// schema. The command must survive normalization so the approval is reviewable.
let permissionReducer = OpenCodeEventReducer()
let permissionCommand = "printf PERMISSION_OK > permission-deny.txt"
let permissionEvents = permissionReducer.reduce([
    "type": "permission.asked", "data": [
        "id": "permission-a", "sessionID": "session-a", "action": "shell",
        "resources": [permissionCommand], "metadata": [:], "always": ["printf *"],
    ],
], sessionID: "session-a")
if case .permission(let permission)? = permissionEvents.first {
    expect(permission.title == "shell requested" && permission.detail == permissionCommand,
           "pinned OpenCode approval lost the capability or command being requested")
} else { expect(false, "pinned OpenCode approval event was dropped") }

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

// Existing v2 sessions remain bound to their real working directory.
let sessionLocation = try JSONSerialization.data(withJSONObject: ["data": ["location": ["directory": directory.path]]])
StubProtocol.set(.status(200, sessionLocation))
let matching = try await makeClient().sessionExists(sessionID: "same", directory: directory)
expect(matching, "same-directory v2 session was discarded")
let wrongDirectory = try await makeClient().sessionExists(sessionID: "same", directory: directory.appendingPathComponent("different"))
expect(!wrongDirectory, "a v2 session was reused in another directory")
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
var recoveredPermissions: [String] = []
let request = AgentTurnRequest(
    turnID: UUID(), conversationID: "conversation-a", assistant: nil,
    priorMessages: [], prompt: "task", screenshots: [],
    workingDirectory: directory, extraWritableRoots: [], trustProfile: .workspace,
    model: AgentModelSelection(provider: "test", model: "model"), instructions: "SYSTEM_PERSONA")
// Missing sessions are idle, but malformed entries must never authorize a
// new POST: the previous turn may still be running in the server.
for malformed in [#"{"data":{"session-a":42}}"#, #"{"data":{"session-a":{}}}"#,
                  #"{"data":{"session-a":{"type":false}}}"#] {
    StubProtocol.set(.status(200, Data(malformed.utf8)))
    let sentBefore = StubProtocol.sentMessageCount()
    do {
        _ = try await client.sendMessage(
            sessionID: "session-a", directory: directory, request: request) { _ in }
        expect(false, "malformed session state was accepted as idle")
    } catch OpenCodeClientError.invalidResponse { }
    catch { expect(false, "malformed session state produced wrong error: \(error)") }
    expect(StubProtocol.sentMessageCount() == sentBefore,
           "malformed session state sent a new message before failing")
}
StubProtocol.set(.normal)
let result = try await client.sendMessage(
    sessionID: "session-a", directory: directory, request: request) { event in
        switch event {
        case .textDelta(_, let delta): deltas.append(delta)
        case .failed(let failure): failures.append(failure.message)
        case .permission(let permission): recoveredPermissions.append(permission.id)
        case .activity: break
        }
    }
expect(recoveredPermissions == ["missed-approval"],
       "a permission omitted by the closed SSE stream was not recovered exactly once")
expect(result.text == "authoritative final",
       "SSE provisional events changed the authoritative final")
expect(result.usage?.inputTokens == 3 && result.usage?.outputTokens == 2,
       "OpenCode authoritative usage was not decoded")
expect(deltas == ["Hi"],
       "duplicate, reordered, or prompt SSE parts were not reduced exactly once: \(deltas)")
expect(failures == ["injected SSE failure"],
       "OpenCode SSE session failure was not normalized")
expect(result.usage?.contextUsage?.tokens == 95_505,
       "OpenCode context must include cached input and reasoning without changing billing fields")
let plainBody = StubProtocol.sentMessageBody()
expect(StubProtocol.instructions()["value"] as? String == "SYSTEM_PERSONA"
       && plainBody["text"] as? String == "task",
       "OpenCode must receive durable instructions separately from task text")
expect((StubProtocol.model()["model"] as? [String: Any])?["id"] as? String == "model",
       "the model selection was not sent to OpenCode")
expect((StubProtocol.model()["model"] as? [String: Any])?["variant"] == nil,
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
expect((StubProtocol.model()["model"] as? [String: Any])?["variant"] as? String == "low",
       "the shared reasoning-effort config should reach OpenCode as the model variant")

let unavailableEffort = AgentTurnRequest(
    turnID: UUID(), conversationID: "conversation-a", assistant: nil,
    priorMessages: [], prompt: "task", screenshots: [],
    workingDirectory: directory, extraWritableRoots: [], trustProfile: .workspace,
    model: AgentModelSelection(provider: "test", model: "model", reasoningEffort: "max"))
var effortActivities: [String] = []
_ = try await client.sendMessage(sessionID: "session-a", directory: directory, request: unavailableEffort) {
    if case .activity(let label) = $0 { effortActivities.append(label) }
}
expect((StubProtocol.model()["model"] as? [String: Any])?["variant"] == nil
       && effortActivities.contains { $0.contains("Max reasoning is unavailable") && $0.contains("provider default") },
       "unavailable v2 variant must fall back visibly instead of failing or misreporting effort")

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
