import Foundation

final class PendingInteraction {
    let sessionId: String?
    init(sessionId: String?) { self.sessionId = sessionId }
}

struct CaptureSummary {
    let id: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let paste = PasteTarget(processIdentifier: 42, name: "Editor")
if case .paste(let target) = CaptureRouter.resolve(
    policy: .contextual, focus: .none, pasteTarget: paste, pendingInteraction: nil) {
    expect(target == paste, "context-free Dictate must retain its exact paste target")
} else {
    expect(false, "context-free Dictate must paste")
}

if case .assistant = CaptureRouter.resolve(
    policy: .contextual, focus: .assistant, pasteTarget: paste, pendingInteraction: nil) {
    // expected
} else {
    expect(false, "visible assistant must outrank the external paste target")
}

let matching = PendingInteraction(sessionId: "A")
if case .session(let id, let interaction) = CaptureRouter.resolve(
    policy: .contextual, focus: .session("A"), pasteTarget: paste,
    pendingInteraction: matching) {
    expect(id == "A", "session route must freeze the visible ID")
    expect(interaction === matching, "matching ask must be frozen with the session")
} else {
    expect(false, "visible session must resolve to an exact session route")
}

let other = PendingInteraction(sessionId: "B")
if case .session(let id, let interaction) = CaptureRouter.resolve(
    policy: .contextual, focus: .session("A"), pasteTarget: nil,
    pendingInteraction: other) {
    expect(id == "A" && interaction == nil, "background ask must not hijack visible session A")
} else {
    expect(false, "visible session A must remain selected")
}

if case .historyOnly = CaptureRouter.resolve(
    policy: .historyOnly, focus: .session("A"), pasteTarget: paste,
    pendingInteraction: matching) {
    // expected
} else {
    expect(false, "toggle Dictate must remain history-only in every visible context")
}

let r1 = UUID(), r2 = UUID()
var run1 = CaptureRun(id: r1, capability: .dictate, route: .historyOnly,
                      startedAt: Date(), snapshot: .notNeeded)
var run2 = CaptureRun(id: r2, capability: .snapshot, route: .paste(paste),
                      startedAt: Date(), snapshot: .pending)
run1.phase = .awaitingTranscription
run2.phase = .awaitingTranscription
let runs = [r1: run1, r2: run2]
expect(CaptureCorrelation.resolve(requestId: r2.uuidString, runs: runs) == r2,
       "explicit R2 result must resolve to R2 even when R1 stopped first")
expect(CaptureCorrelation.resolve(requestId: r1.uuidString, runs: runs) == r1,
       "explicit R1 result must resolve independently")
expect(CaptureCorrelation.resolve(requestId: nil, runs: runs) == nil,
       "ID-less result must never guess between two pending runs")
expect(CaptureCorrelation.resolve(requestId: nil, runs: [r1: run1]) == r1,
       "legacy ID-less result may resolve only when exactly one run is pending")

print("capture routing tests passed")
