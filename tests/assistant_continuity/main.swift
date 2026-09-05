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

// An hour old: outside the recent-activity window, so the model decides.
let anHourAgo = Date().addingTimeInterval(-3600)
let current = AssistantConversation(
    codexThreadId: "thread-current",
    title: "Pantrella next cohort retention",
    messages: [
        AssistantHistoryMessage(at: anHourAgo, role: .user, text: "Plan the follow-up for the next cohort"),
        AssistantHistoryMessage(at: anHourAgo, role: .assistant, text: "Use a 48-hour follow-up and measure return rate"),
    ])

// Recent activity reuses without a model call: the round trip is the whole
// wake latency, so it is paid only when the choice is real.
expect(AssistantContinuityClassifier.defaultRecentReuseSeconds == 180,
       "the recent-activity window should be three minutes")
let recentCalls = LockedCounter()
let recentClassifier = AssistantContinuityClassifier(runner: { _ in
    recentCalls.increment()
    return #"{"decision":"new","confidence":0.99,"reason":"model must not be asked"}"#
})
let recent = AssistantConversation(
    codexThreadId: "thread-recent",
    title: "Live exchange",
    messages: [
        AssistantHistoryMessage(at: anHourAgo, role: .user, text: "Earlier question"),
        AssistantHistoryMessage(at: Date().addingTimeInterval(-40), role: .assistant, text: "Reply 40 s ago"),
    ])
let recentOutcome = awaitOutcome(recentClassifier, current: recent, incoming: "Plan tomorrow's gym session")
expect(recentOutcome.decision == .reuse && !recentOutcome.usedFallback && recentCalls.count == 0,
       "a wake within the window must reuse the current conversation without a model call")
let staleCalls = LockedCounter()
let staleClassifier = AssistantContinuityClassifier(runner: { _ in
    staleCalls.increment()
    return #"{"decision":"new","confidence":0.99,"reason":"unrelated"}"#
})
let staleOutcome = awaitOutcome(staleClassifier, current: current, incoming: "Plan tomorrow's gym session")
expect(staleOutcome.decision == .new && staleCalls.count == 1,
       "a wake outside the window must still ask the model")

expect(AssistantContinuityClassifier.defaultTimeoutSeconds == 15,
       "the production FLORA classifier budget should be 15 seconds")

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

// VF-61: an automation owns its conversation — the job resumes that thread on
// every run — so an ambient wake turn must open a fresh one instead of being
// appended to it, and must not spend a model call to decide that.
let automationCalls = LockedCounter()
func rejectingClassifier(_ counter: LockedCounter) -> AssistantContinuityClassifier {
    AssistantContinuityClassifier(runner: { _ in
        counter.increment()
        return #"{"decision":"reuse","confidence":0.99,"reason":"should not run"}"#
    })
}
let automation = AssistantConversation(
    codexThreadId: "thread-automation",
    title: "Morning",
    messages: [
        AssistantHistoryMessage(role: .user, text: "Say hi, and a joke. I'm testing triggers."),
        AssistantHistoryMessage(role: .assistant, text: "Hi Safet. Here is your joke."),
    ],
    automationJobID: "job-morning")
expect(!automation.acceptsWakeTurns, "an automation-owned conversation must not accept wake turns")
let automationOutcome = awaitOutcome(
    rejectingClassifier(automationCalls), current: automation,
    incoming: "add to the queue that we need to pay for the kindergarten food")
expect(automationOutcome.decision == .new && !automationOutcome.usedFallback,
       "a wake turn must never be appended to an automation's conversation")
expect(automationCalls.count == 0,
       "an ineligible conversation should be rejected without a model call")

// The reconciled many-to-one mirror is authoritative too, and an automation's
// conversation is still blank before its first run — the empty-draft shortcut
// must not claim it.
let mirroredCalls = LockedCounter()
let mirroredEmpty = AssistantConversation(
    title: "Nightly review", automationJobIDs: ["job-nightly"])
expect(!mirroredEmpty.acceptsWakeTurns,
       "a mirrored automation reference must also block wake turns")
let mirroredOutcome = awaitOutcome(
    rejectingClassifier(mirroredCalls), current: mirroredEmpty, incoming: "remind me to call the bank")
expect(mirroredOutcome.decision == .new && mirroredCalls.count == 0,
       "an unrun automation conversation must not be mistaken for a blank draft")

// A thread the user completed is filed away; a wake turn starts fresh.
let completedCalls = LockedCounter()
let completed = AssistantConversation(
    title: "Pantrella next cohort retention",
    messages: [AssistantHistoryMessage(role: .user, text: "Plan the follow-up")],
    completedAt: Date())
expect(!completed.acceptsWakeTurns, "a completed conversation must not accept wake turns")
let completedOutcome = awaitOutcome(
    rejectingClassifier(completedCalls), current: completed, incoming: "and the follow-up copy")
expect(completedOutcome.decision == .new && completedCalls.count == 0,
       "a wake turn must never reopen a completed conversation")

expect(current.acceptsWakeTurns && AssistantConversation().acceptsWakeTurns,
       "ordinary open conversations must stay eligible for continuity")

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
