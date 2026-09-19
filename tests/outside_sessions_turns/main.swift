import Foundation

// V8, an outside session's turns in the store (06 §3.12): a message the person
// sends starts a turn that is `queued` until the session next listens, then
// `running`; each report while it runs is an `assistant_message` item in that
// turn; the turn completes when the session listens again; a report with no
// open turn is a completed turn of its own; a report with a question is a
// question item and the tool call stays blocked until an answer arrives; and a
// listen delivers the user's words to the session.
//
// Everything here goes through `OutsideSessionBridge`'s public surface.

let turnsHarness = BridgeHarness()
let bridge = turnsHarness.bridge
let store = turnsHarness.store
let questions = turnsHarness.questions
let now = turnsHarness.now

_ = try await bridge.seen(sessionID: "s1", client: "claude-code")
_ = try await bridge.report(sessionID: "s1", summary: "Working on it", details: "",
                            question: nil, timeoutSeconds: nil)

// 0. A listen engages an invisible session; a bare check does not.
let listenOnly = BridgeHarness()
_ = try await listenOnly.bridge.seen(sessionID: "sess-listen", client: "claude-code")
_ = try listenOnly.bridge.checkMessages(sessionID: "sess-listen")
check("check_messages alone creates no thread",
      try listenOnly.store.threads(runtime: .external).isEmpty)
_ = try await listenOnly.bridge.waitForMessage(sessionID: "sess-listen", timeoutSeconds: 0.05)
check("wait_for_message engages and creates the thread",
      try listenOnly.store.thread(id: "sess-listen") != nil)

// 1. A message from the person is a queued turn with a user_message item and
//    the command id it was sent with; nothing runs a runtime.
let sent = try await bridge.send(threadID: "s1", text: "What does the diff touch?",
                                 commandID: "c1")
checkEqual("the send is queued", sent.status, .queued)
let queuedItems = try store.items(turnID: sent.id)
checkEqual("the queued turn carries one user message", queuedItems.count, 1)
checkEqual("its kind is user_message", queuedItems.first?.kind, .userMessage)
checkEqual("its text is the person's words", queuedItems.first?.text, "What does the diff touch?")
checkEqual("it keeps the command id", queuedItems.first?.commandID, "c1")

// 2. A listen delivers the queued words and moves that turn to running.
var delivery = try bridge.checkMessages(sessionID: "s1")
checkEqual("a listen delivers the queued message", delivery.outcome, .message)
checkEqual("the delivered text is the person's words", delivery.message?.text,
           "What does the diff touch?")
checkEqual("the delivered message is the user_message item",
           delivery.message?.itemID, queuedItems.first?.id)
checkEqual("the turn is now running", try store.turn(id: sent.id)?.status, .running)
checkEqual("the thread is running", try store.thread(id: "s1")?.activity, .running)

// 3. A report while the turn runs is an assistant_message item in the same turn,
//    and the turn stays open until the next listen.
_ = try await bridge.report(sessionID: "s1", summary: "It touches two files", details: "a.swift, b.swift",
                            question: nil, timeoutSeconds: nil)
let runningItems = try store.items(turnID: sent.id)
checkEqual("the running turn gained one item", runningItems.count, 2)
checkEqual("the report is an assistant_message", runningItems.last?.kind, .assistantMessage)
checkEqual("the report's text is summary and details", runningItems.last?.text,
           "It touches two files\n\na.swift, b.swift")
checkEqual("the turn is still running", try store.turn(id: sent.id)?.status, .running)

// 4. The next listen completes the open turn.
let empty = try bridge.checkMessages(sessionID: "s1")
checkEqual("a listen with nothing queued delivers nothing", empty.outcome, .none)
let completed = try store.turn(id: sent.id)
checkEqual("the listen completed the open turn", completed?.status, .completed)
checkEqual("the completion has an end reason", completed?.stopReason, .endTurn)
check("the completion has an end time", completed?.endedAt != nil)
checkEqual("the thread is idle again", try store.thread(id: "s1")?.activity, .idle)

// 5. A report with no open turn is a completed turn of its own, with no user
//    message.
_ = try await bridge.report(sessionID: "s1", summary: "Done", details: "",
                            question: nil, timeoutSeconds: nil)
let soloTurns = try store.turns(threadID: "s1")
let solo = soloTurns.last!
checkEqual("a report with no open turn makes a turn", solo.status, .completed)
let soloItems = try store.items(turnID: solo.id)
checkEqual("that turn has one item", soloItems.count, 1)
checkEqual("and it is the report, not a user message", soloItems.first?.kind, .assistantMessage)
check("that turn has no user message", soloItems.allSatisfy { $0.kind != .userMessage })

// 6. Two messages queue first in, first out; each listen completes the open
//    turn and starts the next queued one.
let first = try await bridge.send(threadID: "s1", text: "one", commandID: "c2")
let second = try await bridge.send(threadID: "s1", text: "two", commandID: "c3")
checkEqual("both messages are queued", [first.status, second.status], [.queued, .queued])
let deliveryOne = try bridge.checkMessages(sessionID: "s1")
checkEqual("the oldest message is delivered first", deliveryOne.message?.text, "one")
checkEqual("the first turn runs", try store.turn(id: first.id)?.status, .running)
checkEqual("the second turn waits", try store.turn(id: second.id)?.status, .queued)
_ = try await bridge.report(sessionID: "s1", summary: "answer one", details: "",
                            question: nil, timeoutSeconds: nil)
