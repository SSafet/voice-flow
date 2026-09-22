import Foundation
import GRDB
import CryptoKit
import Darwin

// V1, task 2 — the per-thread event log, the two sequence numbers, the one
// transaction, adoption of cloud turns, the text rules, search, deletion and
// the command ledger (06 §3.2; 06 §4 "Provides to 01").

// Exit without unwinding to simulate process death after a canonical write
// but before settlement. The parent created the isolated store and checks it.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--crash-command" {
    let crashRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let (_, crashingStore) = try openStore(configRoot: crashRoot)
    _ = try crashingStore.settle(commandID: "cmd_crash", threadID: "t_one",
                                method: "thread/send", params: Data("{}".utf8)) { db in
        try crashingStore.apply([
            .itemCompleted(makeItem(id: "i_crash", turnID: "turn_1", threadID: "t_one",
                                    text: String(repeating: "c", count: 220_000)))
        ], in: db)
        _exit(73)
    }
    fatalError("crash probe unexpectedly returned")
}

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

// The filesystem is not transactional. A failed replacement must leave the
// bytes the original row/event names unchanged, not just roll back SQL.
func fileHash(_ path: String) throws -> String {
    SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        .map { String(format: "%02x", $0) }.joined()
}
let originalAttachment = longAttachments[0]
let originalPath = originalAttachment.localPath!
let originalHash = try fileHash(originalPath)
require(originalHash == originalAttachment.attachment.sha256, "original full text has its recorded hash")
let attachmentFolder = URL(fileURLWithPath: originalPath).deletingLastPathComponent()
let filesBeforeEdit = try fixtureFileManager.contentsOfDirectory(atPath: attachmentFolder.path).sorted()
let textBeforeEdit = try store.open(threadID: "t_one", sinceSeq: nil).items.first { $0.id == "i_long" }
let seqBeforeEdit = try store.lastSeq(threadID: "t_one")
let replacementText = String(repeating: "z", count: long.utf8.count)
sink.failNext = true
requireRefusal(.invalidParams, "failed overflow edit rolls back") {
    try store.apply([.itemUpdated(makeItem(id: "i_long", turnID: "turn_1", threadID: "t_one",
                                         kind: .assistantMessage, text: replacementText))])
}
try pool.write { _ in } // Drain cleanup queued after the failed transaction.
require(try fileHash(originalPath) == originalHash, "rollback never overwrites the original file")
require(try store.lastSeq(threadID: "t_one") == seqBeforeEdit, "overflow rollback preserves the event counter")
require(try store.open(threadID: "t_one", sinceSeq: nil).items.first { $0.id == "i_long" } == textBeforeEdit,
        "overflow rollback preserves the canonical item")
require(try fixtureFileManager.contentsOfDirectory(atPath: attachmentFolder.path).sorted() == filesBeforeEdit,
        "rollback removes only the new unpublished overflow file")
let replaced = try store.apply([.itemUpdated(makeItem(
    id: "i_long", turnID: "turn_1", threadID: "t_one", kind: .assistantMessage, text: replacementText))])
let replacementID = replaced[0].payload.item!.fullTextAttachmentID!
require(replacementID != fullID, "each changed overflow revision has a distinct attachment identity")
let replacement = try store.attachments(threadID: "t_one").first { $0.attachment.id == replacementID }!
require(try fileHash(replacement.localPath!) == replacement.attachment.sha256,
        "the replacement file matches its committed SHA-256")
require(try fileHash(originalPath) == originalHash, "successful edit retains old event attachment bytes")
require(try store.events(threadID: "t_one", afterSeq: 0).contains {
    $0.payload.item?.fullTextAttachmentID == fullID
}, "the old committed event still resolves its immutable full text")

// A separate store handle reusing committed bytes must not delete them if its
// transaction fails. Both handles publish under the same SQLite writer lock.
let (secondPool, secondStore) = try openStore(configRoot: root)
let secondSink = RecordingEventSink()
secondStore.eventSink = secondSink
secondSink.failNext = true
requireRefusal(.invalidParams, "failed same-content write from another store handle") {
    try secondStore.apply([.itemUpdated(makeItem(id: "i_long", turnID: "turn_1", threadID: "t_one",
                                               kind: .assistantMessage, text: replacementText))])
}
require(try fileHash(replacement.localPath!) == replacement.attachment.sha256,
        "rollback on another handle does not delete shared committed bytes")
require(try fileHash(originalPath) == originalHash, "all committed revisions retain their hashes")

// Force the exact cross-pool cleanup race: the failed writer releases its
// SQLite lock, a second writer commits the same bytes, then rollback cleanup
// resumes. Cleanup must recheck references under a new writer transaction.
let rollbackUnlocked = DispatchSemaphore(value: 0)
let publicationCommitted = DispatchSemaphore(value: 0)
let publicationDone = DispatchSemaphore(value: 0)
let publicationItem = makeItem(id: "i_publication_race", turnID: "turn_1", threadID: "t_one",
                               text: String(repeating: "p", count: 220_000))
