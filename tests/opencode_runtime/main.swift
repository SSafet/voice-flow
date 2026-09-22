import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// Native tools use a dependency-free V2 plugin, generated in private config.
let pluginRoot = VoiceFlowPaths.shared.directory("plugin-fixture")
let nativePlugin = try AgentToolProjection(endpoint: URL(string: "http://127.0.0.1:9/tools")!,
                                           token: "fixture-token").project(into: pluginRoot)
let nativeSource = try String(contentsOf: nativePlugin)
expect(!nativeSource.contains("@opencode-ai/plugin"), "v1 SDK import survived")
expect(nativeSource.contains("ctx.tool.transform") && nativeSource.contains("ctx.rpc.register"),
       "v2 tool/skill registration missing")

final class FakeOpenCodeSupervisor: OpenCodeServing {
    let value = OpenCodeConnection(
        baseURL: URL(string: "http://127.0.0.1:9")!,
        username: "voice-flow", password: "secret", version: "2.0.12")
    var requestedProfiles: [AgentTrustProfile] = []

    func connection(for profile: AgentTrustProfile) async throws -> OpenCodeConnection {
        requestedProfiles.append(profile)
        return value
    }
    func status(for profile: AgentTrustProfile) async -> AgentRuntimeStatus {
        AgentRuntimeStatus(health: .healthy, version: value.version, detail: nil)
    }
    func stop(profile: AgentTrustProfile) async {}
    func stopAll() async {}
}

final class FakeOpenCodeClient: OpenCodeClienting {
    let lock = NSLock()
    var created = 0
    var sentSession: String?
    var aborted = false
    var blockUntilAbort = false
    var sessionsExist = true
    var sentPrompt: String?
    var sentInstructions: String?
    var continuation: CheckedContinuation<OpenCodeMessageResult, Error>?

    func createSession(directory: URL, title: String) async throws -> OpenCodeSession {
        lock.withLock { created += 1 }
        return OpenCodeSession(id: "oc-created")
    }

    func sessionExists(sessionID: String, directory: URL) async throws -> Bool {
        lock.withLock { sessionsExist }
    }

    func sendMessage(sessionID: String, directory: URL,
                     request: AgentTurnRequest,
                     onEvent: @escaping (OpenCodeClientEvent) -> Void) async throws -> OpenCodeMessageResult {
        lock.withLock {
            sentSession = sessionID
            sentPrompt = request.prompt
            sentInstructions = request.instructions
        }
        onEvent(.activity("Using voiceflow_context"))
        onEvent(.textDelta(partID: "part-a", delta: "Open"))
        onEvent(.textDelta(partID: "part-a", delta: "Code"))
        if lock.withLock({ blockUntilAbort }) {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }
        return OpenCodeMessageResult(text: "OpenCode")
    }

    func abort(sessionID: String, directory: URL) async {
        let pending = lock.withLock { () -> CheckedContinuation<OpenCodeMessageResult, Error>? in
            aborted = true
            let value = continuation
            continuation = nil
            return value
        }
        pending?.resume(throwing: CancellationError())
    }

    func respondPermission(sessionID: String, directory: URL,
                           permissionID: String,
                           response: AgentPermissionResponse) async throws {}
}

final class FakeOpenCodeFactory: OpenCodeClientFactory {
    let client: FakeOpenCodeClient
    init(client: FakeOpenCodeClient) { self.client = client }
    func make(connection: OpenCodeConnection) -> any OpenCodeClienting { client }
}

func makeRequest(turnID: UUID = UUID()) -> AgentTurnRequest {
    AgentTurnRequest(
        turnID: turnID, conversationID: "conversation-a", assistant: nil,
        priorMessages: [], prompt: "Task only", screenshots: [],
        workingDirectory: FileManager.default.temporaryDirectory,
        extraWritableRoots: [], trustProfile: .workspace,
        model: AgentModelSelection(provider: "openrouter", model: "test/model"), instructions: "OPENCODE_IDENTITY")
}

// V2 replay boundaries never duplicate deltas or mix sessions.
let reducer = OpenCodeEventReducer()
func textEvent(_ text: String, session: String = "session-a") -> [String: Any] {
    ["type": "session.text.ended", "data": ["sessionID": session,
     "assistantMessageID": "msg_assistant", "ordinal": 0, "text": text]]
}
let delta: [String: Any] = ["id": "evt_delta", "type": "session.text.delta", "data": [
    "sessionID": "session-a", "assistantMessageID": "msg_assistant", "ordinal": 0, "delta": "Hello"]]
expect(reducer.reduce(delta, sessionID: "session-a").count == 1, "first delta missing")
expect(reducer.reduce(delta, sessionID: "session-a").isEmpty, "duplicate delta was replayed")
expect(reducer.reduce(textEvent("Hello"), sessionID: "session-a").isEmpty, "full boundary duplicated delta")
expect(reducer.reduce(textEvent("Hel"), sessionID: "session-a").isEmpty, "stale boundary rewound text")
let suffix = reducer.reduce(textEvent("Hello world"), sessionID: "session-a")
if case .textDelta(_, let delta)? = suffix.first {
    expect(delta == " world", "boundary must recover only the missed suffix")
} else { expect(false, "missed suffix did not recover") }
expect(reducer.reduce(textEvent("wrong", session: "session-b"), sessionID: "session-a").isEmpty,
       "another session's event was rendered")
