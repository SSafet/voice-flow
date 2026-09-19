import Foundation

// Approvals, questions and command idempotency (06 §3.5): a request is an item
// that survives the window closing, the turn waits on it, the first answer wins
// and a second is refused with the first resolution, an expired request ends
// the turn as failed with "no answer", and a command takes effect once per
// commandId.

let harness = EngineHarness()
let engine = harness.engine
let store = harness.store
let driver = harness.driver
let runtime = driver.runtimes[.opencode]!

func waitFor(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    check(what, condition())
}

func startHeld(_ threadID: String, commandID: String, startedBy: TPStartedBy? = nil,
               requestExpirySec: Double? = nil) async throws -> TPTurn {
    try await engine.startTurn(StartTurnRequest(
        commandID: commandID, threadID: threadID, text: "work", attachmentIDs: [],
        startedBy: startedBy ?? userStartedBy(), requestExpirySec: requestExpirySec,
        retryOfTurnID: nil, model: nil, reasoningEffort: nil, sentFrom: nil, speakReply: false))
}

let firstAnswerer = TPClientStamp(clientID: "phone-1", clientKind: .android, label: "Phone")
let secondAnswerer = TPClientStamp(clientID: "mac-1", clientKind: .mac, label: "Mac")

// 1. An approval is an item, the turn waits, the first answer resolves it, and
//    the waiting call returns the answer.
runtime.holdThreads = ["*"]
let threadA = "thread-approval"
store.seed(thread: makeThread(id: threadA))
let turnA = try await startHeld(threadA, commandID: "a-start")
let approvalTask = Task { await engine.requestApproval(threadID: threadA, turnID: turnA.id,
                                                       prompt: makeApprovalPrompt(id: "req-1", threadID: threadA)) }
await waitFor("the approval item is stored") {
    store.storedItems.values.contains { $0.kind == .approval && $0.approval?.requestID == "req-1" }
}
checkEqual("the turn waits", store.storedTurns[turnA.id]?.status, .waiting)
checkEqual("the thread waits", store.storedThreads[threadA]?.activity, .waiting)
try await engine.answerApproval(AnswerApprovalRequest(commandID: "a-answer", threadID: threadA,
                                                      requestID: "req-1", optionID: "allow_once",
                                                      answeredBy: firstAnswerer))
let approvalResponse = await approvalTask.value
checkEqual("the runtime sees the allow", approvalResponse, .once)
let resolvedApproval = store.storedItems.values.first { $0.approval?.requestID == "req-1" }
checkEqual("the approval is allowed", resolvedApproval?.approval?.resolution?.outcome, .allowed)
checkEqual("the first answer is named", resolvedApproval?.approval?.resolution?.answeredBy?.label, "Phone")
checkEqual("the turn runs again", store.storedTurns[turnA.id]?.status, .running)

// 2. A second answer is refused by name, with the first answer named in the
//    reason.
do {
    try await engine.answerApproval(AnswerApprovalRequest(commandID: "a-answer-2", threadID: threadA,
                                                          requestID: "req-1", optionID: "reject_once",
                                                          answeredBy: secondAnswerer))
    check("a second answer is refused", false, "no error was thrown")
} catch let error as TurnEngineError {
    checkEqual("a second answer is refused by name", error.code, "request_already_resolved")
    check("the refusal names the first answer", error.message.contains("Phone"), error.message)
} catch {
    check("a second answer is refused", false, "\(error)")
}
await runtime.release(threadA)
await engine.waitUntilIdle()

// 3. An unanswered request expires: the item says expired, the waiting call is
//    rejected, and the turn ends failed with the fixed reason.
let expireHarness = EngineHarness()
expireHarness.driver.runtimes[.opencode]!.holdThreads = ["*"]
expireHarness.store.seed(thread: makeThread(id: "thread-expire"))
let expireTurn = try await expireHarness.engine.startTurn(StartTurnRequest(
    commandID: "e-start", threadID: "thread-expire", text: "work", attachmentIDs: [],
    startedBy: userStartedBy(), requestExpirySec: 60, retryOfTurnID: nil, model: nil,
    reasoningEffort: nil, sentFrom: nil, speakReply: false))
let expiryTask = Task { await expireHarness.engine.requestApproval(
    threadID: "thread-expire", turnID: expireTurn.id,
    prompt: makeApprovalPrompt(id: "req-expire", threadID: "thread-expire")) }
await waitFor("the expiring approval is stored") {
    expireHarness.store.storedItems.values.contains { $0.approval?.requestID == "req-expire" }
}
let approvalItem = expireHarness.store.storedItems.values.first { $0.approval?.requestID == "req-expire" }
check("the request carries an expiry", approvalItem?.approval?.expiresAt != nil)
checkEqual("the expiry is the turn's own",
           expirySecondsRemaining(approvalItem?.approval?.expiresAt, from: expireHarness.clock.current), 60)
expireHarness.clock.current = expireHarness.clock.current.addingTimeInterval(61)
let expiredIDs = try await expireHarness.engine.sweepExpiredRequests()
checkEqual("the expiry sweep names the request", expiredIDs, ["req-expire"])
let expiryResponse = await expiryTask.value
checkEqual("an expired request is a rejection", expiryResponse, .reject)
let expiredItem = expireHarness.store.storedItems.values.first { $0.approval?.requestID == "req-expire" }
checkEqual("the item is expired", expiredItem?.approval?.resolution?.outcome, .expired)
checkEqual("the turn failed", expireHarness.store.storedTurns[expireTurn.id]?.status, .failed)
checkEqual("the reason is the fixed one", expireHarness.store.storedTurns[expireTurn.id]?.error?.message, "no answer")

