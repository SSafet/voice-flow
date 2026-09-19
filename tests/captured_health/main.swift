import Foundation
import GRDB

// CapturedHealth (07 §3.13): one status object, read by the Captures area,
// built from the index and the sweeper rather than hard-coded.

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
private var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!

private func makeRoot(_ name: String) -> URL {
    let url = VoiceFlowPaths.shared.configRoot.appendingPathComponent(name, isDirectory: true)
    try? files.removeItem(at: url)
    try! files.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func epoch(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0, _ ss: Int = 0) -> Int {
    Int(utc.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm, second: ss))!
        .timeIntervalSince1970)
}
@discardableResult
private func addItem(_ index: CapturedIndex, id: String, kind: CapturedKind, source: CapturedSource,
                     tStart: Int, bytes: Int = 0, path: String? = nil,
                     imageState: CapturedImageState = .none, ocrState: CapturedOCRState = .na,
                     extraJSON: String? = nil) -> CapturedItemRow {
    let row = CapturedItemRow(id: id, kind: kind, source: source, tStart: tStart, tEnd: tStart,
                              path: path, bytes: bytes, imageState: imageState,
                              ocrState: ocrState, extraJSON: extraJSON)
    try! index.upsert(row)
    return row
}
private struct EmptyLinks: CapturedLinkSource {
    func liveLinks() throws -> [CapturedLinkRef] { [] }
}

let now = Date(timeIntervalSince1970: TimeInterval(epoch(2026, 9, 19, 12, 0, 0)))
let root = makeRoot("health")
let index = CapturedIndex(pool: try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root)))

let presentPath = "watcher/2026-09-18/frame-00-00-01.jpg"
try! files.createDirectory(at: root.appendingPathComponent("watcher/2026-09-18"),
                           withIntermediateDirectories: true)
try! Data("jpg".utf8).write(to: root.appendingPathComponent(presentPath))
addItem(index, id: "frame:present", kind: .frame, source: .watcher,
        tStart: epoch(2026, 9, 18, 0, 0, 1), bytes: 100_000_000,
        path: presentPath, imageState: .present, ocrState: .done)
addItem(index, id: "frame:pending", kind: .frame, source: .watcher,
        tStart: epoch(2026, 9, 18, 0, 0, 6), bytes: 50_000_000,
        path: "watcher/2026-09-18/frame-00-00-06.jpg", imageState: .present, ocrState: .pending)
// A line that names a picture that is not on disk.
addItem(index, id: "frame:gone", kind: .frame, source: .watcher,
        tStart: epoch(2026, 9, 18, 0, 0, 11), path: "watcher/2026-09-18/frame-00-00-11.jpg",
        imageState: .missing)
addItem(index, id: "recording:1", kind: .recording, source: .recording,
        tStart: epoch(2026, 9, 1), extraJSON: "{\"state\":\"undelivered\"}")
addItem(index, id: "recording:2", kind: .recording, source: .recording,
        tStart: epoch(2026, 9, 2),
        extraJSON: "{\"state\":\"no_speech_found\",\"no_speech_at\":\(epoch(2026, 9, 18))}")

let sweeper = RetentionSweeper(index: index, root: root, links: EmptyLinks(),
                               settings: CapturedRetentionSettings(picturesBudgetGB: 25),
                               calendar: utc, now: { now })

let inputs = CapturedHealthInputs(
    deviceID: "device-01",
    watcher: TPHealthWatcher(enabled: false, lastError: nil, lastLineAt: nil, running: false),
    progress: CapturedProgress(state: .building, daysDone: 1, daysTotal: 3),
    indexLastError: nil,
    textRecognitionLanguages: ["en-US", "ru-RU"],
    diskLow: false,
    recordingsLastError: nil,
    review: TPHealthReview(lastReviewDay: "2026-08-04", lastRun: nil),
    recordSync: TPHealthRecordSync(lastError: nil, lastSuccessAt: nil, state: .signedOut))

let health = try CapturedHealthBuilder.health(index: index, sweeper: sweeper, inputs: inputs,
                                              now: now, timeZone: TimeZone(identifier: "UTC")!)

// ── the whole object, with every field the design names ───────────────────

expect(health.deviceID == "device-01", "the health object lost the device id")
expect(health.generatedAt.hasSuffix("Z") && health.generatedAt.contains("T"),
       "generatedAt is not an ISO 8601 UTC time: \(health.generatedAt)")
