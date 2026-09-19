import Foundation

// The retirement of the data sources feature: before the code is gone, the
// dictation copies among the snapshots are read once into the dictation
// archive, de-duplicated by id, and everything the feature stored is moved to
// the legacy folder without erasing a byte. These are behaviour tests against
// `DataSourcesRetirement`'s public surface: a temporary configuration root, a
// recording archive, and the files this step reads and moves.

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

func iso(_ text: String) -> Date {
    guard let date = ISO8601DateFormatter().date(from: text) else {
        FileHandle.standardError.write(Data("FAIL: bad test timestamp \(text)\n".utf8))
        exit(1)
    }
    return date
}

func referenceInterval(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }

func fileCountAndBytes(_ root: URL) -> (files: Int, bytes: Int) {
    var files = 0
    var bytes = 0
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys, options: []) else { return (0, 0) }
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isRegularFile == true {
            files += 1
            bytes += values?.fileSize ?? 0
        }
    }
    return (files, bytes)
}

/// Writes one snapshot folder the way `DataSourceStore` wrote it: a
/// `snapshot.json` plus one text file per item. Only the fields the retirement
/// reads are carried, with the same key names and the same `Date` encoding.
func writeSnapshot(root: URL, source: String, snapshot: String,
                   items: [(id: String, text: String, capturedAt: Date)],
                   extraByteFile: (name: String, bytes: Int)? = nil) throws {
    let folder = root.appendingPathComponent("source-snapshots")
        .appendingPathComponent(source).appendingPathComponent(snapshot)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var jsonItems: [[String: Any]] = []
    var total = 0
    for item in items {
        let text = item.text
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(item.id).txt"))
        total += Data(text.utf8).count
        jsonItems.append([
            "id": item.id,
            "title": "Dictation · \(ISO8601DateFormatter().string(from: item.capturedAt))",
            "relativePath": "\(item.id).txt",
            "contentType": "text/plain",
            "preview": String(text.prefix(700)),
            "capturedAt": referenceInterval(item.capturedAt)
        ])
    }
    if let extra = extraByteFile {
        try Data(repeating: 7, count: extra.bytes)
            .write(to: folder.appendingPathComponent(extra.name))
        total += extra.bytes
    }
    let snapshotJSON: [String: Any] = [
        "id": snapshot,
        "sourceID": source,
        "collectedAt": referenceInterval(Date()),
        "items": jsonItems,
        "bytes": total,
        "skippedCount": 0
    ]
    try JSONSerialization.data(withJSONObject: snapshotJSON, options: [.sortedKeys])
        .write(to: folder.appendingPathComponent("snapshot.json"))
}

/// `dictations.json` as the app writes it: an array of history entries whose
/// fields are `id`, `text`, `time`, `timestamp` and `destination`.
func writeDictationsJSON(root: URL,
                         entries: [(id: String, text: String, timestamp: String, destination: String)]) throws {
    let array = entries.map {
        ["id": $0.id, "text": $0.text, "time": $0.timestamp,
         "timestamp": $0.timestamp, "destination": $0.destination]
    }
    try JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])
        .write(to: root.appendingPathComponent("dictations.json"))
}

/// The shape rule 5 gives an id that no live entry could supply:
/// `legacy-ds-` followed by sixteen lower-case hex characters.
func isRecoveredID(_ id: String) -> Bool {
    guard id.hasPrefix("legacy-ds-") else { return false }
    let hex = id.dropFirst("legacy-ds-".count)
    return hex.count == 16 && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
}

struct SinkRefused: Error {}

func freshRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vf-s6-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// The archive, as much of it as the retirement can observe: an id and a
/// content key are the two ways a dictation is already present.
final class RecordingArchive {
    private(set) var added: [LegacyDictation] = []
    /// How many times the retirement handed it a batch. Rule 7 says once.
    private(set) var callCount = 0
    private var byID: [String: LegacyDictation] = [:]
    private var byContent: Set<String> = []

    static func contentKey(_ record: LegacyDictation) -> String {
        let stamp = record.timestamp.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
        return "\(stamp)|\(record.text)"
    }

