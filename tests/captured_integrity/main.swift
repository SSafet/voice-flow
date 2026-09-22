import AppKit
import Foundation
import GRDB
import CryptoKit

func vflog(_ message: String) {}
final class UserSettings {
    static let shared = UserSettings()
    var watcherKeepDays = 30
    var watcherDenseApps: Set<String> = []
}
final class PendingInteraction { var sessionId: String? }
struct CaptureSummary {}
func require(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
    if try !condition() { throw NSError(domain: description, code: 1) }
}
func rejected(_ description: String, _ body: () throws -> Void) throws {
    var failed = false
    do { try body() } catch { failed = true }
    try require(failed, description)
}
let root = VoiceFlowPaths.shared.configRoot
try require(VoiceFlowPaths.shared.isIsolated, "isolated root required")
let files = FileManager.default
func write(_ bytes: Data, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url)
}
func write(_ text: String, _ path: String) throws { try write(Data(text.utf8), path) }
func line(_ fields: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self) + "\n"
}
let service = try CapturedService(root: root)
let index = service.index
let ingest = service.ingest
let day = "2026-09-22"
let epoch = IngestFile.epoch(day, "10-00-00")!
let source = "watcher/\(day)/activity.jsonl"
let first = try line(["app": "Editor", "title": "beforeword", "url": "example.com/project", "t": "10:00:00", "e": epoch, "frame": "frame-10-00-00.jpg"])
let second = try line(["app": "Editor", "title": "afterword", "t": "10:00:05", "e": epoch + 5])
try write(first + "bad JSON\n", source)
try rejected("bad source must not succeed") { _ = try ingest.run(.init(source: "watcher", key: day)) }
try require(try index.countsByKindAndImageState().isEmpty, "failed source must roll back items and search")
try require(try index.cursor(sourcePath: source) == nil, "failed source must not advance cursor")
try write(first + second, source)
try service.catchUpNow()
try require(try index.search("beforeword", limit: 10).count == 2, "frame and activity are searchable after retry")
let firstID = CapturedItemID.activity(day: day, time: "10-00-00")
try require(try index.item(id: firstID)?.url == "example.com/project", "sanitized recorder URL must survive replay")
let stop = try line(["kind": "watcher_stop", "t": "10:00:06", "e": epoch + 6])
let later = try line(["app": "Browser", "title": "tailword", "t": "10:00:10", "e": epoch + 10])
try write(first + second + stop + String(later.prefix(16)), source)
try service.catchUpNow()
let offset = try index.cursor(sourcePath: source)!.byteOffset
try require(offset == Data((first + second + stop).utf8).count, "partial line after a closed span must remain unread")
try write(first + second + stop + later, source)
try service.catchUpNow()
try require(try index.search("tailword", limit: 10).count == 1, "completed tail must become searchable")
let liveBefore = try index.item(id: CapturedItemID.activity(day: day, time: "10-00-10"))
try ingest.ingestWatcherLine([:], at: Date(timeIntervalSince1970: Double(epoch)))
try ingest.ingestWatcherLine([:], at: Date(timeIntervalSince1970: Double(epoch)))
try require(try index.item(id: liveBefore!.id) == liveBefore, "duplicate live notifications must not increment counts")
try write(second, source)
try service.catchUpNow()
try require(try index.search("beforeword", limit: 10).isEmpty, "truncation must remove stale activity and FTS text")
try require(try index.search("tailword", limit: 10).isEmpty, "rewrite must remove vanished spans")

// All bundle rows and its cursor are one transaction; paths cannot escape.
let bundle = "2026-09-22_10-00-00"
let meta = "captures/\(bundle)/meta.json"
try write("""
{"startedAt":"2026-09-22T10:00:00Z","durationSeconds":1,"transcript":"bundleword","frames":[{"file":"frames/frame-01.jpg","elapsed":0},{"file":"../../outside.jpg","elapsed":1}]}
""", meta)
try rejected("bundle escape must fail") { _ = try ingest.run(.init(source: "bundle", key: bundle)) }
try require(try index.item(id: CapturedItemID.capture(bundle: bundle)) == nil, "bad frame rolls back whole bundle")
try require(try index.cursor(sourcePath: meta) == nil, "bad bundle cannot advance cursor")
try require(try index.search("bundleword", limit: 10).isEmpty, "bundle rollback includes FTS")
try files.removeItem(at: root.appendingPathComponent("captures/\(bundle)"))

