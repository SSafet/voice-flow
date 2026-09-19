import Foundation

// V9 · the upward half: what this Mac appends to the outbox and what the
// outbox reads back out of the log when it sends, rewinds or restarts.
// Design: 06 §3.11 "Up", 05 §3.3 "Item streams" (log streams), 06 N7.

let world = ReplicationTestWorld()

// ── install ─────────────────────────────────────────────────────────────
replicationExpect(world.channel.registeredLogPrefixes == ["thread"],
                  "install registers the owner of the thread: log stream")

// ── a stored event appends one pointer, numbered by its originSeq ───────
let first = ReplicationFixtures.ownEvent(threadID: "t1", originSeq: 1)
let second = ReplicationFixtures.ownEvent(threadID: "t1", originSeq: 2)
try! world.replication.stored([first, second])
replicationExpect(world.channel.appends.count == 2, "one outbox append per stored event")
replicationExpect(world.channel.appends[0].stream == "thread:t1", "the stream is thread:<id>")
replicationExpect(world.channel.appends[0].kind == "thread.event", "the kind is thread.event")
replicationExpect(world.channel.appends[0].seq == 1 && world.channel.appends[1].seq == 2,
                  "the channel item's number is the event's originSeq, in order")
replicationExpect(world.channel.appends[0].bodyJson == nil && world.channel.appends[1].bodyJson == nil,
                  "a log stream carries a pointer, not a second copy of the body")

// ── only this Mac's rows go up ──────────────────────────────────────────
let before = world.channel.appends.count
try! world.replication.stored([ReplicationFixtures.ownEvent(threadID: "t1", origin: "atika", originSeq: 9)])
replicationExpect(world.channel.appends.count == before,
                  "an event whose origin is not this Mac is never appended")

// ── the append runs inside the caller's transaction, so its failure
//    must reach the caller ─────────────────────────────────────────────
world.channel.failAppend = { call in
    if call.seq == 4 { throw FakeChannelError.appendRefused("that one") }
}
var refused = false
do {
    try world.replication.stored([ReplicationFixtures.ownEvent(threadID: "t1", originSeq: 4)])
} catch {
    refused = true
}
replicationExpect(refused, "an outbox failure reaches the storing transaction as a thrown error")
world.channel.failAppend = nil
let poisoned = world.channel.appends.count

// ── the log reader encodes branch 01's thread.event body ────────────────
world.store.seedThread(ReplicationFixtures.thread(id: "t1", homeID: "self"))
world.store.seedOwn(ReplicationFixtures.ownEvent(threadID: "t1", originSeq: 1, at: ReplicationTestClock.at(1)))
world.store.seedOwn(ReplicationFixtures.ownEvent(threadID: "t1", originSeq: 2, at: ReplicationTestClock.at(2)))
let items = try! world.channel.readLog("thread:t1", afterSeq: 0)
replicationExpect(items.count == 2, "the reader serves every own event above the rewind point")
replicationExpect(items.map(\.seq) == [1, 2], "the reader numbers items by originSeq, in order, with no gap")
replicationExpect(items.map(\.kind) == ["thread.event", "thread.event"], "every item is a thread.event")
replicationExpect(!items[0].sum.isEmpty && !items[1].sum.isEmpty, "the producer puts a checksum on every item")

let body1 = world.decode(items[0])
let body2 = world.decode(items[1])
replicationExpect(body1.at == ReplicationTestClock.at(1), "the body carries the event's at")
replicationExpect(body1.prevAt == nil, "the first event of this Mac has no prevAt")
replicationExpect(body2.prevAt == ReplicationTestClock.at(1),
                  "prevAt is the at of this Mac's previous event")
replicationExpect(body1.event.thread?.homeID == "home-1",
                  "the item encoder puts the current home id where the store wrote self")

// ── watchedLocally comes from the route report ──────────────────────────
world.routeReport.watchedThreadID = "t1"
let watched = world.decode(try! world.channel.readLog("thread:t1", afterSeq: 0)[0])
replicationExpect(watched.watchedLocally == true, "the Mac had the thread open, so watchedLocally is set")
world.routeReport.watchedThreadID = "other"
let unwatched = world.decode(try! world.channel.readLog("thread:t1", afterSeq: 0)[0])
replicationExpect(unwatched.watchedLocally == false,
                  "another thread on screen means watchedLocally is not set")

// ── a rewind to any earlier point is served from the log ────────────────
world.store.seedOwn(ReplicationFixtures.ownEvent(threadID: "t1", originSeq: 3, at: ReplicationTestClock.at(3)))
let rewound = try! world.channel.readLog("thread:t1", afterSeq: 1)
replicationExpect(rewound.map(\.seq) == [2, 3], "a rewind resends from the number Atika asks for")

// an event larger than the batch ceiling still travels as a batch of its own
let huge = try! world.channel.readLog("thread:t1", afterSeq: 2, maxBytes: 1)
replicationExpect(huge.count == 1 && huge[0].seq == 3,
                  "the reader always returns at least one item when one exists")

// ── live deltas go up on the unacknowledged frame ───────────────────────
let delta = TPLiveDelta(delta: "hel", itemID: "i1", offset: 0, stream: .text, threadID: "t1")
try! world.replication.live(delta)
replicationExpect(world.channel.liveSent.count == 1, "one live delta becomes one live frame")
replicationExpect(world.channel.liveSent[0].stream == "thread:t1", "the live frame names the thread stream")
replicationExpect(world.channel.liveSent[0].kind == "thread.delta", "the live kind is thread.delta")
let sentDelta = replicationDecode(TPLiveDelta.self, world.channel.liveSent[0].bodyJson)
replicationExpect(sentDelta == delta, "the live body is the delta, unchanged")

// ── nothing that was poisoned is left half-done ─────────────────────────
replicationExpect(world.channel.appends.count == poisoned,
                  "a refused append is not followed by a silent success")

print("replication_up: all checks passed")