DispatchQueue.global().async {
    defer { publicationDone.signal() }
    do {
        try pool.write { db in
            db.afterNextTransaction(onCommit: { _ in }, onRollback: { _ in
                rollbackUnlocked.signal()
                require(publicationCommitted.wait(timeout: .now() + 5) == .success,
                        "another pool committed while rollback cleanup was paused")
            })
            try store.apply([.itemCompleted(publicationItem)], in: db)
            throw ThreadStoreError(code: .invalidParams, message: "injected publication rollback")
        }
        require(false, "publication failure must propagate")
    } catch { }
}
require(rollbackUnlocked.wait(timeout: .now() + 5) == .success, "rollback released writer lock before cleanup")
try secondStore.apply([.itemCompleted(publicationItem)])
publicationCommitted.signal()
require(publicationDone.wait(timeout: .now() + 5) == .success, "rollback cleanup completed")
try pool.write { _ in }
let sharedPublication = try secondStore.attachments(threadID: "t_one").first { $0.itemID == publicationItem.id }!
require(try fileHash(sharedPublication.localPath!) == sharedPublication.attachment.sha256,
        "rollback cleanup cannot delete bytes another pool committed while the lock was released")
ok("overflow edit failure preserves original SHA-256, and committed revisions remain immutable")

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
let first = try store.settle(commandID: "cmd_1", threadID: "t_one", method: "thread/send", params: params) { _ in
    ran += 1
    return Data(#"{"turnId":"turn_9"}"#.utf8)
}
let second = try store.settle(commandID: "cmd_1", threadID: "t_one", method: "thread/send", params: params) { _ in
    ran += 1
    return Data(#"{"turnId":"turn_DIFFERENT"}"#.utf8)
}
require(ran == 1, "the work behind the command ran once")
require(first.repeated == false && second.repeated == true, "the second call says it is a repeat")
require(second.result == first.result, "the second call answers with the first result")

// The same command id with different parameters is a mistake, not a repeat.
requireRefusal(.invalidParams, "the same commandId with different parameters") {
    _ = try store.settle(commandID: "cmd_1", threadID: "t_one", method: "thread/send",
                         params: Data(#"{"threadId":"t_one","text":"something else"}"#.utf8)) { _ in
        Data("{}".utf8)
    }
}

// A command whose work fails is not remembered, so it can be sent again.
var failed = false
do {
    _ = try store.settle(commandID: "cmd_2", threadID: "t_one", method: "thread/stop", params: params) { _ in
        throw ThreadStoreError(code: .runtimeUnavailable, message: "OpenCode is not running")
    }
} catch { failed = true }
require(failed, "the failure reached the caller")
let retried = try store.settle(commandID: "cmd_2", threadID: "t_one", method: "thread/stop", params: params) { _ in
    Data(#"{"stopped":true}"#.utf8)
}
require(retried.repeated == false, "a command whose work failed is not settled and can be sent again")
ok("each command takes effect once per commandId and a repeat returns the first result")

for (method, threadID) in [("thread/stop", "t_one"), ("thread/send", "t_two")] {
    requireRefusal(.invalidParams, "command identity includes method and thread") {
        _ = try store.settle(commandID: "cmd_1", threadID: threadID, method: method, params: params) { _ in
            fatalError("a mismatched command identity must never execute")
        }
    }
}

// Fail the last SQL statement, after rows, files, events and an actual outbox
// row have been written. All canonical effects must roll back with settlement.
final class TransactionalTestSink: ThreadEventSink {
    func append(_ events: [StoredEvent], in db: Database) throws {
        for event in events {
            try db.execute(sql: "INSERT INTO integrity_outbox (thread_id, seq) VALUES (?, ?)",
                           arguments: [event.threadID, event.seq])
        }
    }
}
try pool.write { db in
    try db.execute(sql: "CREATE TABLE integrity_outbox (thread_id TEXT, seq INTEGER)")
    try db.execute(sql: """
        CREATE TRIGGER reject_settlement BEFORE INSERT ON thread_commands
        WHEN NEW.command_id = 'cmd_rollback' BEGIN
            SELECT RAISE(ABORT, 'injected settlement failure');
        END
        """)
}
store.eventSink = TransactionalTestSink()
let seqBeforeSettlement = try store.lastSeq(threadID: "t_one")
let filesBeforeSettlement = try fixtureFileManager.contentsOfDirectory(atPath: attachmentFolder.path).sorted()
var settlementFailed = false
do {
    _ = try store.settle(commandID: "cmd_rollback", threadID: "t_one",
                         method: "thread/send", params: Data("{}".utf8)) { db in
        try store.apply([.itemCompleted(makeItem(id: "i_rollback", turnID: "turn_1", threadID: "t_one",
                                                text: replacementText))], in: db)
        return Data("{}".utf8)
    }
} catch { settlementFailed = true }
require(settlementFailed, "injected late settlement failure is reported")
try pool.write { _ in }
try pool.read { db in
    require(try Int.fetchOne(db, sql: "SELECT count(*) FROM items WHERE id = 'i_rollback'") == 0,
            "settlement failure rolls back canonical rows")
    require(try Int.fetchOne(db, sql: "SELECT count(*) FROM thread_commands WHERE command_id = 'cmd_rollback'") == 0,
            "failed command is not settled")
    require(try Int.fetchOne(db, sql: "SELECT count(*) FROM integrity_outbox") == 0,
            "settlement failure rolls back the outbox")
}
require(try store.lastSeq(threadID: "t_one") == seqBeforeSettlement,
        "settlement failure rolls back events and their counters")
require(try fixtureFileManager.contentsOfDirectory(atPath: attachmentFolder.path).sorted() == filesBeforeSettlement,
        "settlement rollback cleans only its new overflow file")
try pool.write { db in try db.execute(sql: "DROP TRIGGER reject_settlement") }
store.eventSink = sink

final class CommandRaceResults: @unchecked Sendable {
    let lock = NSLock()
    private(set) var workCount = 0
    private(set) var results: [CommandSettlement] = []
    private(set) var failures: [String] = []
    func ran() { lock.lock(); defer { lock.unlock() }; workCount += 1 }
    func record(_ result: CommandSettlement) { lock.lock(); defer { lock.unlock() }; results.append(result) }
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; failures.append(String(describing: error)) }
}
let race = CommandRaceResults()
let firstEntered = DispatchSemaphore(value: 0)
let releaseFirst = DispatchSemaphore(value: 0)
let secondStarted = DispatchSemaphore(value: 0)
let bothDone = DispatchGroup()
bothDone.enter()
DispatchQueue.global().async {
    defer { bothDone.leave() }
    do {
        race.record(try store.settle(commandID: "cmd_concurrent", threadID: "t_one",
                                    method: "thread/send", params: Data("{}".utf8)) { db in
            race.ran()
            firstEntered.signal()
            guard releaseFirst.wait(timeout: .now() + 5) == .success else {
                throw ThreadStoreError(code: .invalidParams, message: "concurrency probe timed out")
            }
            try store.apply([.itemCompleted(makeItem(id: "i_concurrent", turnID: "turn_1", threadID: "t_one"))], in: db)
            return Data(#"{"accepted":true}"#.utf8)
        })
    } catch { race.record(error) }
}
require(firstEntered.wait(timeout: .now() + 5) == .success, "first command holds writer transaction")
bothDone.enter()
DispatchQueue.global().async {
    defer { bothDone.leave() }
    secondStarted.signal()
    do {
        race.record(try secondStore.settle(commandID: "cmd_concurrent", threadID: "t_one",
                                          method: "thread/send", params: Data("{}".utf8)) { _ in
            race.ran()
            return Data(#"{"wrong":true}"#.utf8)
        })
    } catch { race.record(error) }
}
require(secondStarted.wait(timeout: .now() + 5) == .success, "duplicate attempts settlement concurrently")
Thread.sleep(forTimeInterval: 0.1)
releaseFirst.signal()
require(bothDone.wait(timeout: .now() + 10) == .success, "both concurrent callers complete")
require(race.failures.isEmpty, "concurrent duplicate waits rather than fails: \(race.failures)")
require(race.workCount == 1, "concurrent duplicate work executes once across two store handles")
require(race.results.count == 2 && race.results.filter(\.repeated).count == 1,
        "one caller executes and one replays its settlement")
require(Set(race.results.map(\.result)).count == 1, "concurrent callers receive identical original results")

let seqBeforeCrash = try store.lastSeq(threadID: "t_one")
let crash = Process()
crash.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
crash.arguments = ["--crash-command", root.path]
try crash.run()
crash.waitUntilExit()
require(crash.terminationStatus == 73, "child died at the pre-settlement failure boundary")
require(try store.lastSeq(threadID: "t_one") == seqBeforeCrash, "process death cannot commit only the mutation")
try pool.read { db in
    require(try Int.fetchOne(db, sql: "SELECT count(*) FROM items WHERE id = 'i_crash'") == 0,
            "process death rolls back the accepted item")
    require(try Int.fetchOne(db, sql: "SELECT count(*) FROM thread_commands WHERE command_id = 'cmd_crash'") == 0,
            "process death leaves no false settlement")
}
let afterCrash = try store.settle(commandID: "cmd_crash", threadID: "t_one",
                                method: "thread/send", params: Data("{}".utf8)) { db in
    try store.apply([.itemCompleted(makeItem(id: "i_crash", turnID: "turn_1", threadID: "t_one",
                                            text: String(repeating: "c", count: 220_000)))], in: db)
    return Data("{}".utf8)
}
require(!afterCrash.repeated, "a process-death rollback can be retried")
require(try fileHash(originalPath) == originalHash, "process death and retry preserve original attachment hash")
ok("late failure and process death roll back commands; concurrent duplicates execute once across pools")

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
