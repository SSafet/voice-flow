import Foundation
import GRDB

// CapturedStore (07 §3.1, §3.2): the one local index over everything VoiceFlow
// captures.
//
// The rule that shapes it: the index is derived. Every row can be rebuilt from
// the files on disk, so ids are derived from where a thing already lives and
// come out the same on every rebuild, writing the same item twice is one row,
// and deleting the database file loses nothing. It is its own file, not part of
// threads.sqlite, exactly so that it can be thrown away and rebuilt.

func vflog(_ message: String) {}

private var failures: [String] = []
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do { if try !condition() { failures.append(message) } }
    catch { failures.append("\(message) — the check itself threw \(error)") }
}
private func finish(_ label: String) -> Never {
    if failures.isEmpty { print("\(label): ok"); exit(0) }
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    fputs("\(label): \(failures.count) failure(s)\n", stderr)
    exit(1)
}

guard VoiceFlowPaths.shared.isIsolated else {
    fputs("FAIL: VOICE_FLOW_CONFIG_ROOT is not an isolated directory\n", stderr)
    exit(1)
}

private let files = FileManager.default
private func makeRoot(_ name: String) -> URL {
    let url = VoiceFlowPaths.shared.configRoot.appendingPathComponent(name, isDirectory: true)
    try? files.removeItem(at: url)
    try! files.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// ── ids are readable, derived, and checked ────────────────────────────────

expect(CapturedItemID.frame(day: "2026-08-18", time: "00-00-06") == "frame:2026-08-18T00-00-06",
       "a watcher frame's id is not the one of 07 §3.2")
expect(CapturedItemID.activity(day: "2026-08-18", time: "00-00-01") == "activity:2026-08-18T00-00-01",
       "an activity span's id is not the one of 07 §3.2")
expect(CapturedItemID.capture(bundle: "2026-08-05_01-37-43") == "capture:2026-08-05_01-37-43",
       "a capture bundle's id is not the one of 07 §3.2")
expect(CapturedItemID.bundleFrame(bundle: "2026-08-05_01-37-43", index: 7)
        == "capture:2026-08-05_01-37-43/07",
       "a bundle frame's id is not the bundle's id and a two-digit number")
expect(CapturedItemID.shot(name: "2026-09-12_14-03-22-118") == "shot:2026-09-12_14-03-22-118",
       "a shot's id is not the one of 07 §3.2")
expect(CapturedItemID.dictation("6F1A-22") == "dictation:6F1A-22", "a dictation's id is wrong")
expect(CapturedItemID.review(day: "2026-08-04") == "review:2026-08-04", "a review's id is wrong")
expect(CapturedItemID.ledger == "review:ledger", "the ledger's id is wrong")
expect(CapturedItemID.recording("9C2B-01") == "recording:9C2B-01", "a recording's id is wrong")

expect(CapturedItemID.isValid("frame:2026-08-18T00-00-06"), "a real id was refused")
expect(CapturedItemID.isValid("capture:2026-08-05_01-37-43/07"), "a bundle frame's id was refused")
expect(!CapturedItemID.isValid("frame:"), "an id with nothing after the colon was accepted")
expect(!CapturedItemID.isValid("notakind:2026-08-18"), "an unknown kind of id was accepted")
expect(!CapturedItemID.isValid("frame:2026-08-18 00-00-06"), "an id with a space was accepted")
expect(!CapturedItemID.isValid("frame:../../etc/passwd"), "an id that walks out of the folder was accepted")
expect(!CapturedItemID.isValid("frame:" + String(repeating: "a", count: 101)),
       "an id longer than the pattern allows was accepted")
expect(!CapturedItemID.isValid(""), "an empty id was accepted")

// ── the file is inside the data folder, and it is not threads.sqlite ──────

let root = makeRoot("store")
let url = CapturedDatabase.url(configRoot: root)
expect(url.lastPathComponent == "captured.sqlite", "the index file is not captured.sqlite")
expect(url.deletingLastPathComponent().lastPathComponent == "index",
       "the index file is not in the index folder")
expect(url.path.hasPrefix(root.path), "the index file is outside the data folder")
expect(url.lastPathComponent != "threads.sqlite",
       "the derived index was put in the thread database, which cannot be thrown away")

let pool = try CapturedDatabase.open(at: url)
expect(files.fileExists(atPath: url.path), "captured.sqlite was not created")

let journal = try pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "" }
expect(journal.lowercased() == "wal",
       "the index is in \(journal) mode, so a tool cannot read while the indexer writes")

