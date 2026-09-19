import Foundation

// Turn lifecycle (06 §3.5, 06 §8 item 13): Stop keeps the partial answer, a
// stopped turn and every queued one can be ended together or one by one, the
// final transaction carries the git state and the changed files, a crash is
// closed as interrupted at launch, and quitting cancels the runtimes.

let harness = EngineHarness()
let engine = harness.engine
let store = harness.store
let driver = harness.driver
let workspace = harness.workspace
let activity = harness.activity
let runtime = driver.runtimes[.opencode]!

func waitFor(_ what: String, timeout: Double = 3, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    check(what, condition())
}

func start(_ threadID: String, _ text: String, commandID: String? = nil,
           runOn: TPRunOn = .auto) async throws -> TPTurn {
    try await engine.startTurn(StartTurnRequest(
        commandID: commandID, threadID: threadID, text: text, attachmentIDs: [],
        startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
        reasoningEffort: nil, sentFrom: nil, speakReply: false, runOn: runOn))
}

// 1. Stop keeps the partial answer: the unfinished assistant item is completed
//    with the text so far, the turn ends interrupted with reason cancelled, and
//    the runtime is told to cancel.
runtime.script = { _ in [.textDelta(partID: "part", delta: "Partial answer")] }
let threadA = "thread-stop"
store.seed(thread: makeThread(id: threadA))
let turnA = try await start(threadA, "go")
await waitFor("the partial text arrived live", timeout: 2) { harness.signals.deltas.contains { $0.delta == "Partial answer" } }
let stopped = try await engine.stop(StopTurnRequest(commandID: "stop-1", threadID: threadA, turnID: turnA.id))
checkEqual("the running turn stopped", stopped.stoppedTurnIDs, [turnA.id])
checkEqual("nothing is left running", stopped.stillRunning, nil)
let stoppedTurn = try await store.turn(id: turnA.id)
checkEqual("a stopped turn is interrupted", stoppedTurn?.status, .interrupted)
checkEqual("a stopped turn says cancelled", stoppedTurn?.stopReason, .cancelled)
let partialItem = (try await store.items(turnID: turnA.id)).first { $0.kind == .assistantMessage }
checkEqual("the partial answer is kept", partialItem?.text, "Partial answer")
checkEqual("the partial answer is completed", partialItem?.status, .completed)
check("the runtime was told to cancel", !runtime.cancelledTurnIDs.isEmpty)
checkEqual("the thread is idle again", try await store.thread(id: threadA)?.activity, .idle)

// 2. Stop without a turn id ends the running turn and every queued one.
driver.madeTurnIDs.removeAll()
runtime.holdThreads = ["*"]
let threadB = "thread-stop-all"
store.seed(thread: makeThread(id: threadB))
let b1 = try await start(threadB, "one")
let b2 = try await start(threadB, "two")
let b3 = try await start(threadB, "three")
let allStopped = try await engine.stop(StopTurnRequest(commandID: "stop-2", threadID: threadB, turnID: nil))
checkEqual("the running and queued turns were named", Set(allStopped.stoppedTurnIDs), Set([b1.id, b2.id, b3.id]))
checkEqual("nothing is queued afterwards", engine.queuedTurnIDs(threadID: threadB), [])

// 3. Stop with a turn id removes only that queued turn.
let threadC = "thread-stop-one"
store.seed(thread: makeThread(id: threadC))
let c1 = try await start(threadC, "one")
let c2 = try await start(threadC, "two")
let c3 = try await start(threadC, "three")
let oneStopped = try await engine.stop(StopTurnRequest(commandID: "stop-3", threadID: threadC, turnID: c2.id))
checkEqual("only the named queued turn stopped", oneStopped.stoppedTurnIDs, [c2.id])
checkEqual("the other queued turn survives", engine.queuedTurnIDs(threadID: threadC), [c3.id])
checkEqual("the running turn is untouched", engine.runningTurnID(threadID: threadC), c1.id)
await runtime.release(threadC)
await engine.waitUntilIdle()

// 4. The final transaction carries the whole end state at once: the committed
//    batch holds the final item and the final turn updated together, with the
//    checkpoints, changed files and git state, and the binding is clean.
let threadD = "thread-final"
store.seed(thread: makeThread(id: threadD))
runtime.holdThreads = []
runtime.script = { _ in [.textDelta(partID: "p", delta: "answer")] }
runtime.finalText = "answer"
let d1 = try await start(threadD, "finish")
await engine.waitUntilIdle()
let finished = try await store.turn(id: d1.id)
checkEqual("a finished turn is completed", finished?.status, .completed)
checkEqual("a finished turn says why it ended", finished?.stopReason, .endTurn)
checkEqual("the before checkpoint is on the turn", finished?.checkpoints?.before, "refs/atika/checkpoints/t/t-before")
checkEqual("the after checkpoint is on the turn", finished?.checkpoints?.after, "refs/atika/checkpoints/t/t-after")
checkEqual("the changed files are on the turn", finished?.changedFiles?.count, 1)
checkEqual("the git state is on the turn", finished?.git?.branch, "main")
checkEqual("the turn has an end", finished?.endedAt != nil, true)
check("the workspace measured the turn", workspace.finished.contains(d1.id))
let finalBatch = store.batches.last(where: { batch in
    batch.events.contains { $0.type == .turnUpdated && $0.turn?.status == .completed }
})
check("the final turn update is in one batch", finalBatch != nil)
check("that batch also holds the final assistant item",
      finalBatch?.events.contains { $0.type == .itemCompleted && $0.item?.kind == .assistantMessage } ?? false)
