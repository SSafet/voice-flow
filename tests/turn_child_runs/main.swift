import Foundation

// Delegation as child runs inside one turn (06 §3.5, decision 17): the engine,
// not the agent, starts and limits them — at most six tasks in one call, at most
// twelve child runs in a turn, three at a time, one level deep, no retry — and
// they are not counted against the admission limits, so a lead holding the only
// slot can still delegate.

let harness = EngineHarness(limits: TurnAdmissionLimits(total: 1, perRuntime: [.opencode: 1]))
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

func startParent(_ threadID: String) async throws -> TPTurn {
    try await engine.startTurn(StartTurnRequest(
        commandID: "parent-\(threadID)", threadID: threadID, text: "lead", attachmentIDs: [],
        startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
        reasoningEffort: nil, sentFrom: nil, speakReply: false))
}

func tasks(_ count: Int, prefix: String = "d") -> [DelegateTask] {
    (0..<count).map { DelegateTask(persona: "\(prefix)\($0)", task: "task \($0)") }
}

// 1. One call takes at most six tasks; the seventh is refused by name, and every
//    child item carries the delegate's name and the lead's call item.
runtime.holdThreads = ["thread-many"]
store.seed(thread: makeThread(id: "thread-many"))
let manyTurn = try await startParent("thread-many")
let manyResults = await engine.runDelegateTasks(threadID: "thread-many", turnID: manyTurn.id,
                                                parentItemID: "call-item", tasks: tasks(7))
checkEqual("seven tasks return seven results", manyResults.count, 7)
checkEqual("the first six ran", manyResults.prefix(6).map(\.status), Array(repeating: "completed", count: 6))
checkEqual("the seventh was refused", manyResults.last?.status, "refused")
checkEqual("the refusal is named", manyResults.last?.error, "delegate_limit")
checkEqual("only six child runs started", driver.childRequests.count, 6)
let childItems = (try await store.items(turnID: manyTurn.id)).filter { $0.toolCall?.name == "delegate.task" }
checkEqual("six child items were written", childItems.count, 6)
check("a child item names its delegate", childItems.allSatisfy { $0.agentName != nil })
check("a child item hangs under the lead's call",
      childItems.allSatisfy { $0.parentItemID == "call-item" })
check("a child item's tool title names the delegate",
      childItems.contains { $0.toolCall?.title == "Asked d0" })
checkEqual("a child run has no turn record of its own",
           (try await store.turns(threadID: "thread-many")).count, 1)
checkEqual("a child run has no queue entry", engine.queuedTurnIDs(threadID: "thread-many"), [])
checkEqual("the lead's turn is still the running one",
           engine.runningTurnID(threadID: "thread-many"), manyTurn.id)
await runtime.release("thread-many")
await engine.waitUntilIdle()

// 2. A turn takes at most twelve child runs; later calls are refused whole.
driver.childRequests.removeAll()
runtime.holdThreads = ["thread-cap"]
store.seed(thread: makeThread(id: "thread-cap"))
let capTurn = try await startParent("thread-cap")
_ = await engine.runDelegateTasks(threadID: "thread-cap", turnID: capTurn.id,
                                  parentItemID: "call-1", tasks: tasks(6, prefix: "a"))
_ = await engine.runDelegateTasks(threadID: "thread-cap", turnID: capTurn.id,
                                  parentItemID: "call-2", tasks: tasks(6, prefix: "b"))
let overCap = await engine.runDelegateTasks(threadID: "thread-cap", turnID: capTurn.id,
                                            parentItemID: "call-3", tasks: tasks(1, prefix: "c"))
checkEqual("twelve child runs happened", driver.childRequests.count, 12)
checkEqual("the thirteenth is refused", overCap.first?.status, "refused")
checkEqual("the cap refusal is named", overCap.first?.error, "delegate_limit")
await runtime.release("thread-cap")
await engine.waitUntilIdle()

