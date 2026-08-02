import Foundation

// AssistantHistory.swift logs through the app helper; the standalone harness
// supplies the same symbol without pulling the AppKit runtime into the test.
func vflog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("voice-flow-assistant-history-tests-\(UUID().uuidString)")
let url = directory.appendingPathComponent("assistant-sessions.json")

// Redirected stores are a privacy boundary: the default initializer must not
// discover or import the host user's ~/.codex rollouts.
expect(VoiceFlowPaths.shared.isIsolated, "history test root is not isolated")
let isolatedDefault = AssistantHistoryStore(
    url: directory.appendingPathComponent("isolated-default.json"))
expect(isolatedDefault.conversations().count == 1
       && isolatedDefault.activeConversation().messages.isEmpty,
       "isolated history imported host Codex data")

// Two conversations round-trip with distinct transcripts and resume pointers.
let store = AssistantHistoryStore(url: url, legacySessionsRoot: nil)
let first = store.activeConversation()
store.appendMessage(sessionId: first.id, role: .user, text: "First question")
store.appendMessage(sessionId: first.id, role: .assistant, text: "First answer")
store.setCodexThreadId("thread-first", for: first.id)

let second = store.createConversation()
store.appendMessage(sessionId: second.id, role: .user, text: "Second question")
store.appendMessage(sessionId: second.id, role: .assistant, text: "Second answer")
store.setCodexThreadId("thread-second", for: second.id)
_ = store.activate(first.id)

let reloaded = AssistantHistoryStore(url: url, legacySessionsRoot: nil)
expect(reloaded.conversations().count == 2, "two sessions should survive reload")
expect(reloaded.activeSessionId == first.id, "active session should survive reload")
expect(reloaded.conversation(first.id)?.codexThreadId == "thread-first", "first resume pointer crossed or disappeared")
expect(reloaded.conversation(second.id)?.codexThreadId == "thread-second", "second resume pointer crossed or disappeared")
expect(reloaded.conversation(first.id)?.messages.map(\.text) == ["First question", "First answer"], "first transcript changed")
expect(reloaded.conversation(second.id)?.messages.map(\.text) == ["Second question", "Second answer"], "second transcript changed")
expect(reloaded.conversation(first.id)?.title == "First question", "title should derive from first user turn")

// New Assistant replies carry the local-picker unread cursor. Viewing them
// consumes that cursor without reordering conversation activity.
expect(reloaded.conversation(first.id)?.hasUnseenAssistantReply == true,
       "new Assistant reply should reload as unseen")
let updatedBeforeSeen = reloaded.conversation(first.id)!.updatedAt
reloaded.markAssistantRepliesSeen(for: first.id)
let seenFirst = reloaded.conversation(first.id)!
expect(seenFirst.hasUnseenAssistantReply == false, "viewing should consume Assistant replies")
expect(seenFirst.messages.last?.seen == true, "seen cursor should persist on the Assistant reply")
expect(seenFirst.updatedAt == updatedBeforeSeen, "viewing must not reorder the conversation")
let seenReloaded = AssistantHistoryStore(url: url, legacySessionsRoot: nil)
expect(seenReloaded.conversation(first.id)?.messages.last?.seen == true,
       "seen cursor should survive reload")

// A process death while a turn is running becomes one durable interruption,
// never a blank thread and never another duplicate note on later launches.
reloaded.setTurnState(.running, for: first.id)
let recovered = AssistantHistoryStore(url: url, legacySessionsRoot: nil)
let recoveredFirst = recovered.conversation(first.id)!
expect(recoveredFirst.turnState == .interrupted, "running turn should recover as interrupted")
expect(recoveredFirst.messages.filter { $0.role == .note }.count == 1, "recovery should append one interruption note")
let recoveredAgain = AssistantHistoryStore(url: url, legacySessionsRoot: nil)
expect(recoveredAgain.conversation(first.id)!.messages.filter { $0.role == .note }.count == 1,
       "repeated reload must not duplicate interruption notes")

