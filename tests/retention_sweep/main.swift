import Foundation
import GRDB

// RetentionSweeper (07 §3.11): one disk budget for unlinked pictures, one
// thinning rule, one bulk guard, one cleanup log, one daily run, and the links
// read from the thread store before every plan.
//
// The sweeper is exercised against a real CapturedIndex and a real folder on
// disk under a temporary configuration root. The link source is an input to
// the sweeper (the thread store is its real implementation elsewhere); what is
// asserted here is the sweeper's own behaviour.

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

// ── fixtures ──────────────────────────────────────────────────────────────

private let files = FileManager.default
private var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!

private func makeRoot(_ name: String) -> URL {
    let url = VoiceFlowPaths.shared.configRoot.appendingPathComponent(name, isDirectory: true)
    try? files.removeItem(at: url)
    try! files.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeIndex(_ name: String) -> (root: URL, index: CapturedIndex) {
    let root = makeRoot(name)
    let pool = try! CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root))
    return (root, CapturedIndex(pool: pool))
}

private func epoch(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0, _ ss: Int = 0) -> Int {
    Int(utc.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm, second: ss))!
        .timeIntervalSince1970)
}

/// Writes a small real file; the row's `bytes` column carries the weight the
/// budget is measured in, exactly as the ingester fills it from the disk.
@discardableResult
private func writeFile(_ root: URL, _ relative: String, _ content: String = "jpg") -> Int {
    let url = root.appendingPathComponent(relative)
    try! files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(content.utf8).write(to: url, options: .atomic)
    return content.utf8.count
}

private func fileExists(_ root: URL, _ relative: String) -> Bool {
    files.fileExists(atPath: root.appendingPathComponent(relative).path)
}

private func removeFile(_ root: URL, _ relative: String) {
    try? files.removeItem(at: root.appendingPathComponent(relative))
}

@discardableResult
private func addItem(_ index: CapturedIndex, id: String, kind: CapturedKind, source: CapturedSource,
                     tStart: Int, bytes: Int = 0, path: String? = nil, parentID: String? = nil,
                     imageState: CapturedImageState = .none, ocr: String? = nil,
                     extraJSON: String? = nil) -> CapturedItemRow {
    let row = CapturedItemRow(
        id: id, kind: kind, source: source, tStart: tStart, tEnd: tStart,
        parentID: parentID, path: path, bytes: bytes, imageState: imageState, ocr: ocr,
        extraJSON: extraJSON)
    try! index.upsert(row)
    return row
}

/// A picture row plus its file on disk.
@discardableResult
private func addPicture(_ index: CapturedIndex, root: URL, id: String, day: String, tStart: Int,
                        bytes: Int, fileName: String, parentID: String? = nil,
                        source: CapturedSource = .watcher, kind: CapturedKind = .frame,
                        ocr: String? = nil) -> String {
    let path = "watcher/\(day)/\(fileName)"
    writeFile(root, path)
    addItem(index, id: id, kind: kind, source: source, tStart: tStart, bytes: bytes,
            path: path, parentID: parentID, imageState: .present, ocr: ocr)
    return path
}

private func makeSweeper(root: URL, index: CapturedIndex, budgetGB: Int,
                         links: CapturedLinkSource = EmptyLinks(), now: Date) -> RetentionSweeper {
    RetentionSweeper(index: index, root: root, links: links,
                     settings: CapturedRetentionSettings(picturesBudgetGB: budgetGB),
                     calendar: utc, now: { now })
}

private struct EmptyLinks: CapturedLinkSource {
    func liveLinks() throws -> [CapturedLinkRef] { [] }
}
private struct Links: CapturedLinkSource {
    let refs: [CapturedLinkRef]
    func liveLinks() throws -> [CapturedLinkRef] { refs }
}