// 4. A question is an item too, and its answer is recorded without a secret.
let answerResult = TPQuestionAnswer(choiceIDS: nil, questionID: "q1", text: "the report")
let questionHarness = EngineHarness()
questionHarness.driver.runtimes[.opencode]!.holdThreads = ["*"]
questionHarness.store.seed(thread: makeThread(id: "thread-question"))
let questionTurn = try await questionHarness.engine.startTurn(StartTurnRequest(
    commandID: "q-start", threadID: "thread-question", text: "ask", attachmentIDs: [],
    startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
    reasoningEffort: nil, sentFrom: nil, speakReply: false))
let questionTask = Task { await questionHarness.engine.requestQuestion(
    threadID: "thread-question", turnID: questionTurn.id,
    question: makeQuestion(requestID: "q-1")) }
await waitFor("the question item is stored") {
    questionHarness.store.storedItems.values.contains { $0.question?.requestID == "q-1" }
}
try await questionHarness.engine.answerQuestion(AnswerQuestionRequest(
    commandID: "q-answer", threadID: "thread-question", requestID: "q-1",
    answers: [answerResult], answeredBy: firstAnswerer))
let questionResolution = await questionTask.value
checkEqual("the answer reaches the asker", questionResolution.outcome, .answered)
checkEqual("the answer is the one given", questionResolution.answers?.first?.text, "the report")
do {
    try await questionHarness.engine.answerQuestion(AnswerQuestionRequest(
        commandID: "q-answer-2", threadID: "thread-question", requestID: "q-1",
        answers: [answerResult], answeredBy: secondAnswerer))
    check("a second question answer is refused", false, "no error was thrown")
} catch let error as TurnEngineError {
    checkEqual("a second question answer is refused by name", error.code, "request_already_resolved")
} catch {
    check("a second question answer is refused", false, "\(error)")
}
await questionHarness.driver.runtimes[.opencode]!.release("thread-question")
await questionHarness.engine.waitUntilIdle()

// 5. A command takes effect once per commandId: a repeat returns the original
//    result and writes nothing second.
runtime.holdThreads = ["*"]
let threadB = "thread-idempotent"
store.seed(thread: makeThread(id: threadB))
let firstSend = try await startHeld(threadB, commandID: "same-command")
await runtime.release(threadB)
await engine.waitUntilIdle()
let repeatedSend = try await startHeld(threadB, commandID: "same-command")
checkEqual("the repeat returns the original turn", repeatedSend.id, firstSend.id)
checkEqual("only one turn was written", (try await store.turns(threadID: threadB)).count, 1)
do {
    _ = try await startHeld(threadB, commandID: "same-command")
    // A repeat of the same parameters is not a new send, so nothing fails.
    check("the third repeat is still the same turn", true)
} catch {
    check("the third repeat is still the same turn", false, "\(error)")
}
do {
    _ = try await engine.startTurn(StartTurnRequest(
        commandID: "same-command", threadID: threadB, text: "a different message", attachmentIDs: [],
        startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
        reasoningEffort: nil, sentFrom: nil, speakReply: false))
    check("a reused command id with new parameters is refused", false, "no error was thrown")
} catch let error as TurnEngineError {
    checkEqual("a reused command id with new parameters is refused by name", error.code, "invalid_params")
} catch {
    check("a reused command id with new parameters is refused", false, "\(error)")
}

// 6. startedBy and requestExpirySec work in-process: a trigger's fields are
//    carried unchanged onto the turn and onto the requests it raises.
let triggerHarness = EngineHarness()
triggerHarness.driver.runtimes[.opencode]!.holdThreads = ["*"]
triggerHarness.store.seed(thread: makeThread(id: "thread-trigger-fields"))
let triggerTurn = try await triggerHarness.engine.startTurn(StartTurnRequest(
    commandID: "t-start", threadID: "thread-trigger-fields", text: "work", attachmentIDs: [],
    startedBy: triggerStartedBy(id: "trg-42"), requestExpirySec: 43_200,
    retryOfTurnID: nil, model: nil, reasoningEffort: nil, sentFrom: nil, speakReply: false))
checkEqual("the trigger id survives", triggerTurn.startedBy.triggerID, "trg-42")
checkEqual("the trigger kind survives", triggerTurn.startedBy.kind, .trigger)
let triggerApproval = Task { await triggerHarness.engine.requestApproval(
    threadID: "thread-trigger-fields", turnID: triggerTurn.id,
    prompt: makeApprovalPrompt(id: "req-trigger", threadID: "thread-trigger-fields")) }
await waitFor("the trigger's approval is stored") {
    triggerHarness.store.storedItems.values.contains { $0.approval?.requestID == "req-trigger" }
}
let triggerItem = triggerHarness.store.storedItems.values.first { $0.approval?.requestID == "req-trigger" }
checkEqual("the trigger's request expires at its own limit",
           expirySecondsRemaining(triggerItem?.approval?.expiresAt, from: triggerHarness.clock.current), 43_200)
await triggerHarness.engine.stop(StopTurnRequest(commandID: "t-stop", threadID: "thread-trigger-fields", turnID: nil))
_ = await triggerApproval.value

finishTurnEngine("turn requests")

// Seconds from `now` to an ISO-8601 instant, rounded to whole seconds; nil when
// the instant is absent or unparseable.
func expirySecondsRemaining(_ stamp: String?, from now: Date) -> Int? {
    guard let stamp else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let at = formatter.date(from: stamp) else { return nil }
    return Int(at.timeIntervalSince(now).rounded())
}
