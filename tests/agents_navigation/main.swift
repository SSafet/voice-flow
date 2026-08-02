import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private let now = Date(timeIntervalSince1970: 10_000)
private let assistantThread = AgentsThreadID(source: .assistant, value: "same-title")
private let mcpThread = AgentsThreadID(source: .mcp, value: "same-title")

private func thread(_ id: AgentsThreadID, unread: Bool = false,
                    pending: Bool = false, live: Bool = false,
                    archived: Bool = false, age: TimeInterval = 0) -> AgentsThreadProjectionInput {
    AgentsThreadProjectionInput(
        id: id, title: "Shared title", owner: id.source.rawValue,
        preview: "preview", updatedAt: now.addingTimeInterval(-age),
        unread: unread, pendingAsk: pending, live: live, archived: archived)
}

// State precedence is deterministic and archived rows never leak into Open.
expect(AgentsThreadProjection.group(for: thread(assistantThread, unread: true, pending: true, live: true)) == .needsYou,
       "pending ask must outrank unread/live")
expect(AgentsThreadProjection.group(for: thread(assistantThread, unread: true, live: true)) == .unread,
       "unread must outrank live")
expect(AgentsThreadProjection.group(for: thread(assistantThread, live: true)) == .live,
       "live thread classified incorrectly")
expect(AgentsThreadProjection.group(for: thread(assistantThread, archived: true)) == .done,
       "archive must outrank every open state")

// Every durable job state has exactly one presentation group.
let expectedJobGroups: [AgentsAutomationState: AgentsAutomationGroup] = [
    .blocked: .needsAttention, .failed: .needsAttention,
    .running: .activeUpcoming, .queued: .activeUpcoming,
    .completed: .ready, .cancelled: .disabled, .disabled: .disabled,
]
expect(expectedJobGroups.count == AgentsAutomationState.allCases.count,
       "test must cover every automation state")
for (state, expected) in expectedJobGroups {
    let input = AgentsAutomationProjectionInput(
        id: state.rawValue, name: state.rawValue, assistantName: "FLORA",
        updatedAt: now, state: state)
    expect(AgentsAutomationProjection.group(for: input) == expected,
           "wrong group for \(state.rawValue)")
}

let automations = [
    AgentsAutomationProjectionInput(id: "blocked", name: "Blocked", assistantName: "FLORA", updatedAt: now, state: .blocked),
    AgentsAutomationProjectionInput(id: "failed", name: "Failed", assistantName: "FLORA", updatedAt: now.addingTimeInterval(1), state: .failed),
    AgentsAutomationProjectionInput(id: "running", name: "Running", assistantName: "FLORA", updatedAt: now.addingTimeInterval(-5), state: .running),
    AgentsAutomationProjectionInput(id: "queued", name: "Queued", assistantName: "FLORA", updatedAt: now, state: .queued),
]
let nowSnapshot = AgentsNowProjection.snapshot(
    threads: [thread(mcpThread, unread: true, pending: true),
              thread(assistantThread, live: true)],
    automations: automations)
expect(nowSnapshot.needsYou.map(\.kind) == [.pendingAsk, .blockedAutomation, .failedAutomation],
       "Now attention ordering or membership is wrong")
expect(nowSnapshot.running.map(\.kind) == [.runningThread, .runningAutomation],
       "Now must contain running work only, ordered by recent activity")
expect(nowSnapshot.attentionCount == 3, "Now badge must count unresolved objects once")

// Equal titles remain distinct typed results and deep-link to their true store.
let documents = [
    AgentsSearchDocument(
        objectID: .thread(assistantThread), primaryText: "Shared title",
        secondaryText: "FLORA", indexText: "local transcript", updatedAt: now),
    AgentsSearchDocument(
        objectID: .thread(mcpThread), primaryText: "Shared title",
        secondaryText: "Claude #5", indexText: "external report", updatedAt: now),
    AgentsSearchDocument(
        objectID: .automation(jobID: "job-1"), primaryText: "Daily triage",
        secondaryText: "FLORA", indexText: "shared title in prompt", updatedAt: now),
]
let titleResults = AgentsSearchIndex.search("shared title", in: documents)
expect(titleResults.count == 3, "search should return all typed title/prompt matches")
expect(Set(titleResults.map(\.objectID)).count == 3, "duplicate titles collapsed distinct objects")
expect(titleResults.filter { $0.destination == .threads }.count == 2,
       "thread search routed to the wrong destination")
expect(AgentsSearchIndex.search("flora transcript", in: documents).map(\.objectID) == [.thread(assistantThread)],
       "multi-token search must use AND semantics across indexed fields")
expect(AgentsSearchIndex.search("", in: documents).isEmpty, "empty query must not dump inventory")

print("agents navigation: ok")
