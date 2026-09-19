import Foundation
import GRDB

// V1, task 2 — the per-thread event log, the two sequence numbers, the one
// transaction, adoption of cloud turns, the text rules, search, deletion and
// the command ledger (06 §3.2; 06 §4 "Provides to 01").

let root = makeConfigRoot("v1-events")
defer { try? fixtureFileManager.removeItem(at: root) }

let (pool, store) = try openStore(configRoot: root, homeID: "h_mac_one")
let sink = RecordingEventSink()
store.eventSink = sink

let projectFolder = makeFolder(root.appendingPathComponent("work", isDirectory: true))
try store.upsertProject(makeProject(id: "p_one", name: "Atika", path: projectFolder.path))
_ = try store.apply([.thread(makeThread(id: "t_one", projectID: "p_one"))])
_ = try store.apply([.thread(makeThread(id: "t_two", projectID: "p_one"))])

// ------------------------------------------------- the two sequence numbers

// Every event gets the next seq for its thread. An event this Mac produced also
// gets the next origin_seq for this Mac in that thread.
let firstBatch = try store.apply([
    .turn(makeTurn(id: "turn_1", threadID: "t_one", status: .running, endedAt: nil, stopReason: nil)),
    .itemStarted(makeItem(id: "i_1", turnID: "turn_1", threadID: "t_one", status: .inProgress)),
    .itemCompleted(makeItem(id: "i_1", turnID: "turn_1", threadID: "t_one")),
])
require(firstBatch.count == 3, "three writes produce three events")
require(firstBatch.map(\.seq) == [2, 3, 4], "seq continues after the thread.updated that created the thread")
require(firstBatch.map(\.originSeq) == [2, 3, 4], "origin_seq runs beside it for this Mac")
require(firstBatch.map(\.type) == [.turnUpdated, .itemStarted, .itemCompleted],
        "each write carries the event type the contract names for it")
require(firstBatch.allSatisfy { $0.origin == "h_mac_one" },
        "a read resolves the origin to the current home id")

// Numbering is per thread, not per store.
let otherThread = try store.apply([.turn(makeTurn(id: "turn_2", threadID: "t_two"))])
require(otherThread.map(\.seq) == [2], "the second thread's numbering is its own")
ok("seq is strictly increasing per thread and origin_seq runs beside it")

// A failed transaction leaves no gap: it inserts nothing, and the next write is
// given the same number.
sink.failNext = true
var refused = false
do {
    _ = try store.apply([.itemCompleted(makeItem(id: "i_gap", turnID: "turn_1", threadID: "t_one"))])
} catch {
    refused = true
}
require(refused, "a sink that throws makes the write fail")
let afterFailure = try pool.read { db in
    try Int.fetchOne(db, sql: "SELECT count(*) FROM items WHERE id = 'i_gap'") ?? -1
}
require(afterFailure == 0, "the item row was rolled back with the event: both are in one transaction")
let next = try store.apply([.itemCompleted(makeItem(id: "i_2", turnID: "turn_1", threadID: "t_one"))])
require(next.map(\.seq) == [5], "the next event takes the number the failed one would have had")
require(next.map(\.originSeq) == [5], "origin_seq has no gap")
ok("a failed write inserts nothing and leaves no gap in origin_seq")

// ------------------------------------------------------- one transaction

// The outbox append happens inside the store's transaction (06 §4, N7), which
// is what the rollback above proves; the sink also sees exactly the events that
// were stored, in order, and nothing else.
let seenForThreadOne = sink.seen.filter { $0.threadID == "t_one" }.map(\.seq)
require(seenForThreadOne == [1, 2, 3, 4, 5],
        "the sink saw thread t_one's events once each, in order, with no gap")
let storedSeqs = try store.events(threadID: "t_one", afterSeq: 0).map(\.seq)
require(storedSeqs == [1, 2, 3, 4, 5], "the log holds the same numbers the sink was handed")
ok("every durable event is stored and handed to the sink in the same transaction")

// ------------------------------------------------------ adopting cloud turns

// An adopted event keeps the origin and origin_seq Atika gave it, takes the next
// local seq, and is never sent back up (06 §3.2, §3.11).
let cloudTurn = makeTurn(id: "turn_cloud", threadID: "t_one")
let down = TPThreadEventDown(
    at: "2026-09-19T12:00:00Z",
    event: makeDurableEvent(.turnUpdated, threadID: "t_one", turn: cloudTurn),
    origin: "atika", originSeq: 17)