// Privacy on a span must survive joining a later shot, not just watcher frames.
let hidden = try line(["app":"Browser","title":"secret","private":true,"t":"10:00:00","e":epoch])
let hiddenEnd = try line(["app":"Browser","title":"secret","private":true,"t":"10:00:05","e":epoch + 5])
try write(hidden + hiddenEnd, source)
try write("picture", "captures/shots/shot-\(day)_10-00-03-000.jpg")
try service.catchUpNow()
let shot = try index.item(id: CapturedItemID.shot(name: "\(day)_10-00-03-000"))
try require(shot?.ocrState == .skippedPrivate && shot?.title == nil, "joined private shot cannot enter OCR")

// An old archive month's edit cannot resurrect a newer month's tombstone.
let old = HistoryEntry(text: "original", time: "12:00", timestamp: "2026-08-01T12:00:00Z", id: "old")
let encoded = try JSONEncoder().encode(old)
try write(encoded + Data("\n".utf8), "dictations/2026-08.jsonl")
try write("{\"id\":\"old\",\"deleted\":true}\n", "dictations/2026-09.jsonl")
try service.catchUpNow()
try require(try index.item(id: "dictation:old") == nil, "tombstone applies on rebuild")
try write(encoded + Data("\n".utf8) + encoded + Data("\n".utf8), "dictations/2026-08.jsonl")
try service.catchUpNow()
try require(try index.item(id: "dictation:old") == nil, "old month retry cannot resurrect deletion")
try require(DictationArchive.load(root: root).isEmpty, "archive reader agrees with derived index")

// Failed imports remain retryable and cannot claim a count for unwritten bytes.
let importRoot = root.appendingPathComponent("import")
try files.createDirectory(at: importRoot, withIntermediateDirectories: true)
let backup = root.appendingPathComponent("backup.json")
try JSONEncoder().encode([old]).write(to: backup)
let blockedMonth = DictationArchive.url(root: importRoot, month: "2026-08")
try files.createDirectory(at: blockedMonth, withIntermediateDirectories: true)
let failed = DictationArchive.importOnce(from: [backup], root: importRoot)
try require(failed.added == 0 && !failed.failures.isEmpty, "failed append must not count or mark import")
try files.removeItem(at: blockedMonth)
let retried = DictationArchive.importOnce(from: [backup], root: importRoot)
try require(retried.added == 1, "failed import can be retried")
let size = try Data(contentsOf: blockedMonth).count
try require(DictationArchive.importOnce(from: [backup], root: importRoot).added == 0, "import replay deduplicates")
try require(try Data(contentsOf: blockedMonth).count == size, "dedup does not append unchanged bytes")
var continued = old
continued.timestamp = "2026-09-22T12:00:00Z"
continued.text = "continued"
try DictationArchive.append([continued], root: importRoot)
try require(DictationArchive.load(root: importRoot).first?.text == "continued", "cross-month continuation wins")
try DictationArchive.appendDeletion(id: "old", at: Date(), root: importRoot)
try require(DictationArchive.load(root: importRoot).isEmpty, "cross-month removal remains removed")

// Legacy identity uses the actual date when present, not just a clock string.
let sameClockA = HistoryEntry(text: "daily phrase", time: "12:00", timestamp: "2026-07-01T12:00:00Z")
let sameClockB = HistoryEntry(text: "daily phrase", time: "12:00", timestamp: "2026-07-02T12:00:00Z")
try require(sameClockA.archiveIdentity != sameClockB.archiveIdentity, "same clock and words on distinct dates must retain both identities")
try DictationArchive.append([sameClockA, sameClockB], root: importRoot)
try require(DictationArchive.load(root: importRoot).filter { $0.text == "daily phrase" }.count == 2, "distinct dated legacy entries must both survive archive fold")
let lateBackup = root.appendingPathComponent("late-backup.json")
try JSONEncoder().encode([old]).write(to: lateBackup)
let lateImport = DictationArchive.importOnce(from: [lateBackup], root: importRoot)
try require(lateImport.added == 0, "discovering a new backup must not resurrect a deleted ID")
try require(!DictationArchive.load(root: importRoot).contains { $0.id == "old" }, "tombstone survives late backup import")

var idlessDeletedCopy = old
idlessDeletedCopy.id = nil
let idlessBackup = root.appendingPathComponent("late-idless-backup.json")
try JSONEncoder().encode([idlessDeletedCopy]).write(to: idlessBackup)
try require(DictationArchive.importOnce(from: [idlessBackup], root: importRoot).added == 0, "an id-less snapshot of deleted speech must also remain deleted")

