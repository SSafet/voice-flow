import AppKit
import Foundation
import GRDB

// The ingesters (07 §3.4): every captured stream reaches the one index,
// reading the files where they already are.
//
// Each reader runs in two modes — catch-up, which reads what it has not read
// yet, newest day first, tracked by byte offset; and live, which is called by
// the recorder the moment it writes. Both write through one upsert, and the
// ids are derived from where the thing lives, so reading the same bytes twice
// can only ever produce the same rows.

func vflog(_ message: String) {}

/// The watcher bus reads the retention setting; nothing here depends on it.
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
    .appendingPathComponent("ingest-data", isDirectory: true)
try? files.removeItem(at: root)
try files.createDirectory(at: root, withIntermediateDirectories: true)

private func folder(_ relative: String) -> URL {
    let url = root.appendingPathComponent(relative, isDirectory: true)
    try? files.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func write(_ text: String, to relative: String) {
    let url = root.appendingPathComponent(relative)
    try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

/// Day folders and file names are in the Mac's local time at capture, and the
/// `e` field is the true moment. The fixture computes both from the same
/// components so the data is self-consistent in whatever time zone this runs.
private let calendar = Calendar(identifier: .gregorian)
private func epoch(_ day: String, _ hms: String) -> Int {
    let d = day.split(separator: "-").map { Int($0)! }
    let t = hms.split(separator: "-").map { Int($0)! }
    let components = DateComponents(year: d[0], month: d[1], day: d[2],
                                    hour: t[0], minute: t[1], second: t[2])
    return Int(calendar.date(from: components)!.timeIntervalSince1970)
}

/// One activity line, as the watcher writes it, plus the bytes it occupies.
@discardableResult
private func appendLine(_ fields: [String: Any], day: String, hms: String) -> Int {
    var line = fields
    line["t"] = hms.replacingOccurrences(of: "-", with: ":")
    line["e"] = epoch(day, hms)
    let url = folder("watcher/\(day)").appendingPathComponent("activity.jsonl")
    let json = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    let bytes = json + Data("\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: bytes)
    } else {
        try! bytes.write(to: url)
    }
    return bytes.count
}

private func picture(_ relative: String) {
    let url = root.appendingPathComponent(relative)
    try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x01]).write(to: url)
}

// ── a day of watcher lines ────────────────────────────────────────────────

let day = "2026-08-18"
var offsetOfThirdSpan = 0
offsetOfThirdSpan += appendLine([
    "app": "Google Chrome", "bundle": "com.google.Chrome", "title": "Disney+ · Watch",
    "url": "https://disneyplus.com/browse?profile=1", "display": 1,
    "geom": ["w": 1568, "h": 1014], "frame": "frame-00-00-01.jpg",
    "input": ["key": 12, "scroll": 3],
], day: day, hms: "00-00-01")
offsetOfThirdSpan += appendLine([
    "app": "Google Chrome", "bundle": "com.google.Chrome", "title": "Disney+ · Watch",
    "url": "https://disneyplus.com/browse?profile=1", "display": 1,
    "geom": ["w": 1568, "h": 1014], "frame": "frame-00-00-06.jpg",
    "input": ["key": 8],
], day: day, hms: "00-00-06")
offsetOfThirdSpan += appendLine([
    "app": "Ghostty", "bundle": "com.mitchellh.ghostty", "title": "~/repos/pantria",
    "display": 1, "geom": ["w": 1568, "h": 1014],
], day: day, hms: "00-00-11")
offsetOfThirdSpan += appendLine(["kind": "pause", "reason": "idle"], day: day, hms: "00-00-16")
offsetOfThirdSpan += appendLine(["kind": "resume", "after": "idle", "seconds": 299],
                                day: day, hms: "00-05-15")
appendLine([
    "app": "Google Chrome", "bundle": "com.google.Chrome", "title": "Disney+ · Watch",
    "url": "https://disneyplus.com/browse?profile=1", "display": 1,
    "geom": ["w": 1568, "h": 1014], "frame": "frame-00-05-20.jpg",
], day: day, hms: "00-05-20")

// 29,105 lines name a picture and 28,646 picture files are on disk: a line
// whose picture is not there is an item with its text, marked missing.
picture("watcher/\(day)/frame-00-00-01.jpg")
picture("watcher/\(day)/frame-00-05-20.jpg")

// A second day, to prove the gap and the day boundary both end a span.
let earlier = "2026-08-17"
appendLine(["app": "Safari", "bundle": "com.apple.Safari", "title": "fly.io · Pricing",
            "url": "https://fly.io/docs/about/pricing/", "display": 1],
           day: earlier, hms: "09-00-00")