let adopted = try store.adopt(down)
require(adopted != nil, "the adopted event was stored")
require(adopted?.origin == "atika", "the adopted event keeps Atika's origin")
require(adopted?.originSeq == 17, "the adopted event keeps Atika's origin_seq")
require(adopted?.seq == 6, "the adopted event takes the next local seq")
require(adopted?.at == "2026-09-19T12:00:00Z", "the adopted event keeps the time Atika gave it")

let sinkCountBefore = sink.seen.count
let again = try store.adopt(down)
require(again == nil, "adopting the same (thread, origin, origin_seq) twice stores nothing the second time")
require(sink.seen.count == sinkCountBefore, "an adopted event is never handed to the sink")
require(!sink.seen.contains(where: { $0.origin == "atika" }),
        "no event whose origin is Atika was ever sent up")

let ownOnly = try store.ownEvents(threadID: "t_one", afterOriginSeq: 0)
require(ownOnly.map(\.originSeq) == [1, 2, 3, 4, 5],
        "only rows whose origin is this Mac are offered for sending up")
require(try store.lastOwnOriginSeq(threadID: "t_one") == 5, "the highest own origin_seq is reported")
require(try store.lastSeq(threadID: "t_one") == 6, "the highest seq counts the adopted event too")
ok("adopted cloud events keep their origin, are idempotent, and are never sent up")

// ------------------------------------------------------------- thread/open

let page = try store.open(threadID: "t_one", sinceSeq: 3)
require(page.events.map(\.seq) == [4, 5, 6], "sinceSeq replays every stored event after that number")
require(page.lastSeq == 6, "the page reports the thread's last number")
require(page.thread.id == "t_one", "the page carries the thread record")
requireRefusal(.snapshotRequired, "a sinceSeq above the store's last number") {
    _ = try store.open(threadID: "t_one", sinceSeq: 99)
}
requireRefusal(.notFound, "opening a thread that is not here") {
    _ = try store.open(threadID: "t_missing", sinceSeq: nil)
}
ok("thread/open replays from sinceSeq and refuses snapshot_required above the last number")

// --------------------------------------------------- live deltas are memory

// 06 §3.2: fragments are sent to subscribers and never stored. The buffer keeps
// the text so far only so a client opening mid-answer gets one catch-up delta
// from offset 0.
let live = LiveTextBuffer()
let d1 = live.append(threadID: "t_one", itemID: "i_live", stream: .text, delta: "Hel")
let d2 = live.append(threadID: "t_one", itemID: "i_live", stream: .text, delta: "lo there")
require(d1.offset == 0, "the first fragment starts at offset 0")
require(d2.offset == 3, "the next fragment starts where the last one ended, counted in UTF-16 units")
require(d1.stream == .text && d2.itemID == "i_live", "the deltas name their stream and item")
let reasoning = live.append(threadID: "t_one", itemID: "i_live", stream: .reasoning, delta: "thinking")
require(reasoning.offset == 0, "each stream of one item has its own offset")

let catchUp = live.catchUp(threadID: "t_one", itemID: "i_live", stream: .text)
require(catchUp?.offset == 0, "a catch-up delta starts at offset 0")
require(catchUp?.delta == "Hello there", "a catch-up delta carries the whole text so far")

let eventsBeforeCompletion = try store.events(threadID: "t_one", afterSeq: 0).count
require(eventsBeforeCompletion == 6, "appending fragments wrote no event")
let liveRows = try pool.read { db in
    try Int.fetchOne(db, sql: "SELECT count(*) FROM items WHERE id = 'i_live'") ?? -1
}
require(liveRows == 0, "appending fragments wrote no item row")

let taken = live.take(itemID: "i_live")
require(taken[.text] == "Hello there", "taking the item gives the text so far, to be stored once")
require(taken[.reasoning] == "thinking", "every stream comes back")
require(live.catchUp(threadID: "t_one", itemID: "i_live", stream: .text) == nil,
        "the buffer forgets an item once it has been taken")
ok("live deltas are kept in memory only and never reach the store")

// ------------------------------------------------------------ text limits