// Deleting one session preserves the other; deleting the final session leaves
// a new empty target so the Assistant can always accept a message.
let remaining = recoveredAgain.delete(first.id)
expect(remaining.id == second.id, "deleting active first session should activate the survivor")
expect(recoveredAgain.conversation(second.id)?.messages.count == 2, "deleting first session damaged second transcript")
let replacement = recoveredAgain.delete(second.id)
expect(replacement.id != first.id && replacement.id != second.id, "final deletion should create a distinct replacement")
expect(replacement.messages.isEmpty, "replacement session should be empty")

// Repeated "new assistant" presses reuse a blank draft instead of creating
// visible rows with no conversation behind them.
let draftsURL = directory.appendingPathComponent("drafts.json")
let drafts = AssistantHistoryStore(url: draftsURL, legacySessionsRoot: nil)
let draftA = drafts.activeConversation()
let draftB = drafts.createConversation()
expect(draftA.id == draftB.id, "new assistant should reuse the active empty draft")
expect(drafts.conversations().count == 1, "empty draft presses should not multiply sessions")
let forcedDraft = drafts.createConversation(force: true)
expect(forcedDraft.id != draftA.id && drafts.conversations().count == 2,
       "QA force-create could not establish isolated concurrency fixtures")

// A pre-store Voice Flow rollout imports once by its explicit preamble and
// keeps all streamed agent messages as the single Assistant reply shown in UI.
let legacyRoot = directory.appendingPathComponent("legacy/2026/07/19")
try! FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
let rollout = legacyRoot.appendingPathComponent("rollout.jsonl")
func jsonLine(_ value: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}
let legacyLines = [
    jsonLine(["type": "session_meta", "payload": ["id": "legacy-thread"]]),
    jsonLine(["timestamp": "2026-07-19T19:32:38.205Z", "type": "event_msg", "payload": [
        "type": "user_message",
        "message": "You are the assistant inside Voice Flow, a macOS companion app\nwrite the finished content into your reply instead of trying to create files or call external services.\n\nRecover this conversation",
    ]]),
    jsonLine(["timestamp": "2026-07-19T19:32:45.507Z", "type": "event_msg", "payload": [
        "type": "agent_message", "message": "Working on it.",
    ]]),
    jsonLine(["timestamp": "2026-07-19T19:34:09.853Z", "type": "event_msg", "payload": [
        "type": "agent_message", "message": "Recovered result.",
    ]]),
    jsonLine(["timestamp": "2026-07-19T19:34:09.869Z", "type": "event_msg", "payload": [
        "type": "task_complete", "last_agent_message": "Recovered result.",
    ]]),
]
try! (legacyLines.joined(separator: "\n") + "\n").write(to: rollout, atomically: true, encoding: .utf8)
let legacyURL = directory.appendingPathComponent("legacy-store.json")
let imported = AssistantHistoryStore(
    url: legacyURL,
    legacySessionsRoot: directory.appendingPathComponent("legacy"))
expect(imported.conversations().count == 1, "import should replace scaffolding with one real legacy session")
let legacy = imported.activeConversation()
expect(legacy.codexThreadId == "legacy-thread", "legacy resume pointer should import")
expect(legacy.messages.map(\.role) == [.user, .assistant], "legacy roles should reconstruct")
expect(legacy.messages[0].text == "Recover this conversation", "Voice Flow preamble should not appear in history")
expect(legacy.messages[1].text == "Working on it.\n\nRecovered result.", "streamed pieces should reconstruct one reply")
expect(legacy.messages[1].seen == nil, "legacy replies without a cursor must remain neutral")
let importedAgain = AssistantHistoryStore(
    url: legacyURL,
    legacySessionsRoot: directory.appendingPathComponent("legacy"))
expect(importedAgain.conversations().count == 1, "legacy import must run only once")

// Runtime synchronization is transactional: resume only through the exact
// canonical context cursor, dirty before I/O, clean only after one final.
let bindingsURL = directory.appendingPathComponent("runtime-bindings.json")
let bindings = AssistantHistoryStore(url: bindingsURL, legacySessionsRoot: nil)
let bindingConversation = bindings.activeConversation()
bindings.appendMessage(sessionId: bindingConversation.id, role: .user, text: "Canonical one")
bindings.appendMessage(sessionId: bindingConversation.id, role: .assistant, text: "Canonical two")
bindings.setCodexThreadId("legacy-codex-thread", for: bindingConversation.id)