    func sink(_ records: [LegacyDictation]) throws -> Int {
        callCount += 1
        var count = 0
        for record in records {
            let key = Self.contentKey(record)
            if byID[record.id] != nil || byContent.contains(key) { continue }
            byID[record.id] = record
            byContent.insert(key)
            added.append(record)
            count += 1
        }
        return count
    }

    func record(text: String) -> LegacyDictation? { added.first { $0.text == text } }
}

func expectCode(_ code: String, _ message: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch let error as DataSourcesRetirementError {
        expect(error.code == code, "\(message): expected \(code), got \(error.code)")
        return
    } catch {
        expect(false, "\(message): expected DataSourcesRetirementError.\(code), got \(error)")
    }
    expect(false, "\(message): expected DataSourcesRetirementError.\(code), nothing was thrown")
}

let fixedNow = iso("2026-09-19T12:00:00Z")
let legacyFolderName = "legacy/data-sources-2026-09-19"

// ── 1. The dictation copies are read once, de-duplicated by id, and
//       everything stored is moved without losing a file or a byte. ────────

do {
    let root = try freshRoot("main")
    defer { try? FileManager.default.removeItem(at: root) }
    // Two snapshots that overlap (the collector rewrote the folder every 75
    // seconds) plus one older dictation that has already dropped out of the
    // newest 200 in dictations.json and would otherwise be lost.
    try writeSnapshot(root: root, source: "builtin-dictations", snapshot: "snap-1", items: [
        (id: "item-1", text: "Oldest dictation", capturedAt: iso("2026-07-01T10:00:00Z")),
        (id: "item-2", text: "Kept dictation", capturedAt: iso("2026-09-01T10:00:00Z"))
    ])
    try writeSnapshot(root: root, source: "builtin-dictations", snapshot: "snap-2", items: [
        (id: "item-1", text: "Kept dictation", capturedAt: iso("2026-09-01T10:00:00Z")),
        (id: "item-2", text: "Second old dictation", capturedAt: iso("2026-07-02T09:00:00Z"))
    ])
    // A non-dictation source is moved whole. Its items are never dictations:
    // only `builtin-dictations` is read into the archive. It also proves the
    // byte count is over the whole folder, not only the dictations.
    try writeSnapshot(root: root, source: "builtin-website", snapshot: "snap-9", items: [
        (id: "item-1", text: "Not a dictation", capturedAt: iso("2026-07-10T10:00:00Z"))
    ], extraByteFile: ("page.html", 4096))
    try writeDictationsJSON(root: root, entries: [
        (id: "live-kept-1", text: "Kept dictation", timestamp: "2026-09-01T10:00:00Z",
         destination: "kept")
    ])
    try Data("{}".utf8).write(to: root.appendingPathComponent("sources-registry.json"))
    try Data("{}".utf8).write(to: root.appendingPathComponent("source-collection-status.json"))

    let baseline = fileCountAndBytes(root.appendingPathComponent("source-snapshots"))
    let baselineWithRegistry = baseline.files + 2

    let archive = RecordingArchive()
    let report = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)

    expect(report.dictationsRead == 4, "all four dictation copies are read, got \(report.dictationsRead)")
    expect(report.dictationsOffered == 3, "the three distinct dictations are offered once, got \(report.dictationsOffered)")
    expect(report.dictationsAdded == 3, "three dictations reach the archive, got \(report.dictationsAdded)")
    expect(archive.added.count == 3, "the archive holds three dictations")
    expect(archive.callCount == 1, "the sink is called once with the whole list, got \(archive.callCount)")
    expect(archive.record(text: "Not a dictation") == nil,
           "an item of a source other than builtin-dictations is never offered as a dictation")
    expect(archive.added.map(\.id).count == Set(archive.added.map(\.id)).count,
           "every offered dictation has a distinct id")
    expect(archive.record(text: "Kept dictation")?.id == "live-kept-1",
           "a dictation still in dictations.json keeps its own id")
    expect(archive.record(text: "Kept dictation")?.destination == "kept",
           "a matched dictation carries the destination of its dictations.json entry")
    expect(archive.record(text: "Oldest dictation") != nil, "a dictation older than the newest 200 is recovered")
    expect(archive.record(text: "Oldest dictation")?.destination == nil,
           "a recovered dictation with no live entry has no destination")
    expect(archive.record(text: "Oldest dictation").map { isRecoveredID($0.id) } == true,
           "a recovered dictation gets a legacy-ds-<16 hex> id, got \(archive.record(text: "Oldest dictation")?.id ?? "none")")
    expect(archive.record(text: "Second old dictation") != nil, "the second old dictation is recovered")
    expect(archive.record(text: "Second old dictation").map { isRecoveredID($0.id) } == true,
           "the second recovered dictation gets a legacy-ds-<16 hex> id")
    expect(archive.added.first?.text == "Oldest dictation", "records are offered oldest first")
    expect(archive.added.last?.text == "Kept dictation", "records are offered newest last")

    let sourceSnapshots = root.appendingPathComponent("source-snapshots")
    expect(!FileManager.default.fileExists(atPath: sourceSnapshots.path),
           "source-snapshots no longer exists under the configuration root")
    let legacy = root.appendingPathComponent(legacyFolderName)
    expect(report.legacyFolder?.standardizedFileURL == legacy.standardizedFileURL, "the report names the legacy folder")
    let moved = fileCountAndBytes(legacy)
    expect(moved.files == baselineWithRegistry,
           "the legacy folder holds the same number of files (\(moved.files) vs \(baselineWithRegistry))")
    expect(moved.bytes == baseline.bytes + 4,
           "the legacy folder holds the same number of bytes (\(moved.bytes) vs \(baseline.bytes + 4))")
    expect(report.filesMoved == moved.files,
           "the report counts the files it moved (\(report.filesMoved) vs \(moved.files))")
    expect(report.bytesMoved == moved.bytes,
           "the report counts the bytes it moved (\(report.bytesMoved) vs \(moved.bytes))")
    expect(report.movedItems.sorted() == ["source-collection-status.json", "source-snapshots", "sources-registry.json"],
           "the report names the three moved items, got \(report.movedItems.sorted())")
    expect(report.alreadyDone == false, "a run that moved the live folder is not already done")
    expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("source-snapshots/builtin-dictations/snap-1/item-1.txt").path),
           "the original dictation copy is still readable under the legacy folder")
    expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("sources-registry.json").path),
           "the registry file is moved rather than erased")
    expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("source-collection-status.json").path),
           "the collection status file is moved rather than erased")

    // Idempotent: the second run finds no live folder, reads the copies from
    // the legacy folder, and the archive rejects every id it already holds.
    let archiveAgain = RecordingArchive()
    _ = try archiveAgain.sink(archive.added)
    let second = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archiveAgain.sink)
    expect(second.dictationsAdded == 0, "the second run adds nothing, got \(second.dictationsAdded)")
    expect(second.movedItems.isEmpty, "the second run moves nothing")
    expect(second.alreadyDone, "the second run reports the retirement as already done")
    expect(second.readFrom?.lastPathComponent == "source-snapshots",
           "the second run reads the copies where they now are")
    let stableAfter = fileCountAndBytes(legacy)
    expect(stableAfter.files == baselineWithRegistry,
           "a later count does not change (\(stableAfter.files) vs \(baselineWithRegistry))")
}