appendLine(["app": "Safari", "bundle": "com.apple.Safari", "title": "fly.io · Pricing",
            "url": "https://fly.io/docs/about/pricing/", "display": 1],
           day: earlier, hms: "09-02-10")
let earliest = "2026-08-16"
appendLine(["app": "Preview", "bundle": "com.apple.Preview", "title": "invoice.pdf", "display": 1],
           day: earliest, hms: "12-00-00")

// A private window, and a legacy line that carries a title it should not keep.
appendLine(["app": "Google Chrome", "bundle": "com.google.Chrome", "private": true,
            "display": 1, "geom": ["w": 1568, "h": 1014], "frame": "frame-13-00-00.jpg"],
           day: earliest, hms: "13-00-00")
appendLine(["app": "1Password", "title": "All Items · Personal", "display": 1,
            "geom": ["w": 1568, "h": 1014], "frame": "frame-14-00-00.jpg"],
           day: earliest, hms: "14-00-00")
picture("watcher/\(earliest)/frame-13-00-00.jpg")
picture("watcher/\(earliest)/frame-14-00-00.jpg")

// ── the other streams ─────────────────────────────────────────────────────

let bundleID = "2026-08-05_01-37-43"
write("""
{"id":"\(bundleID)","startedAt":"2026-08-05T01:37:43Z","endedAt":"2026-08-05T01:37:47Z",
 "durationSeconds":4,"transcript":"ordered narration about the cart",
 "frames":[{"file":"frames/frame-01-t000s.jpg","elapsed":0},
           {"file":"frames/frame-02-t004s.jpg","elapsed":4}]}
""", to: "captures/\(bundleID)/meta.json")
picture("captures/\(bundleID)/frames/frame-01-t000s.jpg")
picture("captures/\(bundleID)/frames/frame-02-t004s.jpg")

picture("captures/shots/shot-\(day)_00-00-03-000.jpg")
picture("captures/shots/shot-\(day)_00-00-03-000.clean.jpg")
picture("captures/shots/pasted-2026-07-04_10-00-00-000.jpg")

write("Three tabs of fly.io and one long Ghostty stretch.\n",
      to: "watcher/reviews/2026-08-04.md")
write("- 2026-08-04 observed: the deploy loop.\n", to: "watcher/ledger.md")

let recordingID = "9C2B0102-0304-0506-0708-090A0B0C0D0E"
write("RIFFfake", to: "pending-audio/\(recordingID).wav")

let dictations = DictationStore(root: root)
dictations.save([
    HistoryEntry(text: "ask Georgi about the VAT threshold", time: "07:12",
                 timestamp: "2026-09-14T07:12:00Z", id: "rec-phone", destination: .kept,
                 seen: nil, capability: .dictate, attachments: nil, captureId: nil,
                 originDevice: "dev-phone"),
    HistoryEntry(text: "pantrella deploy notes", time: "08:00",
                 timestamp: "2026-09-14T08:00:00Z", id: "rec-mac", destination: .kept,
                 seen: nil, capability: .dictate, attachments: nil, captureId: nil,
                 originDevice: nil),
])

// ── what the folder looked like before anything read it ───────────────────

private func listing(of relative: String) -> [String] {
    let base = root.appendingPathComponent(relative, isDirectory: true)
    let enumerator = files.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey])
    var lines: [String] = []
    while let url = enumerator?.nextObject() as? URL {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        lines.append("\(url.path.dropFirst(base.path.count)) \(size)")
    }
    return lines.sorted()
}
let watcherBefore = listing(of: "watcher")
let capturesBefore = listing(of: "captures")

// ── catch-up, newest day first ────────────────────────────────────────────

let pool = try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root))
let index = CapturedIndex(pool: pool)
let ingest = CapturedIngest(index: index, root: root)

let plan = try ingest.plan()
let watcherDays = plan.filter { $0.source == "watcher" }.map(\.key)
expect(watcherDays == [day, earlier, earliest],
       "the watcher days are not planned newest first: \(watcherDays)")
expect(Set(plan.map(\.source)) == ["watcher", "bundle", "shot", "dictation", "review", "recording"],
       "catch-up does not plan all six readers: \(Set(plan.map(\.source)).sorted())")
expect(ingest.progress.daysTotal == 3, "the progress does not count the three day folders")

// Search works for the days already done: one step, and the newest day is in.
_ = try ingest.catchUpStep()
expect(try index.search("Disney", limit: 5).isEmpty == false,
       "after the first step the newest day is not searchable")
expect(try index.search("invoice", limit: 5).isEmpty,
       "a day that has not been read yet is already searchable")
