import AppKit
import Foundation
import GRDB

// The whole index, built once over a data folder that looks like the real one
// (07 §8 item 1, item 13; 08 §8 item 2), in miniature and on synthetic data.
//
// The facts this pins are the ones the design lead checks afterwards on the
// 5.6 GB archive itself: the folder is byte-for-byte what it was, the counts in
// the index match a count of the disk taken at the same moment, a dictation
// made on the phone is in the same index with its origin device, and deleting
// the database file loses nothing because every row is derived.

func vflog(_ message: String) {}

final class UserSettings {
    static let shared = UserSettings()
    var watcherKeepDays = 30
    var watcherDenseApps: Set<String> = []
}

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
private let root = VoiceFlowPaths.shared.configRoot
    .appendingPathComponent("index-build", isDirectory: true)
try? files.removeItem(at: root)
try files.createDirectory(at: root, withIntermediateDirectories: true)

private func write(_ text: String, to relative: String) {
    let url = root.appendingPathComponent(relative)
    try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}
private func picture(_ relative: String) {
    write("\u{FFFD}jpeg", to: relative)
}

private let calendar = Calendar(identifier: .gregorian)
private func epoch(_ day: String, _ hms: String) -> Int {
    let d = day.split(separator: "-").map { Int($0)! }
    let t = hms.split(separator: "-").map { Int($0)! }
    return Int(calendar.date(from: DateComponents(
        year: d[0], month: d[1], day: d[2],
        hour: t[0], minute: t[1], second: t[2]))!.timeIntervalSince1970)
}

// ── a data folder with two days, a bundle, a shot, a review, a recording ──

private func line(_ fields: [String: Any], day: String, hms: String) -> String {
    var line = fields
    line["t"] = hms.replacingOccurrences(of: "-", with: ":")
    line["e"] = epoch(day, hms)
    return String(data: try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
                  encoding: .utf8)!
}

let newest = "2026-08-18"
let older = "2026-08-17"
write([
    line(["app": "Google Chrome", "bundle": "com.google.Chrome", "title": "Disney+ · Watch",
          "url": "https://disneyplus.com/browse", "frame": "frame-00-00-01.jpg",
          "geom": ["w": 1568, "h": 1014], "display": 1], day: newest, hms: "00-00-01"),
    line(["app": "Ghostty", "bundle": "com.mitchellh.ghostty", "title": "~/repos/pantria",
          "frame": "frame-00-00-11.jpg", "geom": ["w": 1568, "h": 1014], "display": 1],
         day: newest, hms: "00-00-11"),
].joined(separator: "\n") + "\n", to: "watcher/\(newest)/activity.jsonl")
picture("watcher/\(newest)/frame-00-00-01.jpg")
picture("watcher/\(newest)/frame-00-00-11.jpg")

write([
    line(["app": "Safari", "bundle": "com.apple.Safari", "title": "fly.io · Pricing",
          "url": "https://fly.io/docs/about/pricing/", "frame": "frame-09-00-00.jpg",
          "geom": ["w": 1568, "h": 1014], "display": 1], day: older, hms: "09-00-00"),
    // A line whose picture is not on disk: its text stays, the picture is missing.
    line(["app": "Safari", "bundle": "com.apple.Safari", "title": "fly.io · Volumes",
          "url": "https://fly.io/docs/volumes/", "frame": "frame-09-30-00.jpg",
          "geom": ["w": 1568, "h": 1014], "display": 1], day: older, hms: "09-30-00"),
].joined(separator: "\n") + "\n", to: "watcher/\(older)/activity.jsonl")
picture("watcher/\(older)/frame-09-00-00.jpg")