private func logRows(_ index: CapturedIndex) -> [(stage: String, day: String, files: Int, bytes: Int)] {
    (try? index.pool.read { db in
        try Row.fetchAll(db, sql: "SELECT stage, day, files, bytes FROM cleanup_log ORDER BY at, day")
            .map { row in
                (stage: row["stage"] ?? "", day: row["day"] ?? "",
                 files: row["files"] ?? 0, bytes: row["bytes"] ?? 0)
            }
    }) ?? []
}

private let now = Date(timeIntervalSince1970: TimeInterval(epoch(2026, 9, 19, 12, 0, 0)))
private let dayJuly = "2026-07-19"

// ── under budget: a run does nothing, and writes no log ───────────────────

do {
    let (root, index) = makeIndex("under")
    addPicture(index, root: root, id: "shot:2026-09-12_14-03-22-118", day: "2026-09-12",
               tStart: epoch(2026, 9, 12, 14, 3, 22), bytes: 100_000_000,
               fileName: "shot-14-03-22.jpg", source: .shot, kind: .shot)
    let sweeper = makeSweeper(root: root, index: index, budgetGB: 25, now: now)
    let result = try sweeper.run()
    expect(result.outcome == .nothingToDo, "a run under budget did not do nothing: \(result.outcome)")
    expect(result.plan?.actions.isEmpty == true, "an under-budget run planned work")
    expect(logRows(index).isEmpty, "an under-budget run wrote a cleanup log row")
    expect(fileExists(root, "watcher/2026-09-12/shot-14-03-22.jpg"), "an under-budget run removed a picture")
}

// ── over budget: thinning, span-first and nearest-to-anchor, then idempotence ─

do {
    let (root, index) = makeIndex("thin")
    let day = "2026-08-18"
    let base = epoch(2026, 8, 18)
    let spanA = "activity:2026-08-18T00-00-00"
    let spanB = "activity:2026-08-18T00-00-10"
    addItem(index, id: spanA, kind: .activity, source: .watcher, tStart: base + 1)
    addItem(index, id: spanB, kind: .activity, source: .watcher, tStart: base + 11)
    let names = ["frame-00-00-01.jpg", "frame-00-00-06.jpg", "frame-00-00-11.jpg",
                 "frame-00-00-16.jpg", "frame-00-00-21.jpg"]
    let ids = ["frame:f1", "frame:f2", "frame:f3", "frame:f4", "frame:f5"]
    let parents: [String?] = [spanA, spanA, spanB, spanB, nil]
    let times = [1, 6, 11, 16, 21]
    for i in 0..<5 {
        addPicture(index, root: root, id: ids[i], day: day, tStart: base + times[i],
                   bytes: 300_000_000, fileName: names[i], parentID: parents[i])
    }
    // The anchors the thinning rule measures distance against.
    addItem(index, id: "dictation:anchor", kind: .dictation, source: .dictation, tStart: base + 15)
    addItem(index, id: "shot:anchor", kind: .shot, source: .shot, tStart: base + 12)

    let sweeper = makeSweeper(root: root, index: index, budgetGB: 1, now: now)
    expect(try sweeper.usedBytes() == 1_500_000_000,
           "used bytes are not the sum of the unlinked pictures: \(try sweeper.usedBytes())")
    let result = try sweeper.run()
    expect(result.outcome == .executed, "an over-budget run was not executed: \(result.outcome)")
    expect(result.thinned == 2, "thinning removed \(result.thinned) pictures, not 2")
    expect(result.removed == 0, "thinning removed a file from disk instead of thinning it")

    for i in 0..<5 {
        let row = try index.item(id: ids[i])
        let expected: CapturedImageState = (i == 1 || i == 4) ? .thinned : .present
        expect(row?.imageState == expected,
               "\(ids[i]) is \(String(describing: row?.imageState)), not \(expected)")
        expect(fileExists(root, "watcher/\(day)/\(names[i])") == (expected == .present),
               "the file of \(ids[i]) does not match its image state")
    }
    expect(try sweeper.usedBytes() == 900_000_000,
           "after thinning the used bytes are \(try sweeper.usedBytes()), not 900 MB")
    let rows = logRows(index)
    expect(rows.count == 1 && rows[0].stage == "thin" && rows[0].files == 2 && rows[0].bytes == 600_000_000,
           "the cleanup log row is not one thin row of 2 files and 600 MB: \(rows)")

    // Running again on the same state does nothing and writes nothing new.
    let again = try sweeper.run()
    expect(again.outcome == .nothingToDo, "a second run over a thinned day did work: \(again.outcome)")
    expect(logRows(index).count == 1, "a second run wrote another cleanup log row")
}