expect(ingest.progress.daysDone == 1, "the progress did not count the finished day")
expect(ingest.progress.state == .building, "the index calls itself ready before it is")

while try ingest.catchUpStep() {}
expect(ingest.progress.state == .ready, "the index never becomes ready")
expect(ingest.progress.daysDone == 3, "the progress did not finish the days")

// ── nothing was moved, renamed or rewritten ───────────────────────────────

expect(listing(of: "watcher") == watcherBefore, "indexing changed the watcher folder")
expect(listing(of: "captures") == capturesBefore, "indexing changed the captures folder")

// ── spans ─────────────────────────────────────────────────────────────────

let firstSpan = CapturedItemID.activity(day: day, time: "00-00-01")
let secondSpan = CapturedItemID.activity(day: day, time: "00-00-11")
let thirdSpan = CapturedItemID.activity(day: day, time: "00-05-20")

guard let span = try index.item(id: firstSpan) else {
    failures.append("the first activity span was not indexed")
    finish("captured ingest")
}
expect(span.kind == .activity && span.source == .watcher, "a span is not an activity item of the watcher")
expect(span.app == "Google Chrome", "the span lost the application")
expect(span.title == "Disney+ · Watch", "the span lost the window title")
expect(span.url == "disneyplus.com/browse", "the span kept the query string")
expect(span.tStart == epoch(day, "00-00-01"), "the span does not start at its first line")
expect(span.tEnd == epoch(day, "00-00-06"), "the span does not end at its last line")
expect(span.imageState == .none && span.ocrState == .na, "a span was given a picture")
let spanExtra = (try? JSONSerialization.jsonObject(with: Data((span.extraJSON ?? "{}").utf8)))
    as? [String: Any] ?? [:]
expect((spanExtra["input"] as? [String: Int])?["key"] == 20,
       "the span did not sum the input counts of its lines: \(spanExtra)")
expect(spanExtra["lines"] as? Int == 2, "the span did not count its lines")

expect(try index.item(id: secondSpan)?.app == "Ghostty", "the span did not break on a new application")
let ghostty = try index.item(id: secondSpan)
let ghosttyExtra = (try? JSONSerialization.jsonObject(with: Data((ghostty?.extraJSON ?? "{}").utf8)))
    as? [String: Any] ?? [:]
let pauses = ghosttyExtra["pauses"] as? [[String: Any]] ?? []
expect(pauses.first?["reason"] as? String == "idle",
       "the pause that interrupted the span was not recorded on it: \(ghosttyExtra)")
expect(pauses.first?["seconds"] as? Int == 299, "the pause's length was not recorded")

expect(try index.item(id: thirdSpan)?.app == "Google Chrome",
       "the same application after a pause did not start a new span")

// The same window, more than two minutes later, is a new span: the watcher
// ticks every five seconds, so a gap means it was not recording.
expect(try index.item(id: CapturedItemID.activity(day: earlier, time: "09-00-00")) != nil,
       "the earlier day's first span is missing")
expect(try index.item(id: CapturedItemID.activity(day: earlier, time: "09-02-10")) != nil,
       "a gap of more than two minutes did not end the span")

// ── frames ────────────────────────────────────────────────────────────────

guard let firstFrame = try index.item(id: CapturedItemID.frame(day: day, time: "00-00-01")) else {
    failures.append("a watcher frame was not indexed")
    finish("captured ingest")
}
expect(firstFrame.kind == .frame && firstFrame.source == .watcher, "a watcher frame has the wrong kind")
expect(firstFrame.parentID == firstSpan, "a frame does not belong to its span")
expect(firstFrame.path == "watcher/\(day)/frame-00-00-01.jpg",
       "a frame's path is not relative to the data folder: \(firstFrame.path ?? "nothing")")
expect(firstFrame.imageState == .present, "a frame whose picture is on disk is not present")
expect(firstFrame.ocrState == .pending, "a frame's picture was not queued for text recognition")
expect(firstFrame.imgW == 1568 && firstFrame.imgH == 1014, "a frame lost the size it was stored at")

expect(try index.item(id: CapturedItemID.frame(day: day, time: "00-00-06"))?.imageState == .missing,
       "a line naming a picture that is not on disk was not marked missing")
expect(try index.item(id: CapturedItemID.frame(day: day, time: "00-00-06"))?.app == "Google Chrome",
       "a missing picture lost its context, which is still known")

// ── private lines keep nothing they should not ────────────────────────────

let privateFrame = try index.item(id: CapturedItemID.frame(day: earliest, time: "13-00-00"))
expect(privateFrame?.ocrState == .skippedPrivate,
       "a picture taken while a private window was in front was queued for text recognition")