checkEqual("the binding is clean after the turn",
           try await store.binding(threadID: threadD, runtime: .opencode)?.state, .clean)

// 5. A crash is closed at launch: running and waiting turns become interrupted
//    with a restart notice, unfinished items fail, open requests expire, the
//    binding is marked dirty, and the after-checkpoint is taken then.
let crashHarness = EngineHarness()
let crashStore = crashHarness.store
let crashEngine = crashHarness.engine
let crashThread = makeThread(id: "thread-crash", activity: .running)
crashStore.seed(thread: crashThread)
crashStore.seed(turn: makeTurn(id: "turn-crash", threadID: crashThread.id, status: .running))
crashStore.seed(turn: makeTurn(id: "turn-crash-wait", threadID: crashThread.id, status: .waiting,
                               createdAt: turnEngineFixedDate.addingTimeInterval(1)))
crashStore.seed(item: makeItem(id: "item-running", threadID: crashThread.id, turnID: "turn-crash",
                               kind: .assistantMessage, status: .inProgress, text: "half"))
crashStore.seed(item: makeApprovalItem(id: "item-approval", threadID: crashThread.id,
                                       turnID: "turn-crash-wait",
                                       approval: makeApproval(requestID: "req-1")))
crashStore.seed(item: makeQuestionItem(id: "item-question", threadID: crashThread.id,
                                       turnID: "turn-crash-wait",
                                       question: makeQuestion(requestID: "req-2")))
crashStore.seed(binding: RuntimeBinding(externalSessionID: "ext", state: .clean),
                threadID: crashThread.id, runtime: .opencode)
let report = try await crashEngine.recoverInterruptedTurns()
checkEqual("both turns were interrupted", Set(report.interruptedTurnIDs), Set(["turn-crash", "turn-crash-wait"]))
checkEqual("the unfinished item failed", (crashStore.storedItems["item-running"])?.status, .failed)
checkEqual("the approval expired", crashStore.storedItems["item-approval"]?.approval?.resolution?.outcome, .expired)
checkEqual("the question expired", crashStore.storedItems["item-question"]?.question?.resolution?.outcome, .expired)
checkEqual("the running turn is interrupted",
           crashStore.storedTurns["turn-crash"]?.status, .interrupted)
checkEqual("the wait turn is interrupted",
           crashStore.storedTurns["turn-crash-wait"]?.status, .interrupted)
let restartNotice = try await crashStore.items(turnID: "turn-crash").first { $0.kind == .notice }
checkEqual("the turn says why it ended", restartNotice?.notice?.code, .interruptedByRestart)
checkEqual("the binding was marked dirty",
           crashStore.storedBindings["\(crashThread.id)|opencode"]?.state, .dirty)
check("the after-checkpoint was taken at restart", crashHarness.workspace.finished.contains("turn-crash"))
checkEqual("no running turn is left", crashEngine.runningTurnID(threadID: crashThread.id), nil)

// 6. Quitting cancels the runtimes: shutdown signals the running turn's process
//    and closes the turn.
let quitHarness = EngineHarness()
let quitRuntime = quitHarness.driver.runtimes[.opencode]!
quitRuntime.holdThreads = ["*"]
quitHarness.store.seed(thread: makeThread(id: "thread-quit"))
let quitTurn = try await quitHarness.engine.startTurn(StartTurnRequest(
    commandID: "quit-1", threadID: "thread-quit", text: "work", attachmentIDs: [],
    startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
    reasoningEffort: nil, sentFrom: nil, speakReply: false))
await waitFor("the quit turn started running") { quitRuntime.startedThreads.count == 1 }
await quitHarness.engine.shutdown()
check("quitting cancelled the runtime", !quitRuntime.cancelledTurnIDs.isEmpty)
checkEqual("the turn is closed after quit", quitHarness.store.storedTurns[quitTurn.id]?.status, .interrupted)

// 7. The Mac refuses a cloud run by name: it never sends its own work up.
let cloudHarness = EngineHarness()
cloudHarness.store.seed(thread: makeThread(id: "thread-cloud"))
do {
    _ = try await cloudHarness.engine.startTurn(StartTurnRequest(
        commandID: "cloud-1", threadID: "thread-cloud", text: "up", attachmentIDs: [],
        startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
        reasoningEffort: nil, sentFrom: nil, speakReply: false, runOn: .cloud))
    check("a cloud run is refused", false, "no error was thrown")
} catch let error as TurnEngineError {
    checkEqual("a cloud run is refused by name", error.code, "cloud_continuation_unavailable")
} catch {
    check("a cloud run is refused", false, "\(error)")
}

// 8. The power assertion is held from the first running turn to the last.
check("the assertion was taken", activity.beginCount >= 1)
check("the assertion was released", activity.endCount >= 1)

finishTurnEngine("turn lifecycle")