// ── the thread store is the source of truth for exemptions ─────────────────

do {
    let (root, index) = makeIndex("links")
    let day = "2026-08-18"
    let base = epoch(2026, 8, 18)
    let span = "activity:2026-08-18T00-00-00"
    addItem(index, id: span, kind: .activity, source: .watcher, tStart: base + 1)
    // g1 is a span's first picture and is kept regardless.
    addPicture(index, root: root, id: "frame:g1", day: day, tStart: base + 1,
               bytes: 400_000_000, fileName: "frame-00-00-01.jpg", parentID: span)
    // g2 is removable and has a stale link row in the index, which is ignored.
    let g2Path = addPicture(index, root: root, id: "frame:g2", day: day, tStart: base + 6,
                            bytes: 400_000_000, fileName: "frame-00-00-06.jpg")
    // g3 is removable but the thread store still needs it.
    addPicture(index, root: root, id: "frame:g3", day: day, tStart: base + 9,
               bytes: 400_000_000, fileName: "frame-00-00-09.jpg")
    try index.pool.write { db in
        try db.execute(sql: "INSERT INTO link (item_id, thread_id, turn_id, role, at) VALUES (?,?,?,?,?)",
                       arguments: StatementArguments(["frame:g2", "thread:stale", "turn:stale", "attached", 0]))
    }
    let sweeper = makeSweeper(root: root, index: index, budgetGB: 1,
                              links: Links(refs: [CapturedLinkRef(itemID: "frame:g3", threadID: "thread:live")]),
                              now: now)
    let result = try sweeper.run()
    expect(result.outcome == .executed, "the linked-picture run was not executed: \(result.outcome)")
    expect(try index.item(id: "frame:g2")?.imageState == .thinned,
           "a stale index link row exempted a picture the thread store does not need")
    expect(try index.item(id: "frame:g3")?.imageState == .present && fileExists(root, "watcher/\(day)/frame-00-00-09.jpg"),
           "a picture the thread store still needs was swept")
    expect(try index.item(id: "frame:g1")?.imageState == .present,
           "a span's first picture was swept")
    expect(fileExists(root, g2Path) == false, "the thinned picture's file was left behind")
}

// ── stage 2: every day thinned, still over budget, remove the oldest day's ─

do {
    let (root, index) = makeIndex("stage2")
    let day = "2026-08-17"
    let base = epoch(2026, 8, 17)
    for i in 0..<4 {
        let span = "activity:2026-08-17T00-00-0\(i)"
        addItem(index, id: span, kind: .activity, source: .watcher, tStart: base + i + 1)
        addPicture(index, root: root, id: "frame:k\(i)", day: day, tStart: base + i + 1,
                   bytes: 300_000_000, fileName: "frame-00-00-0\(i).jpg", parentID: span,
                   ocr: i == 0 ? "recognised text kept" : nil)
    }
    let sweeper = makeSweeper(root: root, index: index, budgetGB: 1, now: now)
    let result = try sweeper.run()
    expect(result.outcome == .executed, "the stage-2 run was not executed: \(result.outcome)")
    expect(result.thinned == 0 && result.removed == 1,
           "stage 2 reported \(result.thinned) thinned and \(result.removed) removed, not 0 and 1")
    let victim = try index.item(id: "frame:k0")
    expect(victim?.imageState == .deleted, "the oldest day's picture was not marked deleted")
    expect(!fileExists(root, "watcher/\(day)/frame-00-00-00.jpg"), "the removed picture's file was left behind")
    expect(victim?.ocr == "recognised text kept",
           "removing a picture threw away its recognised text")
    expect(try sweeper.usedBytes() == 900_000_000,
           "after stage 2 the used bytes are \(try sweeper.usedBytes()), not 900 MB")
}