expect(privateFrame?.title == nil && privateFrame?.url == nil,
       "a private frame carries a title or an address")
let managerFrame = try index.item(id: CapturedItemID.frame(day: earliest, time: "14-00-00"))
expect(managerFrame?.ocrState == .skippedPrivate,
       "a picture of a password manager was queued for text recognition")
expect(managerFrame?.title == nil,
       "a legacy line naming a password manager kept the window title it was written with")

// ── the cursor stops at the open span, and never mid-line ─────────────────

let activityPath = "watcher/\(day)/activity.jsonl"
expect(try index.cursor(sourcePath: activityPath)?.byteOffset == offsetOfThirdSpan,
       "the cursor is not at the start of the span that is still open: "
       + "\(String(describing: try? index.cursor(sourcePath: activityPath)?.byteOffset)) "
       + "instead of \(offsetOfThirdSpan)")

let partial = "{\"app\":\"Ghostty\",\"bundle\":\"com.mitchellh.ghostty\""
let activityURL = root.appendingPathComponent(activityPath)
let handle = try FileHandle(forWritingTo: activityURL)
_ = try handle.seekToEnd()
try handle.write(contentsOf: Data(partial.utf8))
try handle.close()

let itemsBeforePartial = try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM item") ?? -1 }
while try ingest.catchUpStep() {}
let itemsAfterPartial = try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM item") ?? -1 }
expect(itemsAfterPartial == itemsBeforePartial,
       "a half-written line was read: \(itemsBeforePartial) items became \(itemsAfterPartial)")

// Finishing the line makes it a span, and the span that was open is extended
// in place rather than duplicated.
let rest = ",\"title\":\"~/repos/atika\",\"display\":1,\"t\":\"00:05:25\",\"e\":\(epoch(day, "00-05-25"))}\n"
let handle2 = try FileHandle(forWritingTo: activityURL)
_ = try handle2.seekToEnd()
try handle2.write(contentsOf: Data(rest.utf8))
try handle2.close()
while try ingest.catchUpStep() {}
expect(try index.item(id: CapturedItemID.activity(day: day, time: "00-05-25")) != nil,
       "the completed line was still not read")
expect(try index.item(id: thirdSpan)?.tEnd == epoch(day, "00-05-20"),
       "the span that was open was not closed at its own last line")
let spansOnDay = try pool.read { db in
    try Int.fetchOne(db, sql: "SELECT count(*) FROM item WHERE kind = 'activity' AND id LIKE ?",
                     arguments: ["activity:\(day)%"]) ?? -1
}
expect(spansOnDay == 4, "the day holds \(spansOnDay) spans, not the 4 its lines describe")

// ── reading the same bytes again changes nothing ──────────────────────────

let before = try index.countsByKindAndImageState()
while try ingest.catchUpStep() {}
let againPlan = try ingest.plan()
expect(againPlan.isEmpty, "catch-up wants to read files it has already read: \(againPlan)")
expect(try index.countsByKindAndImageState() == before,
       "reading the same folder twice changed the index")

// ── bundles, shots, reviews, recordings, dictations ───────────────────────

guard let bundle = try index.item(id: CapturedItemID.capture(bundle: bundleID)) else {
    failures.append("the capture bundle was not indexed")
    finish("captured ingest")
}
expect(bundle.kind == .capture && bundle.source == .bundle, "a bundle has the wrong kind")
expect(bundle.body == "ordered narration about the cart", "the bundle lost its narration")
expect(bundle.imageState == .none, "the bundle itself was given a picture; its frames carry them")
let bundleExtra = (try? JSONSerialization.jsonObject(with: Data((bundle.extraJSON ?? "{}").utf8)))
    as? [String: Any] ?? [:]
expect(bundleExtra["frameCount"] as? Int == 2, "the bundle did not count its frames")
expect((bundleExtra["durationSeconds"] as? Double) == 4
        || (bundleExtra["durationSeconds"] as? Int) == 4, "the bundle lost its length")

let bundleFrame = try index.item(id: CapturedItemID.bundleFrame(bundle: bundleID, index: 2))
expect(bundleFrame?.kind == .frame && bundleFrame?.source == .bundle,
       "a bundle frame is not a frame of the bundle reader")
expect(bundleFrame?.parentID == CapturedItemID.capture(bundle: bundleID),
       "a bundle frame does not belong to its bundle")
expect(bundleFrame?.path == "captures/\(bundleID)/frames/frame-02-t004s.jpg",
       "a bundle frame points at the wrong file")

