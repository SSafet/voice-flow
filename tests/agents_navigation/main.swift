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
                    archived: Bool = false, running: Bool = false,
                    age: TimeInterval = 0) -> AgentsThreadProjectionInput {
    AgentsThreadProjectionInput(
        id: id, title: "Shared title", owner: id.source.rawValue,
        preview: "preview", updatedAt: now.addingTimeInterval(-age),
        unread: unread, pendingAsk: pending, live: live, archived: archived,
        running: running)
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

let filterThreads = [
    thread(assistantThread, unread: true, pending: true, live: true),
    thread(mcpThread, unread: true, live: true, age: 1),
    thread(AgentsThreadID(source: .assistant, value: "neutral-live"), live: true, age: 2),
    thread(AgentsThreadID(source: .mcp, value: "recent"), age: 3),
    thread(AgentsThreadID(source: .assistant, value: "done"), unread: true, archived: true),
]
let openSections = AgentsThreadProjection.sections(filterThreads, for: .open)
expect(openSections.map(\.group) == [.needsYou, .unread, .live, .recent],
       "Open filter must use exclusive attention precedence")
expect(openSections.flatMap(\.rows).count == 4,
       "Open filter duplicated or leaked a completed thread")
expect(AgentsThreadProjection.filtered(filterThreads, by: .needs).map(\.id) == [assistantThread],
       "Needs filter must contain the overlapping high-priority thread")
expect(Set(AgentsThreadProjection.filtered(filterThreads, by: .unread).map(\.id))
       == Set([assistantThread, mcpThread]),
       "Unread filter must overlap Needs without including Done")
expect(AgentsThreadProjection.filtered(filterThreads, by: .live).count == 3,
       "Live filter must include every open live thread")
expect(AgentsThreadProjection.filtered(filterThreads, by: .done).map(\.id)
       == [AgentsThreadID(source: .assistant, value: "done")],
       "Done filter must contain only completed history")
expect(AgentsThreadProjection.attentionCount(filterThreads) == 2,
       "Threads badge must count unique open needs/unread threads")

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
expect(AgentsAutomationProjection.group(for: AgentsAutomationProjectionInput(
    id: "off-failure", name: "Off failure", assistantName: "FLORA",
    updatedAt: now, state: .failed, isEnabled: false)) == .disabled,
       "explicit Disable must outrank a retained failure diagnostic")

let automations = [
    AgentsAutomationProjectionInput(id: "blocked", name: "Blocked", assistantName: "FLORA", updatedAt: now, state: .blocked),
    AgentsAutomationProjectionInput(id: "failed", name: "Failed", assistantName: "FLORA", updatedAt: now.addingTimeInterval(1), state: .failed),
    AgentsAutomationProjectionInput(id: "running", name: "Running", assistantName: "FLORA", updatedAt: now.addingTimeInterval(-5), state: .running),
    AgentsAutomationProjectionInput(id: "queued", name: "Queued", assistantName: "FLORA", updatedAt: now, state: .queued),
]
let nowSnapshot = AgentsNowProjection.snapshot(
    threads: [thread(mcpThread, unread: true, pending: true),
              thread(assistantThread, live: true, running: true)],
    automations: automations)
expect(nowSnapshot.needsYou.map(\.kind) == [.pendingAsk, .blockedAutomation, .failedAutomation],
       "Now attention ordering or membership is wrong")
expect(nowSnapshot.running.map(\.kind) == [.runningThread, .runningAutomation],
       "Now must contain running work only, ordered by recent activity")
expect(nowSnapshot.attentionCount == 3, "Now badge must count unresolved objects once")

// Unread replies are for the user: they belong in Now, after asks and running
// work, newest first — but they never inflate the attention badge, and an
// archived or asking thread is never listed twice.
let unreadSnapshot = AgentsNowProjection.snapshot(
    threads: [thread(AgentsThreadID(source: .mcp, value: "older"), unread: true, age: 5),
              thread(AgentsThreadID(source: .assistant, value: "newer"), unread: true, age: 1),
              thread(mcpThread, unread: true, pending: true),
              thread(AgentsThreadID(source: .mcp, value: "done"), unread: true, archived: true),
              thread(AgentsThreadID(source: .mcp, value: "quiet"))],
    automations: [])
expect(unreadSnapshot.unread.map(\.objectID) == [
    .thread(AgentsThreadID(source: .assistant, value: "newer")),
    .thread(AgentsThreadID(source: .mcp, value: "older"))],
       "Now must list open unread threads newest first, without asks or archive")
expect(unreadSnapshot.needsYou.map(\.objectID) == [.thread(mcpThread)],
       "an unread ask stays in Needs you only")
expect(unreadSnapshot.attentionCount == 1,
       "unread threads must not inflate the attention badge")
let onlyUnread = AgentsNowProjection.snapshot(
    threads: [thread(AgentsThreadID(source: .mcp, value: "only-unread"), unread: true)],
    automations: [])
expect(onlyUnread.needsYou.isEmpty && onlyUnread.running.isEmpty && !onlyUnread.isEmpty,
       "Now must not read All clear while an unread reply is waiting")

// Live means reachable; running means verifiably working. An idle connected
// external session must never occupy "Running now" (or Now can never reach
// "All clear"), while it still groups as Live in the Threads destination.
let idleConnected = thread(mcpThread, live: true)
let idleSnapshot = AgentsNowProjection.snapshot(threads: [idleConnected], automations: [])
expect(idleSnapshot.running.isEmpty && idleSnapshot.needsYou.isEmpty,
       "an idle connected session leaked into Now")
expect(AgentsThreadProjection.group(for: idleConnected) == .live,
       "an idle connected session must still group as Live in Threads")

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

// The nav bar shows reading surfaces first and one Setup surface; automations
// deep-link into Setup rather than owning a tab.
expect(AgentsDestination.navigation == [.now, .threads, .assistants],
       "nav bar must be Now · Threads · Setup")
expect(AgentsDestination.automations.navigationItem == .assistants
       && AgentsDestination.threads.navigationItem == .threads,
       "automations must light the Setup item; every other destination lights itself")
expect(AgentsDestination.assistants.label == "Setup", "the shared setup surface is labelled Setup")