// ── 2. The same copy in two snapshots yields one deterministic id. ─────────

do {
    let first = try freshRoot("id-a")
    defer { try? FileManager.default.removeItem(at: first) }
    let second = try freshRoot("id-b")
    defer { try? FileManager.default.removeItem(at: second) }
    for (root, snapshot) in [(first, "snap-a"), (second, "snap-b")] {
        try writeSnapshot(root: root, source: "builtin-dictations", snapshot: snapshot, items: [
            (id: "item-1", text: "Only once", capturedAt: iso("2026-07-03T08:00:00Z"))
        ])
    }
    let archiveA = RecordingArchive()
    _ = try DataSourcesRetirement.run(configRoot: first, now: fixedNow, dictationSink: archiveA.sink)
    let archiveB = RecordingArchive()
    _ = try DataSourcesRetirement.run(configRoot: second, now: fixedNow, dictationSink: archiveB.sink)
    expect(archiveA.added.count == 1 && archiveB.added.count == 1, "each copy is offered once")
    expect(archiveA.added[0].id == archiveB.added[0].id,
           "a dictation with no live id gets the same deterministic id on every run")
    expect(isRecoveredID(archiveA.added[0].id),
           "the deterministic id has the legacy-ds-<16 hex> shape, got \(archiveA.added[0].id)")
}