let shotID = CapturedItemID.shot(name: "\(day)_00-00-03-000")
guard let shot = try index.item(id: shotID) else {
    failures.append("the shot was not indexed")
    finish("captured ingest")
}
expect(shot.kind == .shot && shot.source == .shot, "a shot has the wrong kind")
expect(shot.path == "captures/shots/shot-\(day)_00-00-03-000.jpg", "the shot points at the wrong file")
expect(shot.pathClean == "captures/shots/shot-\(day)_00-00-03-000.clean.jpg",
       "the unmarked picture was not attached to the shot")
expect(try index.item(id: CapturedItemID.shot(name: "\(day)_00-00-03-000.clean")) == nil,
       "the unmarked picture became an item of its own")
// A shot taken while the watcher was running falls inside a known span.
expect(shot.app == "Google Chrome", "the shot did not take the context of the span covering it")
expect(shot.url == "disneyplus.com/browse", "the shot did not take the span's address")
let shotExtra = (try? JSONSerialization.jsonObject(with: Data((shot.extraJSON ?? "{}").utf8)))
    as? [String: Any] ?? [:]
expect(shotExtra["contextSource"] as? String == "watcher_join",
       "the shot does not say where its context came from: \(shotExtra)")

let pasted = try index.item(id: CapturedItemID.shot(name: "2026-07-04_10-00-00-000"))
expect(pasted?.source == .paste, "a pasted picture was not marked as pasted")
expect(pasted?.app == nil, "a picture from a day with no watcher data was given a context")

expect(try index.item(id: CapturedItemID.review(day: "2026-08-04"))?.body
        == "Three tabs of fly.io and one long Ghostty stretch.\n", "the review lost its text")
expect(try index.item(id: CapturedItemID.ledger)?.kind == .review, "the ledger was not indexed")

guard let recording = try index.item(id: CapturedItemID.recording(recordingID)) else {
    failures.append("the undelivered recording was not indexed")
    finish("captured ingest")
}
expect(recording.kind == .recording && recording.imageState == .none, "a recording has the wrong kind")
let recordingExtra = (try? JSONSerialization.jsonObject(with: Data((recording.extraJSON ?? "{}").utf8)))
    as? [String: Any] ?? [:]
expect(recordingExtra["state"] as? String == "undelivered",
       "the recording is not marked undelivered: \(recordingExtra)")

expect(try index.item(id: CapturedItemID.dictation("rec-phone"))?.originDevice == "dev-phone",
       "a dictation made on the phone is not marked as made there")
expect(try index.item(id: CapturedItemID.dictation("rec-mac"))?.originDevice == nil,
       "a dictation made on this Mac was marked as made elsewhere")
expect(try index.item(id: CapturedItemID.dictation("rec-phone"))?.body
        == "ask Georgi about the VAT threshold", "the dictation lost its words")
expect(try index.search("Georgi", limit: 5) == [CapturedItemID.dictation("rec-phone")],
       "a phone dictation is not found by the same search as everything else")

// ── live: the recorder tells the index the moment it writes ───────────────

let liveTime = epoch(day, "00-05-30")
let liveFields: [String: Any] = [
    "app": "Google Chrome", "bundle": "com.google.Chrome", "title": "Atika · Threads",
    "url": "https://atika.ai/t/abc?x=1", "display": 1, "t": "00:05:30", "e": liveTime,
 ]
let liveSource = root.appendingPathComponent("watcher/\(day)/activity.jsonl")
let liveHandle = try FileHandle(forWritingTo: liveSource)
try liveHandle.seekToEnd()
try liveHandle.write(contentsOf: try JSONSerialization.data(withJSONObject: liveFields) + Data("\n".utf8))
try liveHandle.close()
try ingest.ingestWatcherLine(liveFields, at: Date(timeIntervalSince1970: TimeInterval(liveTime)))
let live = try index.item(id: CapturedItemID.activity(day: day, time: "00-05-30"))
expect(live?.title == "Atika · Threads", "a line handed to the index live did not become a span")
expect(live?.url == "atika.ai/t/abc", "a live line kept the query string")

// The bus fans out to every listener: the index and the triggers both hear
// every line, and a second listener cannot unsubscribe the first.
let bus = DayBus()
var heard = 0
var alsoHeard = 0
bus.addAppendObserver { _, _, _ in heard += 1 }
bus.addAppendObserver { _, _, _ in alsoHeard += 1 }
bus.append(["app": "QA"], to: "activity", at: Date())
expect(heard == 1 && alsoHeard == 1,
       "the watcher bus still holds one listener: \(heard) and \(alsoHeard)")

finish("captured ingest")

final class PendingInteraction { var sessionId: String? }
struct CaptureSummary {}