expect(reducer.reduce(["type": "session.inbox.delivered", "data": ["sessionID": "session-a", "text": "prompt"]],
                      sessionID: "session-a").isEmpty, "user input was rendered as an assistant delta")

let supervisor = FakeOpenCodeSupervisor()
let client = FakeOpenCodeClient()
let runtime = OpenCodeAgentRuntime(
    supervisor: supervisor, factory: FakeOpenCodeFactory(client: client))
let request = makeRequest()
let firstDone = DispatchSemaphore(value: 0)
var firstResult: AgentTurnResult?
var firstEvents: [String] = []
Task {
    firstResult = try? await runtime.run(request, binding: nil) { event in
        switch event {
        case .started(let id): firstEvents.append("started:\(id)")
        case .activity(let label): firstEvents.append("activity:\(label)")
        case .textDelta(_, let delta): firstEvents.append("delta:\(delta)")
        case .completed(let text): firstEvents.append("completed:\(text)")
        case .permission, .usage, .failed, .interrupted: break
        }
    }
    firstDone.signal()
}
expect(firstDone.wait(timeout: .now() + 3) == .success, "OpenCode runtime did not finish")
expect(client.created == 1, "missing binding must create one session")
expect(client.sentSession == "oc-created", "new session id was not used")
expect(firstResult?.text == "OpenCode", "authoritative final changed")
expect(firstResult?.runtimeVersion == "2.0.12", "runtime version was not recorded")
expect(firstEvents == [
    "started:oc-created", "activity:Using voiceflow_context",
    "delta:Open", "delta:Code", "completed:OpenCode",
], "normalized OpenCode events changed: \(firstEvents)")

let resumeDone = DispatchSemaphore(value: 0)
Task {
    _ = try? await runtime.run(
        makeRequest(),
        binding: RuntimeBinding(externalSessionID: "oc-resume", state: .clean, runtimeVersion: "2.0.12")) { _ in }
    resumeDone.signal()
}
expect(resumeDone.wait(timeout: .now() + 3) == .success, "resume turn did not finish")
expect(client.created == 1, "clean binding must not create another session")
expect(client.sentSession == "oc-resume", "clean binding must use its exact session")

client.lock.withLock { client.sessionsExist = false }
let staleMessage = AssistantHistoryMessage(role: .assistant, text: "Canonical prior answer")
let staleRequest = AgentTurnRequest(
    turnID: UUID(), conversationID: "conversation-a", assistant: nil,
    priorMessages: [staleMessage], prompt: "# Current task\nRecover", screenshots: [],
    workingDirectory: FileManager.default.temporaryDirectory,
    extraWritableRoots: [], trustProfile: .workspace,
    model: AgentModelSelection(provider: "openrouter", model: "test/model"), instructions: "OPENCODE_IDENTITY")
let staleDone = DispatchSemaphore(value: 0)
Task {
    _ = try? await runtime.run(
        staleRequest,
        binding: RuntimeBinding(externalSessionID: "missing-session", state: .clean, runtimeVersion: "2.0.12")) { _ in }
    staleDone.signal()
}
expect(staleDone.wait(timeout: .now() + 3) == .success, "stale binding recovery did not finish")
expect(client.created == 2 && client.sentSession == "oc-created",
       "missing external session did not reseed once")
expect(client.sentPrompt?.contains("Canonical prior answer") == true,
       "reseeded session omitted canonical history")
expect(client.sentInstructions == "OPENCODE_IDENTITY"
       && client.sentPrompt?.contains("OPENCODE_IDENTITY") == false
       && client.sentPrompt?.contains(AgentPromptComposer.systemRole) == false,
       "OpenCode missing-session recovery must keep both channels separate")
client.lock.withLock { client.sessionsExist = true }
let legacyDone = DispatchSemaphore(value: 0)
Task {
    _ = try? await runtime.run(staleRequest,
        binding: RuntimeBinding(externalSessionID: "v1-still-present", state: .clean,
                                runtimeVersion: "1.17.11")) { _ in }
    legacyDone.signal()
}
expect(legacyDone.wait(timeout: .now() + 3) == .success, "v1 canonical reseed did not finish")
expect(client.created == 3 && client.sentSession == "oc-created"
       && client.sentPrompt?.contains("Canonical prior answer") == true,
       "v2 reused a v1 binding instead of reseeding canonical history")

client.lock.withLock { client.blockUntilAbort = true }
let cancelRequest = makeRequest()
let cancelDone = DispatchSemaphore(value: 0)
var wasInterrupted = false
Task {
    do { _ = try await runtime.run(cancelRequest, binding: nil) { _ in } }
    catch is CancellationError { wasInterrupted = true }
    catch {}
    cancelDone.signal()
}
for _ in 0..<100 {
    if client.lock.withLock({ client.continuation != nil }) { break }
    Thread.sleep(forTimeInterval: 0.01)
}
let abortDone = DispatchSemaphore(value: 0)
Task { await runtime.cancel(turnID: cancelRequest.turnID); abortDone.signal() }
expect(abortDone.wait(timeout: .now() + 1) == .success, "runtime abort did not return")
expect(cancelDone.wait(timeout: .now() + 1) == .success, "aborted turn did not unwind")
expect(client.aborted && wasInterrupted, "abort must propagate cancellation")

print("opencode runtime tests passed")