// ── 2b. Two dictations of the same moment are ordered by their text. ───────

do {
    let root = try freshRoot("tie")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSnapshot(root: root, source: "builtin-dictations", snapshot: "snap-tie", items: [
        (id: "item-1", text: "Bravo said second", capturedAt: iso("2026-07-06T08:00:00Z")),
        (id: "item-2", text: "Alpha said first", capturedAt: iso("2026-07-06T08:00:00Z"))
    ])
    let archive = RecordingArchive()
    _ = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)
    expect(archive.added.map(\.text) == ["Alpha said first", "Bravo said second"],
           "records of the same moment are ordered by text, got \(archive.added.map(\.text))")
}

// ── 3. Already moved by the importer: nothing to move, still read. ─────────

do {
    let root = try freshRoot("moved")
    defer { try? FileManager.default.removeItem(at: root) }
    let movedRoot = root.appendingPathComponent("legacy/pre-threads-2026-09-18")
    try writeSnapshot(root: movedRoot, source: "builtin-dictations", snapshot: "snap-1", items: [
        (id: "item-1", text: "Moved earlier", capturedAt: iso("2026-07-04T08:00:00Z"))
    ])
    let archive = RecordingArchive()
    let report = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)
    expect(report.movedItems.isEmpty, "a run that finds nothing live moves nothing")
    expect(report.filesMoved == 0 && report.bytesMoved == 0, "a run that moves nothing counts nothing")
    expect(report.alreadyDone, "a run that finds the copies already under legacy reports it")
    expect(report.dictationsRead == 1, "the copy under the legacy folder is read, got \(report.dictationsRead)")
    expect(report.dictationsAdded == 1, "the copy is still read from the legacy folder")
    expect(report.readFrom?.resolvingSymlinksInPath().path.hasPrefix(movedRoot.resolvingSymlinksInPath().path) == true,
           "the report names the legacy location it read from")
    expect(archive.added.first?.text == "Moved earlier", "the moved dictation reaches the archive")
    expect(FileManager.default.fileExists(atPath: movedRoot.appendingPathComponent("source-snapshots/builtin-dictations/snap-1/item-1.txt").path),
           "the copy the importer had already moved is left where it is")
}

// ── 4. Refusals and failures by name. ─────────────────────────────────────

do {
    // More than one legacy source-snapshots folder is ambiguous: refuse.
    let root = try freshRoot("ambiguous")
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("legacy/pre-threads-2026-09-17")
    let b = root.appendingPathComponent("legacy/pre-threads-2026-09-18")
    try writeSnapshot(root: a, source: "builtin-dictations", snapshot: "s", items: [
        (id: "i", text: "A", capturedAt: iso("2026-07-05T08:00:00Z"))
    ])
    try writeSnapshot(root: b, source: "builtin-dictations", snapshot: "s", items: [
        (id: "i", text: "B", capturedAt: iso("2026-07-05T08:00:00Z"))
    ])
    let archive = RecordingArchive()
    expectCode("data_sources_legacy_ambiguous", "two legacy copies are refused") {
        _ = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)
    }
}

do {
    // A live folder beside an existing destination would need a merge; refuse.
    let root = try freshRoot("destination")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSnapshot(root: root, source: "builtin-dictations", snapshot: "s", items: [
        (id: "i", text: "Live", capturedAt: iso("2026-07-05T08:00:00Z"))
    ])
    try FileManager.default.createDirectory(at: root.appendingPathComponent(legacyFolderName),
                                            withIntermediateDirectories: true)
    let archive = RecordingArchive()
    expectCode("data_sources_destination_exists", "an existing destination is refused") {
        _ = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)
    }
    expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("source-snapshots").path),
           "the refused run leaves the live folder in place")
    expect(archive.added.isEmpty, "the refused run appends nothing")
}