let deliveryTwo = try bridge.checkMessages(sessionID: "s1")
checkEqual("the listen completes the first turn", try store.turn(id: first.id)?.status, .completed)
checkEqual("and delivers the second", deliveryTwo.message?.text, "two")
checkEqual("the second turn now runs", try store.turn(id: second.id)?.status, .running)

// 7. One effect per command id: a repeat returns the same turn and writes
//    nothing; the same id with different words is refused by name.
let turnsBefore = try store.turns(threadID: "s1").count
let repeatTurn = try await bridge.send(threadID: "s1", text: "two", commandID: "c3")
checkEqual("a repeated command id returns the first turn", repeatTurn.id, second.id)
checkEqual("and writes no new turn", try store.turns(threadID: "s1").count, turnsBefore)
await expectOutsideSessionErrorAsync("the same command id with different words is refused",
                                     code: "invalid_params") {
    _ = try await bridge.send(threadID: "s1", text: "different", commandID: "c3")
}

// 8. A report with a question raises it through the questions seam and blocks
//    until the answer; the answer comes back to the session.
questions.resolution = osQuestionAnswer("yes, revert it")
let callsBefore = questions.calls.count
let answered = try await bridge.report(sessionID: "s1", summary: "One file is dirty",
                                       details: "", question: "Should I revert it?",
                                       timeoutSeconds: nil)
checkEqual("the question was raised once", questions.calls.count, callsBefore + 1)
checkEqual("the question carries the session's own words",
           questions.calls.last?.prompt, "Should I revert it?")
checkEqual("the question is asked on the thread and its open turn",
           questions.calls.last?.threadID, "s1")
checkEqual("the tool call returns the person's answer", answered.answer, "yes, revert it")
checkEqual("the outcome is answered", answered.outcome, "answered")
let askedTurnID = questions.calls.last!.turnID
checkEqual("the turn that asked is completed", try store.turn(id: askedTurnID)?.status, .completed)
checkEqual("the thread is idle after the answer", try store.thread(id: "s1")?.activity, .idle)

// 9. A question nobody answers ends the turn failed with the reason "no answer".
questions.resolution = osExpiredQuestion()
let expired = try await bridge.report(sessionID: "s1", summary: "Waiting",
                                      details: "", question: "Anyone there?",
                                      timeoutSeconds: 60)
let expiredTurnID = questions.calls.last!.turnID
let expiredTurn = try store.turn(id: expiredTurnID)
checkEqual("an unanswered question fails its turn", expiredTurn?.status, .failed)
checkEqual("the failure reason is the design's", expiredTurn?.error?.message, "no answer")
checkEqual("the failure code is the contract's", expiredTurn?.error?.code, "request_expired")
checkEqual("the result says it expired", expired.outcome, "expired")
checkEqual("the thread is idle again", try store.thread(id: "s1")?.activity, .idle)

// 10. A report with no substance is refused by name.
await expectOutsideSessionErrorAsync("a report needs a summary", code: "invalid_params") {
    _ = try await bridge.report(sessionID: "s1", summary: "  ", details: "x",
                                question: nil, timeoutSeconds: nil)
}

// 11. A listen with a message already queued returns it without waiting, and a
//     listen with nothing and a short timeout answers none.
let quick = BridgeHarness()
_ = try await quick.bridge.seen(sessionID: "sq", client: "claude-code")
_ = try await quick.bridge.report(sessionID: "sq", summary: "hi", details: "",
                                  question: nil, timeoutSeconds: nil)
_ = try await quick.bridge.send(threadID: "sq", text: "hello", commandID: "q1")
let quickDelivery = try await quick.bridge.waitForMessage(sessionID: "sq", timeoutSeconds: 5)
checkEqual("a message already queued comes back at once", quickDelivery.message?.text, "hello")
let nothing = try await quick.bridge.waitForMessage(sessionID: "sq", timeoutSeconds: 0.05)
checkEqual("an empty listen times out as none", nothing.outcome, .none)

// 12. A parked listener wakes when the person sends, a newer listener supersedes
//     the older, and closing the session ends it.
let parked = BridgeHarness()
_ = try await parked.bridge.seen(sessionID: "sp", client: "claude-code")
_ = try await parked.bridge.report(sessionID: "sp", summary: "ready", details: "",
                                   question: nil, timeoutSeconds: nil)

func waitUntilParked(_ bridge: OutsideSessionBridge, _ sessionID: String) async -> Bool {
    for _ in 0..<10_000 {
        if await bridge.hasListener(sessionID: sessionID) { return true }
        await Task.yield()
    }
    return false
}

let waiting = Task { try await parked.bridge.waitForMessage(sessionID: "sp", timeoutSeconds: 10) }
let didPark = await waitUntilParked(parked.bridge, "sp")
check("the listener parked", didPark)
_ = try await parked.bridge.send(threadID: "sp", text: "a typed answer", commandID: "p1")
let woken = try await waiting.value
checkEqual("the parked listener got the person's words", woken.message?.text, "a typed answer")

let older = Task { try await parked.bridge.waitForMessage(sessionID: "sp", timeoutSeconds: 10) }
_ = await waitUntilParked(parked.bridge, "sp")
let newer = Task { try await parked.bridge.waitForMessage(sessionID: "sp", timeoutSeconds: 10) }
let superseded = try await older.value
checkEqual("a newer listener supersedes the older", superseded.outcome, .superseded)
_ = try await parked.bridge.close(sessionID: "sp")
let terminated = try await newer.value
checkEqual("closing the session terminates the listener", terminated.outcome, .terminated)

finishOutsideSessions("outside sessions: turns")