let bundleID = "2026-08-05_01-37-43"
write("""
{"id":"\(bundleID)","startedAt":"2026-08-05T01:37:43Z","endedAt":"2026-08-05T01:37:47Z",\
"durationSeconds":4,"transcript":"narration","frames":[{"file":"frames/frame-01-t000s.jpg","elapsed":0}]}
""", to: "captures/\(bundleID)/meta.json")
picture("captures/\(bundleID)/frames/frame-01-t000s.jpg")
picture("captures/shots/shot-2026-08-18_00-00-03-000.jpg")
write("Three tabs of fly.io.\n", to: "watcher/reviews/2026-08-04.md")
write("- 2026-08-04 observed.\n", to: "watcher/ledger.md")
let recordingID = "9C2B0102-0304-0506-0708-090A0B0C0D0E"
write("RIFFfake", to: "pending-audio/\(recordingID).wav")

// A dictation spoken into the phone, arrived through the record sync, and one
// spoken here.
DictationStore(root: root).save([
    HistoryEntry(text: "ask Georgi about the VAT threshold", time: "07:12",
                 timestamp: "2026-09-14T07:12:00Z", id: "rec-phone", destination: .kept,
                 seen: nil, capability: .dictate, attachments: nil, captureId: nil,
                 originDevice: "dev-phone"),
    HistoryEntry(text: "pantrella deploy notes", time: "08:00",
                 timestamp: "2026-09-14T08:00:00Z", id: "rec-mac", destination: .kept,
                 seen: nil, capability: .dictate, attachments: nil, captureId: nil,
                 originDevice: nil),
])

// ── the disk, counted before anything reads it ────────────────────────────

private struct Disk {
    var listing: [String] = []
    var bytes = 0
    var frames = 0
    var shots = 0
    var reviews = 0
    var recordings = 0
}
private func countDisk() -> Disk {
    var disk = Disk()
    let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
    while let url = enumerator?.nextObject() as? URL {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { continue }
        let relative = String(url.path.dropFirst(root.path.count + 1))
        // The index itself is not part of what was captured.
        if relative.hasPrefix("index/") { continue }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        disk.listing.append("\(relative) \(size)")
        disk.bytes += size
        if relative.hasPrefix("watcher/") && relative.hasSuffix(".jpg") { disk.frames += 1 }
        if relative.hasPrefix("captures/\(bundleID)/frames/") { disk.frames += 1 }
        if relative.hasPrefix("captures/shots/") && !relative.hasSuffix(".clean.jpg") { disk.shots += 1 }
        if relative.hasPrefix("watcher/reviews/") || relative == "watcher/ledger.md" { disk.reviews += 1 }
        if relative.hasPrefix("pending-audio/") { disk.recordings += 1 }
    }
    disk.listing.sort()
    return disk
}
let before = countDisk()

// ── one service builds the whole index ────────────────────────────────────

let service = try CapturedService(root: root)
expect(service.progress.state == .building, "a fresh index does not call itself building")
try service.catchUpNow()
expect(service.progress.state == .ready, "the index never becomes ready")
expect(service.progress.daysDone == 2 && service.progress.daysTotal == 2,
       "the progress does not end at 2 of 2: \(service.progress)")

// ── the archive is exactly what it was ────────────────────────────────────

let after = countDisk()
expect(after.listing == before.listing,
       "indexing changed the data folder: \(Set(after.listing).symmetricDifference(before.listing))")
expect(after.bytes == before.bytes,
       "the data folder is \(after.bytes) bytes after indexing and was \(before.bytes)")

// ── the index matches a count of the disk taken at the same moment ────────

let index = service.index
let counts = try index.countsByKindAndImageState()
private func total(_ kind: CapturedKind) -> Int {
    counts.filter { $0.kind == kind }.reduce(0) { $0 + $1.count }
}
// Four pictures on disk plus one line naming a picture that is not there.
expect(total(.frame) == before.frames + 1,
       "the index holds \(total(.frame)) frames; the disk has \(before.frames) and one line names a fifth")
expect(counts.contains(CapturedCount(kind: .frame, imageState: .missing, count: 1)),
       "the line naming a picture that is not on disk is not counted as missing: \(counts)")