// Real backup names and SourceCollector snapshot envelopes, not invented arrays.
let legacyRoot = root.appendingPathComponent("legacy-fixture")
try files.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
let namedBackup = legacyRoot.appendingPathComponent("dictations.json.backup-2026-07-23T1045")
try JSONEncoder().encode([old]).write(to: namedBackup)
let snapshotDir = legacyRoot.appendingPathComponent("source-snapshots/builtin-dictations/copy")
try files.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
try Data("snapshot words beyond preview".utf8).write(to: snapshotDir.appendingPathComponent("item-1.txt"))
try Data("original".utf8).write(to: snapshotDir.appendingPathComponent("item-2.txt"))
let manifest = """
{"sourceID":"builtin-dictations","items":[{"title":"Dictation · 2026-07-22T12:00:00Z","relativePath":"item-1.txt","preview":"snapshot"},{"title":"Dictation · 2026-08-01T12:00:00Z","relativePath":"item-2.txt","preview":"original"}]}
"""
try Data(manifest.utf8).write(to: snapshotDir.appendingPathComponent("snapshot.json"))
let recovery = LegacyDictationRecovery.run(root: legacyRoot)
try require(recovery.added == 2 && recovery.failures.isEmpty, "real named backup and snapshot copies are recovered once and deduplicated")
try require(DictationArchive.load(root: legacyRoot).contains { $0.text == "snapshot words beyond preview" }, "snapshot recovery uses full text, never truncated preview")
try require(LegacyDictationRecovery.run(root: legacyRoot).added == 0, "legacy recovery is idempotent")
let recentOnly = HistoryEntry(text: "recent only words", time: "12:00", timestamp: "2026-09-22T12:00:00Z", id: "recent-only")
try JSONEncoder().encode([recentOnly]).write(to: root.appendingPathComponent("dictations.json"))
try service.catchUpNow()
try require(try index.item(id: "dictation:recent-only")?.body == recentOnly.text, "initial existing dictations.json is searchable before archive has been created")

// Indexing and a full rebuild leave every source byte intact, not merely size.
func sourceHashes() throws -> [String: String] {
    let walk = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
    var result: [String: String] = [:]
    while let url = walk.nextObject() as? URL {
        let relative = IngestFile.relativePath(url, root: root)
        if relative.hasPrefix("index/") { continue }
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[relative] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format:"%02x", $0) }.joined()
        }
    }
    return result
}
let before = try sourceHashes()
func rows() throws -> [String] {
    try index.read { db in try String.fetchAll(db, sql: "SELECT id || '|' || kind || '|' || t_start || '|' || t_end || '|' || image_state FROM item ORDER BY id") }
}
let snapshot = try rows()
try index.pool.write { db in
    try CapturedSchema.dropAll(db)
    try CapturedSchema.apply(to: db)
}
try service.catchUpNow()
try require(try rows() == snapshot, "rebuild recovers same ids, kinds, times and picture states")
try require(try sourceHashes() == before, "index rebuild cannot mutate source bytes")

// Observe committed SQLite rows while the real native writer runs after the
// initial catch-up. No direct catchUp call or test-only lifecycle hook is used.
let livePaths = VoiceFlowPaths(environment: [
    VoiceFlowPaths.configRootEnvironmentKey: root.appendingPathComponent("native-live").path,
])
let liveService = try CapturedService(root: livePaths.configRoot)
func expectIndexedRecording(_ runID: UUID, action: () throws -> Void) throws {
    let changed = DispatchSemaphore(value: 0)
    let observation = ValueObservation.tracking { db in
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM item WHERE id = ?)",
                          arguments: [CapturedItemID.recording(runID.uuidString)]) ?? false
    }.start(in: liveService.index.pool,
            scheduling: .async(onQueue: DispatchQueue(label: "captured.integrity.observe")),
            onError: { _ in changed.signal() },
            onChange: { found in if found { changed.signal() } })
    defer { observation.cancel() }
    try action()
    try require(changed.wait(timeout: .now() + 15) == .success,
                "native recording commit must reach the running index")
    try require(try liveService.index.item(id: CapturedItemID.recording(runID.uuidString)) != nil,
                "native recording must be durably queryable")
}
let existingRun = UUID()
let pcm = Data(repeating: 0, count: 320)
try require(PendingAudioStore.save(pcm: pcm, runId: existingRun, sampleRate: 16000, root: livePaths) != nil,
            "seed WAV must be written")
try expectIndexedRecording(existingRun) { liveService.start() }
let newRun = UUID()
try expectIndexedRecording(newRun) {
    try require(PendingAudioStore.save(pcm: pcm, runId: newRun, sampleRate: 16000, root: livePaths) != nil,
                "new WAV must be written after startup catch-up")
}
try require(try index.item(id: CapturedItemID.recording(newRun.uuidString)) == nil,
            "a different root's recording cannot leak into this index")
print("captured integrity: passed rollback, cursor tail/rewrite, duplicate live replay, path boundary, privacy join, tombstones, failed-import retry, source SHA256 and rebuild checks")
print("captured native lifecycle: startup catch-up and subsequent WAV commit observed through GRDB")
