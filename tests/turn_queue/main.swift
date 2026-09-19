import Foundation

// Turn queue and admission (06 §3.5, 06 §8 item 11): one running turn per
// thread, a first-in-first-out queue behind it, concurrent threads under one
// admission limit, a person's message ahead of a trigger's, and durable events
// stored before anyone sees them.

let harness = EngineHarness(limits: TurnAdmissionLimits(total: 8,
                                                        perRuntime: [.opencode: 4, .codex: 3, .claude: 3]))
let engine = harness.engine
let store = harness.store
let driver = harness.driver
let signals = harness.signals
let runtime = driver.runtimes[.opencode]!

func send(_ threadID: String, _ text: String, commandID: String? = nil,
          startedBy: TPStartedBy? = nil) async throws -> TPTurn {
    let request = StartTurnRequest(commandID: commandID, threadID: threadID, text: text,
                                   attachmentIDs: [], startedBy: startedBy ?? userStartedBy(),
                                   requestExpirySec: nil, retryOfTurnID: nil, model: nil,
                                   reasoningEffort: nil, sentFrom: nil, speakReply: false)
    return try await engine.startTurn(request)
}

// 1. createThread with a first message writes the thread, the running turn and
//    the user's message item in one transaction, and the title is the
//    contract's first-line title.
let created = try await engine.createThread(CreateThreadRequest(
    commandID: "cmd-create-1", projectID: "proj-1", personaID: nil, personaName: nil,
    runtime: .opencode, model: nil, reasoningEffort: nil, trustProfile: .workspace,
    ownWorkingCopy: false, startedBy: userStartedBy(), requestExpirySec: nil,
    message: "Make the checkout faster\nand the tests green", attachmentIDs: [], sentFrom: nil))
checkEqual("createThread returns a thread", created.thread.id.isEmpty, false)
checkEqual("createThread returns a turn", created.turn?.status, TPTurnStatus.running)
checkEqual("the title follows the first-line rule",
           created.thread.title, ContractTitle.firstLineTitle("Make the checkout faster\nand the tests green"))
let firstTurnID = created.turn!.id
await runtime.release(created.thread.id)
await engine.waitUntilIdle()
checkEqual("the first turn completed", (try await store.turn(id: firstTurnID))?.status, .completed)

// 2. A second message to a busy thread is queued behind the running one, and a
//    third behind the second: first in, first out.
runtime.holdThreads = ["*"]
let threadA = "thread-a"
store.seed(thread: makeThread(id: threadA))
let a1 = try await send(threadA, "one")
let a2 = try await send(threadA, "two")
let a3 = try await send(threadA, "three")
checkEqual("the first turn is running", a1.status, .running)
checkEqual("the second turn is queued", a2.status, .queued)
checkEqual("the third turn is queued", a3.status, .queued)
checkEqual("the queue is in order", engine.queuedTurnIDs(threadID: threadA), [a2.id, a3.id])
let queuedNotice = (try await store.items(turnID: a2.id)).first { $0.kind == .notice }
check("the queued turn says why it waits",
      queuedNotice?.notice?.message.contains("Queued behind the running turn") ?? false,
      queuedNotice?.notice?.message ?? "no notice")
await runtime.release(threadA)
await engine.waitUntilIdle()
checkEqual("the queue drained in order",
           driver.madeTurnIDs, [firstTurnID, a1.id, a2.id, a3.id])

// 3. Threads run at the same time, and a runtime's own limit is honoured.
driver.madeTurnIDs.removeAll()
runtime.holdThreads = ["*"]
let codexRuntime = driver.runtimes[.codex]!
codexRuntime.holdThreads = ["*"]
let threadB = "thread-b"
store.seed(thread: makeThread(id: threadB, runtime: .codex))
let b1 = try await send(threadA, "a-one")
let b2 = try await send(threadB, "b-one", startedBy: nil)
checkEqual("two runtimes are running at once", b1.status, .running)
checkEqual("the second runtime's turn is running", b2.status, .running)
await runtime.release(threadA)
await codexRuntime.release(threadB)
await engine.waitUntilIdle()

// 4. The total admission limit queues a turn with the exact notice, and a
//    person's message goes ahead of a trigger's in that wait.
let tight = EngineHarness(limits: TurnAdmissionLimits(total: 1, perRuntime: [.opencode: 1]))
let tightRuntime = tight.driver.runtimes[.opencode]!
let holder = "thread-holder"
tight.store.seed(thread: makeThread(id: holder))
let held = try await tight.engine.startTurn(StartTurnRequest(
    commandID: "c-hold", threadID: holder, text: "hold", attachmentIDs: [],
    startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
    reasoningEffort: nil, sentFrom: nil, speakReply: false))
checkEqual("the holder runs", held.status, .running)
let triggerThread = "thread-trigger"
tight.store.seed(thread: makeThread(id: triggerThread))
let triggerTurn = try await tight.engine.startTurn(StartTurnRequest(
    commandID: "c-trigger", threadID: triggerThread, text: "triggered", attachmentIDs: [],
    startedBy: triggerStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
    reasoningEffort: nil, sentFrom: nil, speakReply: false))