// Message text above the contract's limit is cut in the item and kept whole as
// an attachment. Nothing is discarded.
let long = String(repeating: "a", count: ItemText.messageMaxBytes + 5_000)
let longEvents = try store.apply([
    .itemCompleted(makeItem(id: "i_long", turnID: "turn_1", threadID: "t_one",
                            kind: .assistantMessage, text: long)),
])
let storedLong = longEvents[0].payload.item
require(storedLong?.truncated == true, "the item says its text was cut")
require(storedLong?.text?.utf8.count ?? 0 <= ItemText.messageMaxBytes,
        "the stored text fits the contract's limit")
require(storedLong?.text?.count ?? 0 < long.count, "the stored text really is shorter")
let fullID = storedLong?.fullTextAttachmentID
require(fullID != nil, "the item points at the attachment that holds the whole text")
let longAttachments = try store.attachments(threadID: "t_one").filter { $0.attachment.id == fullID }
require(longAttachments.count == 1, "the whole text was kept as one attachment")
require(longAttachments[0].attachment.kind == .file, "the whole text is kept as a file attachment")
require(longAttachments[0].attachment.sizeBytes == long.utf8.count, "the attachment holds all of it")
require(longAttachments[0].itemID == "i_long", "the attachment names the item it came from")

// A tool call's output has its own, smaller limit.
let longToolText = String(repeating: "b", count: ItemText.toolOutputMaxBytes + 1_000)
let toolEvents = try store.apply([
    .itemCompleted(makeItem(id: "i_tool", turnID: "turn_1", threadID: "t_one",
                            kind: .toolCall, text: longToolText,
                            toolCall: TPToolCall(errorMessage: nil, inputJSON: nil, kind: .execute,
                                                 locations: nil, name: "bash",
                                                 output: nil, title: "bash"))),
])
require(toolEvents[0].payload.item?.text?.utf8.count ?? 0 <= ItemText.toolOutputMaxBytes,
        "a tool call's text is cut at the tool limit, not the message limit")
require(toolEvents[0].payload.item?.truncated == true, "the tool item says its text was cut")

// The cut never halves a character, and the cleaning runs after the cut.
let emoji = String(repeating: "😀", count: 4)
let fitted = ItemText.fit(emoji, budgetBytes: 7)
require(!fitted.kept.unicodeScalars.contains { $0.value == 0xFFFD },
        "a cut between the halves of a character never leaves a replacement character behind")
require(fitted.kept.utf8.count <= 7, "the cut respects the budget in bytes")
require(fitted.cut, "the cut is reported")

let dirty = "before\u{0000}after"
let cleaned = try store.apply([
    .itemCompleted(makeItem(id: "i_zero", turnID: "turn_1", threadID: "t_one", text: dirty)),
])
require(cleaned[0].payload.item?.text?.contains("\u{0000}") == false,
        "a zero character never reaches the log")
require(cleaned[0].payload.item?.text == "before\u{FFFD}after",
        "cleanText replaces it with the replacement character and changes nothing else")
ok("long text is cut and kept whole, and every text is cleaned after the cut")

// ---------------------------------------------------------------- search

_ = try store.apply([
    .itemCompleted(makeItem(id: "i_find", turnID: "turn_1", threadID: "t_one",
                            text: "the checkpoint reference lives under refs")),
    .itemCompleted(makeItem(id: "i_other", turnID: "turn_2", threadID: "t_two",
                            text: "the checkpoint reference is elsewhere")),
])
let hits = try store.search("checkpoint", threadID: nil, limit: 10)
require(hits.count == 2, "search finds the word in both threads")
require(Set(hits.map(\.threadID)) == ["t_one", "t_two"], "each hit names its thread")
require(hits.allSatisfy { !$0.snippet.isEmpty }, "each hit carries a snippet")
let filtered = try store.search("checkpoint", threadID: "t_two", limit: 10)
require(filtered.map(\.itemID) == ["i_other"], "the threadId filter narrows the search")
require(try store.search("nothingatallhere", threadID: nil, limit: 10).isEmpty,
        "a word that is not there finds nothing")
ok("the full-text index answers index/search and its threadId filter")

// ------------------------------------------------------- the command ledger

