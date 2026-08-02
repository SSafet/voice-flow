import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let codexEnvironment = CodexExecBackend.sanitizedEnvironment(source: [
    "PATH": "/usr/bin", "HOME": "/tmp/home", "CODEX_HOME": "/tmp/codex",
    "OPENAI_API_KEY": "secret", "ANTHROPIC_API_KEY": "secret", "MCP_TOKEN": "secret",
])
expect(codexEnvironment == [
    "PATH": "/usr/bin", "HOME": "/tmp/home", "CODEX_HOME": "/tmp/codex",
], "Codex child inherited a non-allowlisted environment value")
let codexArguments = CodexExecBackend.executionArguments(
    prompt: "task", imagePaths: ["/tmp/shot.jpg"], resumeThread: "thread-a",
    extraWritableRoots: ["/tmp/allowed"])
expect(codexArguments.prefix(3) == ["exec", "resume", "thread-a"],
       "Codex resume arguments changed")
expect(codexArguments.contains("mcp_servers={}"),
       "Codex external MCP configuration is not neutralized")
expect(codexArguments.suffix(3) == ["-i", "/tmp/shot.jpg", "task"],
       "Codex image or task argument ordering changed")

final class FakeCodex: CodexExecuting {
    var receivedPrompt = ""
    var receivedImages = 0
    var receivedResume: String?
    var interrupted = false

    func interrupt() { interrupted = true }

    func run(prompt: String, images: [Data], resumeThread: String?,
             workingDirectory: URL?, extraWritableRoots: [String],
             onThreadStarted: @escaping (String) -> Void,
             onToolActivity: @escaping (String) -> Void,
             onAgentText: @escaping (String) -> Void) async throws -> CodexExecBackend.TurnResult {
        receivedPrompt = prompt
        receivedImages = images.count
        receivedResume = resumeThread
        onThreadStarted("codex-new")
        onToolActivity("Reading files")
        onAgentText("first ")
        onAgentText("second")
        return CodexExecBackend.TurnResult(text: "first second", threadId: "codex-new")
    }
}

let fake = FakeCodex()
let runtime = CodexAgentRuntime(backend: fake)
let request = AgentTurnRequest(
    turnID: UUID(), conversationID: "conversation-a", assistant: nil,
    priorMessages: [], prompt: "Do the task", screenshots: [Data([1, 2, 3])],
    workingDirectory: FileManager.default.temporaryDirectory,
    extraWritableRoots: ["/tmp/allowed"], trustProfile: .workspace, model: nil)
let binding = RuntimeBinding(
    externalSessionID: "codex-old", syncedThroughMessageID: UUID(),
    state: .clean)

let semaphore = DispatchSemaphore(value: 0)
var result: AgentTurnResult?
var failure: Error?
var events: [String] = []
Task {
    do {
        result = try await runtime.run(request, binding: binding) { event in
            switch event {
            case .started(let id): events.append("started:\(id)")
            case .activity(let label): events.append("activity:\(label)")
            case .textDelta(_, let delta): events.append("delta:\(delta)")
            case .completed(let text): events.append("completed:\(text)")
            case .permission, .usage, .failed, .interrupted: break
            }
        }
    } catch {
        failure = error
    }
    semaphore.signal()
}
expect(semaphore.wait(timeout: .now() + 3) == .success, "runtime did not finish")
expect(failure == nil, "runtime unexpectedly failed")
expect(fake.receivedPrompt == "Do the task", "adapter changed the prepared prompt")
expect(fake.receivedImages == 1, "adapter dropped image input")
expect(fake.receivedResume == "codex-old", "adapter dropped the resume binding")
expect(result?.externalSessionID == "codex-new", "adapter did not return authoritative thread id")
expect(result?.text == "first second", "adapter changed final text")
expect(events == [
    "started:codex-new", "activity:Reading files",
    "delta:first ", "delta:second", "completed:first second",
], "normalized runtime event order changed: \(events)")

let cancelSemaphore = DispatchSemaphore(value: 0)
Task { await runtime.cancel(turnID: request.turnID); cancelSemaphore.signal() }
expect(cancelSemaphore.wait(timeout: .now() + 1) == .success, "cancel did not return")
expect(fake.interrupted, "cancel did not terminate the backend")

print("codex runtime tests passed")
