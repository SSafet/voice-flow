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
let importedAgain = AssistantHistoryStore(
    url: legacyURL,
    legacySessionsRoot: directory.appendingPathComponent("legacy"))
expect(importedAgain.conversations().count == 1, "legacy import must run only once")

print("assistant history tests passed")