// 06 §3.2: a command that arrives twice takes effect once and answers with the
// first result, whichever door it came through.
var ran = 0
let params = Data(#"{"threadId":"t_one","text":"go"}"#.utf8)
let first = try store.settle(commandID: "cmd_1", threadID: "t_one", method: "thread/send", params: params) {
    ran += 1
    return Data(#"{"turnId":"turn_9"}"#.utf8)
}
let second = try store.settle(commandID: "cmd_1", threadID: "t_one", method: "thread/send", params: params) {
    ran += 1
    return Data(#"{"turnId":"turn_DIFFERENT"}"#.utf8)
}
require(ran == 1, "the work behind the command ran once")
require(first.repeated == false && second.repeated == true, "the second call says it is a repeat")
require(second.result == first.result, "the second call answers with the first result")

// The same command id with different parameters is a mistake, not a repeat.
requireRefusal(.invalidParams, "the same commandId with different parameters") {
    _ = try store.settle(commandID: "cmd_1", threadID: "t_one", method: "thread/send",
                         params: Data(#"{"threadId":"t_one","text":"something else"}"#.utf8)) {
        Data("{}".utf8)
    }
}

// A command whose work fails is not remembered, so it can be sent again.
var failed = false
do {
    _ = try store.settle(commandID: "cmd_2", threadID: "t_one", method: "thread/stop", params: params) {
        throw ThreadStoreError(code: .runtimeUnavailable, message: "OpenCode is not running")
    }
} catch { failed = true }
require(failed, "the failure reached the caller")
let retried = try store.settle(commandID: "cmd_2", threadID: "t_one", method: "thread/stop", params: params) {
    Data(#"{"stopped":true}"#.utf8)
}
require(retried.repeated == false, "a command whose work failed is not settled and can be sent again")
ok("each command takes effect once per commandId and a repeat returns the first result")

// --------------------------------------------------------------- deletion

// Deleting a thread sets deletedAt on its record, which is how the deletion
// reaches Atika and every client; its events and items are erased in the same
// transaction, and its attachment files are removed after the commit.
let attachmentsRoot = makeFolder(root.appendingPathComponent("thread-attachments", isDirectory: true))
let doomedFolder = makeFolder(attachmentsRoot.appendingPathComponent("t_two", isDirectory: true))
fixtureFileManager.createFile(atPath: doomedFolder.appendingPathComponent("a.png").path, contents: Data([1, 2]))

let deletion = try store.deleteThread("t_two")
require(deletion.attachmentFolder.standardizedFileURL == doomedFolder.standardizedFileURL,
        "the deletion names the folder whose files belong to the thread")
require(!fixtureFileManager.fileExists(atPath: doomedFolder.path),
        "the files are removed after the commit, because they cannot be part of the transaction")
let remaining = try store.thread("t_two")
require(remaining?.deletedAt != nil, "the record stays with deletedAt set, so the deletion can be mirrored")
require(try store.events(threadID: "t_two", afterSeq: 0).isEmpty, "its events are gone")
let itemsLeft = try pool.read { db in
    try Int.fetchOne(db, sql: "SELECT count(*) FROM items WHERE thread_id = 't_two'") ?? -1
}
require(itemsLeft == 0, "its items are gone")
require(deletion.erasedItems >= 1 && deletion.erasedEvents >= 1, "the deletion reports what it erased")

// The launch sweep is the second half of that rule: after a crash between the
// commit and the removal, a folder is left behind whose thread is deleted or
// has no row at all. It goes at the next launch; a live thread's folder stays.
_ = makeFolder(doomedFolder)
fixtureFileManager.createFile(atPath: doomedFolder.appendingPathComponent("a.png").path, contents: Data([1, 2]))
let liveFolder = makeFolder(attachmentsRoot.appendingPathComponent("t_one", isDirectory: true))
let strayFolder = makeFolder(attachmentsRoot.appendingPathComponent("t_never_existed", isDirectory: true))
let swept = try store.sweepAttachmentFolders().map { $0.lastPathComponent }.sorted()
require(swept == ["t_never_existed", "t_two"],
        "the sweep removes the deleted thread's folder and the stray one")
require(fixtureFileManager.fileExists(atPath: liveFolder.path), "a live thread's folder is left alone")
require(!fixtureFileManager.fileExists(atPath: strayFolder.path), "the stray folder is really gone")
ok("deleting a thread keeps the record, erases its log, and its files go after the commit")

print("thread store events: numbering, one transaction, adoption, text, search, commands, deletion")