expect(health.index.state == .building && health.index.daysDone == 1 && health.index.daysTotal == 3,
       "the index state is not the progress it was given: \(health.index)")
expect(health.index.picturesTotal == 2, "picturesTotal is \(health.index.picturesTotal), not 2")
expect(health.index.picturesRecognised == 1,
       "picturesRecognised is \(health.index.picturesRecognised), not 1")
expect(health.textRecognitionLanguages == ["en-US", "ru-RU"],
       "the recognition languages are not the ones passed in")

// ── pictures: the budget, what is used, and what names a missing file ──────

expect(health.pictures.usedBytes == 150_000_000,
       "usedBytes is \(health.pictures.usedBytes), not the 150 MB of present pictures")
expect(health.pictures.budgetBytes == 25_000_000_000,
       "budgetBytes is \(health.pictures.budgetBytes), not 25 GB")
expect(health.pictures.missing == 1,
       "missing is \(health.pictures.missing), not the one line naming an absent file")
expect(health.pictures.diskLow == false, "diskLow is not the value passed in")
expect(health.pictures.pendingPlan == nil && health.pictures.lastCleanup == nil,
       "a fresh index already reports a cleanup")

// ── recordings: what is undelivered and what found no speech ───────────────

expect(health.recordings.undelivered == 1,
       "undelivered is \(health.recordings.undelivered), not 1")
expect(health.recordings.noSpeech == 1,
       "noSpeech is \(health.recordings.noSpeech), not 1")

// ── retention is read from the setting, not written into the builder ───────

expect(health.retention.map(\.stream) == RetentionStream.allCases.map(\.rawValue),
       "the health retention list does not carry every stream")
expect(health.retention.first { $0.stream == RetentionStream.unlinkedPictures.rawValue }?.value == 25,
       "the health retention list does not carry the budget")

// ── a pending plan and a completed cleanup are surfaced ────────────────────

// Blow past the budget so the sweeper raises a bulk review, then confirm it and
// check both the pending plan and the last cleanup come through in health.
addItem(index, id: "frame:b1", kind: .frame, source: .watcher,
        tStart: epoch(2026, 8, 1), bytes: 2_000_000_000,
        path: "watcher/2026-08-01/frame-00-00-01.jpg", imageState: .present)
let bulkRoot = root
try! files.createDirectory(at: bulkRoot.appendingPathComponent("watcher/2026-08-01"),
                           withIntermediateDirectories: true)
try! Data("jpg".utf8).write(to: bulkRoot.appendingPathComponent("watcher/2026-08-01/frame-00-00-01.jpg"))
let bulkSweeper = RetentionSweeper(index: index, root: root, links: EmptyLinks(),
                                   settings: CapturedRetentionSettings(picturesBudgetGB: 1),
                                   calendar: utc, now: { now })
_ = try bulkSweeper.run()
let withPlan = try CapturedHealthBuilder.health(index: index, sweeper: bulkSweeper, inputs: inputs,
                                                now: now, timeZone: TimeZone(identifier: "UTC")!)
expect(withPlan.pictures.pendingPlan != nil,
       "a bulk plan did not surface as a pendingPlan in health")
expect(withPlan.pictures.pendingPlan?.bytes == 2_000_000_000,
       "the pending plan's bytes are not the plan's: \(String(describing: withPlan.pictures.pendingPlan))")
if let plan = withPlan.pictures.pendingPlan {
    _ = try bulkSweeper.decide(planID: plan.planID, run: true)
}
let after = try CapturedHealthBuilder.health(index: index, sweeper: bulkSweeper, inputs: inputs,
                                             now: now, timeZone: TimeZone(identifier: "UTC")!)
expect(after.pictures.pendingPlan == nil, "a confirmed plan stayed in health as pending")
expect(after.pictures.lastCleanup != nil, "an executed cleanup did not surface in health")
expect(after.pictures.lastCleanup?.bytes == 2_000_000_000,
       "lastCleanup's bytes are \(String(describing: after.pictures.lastCleanup?.bytes)), not the plan's")
expect(after.pictures.lastCleanup?.at.hasSuffix("Z") == true,
       "lastCleanup's time is not ISO 8601 UTC")

finish("captured health")