let migratedBinding = AssistantHistoryStore(url: bindingsURL, legacySessionsRoot: nil)
    .conversation(bindingConversation.id)?.runtimeBinding(.codex)
expect(migratedBinding?.externalSessionID == "legacy-codex-thread",
       "legacy Codex id must expand into a runtime binding")
expect(migratedBinding?.state == .dirty,
       "legacy Codex binding must be dirty because API fallback may have advanced history")

bindings.setPreferredRuntime(.opencode, for: bindingConversation.id)
let firstOpenCode = bindings.beginRuntimeTurn(
    sessionId: bindingConversation.id, runtime: .opencode, text: "OpenCode turn")!
expect(firstOpenCode.requiresFreshSession, "first OpenCode turn must create a fresh session")
expect(firstOpenCode.resumeExternalSessionID == nil, "first OpenCode turn cannot resume")
expect(bindings.conversation(bindingConversation.id)?.runtimeBinding(.opencode)?.state == .dirty,
       "binding must persist dirty before runtime I/O")
bindings.recordRuntimeStarted(
    sessionId: bindingConversation.id, runtime: .opencode,
    externalSessionID: "oc-one", runtimeVersion: "1.2.3", fresh: true)
let openCodeFinal = bindings.completeRuntimeTurn(
    sessionId: bindingConversation.id, runtime: .opencode,
    text: "OpenCode answer", externalSessionID: "oc-one", runtimeVersion: "1.2.3")!
let cleanOpenCode = bindings.conversation(bindingConversation.id)!.runtimeBinding(.opencode)!
expect(cleanOpenCode.state == .clean, "authoritative final must clean the selected binding")
expect(cleanOpenCode.syncedThroughMessageID == openCodeFinal.id,
       "clean cursor must point at the canonical final message")
expect(cleanOpenCode.generation == 1, "fresh external session increments generation once")

let resumedOpenCode = bindings.beginRuntimeTurn(
    sessionId: bindingConversation.id, runtime: .opencode, text: "Resume OpenCode")!
expect(resumedOpenCode.resumeExternalSessionID == "oc-one",
       "exact clean cursor must resume its external session")
bindings.endRuntimeTurnWithoutFinal(sessionId: bindingConversation.id, interrupted: true)
expect(bindings.conversation(bindingConversation.id)?.runtimeBinding(.opencode)?.state == .dirty,
       "interruption must leave the binding dirty")
let recoveredOpenCode = bindings.beginRuntimeTurn(
    sessionId: bindingConversation.id, runtime: .opencode, text: "Recover OpenCode")!
expect(recoveredOpenCode.requiresFreshSession,
       "a turn after interruption must reseed instead of resuming uncertain state")
let messagesBeforeOverlap = bindings.conversation(bindingConversation.id)!.messages.count
let overlappingTurn = bindings.beginRuntimeTurn(
    sessionId: bindingConversation.id, runtime: .codex, text: "Must not overlap")
expect(overlappingTurn == nil, "foreground/background turns overlapped one conversation")
expect(bindings.conversation(bindingConversation.id)!.messages.count == messagesBeforeOverlap,
       "rejected overlapping turn still appended a user message")
bindings.endRuntimeTurnWithoutFinal(sessionId: bindingConversation.id, interrupted: true)

let persistedBindingData = try! Data(contentsOf: bindingsURL)
let persistedBindingJSON = try! JSONSerialization.jsonObject(with: persistedBindingData) as! [String: Any]
expect(persistedBindingJSON["version"] as? Int == 1,
       "expand migration must retain the rollback-readable version-1 envelope")
let persistedSessions = persistedBindingJSON["sessions"] as! [[String: Any]]
expect(persistedSessions.first?["codexThreadId"] as? String == "legacy-codex-thread",
       "legacy Codex id must remain mirrored during the rollback window")

print("assistant history tests passed")