// ── the bulk guard: nothing runs until it is confirmed ─────────────────────

do {
    let (root, index) = makeIndex("bulk")
    for i in 0..<18 {
        let day = String(format: "2026-08-%02d", i + 1)
        let t = epoch(2026, 8, i + 1)
        let span = "activity:\(day)T00-00-00"
        addItem(index, id: span, kind: .activity, source: .watcher, tStart: t + 1)
        addPicture(index, root: root, id: "frame:b\(i)", day: day, tStart: t + 1,
                   bytes: 200_000_000, fileName: "frame-00-00-01.jpg", parentID: span)
    }
    let sweeper = makeSweeper(root: root, index: index, budgetGB: 1, now: now)
    let result = try sweeper.run()
    expect(result.outcome == .needsReview, "a bulk plan ran instead of asking for review: \(result.outcome)")
    guard let pending = try sweeper.pendingPlan() else {
        failures.append("a bulk plan left no pendingPlan in the health object")
        finish("retention sweep")
    }
    expect(pending.isBulk, "the pending plan does not call itself bulk")
    expect(pending.bytes > 1_000_000_000, "the pending plan removes \(pending.bytes) bytes, not more than 1 GB")
    expect(pending.days.count > 7, "the pending plan touches \(pending.days.count) days, not more than 7")
    expect(fileExists(root, "watcher/2026-08-01/frame-00-00-01.jpg"),
           "a bulk plan removed a file without confirmation")
    expect(logRows(index).isEmpty, "a bulk plan wrote a cleanup log row")

    // Dismissing clears it; confirming runs exactly the stored plan.
    _ = try sweeper.decide(planID: pending.planID, run: false)
    expect(try sweeper.pendingPlan() == nil, "dismissing did not clear the pending plan")
    expect(fileExists(root, "watcher/2026-08-01/frame-00-00-01.jpg"),
           "dismissing a bulk plan removed a file")

    let second = try sweeper.run()
    expect(second.outcome == .needsReview, "the second bulk run did not ask for review again")
    guard let pending2 = try sweeper.pendingPlan(), try second.plan != nil else {
        failures.append("the second bulk run left no plan to confirm")
        finish("retention sweep")
    }
    let run = try sweeper.decide(planID: pending2.planID, run: true)
    expect(run.outcome == .executed, "confirming a bulk plan did not execute it: \(run.outcome)")
    expect(try sweeper.usedBytes() <= 1_000_000_000,
           "after the confirmed bulk run the used bytes are still \(try sweeper.usedBytes())")
    expect(!fileExists(root, "watcher/2026-08-01/frame-00-00-01.jpg"),
           "the confirmed bulk run did not remove the oldest day")
    expect(fileExists(root, "watcher/2026-08-18/frame-00-00-01.jpg"),
           "the confirmed bulk run removed the newest day too")
    expect(!logRows(index).isEmpty, "the confirmed bulk run wrote no cleanup log row")
    expect(try sweeper.pendingPlan() == nil, "the confirmed bulk plan stayed pending")
}

// ── the daily run: at launch only when the last one is over a day old ──────