let tables = try pool.read { db -> Set<String> in
    Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view')"))
}
for table in ["item", "item_fts", "link", "ingest_cursor", "cleanup_log", "meta"] {
    expect(tables.contains(table), "the schema has no \(table) table")
}
let linkColumns = try pool.read { db -> Set<String> in
    Set(try Row.fetchAll(db, sql: "PRAGMA table_info(link)").compactMap { $0["name"] as String? })
}
expect(linkColumns == ["item_id", "thread_id", "turn_id", "role", "at"],
       "the link table's columns are not the five of 07 §3.1: \(linkColumns.sorted())")

let index = CapturedIndex(pool: pool)
expect(try index.meta("schema_version") == String(CapturedSchema.version),
       "the schema version was not written into meta")

// ── writing the same item twice is one row ────────────────────────────────

let frameID = CapturedItemID.frame(day: "2026-08-18", time: "00-00-06")
var frame = CapturedItemRow(
    id: frameID, kind: .frame, source: .watcher, tStart: 1_755_475_206, tEnd: 1_755_475_206,
    parentID: CapturedItemID.activity(day: "2026-08-18", time: "00-00-01"),
    app: "Google Chrome", bundleID: "com.google.Chrome", title: "Disney+ · Watch",
    url: "disneyplus.com/browse", display: "1", imgW: 1568, imgH: 1014,
    path: "watcher/2026-08-18/frame-00-00-06.jpg", pathClean: nil, bytes: 140_233,
    imageState: .present, body: nil, ocr: "upstream request timeout",
    ocrState: .done, marksJSON: nil, extraJSON: "{\"chg\":[10,10,40,40]}", originDevice: nil)

expect(try index.upsert(frame) == .inserted, "the first write of an item was not an insert")
let rowID = try index.rowID(of: frameID)
expect(rowID != nil, "the item has no row number")
expect(try index.upsert(frame) == .updated, "writing the same item twice was not an update")
let count = try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM item") ?? -1 }
expect(count == 1, "writing the same item twice made \(count) rows")
expect(try index.rowID(of: frameID) == rowID,
       "the row number changed on an update, so the search table now points at nothing")

let readBack = try index.item(id: frameID)
expect(readBack == frame, "the item did not come back as it was written")

frame.title = "Disney+ · Account"
_ = try index.upsert(frame)
expect(try index.item(id: frameID)?.title == "Disney+ · Account", "an update did not change the row")

// ── an item that cannot be pointed at is refused by name ──────────────────

do {
    var broken = frame
    broken.id = "frame:has a space"
    _ = try index.upsert(broken)
    failures.append("an item with an unusable id was stored")
} catch CapturedStoreError.invalidItemID {
} catch {
    failures.append("an item with an unusable id was refused with \(error), not invalidItemID")
}

do {
    var broken = frame
    broken.id = CapturedItemID.frame(day: "2026-08-18", time: "00-00-07")
    broken.tEnd = broken.tStart - 1
    _ = try index.upsert(broken)
    failures.append("an item that ends before it starts was stored")
} catch CapturedStoreError.invalidTimeRange {
} catch {
    failures.append("an item that ends before it starts was refused with \(error), not invalidTimeRange")
}

// ── one search table over every kind ──────────────────────────────────────

let dictationID = CapturedItemID.dictation("6F1A-22")
let dictation = CapturedItemRow(
    id: dictationID, kind: .dictation, source: .dictation,
    tStart: 1_757_680_000, tEnd: 1_757_680_000,
    body: "pantrella deploy notes for tomorrow", ocrState: .na,
    extraJSON: "{\"destination\":\"kept\"}", originDevice: "dev-phone")
_ = try index.upsert(dictation)

expect(try index.search("timeout", limit: 10) == [frameID],
       "the recognised screen text of a frame is not searchable")
expect(try index.search("Chrome", limit: 10) == [frameID], "an application name is not searchable")
expect(try index.search("disneyplus.com", limit: 10) == [frameID], "an address is not searchable")
expect(try index.search("Account", limit: 10) == [frameID], "a window title is not searchable")
expect(try index.search("pantrella", limit: 10) == [dictationID], "a dictation's words are not searchable")
expect(try index.search("pantr*", limit: 10) == [dictationID], "the prefix index does not answer")
expect(try index.search("nothingatall", limit: 10).isEmpty, "the search invented a result")