checkEqual("the trigger's turn waits", triggerTurn.status, .queued)
let waitingNotice = (try await tight.store.items(turnID: triggerTurn.id)).first { $0.kind == .notice }
checkEqual("the wait states the running count",
           waitingNotice?.notice?.message, "Waiting for a free slot: 1 turns are running on this Mac")
let personThread = "thread-person"
tight.store.seed(thread: makeThread(id: personThread))
let personTurn = try await tight.engine.startTurn(StartTurnRequest(
    commandID: "c-person", threadID: personThread, text: "person", attachmentIDs: [],
    startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
    reasoningEffort: nil, sentFrom: nil, speakReply: false))
checkEqual("the person's turn waits too", personTurn.status, .queued)
await tightRuntime.release(holder)
await tight.engine.waitUntilIdle()
checkEqual("the person's message ran before the trigger's",
           tight.driver.madeTurnIDs, [held.id, personTurn.id, triggerTurn.id])

// 5. A runtime's own limit queues even when the total has room.
let perRuntime = EngineHarness(limits: TurnAdmissionLimits(total: 4, perRuntime: [.opencode: 1]))
let perRuntimeOpenCode = perRuntime.driver.runtimes[.opencode]!
let first = "thread-first"
perRuntime.store.seed(thread: makeThread(id: first))
let firstTurn = try await perRuntime.engine.startTurn(StartTurnRequest(
    commandID: "c-1", threadID: first, text: "first", attachmentIDs: [], startedBy: userStartedBy(),
    requestExpirySec: nil, retryOfTurnID: nil, model: nil, reasoningEffort: nil, sentFrom: nil,
    speakReply: false))
let second = "thread-second"
perRuntime.store.seed(thread: makeThread(id: second))
let secondTurn = try await perRuntime.engine.startTurn(StartTurnRequest(
    commandID: "c-2", threadID: second, text: "second", attachmentIDs: [], startedBy: userStartedBy(),
    requestExpirySec: nil, retryOfTurnID: nil, model: nil, reasoningEffort: nil, sentFrom: nil,
    speakReply: false))
checkEqual("the first OpenCode turn runs", firstTurn.status, .running)
checkEqual("the second OpenCode turn waits on the runtime limit", secondTurn.status, .queued)
await perRuntimeOpenCode.release(first)
await perRuntime.engine.waitUntilIdle()
checkEqual("the runtime limit released the queue", perRuntimeOpenCode.startedThreads.count, 2)

// 6. Durable events are stored before anyone sees them: at every stored
//    signal the store already holds that many events and at least one write.
let storedSignals = signals.storedSignals
check("some durable events were signalled", !storedSignals.isEmpty)
var durableBeforeVisible = true
for (index, entry) in storedSignals.enumerated() {
    let (stamp, _) = entry
    if signals.storedEventCountAtSignal[index] < stamp.seq
        || signals.storedStoreVersionAtSignal[index] < 1
        || signals.storedEventWasPresentAtSignal[index] == false {
        durableBeforeVisible = false
    }
}
check("every durable event reached the store before the subscriber", durableBeforeVisible)

// 7. Streaming fragments are live-only: they arrive as deltas with offsets and
//    never become stored text, and the completed item carries the whole answer.
let streamHarness = EngineHarness()
let streamRuntime = streamHarness.driver.runtimes[.opencode]!
streamRuntime.holdThreads = []
streamRuntime.script = { _ in
    [.textDelta(partID: "p1", delta: "Hel"), .textDelta(partID: "p1", delta: "lo")]
}
streamRuntime.finalText = "Hello"
let streamThread = "thread-stream"
streamHarness.store.seed(thread: makeThread(id: streamThread))
let streamTurn = try await streamHarness.engine.startTurn(StartTurnRequest(
    commandID: "c-stream", threadID: streamThread, text: "hi", attachmentIDs: [],
    startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
    reasoningEffort: nil, sentFrom: nil, speakReply: false))
await streamHarness.engine.waitUntilIdle()
let streamDeltas = streamHarness.signals.deltas
checkEqual("two live deltas arrived", streamDeltas.count, 2)
checkEqual("the first delta starts at zero", streamDeltas.first?.offset, 0)
checkEqual("the second delta continues after the first", streamDeltas.dropFirst().first?.offset, 3)
checkEqual("the deltas carry the runtime's own text",
           streamDeltas.map(\.delta), ["Hel", "lo"])
let streamItems = try await streamHarness.store.items(turnID: streamTurn.id)
let assistantItem = streamItems.first { $0.kind == .assistantMessage }
checkEqual("the stored answer is the whole text", assistantItem?.text, "Hello")
check("no stored item holds a live fragment",
      streamItems.allSatisfy { ($0.text ?? "") != "Hel" && ($0.text ?? "") != "lo" })

finishTurnEngine("turn queue")
