import Foundation

// V9 · commands from other clients arrive, run once per commandId, and an
// expired one is refused at once with nothing held; and a stream whose two
// stores have gone back in time is blocked visibly and healed the way need N5
// recommends. Design: 06 §3.11 "In"; 05 §3.3 commands, 05 N5.

func commandPayload(_ commandID: String, method: String, params: String) -> String {
    let body = "{\"commandId\":\"\(commandID)\",\"method\":\"\(method)\",\"paramsJson\":\(String(data: try! JSONEncoder().encode(params), encoding: .utf8)!)}"
    return body
}

let world = ReplicationTestWorld()
world.store.seedThread(ReplicationFixtures.thread(id: "t1", homeID: "home-1"))

// ── install ─────────────────────────────────────────────────────────────
replicationExpect(Set(world.channel.registeredCommandKinds) == ["thread.command", "thread.system"],
                  "install registers both command kinds branch 01 sends down")

// ── a person's command runs once and its result is kept ─────────────────
let send = ReplicationCommand(
    commandID: "c1",
    kind: "thread.command",
    delivery: "connected",
    expiresAt: ReplicationTestClock.at(1000),
    payloadJson: commandPayload("c1", method: "thread/send", params: "{\"threadId\":\"t1\",\"text\":\"hi\"}")
)
let accepted = await world.channel.deliverCommand(send)
replicationExpect(accepted == .accepted(resultJson: "{\"ok\":true}"),
                  "an accepted command answers the engine's result")
replicationExpect(world.engine.calls.count == 1, "the engine runs the command once")
replicationExpect(world.engine.calls[0].method == "thread/send", "the method reaches the engine unchanged")
replicationExpect(world.engine.calls[0].commandID == "c1", "the commandId reaches the engine unchanged")
replicationExpect(world.store.commandResults["c1"] == "{\"ok\":true}", "the result is stored")

// ── a repeat is answered from the ledger, without running again ─────────
let duplicate = await world.channel.deliverCommand(send)
replicationExpect(duplicate == .duplicate(resultJson: "{\"ok\":true}"),
                  "a repeat is answered duplicate with the first result")
replicationExpect(world.engine.calls.count == 1, "a repeat never reaches the engine")

// ── an expired command is refused at once, nothing held ─────────────────
let expired = ReplicationCommand(
    commandID: "c2",
    kind: "thread.command",
    delivery: "connected",
    expiresAt: ReplicationTestClock.at(-10),
    payloadJson: commandPayload("c2", method: "thread/send", params: "{}")
)
let refused = await world.channel.deliverCommand(expired)
if case .rejected(let code, _) = refused {
    replicationExpect(code == "request_expired", "an expired command is refused with request_expired")
} else {
    replicationExpect(false, "an expired command is refused, not accepted")
}
replicationExpect(world.engine.calls.count == 1, "an expired command never reaches the engine")
replicationExpect(world.store.commandResults["c2"] == nil, "an expired command stores no result")

// ── a refusal from the engine keeps its own code ────────────────────────
world.engine.error = ReplicationError.protocolError(code: "not_found", message: "no such thread", retryable: false)
let missing = ReplicationCommand(
    commandID: "c3",
    kind: "thread.command",
    delivery: "connected",
    expiresAt: ReplicationTestClock.at(1000),
    payloadJson: commandPayload("c3", method: "thread/send", params: "{}")
)
let missingOutcome = await world.channel.deliverCommand(missing)
if case .rejected(let code, _) = missingOutcome {
    replicationExpect(code == "not_found", "a refusal keeps the engine's own code")
} else {
    replicationExpect(false, "a refusal is a rejected outcome")
}
replicationExpect(world.store.commandResults["c3"] == nil, "a refused command stores no result")
world.engine.error = nil

// ── a system item takes the same path and may wait ──────────────────────
let title = ReplicationCommand(
    commandID: "s1",
    kind: "thread.system",
    delivery: "stored",
    expiresAt: ReplicationTestClock.at(1000),
    payloadJson: commandPayload("s1", method: "thread/setAutoTitle", params: "{\"threadId\":\"t1\"}")
)
let titleOutcome = await world.channel.deliverCommand(title)
replicationExpect(titleOutcome == .accepted(resultJson: "{\"ok\":true}"),
                  "a stored system item is executed like any command")
replicationExpect(world.engine.calls.last?.method == "thread/setAutoTitle",
                  "the system method reaches the engine unchanged")

// ── store_diverged: block visibly, ask for the truth, change nothing ────
world.store.seedOwn(ReplicationFixtures.ownEvent(threadID: "t4", originSeq: 1))
world.store.seedOwn(ReplicationFixtures.ownEvent(threadID: "t4", originSeq: 2))
world.store.seedOwn(ReplicationFixtures.ownEvent(threadID: "t4", originSeq: 3))
world.store.seedThread(ReplicationFixtures.thread(id: "t4", homeID: "home-1"))

world.channel.raise(StreamBlock(stream: "thread:t4", code: "store_diverged",
                                message: "this Mac's copy is older", agreedSeq: 2))
replicationExpect((world.store.mirrorBlocks["t4"] ?? nil)?.code == "store_diverged",
                  "a diverged stream marks the thread with store_diverged")
replicationExpect(world.replication.isBehind(threadID: "t4"), "a diverged thread is behind")
replicationExpect(world.channel.appends.contains { $0.kind == "thread.restore_request" },
                  "the Mac asks Atika for the events it is missing")
let beforeDiverged = world.channel.appends.count
try! world.replication.stored([ReplicationFixtures.ownEvent(threadID: "t4", originSeq: 4)])
replicationExpect(world.channel.appends.count == beforeDiverged,
                  "nothing is sent on a diverged stream")

// ── the block clears: the differing local events move to a new origin ───
world.channel.raise(StreamBlock(stream: "thread:t4", code: "", message: "", agreedSeq: 2))
replicationExpect(world.store.mirrorBlocks["t4"]! == nil, "the mark clears when the stream is agreed")
replicationExpect(world.store.movedOwnEvents.count == 1, "the differing local events are moved once")
replicationExpect(world.store.movedOwnEvents[0].above == 2,
                  "only events above the number both sides agree on move")
replicationExpect(world.store.movedOwnEvents[0].toOrigin == "home-1-restored-1",
                  "they move to a new origin built from the home id (need N5)")
replicationExpect(!world.replication.isBehind(threadID: "t4"), "the thread is no longer behind")

print("replication_commands: all checks passed")