// 3. Child runs are not counted against admission, and at most three run at a
//    time; the parent holds the only slot in the whole Mac.
driver.childRequests.removeAll()
runtime.startedThreads.removeAll()
runtime.holdThreads = ["thread-slot", "child-d0", "child-d1", "child-d2",
                       "child-d3", "child-d4", "child-d5"]
store.seed(thread: makeThread(id: "thread-slot"))
let slotTurn = try await startParent("thread-slot")
let slotTask = Task { await engine.runDelegateTasks(threadID: "thread-slot", turnID: slotTurn.id,
                                                    parentItemID: "call-slot", tasks: tasks(6, prefix: "d")) }
await waitFor("three child runs start though the parent holds the only slot") {
    runtime.startedThreads.filter { $0.hasPrefix("child-") }.count == 3
}
checkEqual("no fourth child started", runtime.startedThreads.filter { $0.hasPrefix("child-") }.count, 3)
await runtime.release("child-d0")
await waitFor("a fourth child starts when one ends") {
    runtime.startedThreads.filter { $0.hasPrefix("child-") }.count == 4
}
for name in ["child-d1", "child-d2", "child-d3", "child-d4", "child-d5"] {
    await runtime.release(name)
}
let slotResults = await slotTask.value
checkEqual("all six tasks finished", slotResults.map(\.status), Array(repeating: "completed", count: 6))
checkEqual("the lead never lost its own slot", engine.runningTurnID(threadID: "thread-slot"), slotTurn.id)
await runtime.release("thread-slot")
await engine.waitUntilIdle()

// 4. A failing child is returned failed with its error and no retry; its item
//    fails too.
driver.childRequests.removeAll()
runtime.startedThreads.removeAll()
runtime.holdThreads = ["thread-fail"]
runtime.failureByThread["child-d1"] = AgentRuntimeFailure(code: "runtime_error",
                                                          message: "the delegate crashed",
                                                          retryable: false)
store.seed(thread: makeThread(id: "thread-fail"))
let failTurn = try await startParent("thread-fail")
let failResults = await engine.runDelegateTasks(threadID: "thread-fail", turnID: failTurn.id,
                                                parentItemID: "call-fail", tasks: tasks(2, prefix: "d"))
checkEqual("the first task completed", failResults.first?.status, "completed")
checkEqual("the second failed", failResults.last?.status, "failed")
checkEqual("the failure carries the runtime's error", failResults.last?.error, "the delegate crashed")
checkEqual("the child was not retried", driver.childRequests.filter { $0.conversationID == "child-d1" }.count, 1)
let failedChildItem = (try await store.items(turnID: failTurn.id)).first { $0.agentName == "d1" }
checkEqual("the child item failed", failedChildItem?.status, .failed)
await runtime.release("thread-fail")
await engine.waitUntilIdle()

// 5. Stop ends the turn and every child run: pending tasks come back stopped and
//    no further child starts.
driver.childRequests.removeAll()
runtime.startedThreads.removeAll()
runtime.failureByThread.removeAll()
runtime.holdThreads = ["thread-stop-children", "child-d0", "child-d1", "child-d2"]
store.seed(thread: makeThread(id: "thread-stop-children"))
let stopTurn = try await startParent("thread-stop-children")
let stopTask = Task { await engine.runDelegateTasks(threadID: "thread-stop-children",
                                                    turnID: stopTurn.id, parentItemID: "call-stop",
                                                    tasks: tasks(6, prefix: "d")) }
await waitFor("the first children start") {
    runtime.startedThreads.filter { $0.hasPrefix("child-") }.count == 3
}
_ = try await engine.stop(StopTurnRequest(commandID: "stop-children",
                                          threadID: "thread-stop-children", turnID: nil))
let stopResults = await stopTask.value
check("the pending tasks came back stopped", stopResults.contains { $0.status == "stopped" })
checkEqual("no child beyond the first three started",
           runtime.startedThreads.filter { $0.hasPrefix("child-") }.count, 3)

finishTurnEngine("turn child runs")