// One question finds every kind together, which is why there is one search
// table and not one per kind.
_ = try index.upsert(CapturedItemRow(
    id: CapturedItemID.review(day: "2026-08-04"), kind: .review, source: .review,
    tStart: 1_754_265_600, tEnd: 1_754_351_999,
    body: "pantrella came up three times today", ocrState: .na))
expect(try Set(index.search("pantrella", limit: 10)).count == 2,
       "one question did not find a dictation and a review together")

// The search table follows an update. This is the failure the external-content
// table is famous for: the old words stay findable and point at a row that no
// longer says them.
var reworded = dictation
reworded.body = "grocery list for the weekend"
_ = try index.upsert(reworded)
expect(try index.search("pantrella", limit: 10) == [CapturedItemID.review(day: "2026-08-04")],
       "a reworded dictation is still found by its old words")
expect(try index.search("grocery", limit: 10) == [dictationID], "a reworded dictation is not found by its new words")

try index.remove(id: dictationID)
expect(try index.search("grocery", limit: 10).isEmpty, "a removed item is still in the search table")
expect(try index.item(id: dictationID) == nil, "a removed item is still in the item table")

// ── the counts the validation reads ───────────────────────────────────────

_ = try index.upsert(CapturedItemRow(
    id: CapturedItemID.frame(day: "2026-08-18", time: "00-00-11"), kind: .frame, source: .watcher,
    tStart: 1_755_475_211, tEnd: 1_755_475_211,
    path: "watcher/2026-08-18/frame-00-00-11.jpg", imageState: .missing, ocrState: .na))
let counts = try index.countsByKindAndImageState()
expect(counts.contains(CapturedCount(kind: .frame, imageState: .present, count: 1)),
       "the counts do not report one present frame: \(counts)")
expect(counts.contains(CapturedCount(kind: .frame, imageState: .missing, count: 1)),
       "the counts do not report one missing frame: \(counts)")
expect(counts.contains(CapturedCount(kind: .review, imageState: .none, count: 1)),
       "a text-only item is not counted with no picture: \(counts)")

// ── cursors, so catch-up knows what it has read ───────────────────────────

expect(try index.cursor(sourcePath: "watcher/2026-08-18/activity.jsonl") == nil,
       "an unread file already has a cursor")
let cursor = CapturedCursor(sourcePath: "watcher/2026-08-18/activity.jsonl",
                            byteOffset: 4096, mtime: 1_755_475_211, size: 8192)
try index.saveCursor(cursor)
expect(try index.cursor(sourcePath: cursor.sourcePath) == cursor, "the cursor did not come back")
var moved = cursor
moved.byteOffset = 8192
try index.saveCursor(moved)
expect(try index.cursor(sourcePath: cursor.sourcePath)?.byteOffset == 8192, "the cursor did not move")
let cursorRows = try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM ingest_cursor") ?? -1 }
expect(cursorRows == 1, "moving a cursor made a second row")

// ── the index is derived: a new schema throws the tables away ─────────────

try index.setMeta("schema_version", "0")
let reopened = try CapturedDatabase.open(at: url)
let afterRebuild = CapturedIndex(pool: reopened)
expect(try reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM item") ?? -1 } == 0,
       "an older schema was migrated instead of rebuilt")
expect(try afterRebuild.meta("schema_version") == String(CapturedSchema.version),
       "the rebuilt index does not carry the current schema version")
expect(try afterRebuild.cursor(sourcePath: cursor.sourcePath) == nil,
       "the cursors survived a rebuild, so the sources would never be read again")

// ── a damaged file is moved aside, not fought over ────────────────────────

let damagedRoot = makeRoot("damaged")
let damagedURL = CapturedDatabase.url(configRoot: damagedRoot)
try files.createDirectory(at: damagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("this is not a database".utf8).write(to: damagedURL)
let repaired = try CapturedDatabase.open(at: damagedURL)
let repairedCount = try repaired.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM item") ?? -1 }
expect(repairedCount == 0, "the damaged file was opened instead of replaced")
let siblings = (try? files.contentsOfDirectory(atPath: damagedURL.deletingLastPathComponent().path)) ?? []
expect(siblings.contains { $0.hasPrefix("captured.sqlite.broken-") },
       "the damaged file was deleted instead of moved aside: \(siblings)")

finish("captured store")
