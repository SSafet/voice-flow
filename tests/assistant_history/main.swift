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
let store = AssistantHistoryStore(url: url)
let first = store.activeConversation()
store.appendMessage(sessionId: first.id, role: .user, text: "First question")
store.appendMessage(sessionId: first.id, role: .assistant, text: "First answer")
store.setCodexThreadId("thread-first", for: first.id)

let second = store.createConversation()
store.appendMessage(sessionId: second.id, role: .user, text: "Second question")
store.appendMessage(sessionId: second.id, role: .assistant, text: "Second answer")
store.setCodexThreadId("thread-second", for: second.id)
_ = store.activate(first.id)

let reloaded = AssistantHistoryStore(url: url)
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
let recovered = AssistantHistoryStore(url: url)
let recoveredFirst = recovered.conversation(first.id)!
expect(recoveredFirst.turnState == .interrupted, "running turn should recover as interrupted")
expect(recoveredFirst.messages.filter { $0.role == .note }.count == 1, "recovery should append one interruption note")
let recoveredAgain = AssistantHistoryStore(url: url)
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

print("assistant history tests passed")
