import Foundation

// AssistantHistory.swift logs through the app helper; the standalone harness
// supplies the same symbol without pulling AppKit into this focused test.
func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

private func awaitOutcome(
    _ classifier: AssistantContinuityClassifier,
    current: AssistantConversation,
    incoming: String
) -> AssistantContinuityOutcome {
    let semaphore = DispatchSemaphore(value: 0)
    var result: AssistantContinuityOutcome?
    Task {
        result = await classifier.decide(current: current, incoming: incoming)
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

let current = AssistantConversation(
    codexThreadId: "thread-current",
    title: "Pantrella next cohort retention",
    messages: [
        AssistantHistoryMessage(role: .user, text: "Plan the follow-up for the next cohort"),
        AssistantHistoryMessage(role: .assistant, text: "Use a 48-hour follow-up and measure return rate"),
    ])

let reuseClassifier = AssistantContinuityClassifier(runner: { _ in
    #"{"decision":"reuse","confidence":0.92,"reason":"referential follow-up"}"#
})
let reuse = awaitOutcome(
    reuseClassifier, current: current,
    incoming: "And turn that into a message I can send")
expect(reuse.decision == .reuse && !reuse.usedFallback, "valid reuse decision should pass through")

let newClassifier = AssistantContinuityClassifier(runner: { _ in
    #"{"decision":"new","confidence":0.91,"reason":"unrelated gym plan"}"#
})
let fresh = awaitOutcome(
    newClassifier, current: current,
    incoming: "Plan tomorrow's gym session")
expect(fresh.decision == .new && !fresh.usedFallback, "confident new decision should pass through")

let lowConfidence = AssistantContinuityClassifier(runner: { _ in
    #"{"decision":"new","confidence":0.64,"reason":"maybe unrelated"}"#
})
let low = awaitOutcome(lowConfidence, current: current, incoming: "Maybe another thing")
expect(low.decision == .reuse && low.usedFallback, "low-confidence new must fail safe to reuse")

let malformed = AssistantContinuityClassifier(runner: { _ in "not json" })
let invalid = awaitOutcome(malformed, current: current, incoming: "Anything")
expect(invalid.decision == .reuse && invalid.usedFallback, "malformed output must fail safe to reuse")

let missing = AssistantContinuityClassifier(runner: { _ in "" })
let emptyOutput = awaitOutcome(missing, current: current, incoming: "Anything")
expect(emptyOutput.decision == .reuse && emptyOutput.usedFallback,
       "missing output must fail safe to reuse")

enum StubFailure: Error { case processExit }
let failedProcess = AssistantContinuityClassifier(runner: { _ in throw StubFailure.processExit })
let failed = awaitOutcome(failedProcess, current: current, incoming: "Anything")
expect(failed.decision == .reuse && failed.usedFallback, "process failure must fail safe to reuse")

let unknownDecision = AssistantContinuityClassifier(runner: { _ in
    #"{"decision":"older","confidence":0.99,"reason":"forbidden"}"#
})
let unknown = awaitOutcome(unknownDecision, current: current, incoming: "Anything")
expect(unknown.decision == .reuse && unknown.usedFallback,
       "unknown decisions must never select another conversation")

let timeout = AssistantContinuityClassifier(timeoutSeconds: 0.05, runner: { _ in
    try await Task.sleep(nanoseconds: 2_000_000_000)
    return #"{"decision":"new","confidence":1,"reason":"late"}"#
})
let timedOut = awaitOutcome(timeout, current: current, incoming: "Anything")
expect(timedOut.decision == .reuse && timedOut.usedFallback, "timeout must fail safe to reuse")

let calls = LockedCounter()
let emptyClassifier = AssistantContinuityClassifier(runner: { _ in
    calls.increment()
    return #"{"decision":"new","confidence":1,"reason":"should not run"}"#
})
let empty = awaitOutcome(emptyClassifier, current: AssistantConversation(), incoming: "First message")
expect(empty.decision == .reuse && calls.count == 0, "empty draft should reuse without a model call")

var manyMessages: [AssistantHistoryMessage] = []
for index in 1...8 {
    manyMessages.append(AssistantHistoryMessage(role: .user, text: "message-\(index)"))
}
let bounded = AssistantConversation(title: "Bounded context", messages: manyMessages)
let prompt = AssistantContinuityClassifier.prompt(current: bounded, incoming: "next")
expect(!prompt.contains("message-1") && !prompt.contains("message-2"),
       "classifier context should exclude messages older than the last six")
expect(prompt.contains("message-3") && prompt.contains("message-8"),
       "classifier context should retain the last six messages")
expect(prompt.contains("Never choose or mention an older conversation"),
       "prompt must prohibit historical-session selection")

let localId = LocalAssistantSessionAdapter.id(for: "flora")
expect(localId == "assistant:flora", "local Assistant id should be stable and namespaced")
expect(LocalAssistantSessionAdapter.slug(from: localId) == "flora", "local Assistant id should round-trip")
expect(LocalAssistantSessionAdapter.slug(from: "mcp-session") == nil,
       "MCP ids must never be mistaken for local Assistant ids")

print("assistant continuity tests passed")