do {
    // An unreadable snapshot fails fast and moves nothing.
    let root = try freshRoot("corrupt")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("source-snapshots/builtin-dictations/snap-x")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: folder.appendingPathComponent("snapshot.json"))
    let archive = RecordingArchive()
    expectCode("source_snapshot_unreadable", "an unreadable snapshot is named") {
        _ = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)
    }
    expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("source-snapshots").path),
           "a failed read moves nothing")
    expect(archive.added.isEmpty, "a failed read appends nothing")
}

do {
    // An item path that escapes its snapshot folder is refused by the same
    // name, and nothing is moved: the retirement never reads outside the
    // folder it was given.
    let root = try freshRoot("escape")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("source-snapshots/builtin-dictations/snap-e")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let snapshot: [String: Any] = [
        "id": "snap-e", "sourceID": "builtin-dictations",
        "collectedAt": referenceInterval(iso("2026-07-07T08:00:00Z")),
        "bytes": 0, "skippedCount": 0,
        "items": [[
            "id": "item-1", "title": "Dictation · escape",
            "relativePath": "../../../../dictations.json",
            "contentType": "text/plain", "preview": "",
            "capturedAt": referenceInterval(iso("2026-07-07T08:00:00Z"))
        ]]
    ]
    try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        .write(to: folder.appendingPathComponent("snapshot.json"))
    let archive = RecordingArchive()
    expectCode("source_snapshot_unreadable", "an item path that leaves its folder is named") {
        _ = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)
    }
    expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("source-snapshots").path),
           "an escaping item path moves nothing")
    expect(archive.added.isEmpty, "an escaping item path appends nothing")
}

do {
    // The copies reach the archive before a single file is moved, and a move
    // that cannot be made is named. `legacy` is a file here, so the
    // destination cannot be created.
    let root = try freshRoot("movefail")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSnapshot(root: root, source: "builtin-dictations", snapshot: "snap-m", items: [
        (id: "item-1", text: "Read before the move", capturedAt: iso("2026-07-08T08:00:00Z"))
    ])
    try Data("not a folder".utf8).write(to: root.appendingPathComponent("legacy"))
    let archive = RecordingArchive()
    expectCode("data_sources_move_failed", "a move that cannot be made is named") {
        _ = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)
    }
    expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("source-snapshots").path),
           "a failed move leaves the live folder in place")
    expect(archive.added.count == 1,
           "the dictation reached the archive before the move was attempted, got \(archive.added.count)")

    // The retry is not a duplicate: the same copy yields the same id.
    try FileManager.default.removeItem(at: root.appendingPathComponent("legacy"))
    let retry = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)
    expect(retry.dictationsAdded == 0, "the retry adds nothing, got \(retry.dictationsAdded)")
    expect(archive.added.count == 1, "the retry leaves one record in the archive")
    expect(retry.movedItems.contains("source-snapshots"), "the retry moves the live folder")
    expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(legacyFolderName)/source-snapshots/builtin-dictations/snap-m/item-1.txt").path),
           "the copy is readable under the legacy folder after the retry")
}

do {
    // If the archive refuses the records, nothing has been moved and no
    // destination folder is left behind for the next run to refuse.
    let root = try freshRoot("sinkfails")
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSnapshot(root: root, source: "builtin-dictations", snapshot: "snap-s", items: [
        (id: "item-1", text: "Never stored", capturedAt: iso("2026-07-09T08:00:00Z"))
    ])
    var thrown = false
    do {
        _ = try DataSourcesRetirement.run(configRoot: root, now: fixedNow,
                                          dictationSink: { _ in throw SinkRefused() })
    } catch { thrown = true }
    expect(thrown, "a sink that refuses fails the run")
    expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("source-snapshots").path),
           "a refused sink moves nothing")
    expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(legacyFolderName).path),
           "a refused sink leaves no destination folder behind")
}

do {
    // Nothing to do is not an error.
    let root = try freshRoot("empty")
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = RecordingArchive()
    let report = try DataSourcesRetirement.run(configRoot: root, now: fixedNow, dictationSink: archive.sink)
    expect(report.dictationsOffered == 0 && report.movedItems.isEmpty,
           "a configuration root with nothing to retire is quiet")
    expect(report.readFrom == nil, "a configuration root with nothing to retire names no reader")
    expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(legacyFolderName).path),
           "a configuration root with nothing to retire creates no legacy folder")
}

print("data sources retirement: ok")
