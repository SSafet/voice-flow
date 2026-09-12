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
expect(!codexArguments.contains("model_reasoning_effort=\"\""),
       "an unset reasoning effort must not reach the CLI at all")
let codexEffortArguments = CodexExecBackend.executionArguments(
    prompt: "task", imagePaths: [], resumeThread: nil,
    extraWritableRoots: [], reasoningEffort: "low")
expect(codexEffortArguments.contains("model_reasoning_effort=\"low\""),
       "the shared reasoning-effort config should reach codex as its own config key")
let codexModelArguments = CodexExecBackend.executionArguments(
    prompt: "task", imagePaths: [], resumeThread: nil,
    extraWritableRoots: [], model: "gpt-5.6-luna", reasoningEffort: nil)
expect(codexModelArguments.contains("-m") && codexModelArguments.contains("gpt-5.6-luna")
       && !codexEffortArguments.contains("-m"),
       "a chosen model must reach codex as -m, and only when chosen")
expect(AgentModelSelection.codex(model: "", reasoningEffort: "") == nil
       && AgentModelSelection.codex(model: "gpt-6-astra", reasoningEffort: nil)?.model == "gpt-6-astra",
       "the codex selection must carry a chosen model and stay nil when nothing is chosen")
expect(CodexModelCatalog.visibleSlugs(from: Data(#"{"models":[{"slug":"gpt-6-astra","visibility":"list"},{"slug":"gpt-reserve","visibility":"hide"},{"slug":"gpt-5.5"}]}"#.utf8))
       == ["gpt-6-astra", "gpt-5.5"],
       "the Codex model catalog must list visible slugs in the CLI's order")

final class FakeCodex: CodexExecuting {
    var receivedPrompt = ""
    var receivedInstructions = ""
    var receivedImages = 0
    var receivedResume: String?
    var receivedEffort: String?
    var interrupted = false

    func interrupt() { interrupted = true }

    func run(prompt: String, instructions: String, images: [Data], resumeThread: String?,
             workingDirectory: URL?, extraWritableRoots: [String],
             model: String?,
             reasoningEffort: String?,
             onThreadStarted: @escaping (String) -> Void,
             onToolActivity: @escaping (String) -> Void,
             onAgentText: @escaping (String) -> Void) async throws -> CodexExecBackend.TurnResult {
        receivedPrompt = prompt
        receivedInstructions = instructions
        receivedImages = images.count
        receivedResume = resumeThread
        receivedEffort = reasoningEffort
        onThreadStarted("codex-new")
        onToolActivity("Reading files")
        onAgentText("first ")
        onAgentText("second")
        return CodexExecBackend.TurnResult(text: "first second", threadId: "codex-new")
    }
}

let fake = FakeCodex()
let runtime = CodexAgentRuntime(backend: fake, fallback: nil)
let request = AgentTurnRequest(
    turnID: UUID(), conversationID: "conversation-a", assistant: nil,
    priorMessages: [], prompt: "Do the task", screenshots: [Data([1, 2, 3])],
    workingDirectory: FileManager.default.temporaryDirectory,
    extraWritableRoots: ["/tmp/allowed"], trustProfile: .workspace,
    model: AgentModelSelection(
        provider: "openai", model: "gpt-5.6-luna", reasoningEffort: "low"),
    instructions: "PERSONA_AND_SKILLS")
let binding = RuntimeBinding(
    externalSessionID: "codex-old", syncedThroughMessageID: UUID(),
    state: .clean, instructionFingerprint: AgentInstructionEncoding.fingerprint(request.instructions))

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
expect(fake.receivedInstructions == "PERSONA_AND_SKILLS", "adapter dropped instructions on resume")
expect(fake.receivedImages == 1, "adapter dropped image input")
expect(fake.receivedResume == "codex-old", "adapter dropped the resume binding")
expect(fake.receivedEffort == "low",
       "adapter dropped the reasoning effort from the shared model config")
expect(result?.externalSessionID == "codex-new", "adapter did not return authoritative thread id")
expect(result?.text == "first second", "adapter changed final text")
expect(events == [
    "started:codex-new", "activity:Reading files",
    "delta:first ", "delta:second", "completed:first second",
], "normalized runtime event order changed: \(events)")

// Cancel after the turn ended is a no-op: on the shared app-server an
// untargeted interrupt would hit every other turn.
let lateCancel = DispatchSemaphore(value: 0)
Task { await runtime.cancel(turnID: request.turnID); lateCancel.signal() }
expect(lateCancel.wait(timeout: .now() + 1) == .success, "cancel did not return")
expect(!fake.interrupted, "a cancel after completion must not interrupt the backend")

// Cancel during the turn targets that turn's thread — whether it arrives
// after the thread is known or (queued) before.
final class BlockingCodex: CodexExecuting {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var interruptedThreads: [String?] = []
    var announceThread = true
    func interrupt() { interruptedThreads.append(nil) }
    func interrupt(threadId: String?) { interruptedThreads.append(threadId) }
    func run(prompt: String, instructions: String, images: [Data], resumeThread: String?,
             workingDirectory: URL?, extraWritableRoots: [String],
             model: String?,
             reasoningEffort: String?,
             onThreadStarted: @escaping (String) -> Void,
             onToolActivity: @escaping (String) -> Void,
             onAgentText: @escaping (String) -> Void) async throws -> CodexExecBackend.TurnResult {
        if announceThread { onThreadStarted("thr-live") }
        started.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { self.release.wait(); continuation.resume() }
        }
        if !announceThread { onThreadStarted("thr-late") }
        return CodexExecBackend.TurnResult(text: "done", threadId: announceThread ? "thr-live" : "thr-late")
    }
}
for lateThread in [false, true] {
    let blocking = BlockingCodex()
    blocking.announceThread = !lateThread
    let blockingRuntime = CodexAgentRuntime(backend: blocking, fallback: nil)
    let liveRequest = AgentTurnRequest(
        turnID: UUID(), conversationID: "conversation-c", assistant: nil,
        priorMessages: [], prompt: "long task", screenshots: [],
        workingDirectory: FileManager.default.temporaryDirectory,
        extraWritableRoots: [], trustProfile: .workspace, model: nil)
    let finished = DispatchSemaphore(value: 0)
    Task {
        _ = try? await blockingRuntime.run(liveRequest, binding: nil) { _ in }
        finished.signal()
    }
    expect(blocking.started.wait(timeout: .now() + 3) == .success, "blocking turn did not start")
    let cancelled = DispatchSemaphore(value: 0)
    Task { await blockingRuntime.cancel(turnID: liveRequest.turnID); cancelled.signal() }
    expect(cancelled.wait(timeout: .now() + 1) == .success, "cancel did not return")
    if lateThread {
        expect(blocking.interruptedThreads.isEmpty, "a cancel before the thread exists must wait, not interrupt everything")
    } else {
        expect(blocking.interruptedThreads == ["thr-live"], "cancel must interrupt exactly the turn's thread: \(blocking.interruptedThreads)")
    }
    blocking.release.signal()
    expect(finished.wait(timeout: .now() + 3) == .success, "blocking turn did not finish")
    if lateThread {
        expect(blocking.interruptedThreads == ["thr-late"], "a queued cancel must apply once the thread is known: \(blocking.interruptedThreads)")
    }
}

// A remembered thread that no longer exists on disk: the adapter starts a
// fresh thread with the canonical handoff instead of failing the turn.
final class GoneThreadCodex: CodexExecuting {
    var prompts: [String] = []
    var instructionInputs: [String] = []
    var resumes: [String?] = []
    func interrupt() {}
    func run(prompt: String, instructions: String, images: [Data], resumeThread: String?,
             workingDirectory: URL?, extraWritableRoots: [String],
             model: String?,
             reasoningEffort: String?,
             onThreadStarted: @escaping (String) -> Void,
             onToolActivity: @escaping (String) -> Void,
             onAgentText: @escaping (String) -> Void) async throws -> CodexExecBackend.TurnResult {
        prompts.append(prompt)
        instructionInputs.append(instructions)
        resumes.append(resumeThread)
        if let resumeThread { throw CodexBackendError.threadNotFound(resumeThread) }
        onThreadStarted("codex-fresh")
        onAgentText("fresh reply")
        return CodexExecBackend.TurnResult(text: "fresh reply", threadId: "codex-fresh")
    }
}
let gone = GoneThreadCodex()
let goneRuntime = CodexAgentRuntime(backend: gone, fallback: nil)
let goneRequest = AgentTurnRequest(
    turnID: UUID(), conversationID: "conversation-b", assistant: nil,
    priorMessages: [AssistantHistoryMessage(role: .user, text: "earlier question"),
                    AssistantHistoryMessage(role: .assistant, text: "earlier answer")],
    prompt: "follow-up", screenshots: [],
    workingDirectory: FileManager.default.temporaryDirectory,
    extraWritableRoots: [], trustProfile: .workspace, model: nil, instructions: "FRESH_IDENTITY")
let goneSemaphore = DispatchSemaphore(value: 0)
var goneResult: AgentTurnResult?
var goneEvents: [String] = []
Task {
    goneResult = try? await goneRuntime.run(goneRequest, binding: RuntimeBinding(
        externalSessionID: "codex-old", state: .clean,
        instructionFingerprint: AgentInstructionEncoding.fingerprint(goneRequest.instructions))) { event in
        if case .started(let id) = event { goneEvents.append("started:\(id)") }
    }
    goneSemaphore.signal()
}
expect(goneSemaphore.wait(timeout: .now() + 3) == .success, "fallback runtime did not finish")
expect(gone.resumes == ["codex-old", nil], "the adapter must retry once without the dead thread: \(gone.resumes)")
expect(gone.prompts.count == 2 && gone.prompts[1].contains("earlier answer") && gone.prompts[1].hasSuffix("follow-up"),
       "the fresh start must carry the canonical handoff before the task: \(gone.prompts)")
expect(gone.instructionInputs == ["FRESH_IDENTITY", "FRESH_IDENTITY"]
       && gone.prompts.allSatisfy { !$0.contains("FRESH_IDENTITY") && !$0.contains(AgentPromptComposer.systemRole) },
       "dead-session recovery must preserve instructions without moving them to the handoff")
expect(goneResult?.externalSessionID == "codex-fresh" && goneEvents == ["started:codex-fresh"],
       "the fresh thread must become the binding")

// An older CLI without app-server: the exec backend takes over for good.
final class NoAppServer: CodexExecuting {
    var calls = 0
    func interrupt() {}
    func run(prompt: String, instructions: String, images: [Data], resumeThread: String?,
             workingDirectory: URL?, extraWritableRoots: [String],
             model: String?,
             reasoningEffort: String?,
             onThreadStarted: @escaping (String) -> Void,
             onToolActivity: @escaping (String) -> Void,
             onAgentText: @escaping (String) -> Void) async throws -> CodexExecBackend.TurnResult {
        calls += 1
        throw CodexBackendError.appServerUnavailable("too old")
    }
}
let broken = NoAppServer()
let execFallback = FakeCodex()
let fallbackRuntime = CodexAgentRuntime(backend: broken, fallback: execFallback)
let fallbackSemaphore = DispatchSemaphore(value: 0)
var fallbackResults: [String] = []
Task {
    for _ in 0..<2 {
        if let result = try? await fallbackRuntime.run(request, binding: nil, emit: { _ in }) {
            fallbackResults.append(result.text)
        }
    }
    fallbackSemaphore.signal()
}
expect(fallbackSemaphore.wait(timeout: .now() + 3) == .success, "exec fallback did not finish")
expect(fallbackResults == ["first second", "first second"], "turns must succeed through the exec fallback")
expect(execFallback.receivedInstructions == request.instructions && execFallback.receivedPrompt == request.prompt,
       "exec fallback must preserve both channels")
expect(broken.calls == 1, "the app-server must be tried once, then left alone: \(broken.calls)")

// Instruction edits (persona, skill, source guidance, or app policy) must not
// resume Codex's stale developer message, even when the history cursor matches.
let editedRequest = AgentTurnRequest(
    turnID: UUID(), conversationID: "conversation-a", assistant: nil,
    priorMessages: [AssistantHistoryMessage(role: .user, text: "CANONICAL_QUESTION"),
                    AssistantHistoryMessage(role: .assistant, text: "CANONICAL_ANSWER")],
    prompt: "NEW_TASK", screenshots: [], workingDirectory: FileManager.default.temporaryDirectory,
    extraWritableRoots: [], trustProfile: .workspace, model: nil, instructions: "UPDATED_PERSONA")
let editedDone = DispatchSemaphore(value: 0)
Task {
    _ = try? await runtime.run(editedRequest, binding: binding) { _ in }
    editedDone.signal()
}
expect(editedDone.wait(timeout: .now() + 3) == .success, "edited-instructions turn did not finish")
expect(fake.receivedResume == nil && fake.receivedInstructions == "UPDATED_PERSONA"
       && fake.receivedPrompt.contains("CANONICAL_ANSWER") && fake.receivedPrompt.hasSuffix("NEW_TASK")
       && !fake.receivedPrompt.contains("UPDATED_PERSONA"),
       "instruction changes must reseed with current instructions and canonical context")

for session in [nil, "resume-id"] as [String?] {
    let instructions = "line one\nline two \"quoted\" \\path $(literal)"
    let args = CodexExecBackend.executionArguments(prompt: "TASK", imagePaths: [],
        resumeThread: session, extraWritableRoots: [], instructions: instructions)
    expect(args.contains("developer_instructions=" + CodexExecBackend.tomlString(instructions))
           && args.last == "TASK", "exec new/resume must use the config instruction channel")
}
print("codex runtime tests passed")