do {
    let (root, index) = makeIndex("due")
    let base = epoch(2026, 8, 18)
    for i in 0..<2 {
        addPicture(index, root: root, id: "frame:d\(i)", day: "2026-08-18",
                   tStart: base + i + 1, bytes: 700_000_000, fileName: "frame-00-00-0\(i).jpg")
    }
    let sweeper = makeSweeper(root: root, index: index, budgetGB: 1, now: now)
    let first = try sweeper.runIfDue()
    expect(first.outcome == .executed, "the first launch run was skipped: \(first.outcome)")
    expect(try index.meta("retention_last_checked") != nil, "the run did not record when it ran")

    // A second picture arrives; a launch an hour later must not touch it.
    addPicture(index, root: root, id: "frame:d2", day: "2026-08-18",
               tStart: base + 3, bytes: 1_100_000_000, fileName: "frame-00-00-02.jpg")
    let soon = makeSweeper(root: root, index: index, budgetGB: 1, now: now.addingTimeInterval(3600))
    let skipped = try soon.runIfDue()
    expect(skipped.outcome == .nothingToDo, "a run an hour after the last one was not skipped")
    expect(try index.item(id: "frame:d2")?.imageState == .present,
           "a run an hour after the last one swept a picture")

    // A launch a day and an hour later is due again.
    let later = makeSweeper(root: root, index: index, budgetGB: 1,
                            now: now.addingTimeInterval(90_000))
    let due = try later.runIfDue()
    expect(due.outcome == .executed, "a run more than a day after the last one was skipped")
    expect(try index.item(id: "frame:d2")?.imageState != .present,
           "the due run left a removable picture alone")
}

// ── derived crops last one day; "no speech found" recordings last seven ────

do {
    let (root, index) = makeIndex("crops")
    let cropOld = root.appendingPathComponent("captures/derived/crop-old.jpg")
    let cropNew = root.appendingPathComponent("captures/derived/crop-new.jpg")
    try! files.createDirectory(at: cropOld.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("crop".utf8).write(to: cropOld)
    try! Data("crop".utf8).write(to: cropNew)
    try! files.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: cropOld.path)
    try! files.setAttributes([.modificationDate: now], ofItemAtPath: cropNew.path)

    let wavOld = root.appendingPathComponent("pending-audio/2A2B.wav")
    try! files.createDirectory(at: wavOld.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("wav".utf8).write(to: wavOld)
    addItem(index, id: "recording:2A2B", kind: .recording, source: .recording,
            tStart: epoch(2026, 9, 1), path: "pending-audio/2A2B.wav",
            extraJSON: "{\"state\":\"no_speech_found\",\"no_speech_at\":\(epoch(2026, 9, 10))}")
    addItem(index, id: "recording:2C2D", kind: .recording, source: .recording,
            tStart: epoch(2026, 9, 18), path: "pending-audio/2C2D.wav",
            extraJSON: "{\"state\":\"no_speech_found\",\"no_speech_at\":\(epoch(2026, 9, 18))}")
    writeFile(root, "pending-audio/2C2D.wav")
    addItem(index, id: "recording:2E2F", kind: .recording, source: .recording,
            tStart: epoch(2026, 9, 1), path: "pending-audio/2E2F.wav",
            extraJSON: "{\"state\":\"undelivered\"}")
    writeFile(root, "pending-audio/2E2F.wav")

    let sweeper = makeSweeper(root: root, index: index, budgetGB: 25, now: now)
    let result = try sweeper.run()
    expect(result.outcome == .executed, "the crop/recording run did nothing: \(result.outcome)")
    expect(!files.fileExists(atPath: cropOld.path), "a derived crop older than a day survived")
    expect(files.fileExists(atPath: cropNew.path), "a derived crop from today was removed")
    expect(try index.item(id: "recording:2A2B") == nil,
           "a 'no speech found' recording older than seven days survived")
    expect(!fileExists(root, "pending-audio/2A2B.wav"), "its file was left behind")
    expect(try index.item(id: "recording:2C2D") != nil,
           "a 'no speech found' recording from today was removed")
    expect(try index.item(id: "recording:2E2F") != nil,
           "an undelivered recording was removed instead of kept until delivered")
    expect(fileExists(root, "pending-audio/2E2F.wav"), "an undelivered recording's file was removed")
}

finish("retention sweep")