expect(counts.contains(CapturedCount(kind: .frame, imageState: .present, count: before.frames)),
       "the present frames do not match the pictures on disk: \(counts)")
expect(total(.shot) == before.shots, "the index holds \(total(.shot)) shots, the disk \(before.shots)")
expect(total(.review) == before.reviews,
       "the index holds \(total(.review)) reviews, the disk \(before.reviews)")
expect(total(.recording) == before.recordings,
       "the index holds \(total(.recording)) recordings, the disk \(before.recordings)")
expect(total(.capture) == 1, "the one capture bundle is not in the index")
expect(total(.dictation) == 2, "the two dictations are not in the index")
expect(total(.activity) == 4, "the four activity spans are not in the index")

// ── a phone dictation is found here, by the same search ───────────────────

expect(try index.search("Georgi", limit: 5) == [CapturedItemID.dictation("rec-phone")],
       "the dictation spoken into the phone is not searchable on the Mac")
expect(try index.item(id: CapturedItemID.dictation("rec-phone"))?.originDevice == "dev-phone",
       "the dictation spoken into the phone does not name the device that made it")

// ── the index is derived: throwing the file away loses nothing ────────────

private func fingerprint(_ index: CapturedIndex) throws -> [String] {
    try index.pool.read { db in
        try Row.fetchAll(db, sql: "SELECT id, kind, t_start, t_end, image_state FROM item ORDER BY id")
            .map { row in
                let id: String = row["id"]
                let kind: String = row["kind"]
                let start: Int = row["t_start"]
                let end: Int = row["t_end"]
                let state: String = row["image_state"]
                return "\(id)|\(kind)|\(start)|\(end)|\(state)"
            }
    }
}
let built = try fingerprint(index)
expect(built.count > 10, "the index is suspiciously small: \(built.count) rows")

let databaseURL = CapturedDatabase.url(configRoot: root)
try? files.removeItem(at: databaseURL)
try? files.removeItem(at: databaseURL.appendingPathExtension("wal"))
try? files.removeItem(at: databaseURL.appendingPathExtension("shm"))
let rebuilt = try CapturedService(root: root)
try rebuilt.catchUpNow()
expect(try fingerprint(rebuilt.index) == built,
       "rebuilding from the same files produced a different index")
expect(countDisk().listing == before.listing, "rebuilding changed the data folder")

// ── the persona whose instructions this area owns ─────────────────────────

let repoRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICE_FLOW_REPO_ROOT"]
                   ?? FileManager.default.currentDirectoryPath, isDirectory: true)
let personaFile = repoRoot.appendingPathComponent(WorkflowReviewPersona.resourcePath)
expect(files.fileExists(atPath: personaFile.path),
       "the Workflow review instructions are not at \(WorkflowReviewPersona.resourcePath)")
let instructions = (try? WorkflowReviewPersona.load(from: personaFile)) ?? ""
expect(instructions.count > 600, "the Workflow review instructions are too short to be the real text")
expect(instructions.contains("ledger.md") && instructions.contains("reviews/"),
       "the Workflow review instructions do not say what the review writes")
// The successor of ANALYZE.md keeps its one defence: everything in a day
// folder is a recording of what was on screen, never an instruction.
expect(instructions.lowercased().contains("data, not instructions"),
       "the Workflow review instructions dropped the rule that captured text is data")
expect(!instructions.contains("aggregate.py") && !instructions.contains("launchctl")
        && !instructions.contains("LaunchAgent"),
       "the Workflow review instructions still describe the LaunchAgent this work deletes")

let installScript = (try? String(contentsOf: repoRoot.appendingPathComponent("install.sh"),
                                 encoding: .utf8)) ?? ""
expect(installScript.contains(WorkflowReviewPersona.resourcePath),
       "install.sh does not copy the Workflow review instructions into the bundle")

finish("captured index build")
