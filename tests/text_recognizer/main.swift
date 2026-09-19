import Foundation
import GRDB

// TextRecognizer (07 §3.5). Apple's Vision reads the words out of a picture on
// the device, behind a protocol so this suite can run a fake; the backlog works
// through the pictures whose `ocr_state` is still `pending`, newest first,
// never touching a private context, pausing when the machine says so, and
// retrying a failure at the next launch.

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

let files = FileManager.default

func makeRoot(_ name: String) -> URL {
    let url = VoiceFlowPaths.shared.configRoot.appendingPathComponent(name, isDirectory: true)
    try? files.removeItem(at: url)
    try! files.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func write(_ marker: String, to root: URL, path: String) {
    let url = root.appendingPathComponent(path)
    try! files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(marker.utf8).write(to: url)
}
let tz = TimeZone(secondsFromGMT: 3 * 3600)!
let iso = ISO8601DateFormatter()
iso.timeZone = tz
iso.formatOptions = [.withInternetDateTime]
func at(_ s: String) -> Int { Int(iso.date(from: s)!.timeIntervalSince1970) }

// ── the pure value: boxes survive, and the text inside a box is readable ──
let recognised = RecognizedText(
    text: "upstream request timeout\nPOST /api/cart 200",
    lines: [RecognizedLine(text: "upstream request timeout", box: [812, 340, 220, 90]),
            RecognizedLine(text: "POST /api/cart 200", box: [412, 220, 200, 20])])
expect(recognised.lines.count == 2, "recognised lines did not survive")
expect(recognised.text(in: [812, 340, 220, 90]) == "upstream request timeout",
       "the text inside a mark's box is not readable")
expect(recognised.text(in: [0, 0, 10, 10]).isEmpty, "a box over nothing returned text")

// ── the skip rules, by name ───────────────────────────────────────────────
func row(app: String?, extra: String?) -> CapturedItemRow {
    CapturedItemRow(id: "frame:2026-09-01T10-00-00", kind: .frame, source: .watcher,
                    tStart: 1, tEnd: 1, app: app, imageState: .present,
                    ocrState: .pending, extraJSON: extra)
}
expect(TextRecognitionPolicy.shouldSkip(row(app: "1Password", extra: nil)),
       "a picture in front of a password manager was not skipped")
expect(TextRecognitionPolicy.shouldSkip(row(app: "Google Chrome", extra: "{\"private\":true}")),
       "a picture whose line says private was not skipped")
expect(TextRecognitionPolicy.shouldSkip(row(app: "Google Chrome", extra: "{\"secure\":true}")),
       "a picture whose line says secure was not skipped")
expect(TextRecognitionPolicy.shouldSkip(row(app: "SecurityAgent", extra: nil)),
       "the macOS security agent was not treated as private")
expect(!TextRecognitionPolicy.shouldSkip(row(app: "Google Chrome", extra: "{\"private\":false}")),
       "an ordinary picture was skipped")

// ── the backlog: newest first, skipping, failing, and recording ───────────
final class FakeRecognizer: TextRecognizer {
    let languages = ["en-US"]
    var calls: [String] = []
    var failFor: String?
    func recognize(_ image: Data) throws -> RecognizedText {
        let marker = String(data: image, encoding: .utf8) ?? ""
        calls.append(marker)
        if marker == failFor { throw NSError(domain: "test", code: 1) }
        return RecognizedText(text: "text of \(marker)",
                              lines: [RecognizedLine(text: marker, box: [0, 0, 10, 10])])
    }
}

let root = makeRoot("recognition")
let pool = try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root))
let index = CapturedIndex(pool: pool)
func seed(_ id: String, _ start: String, app: String, path: String, extra: String? = nil) {
    _ = try! index.upsert(CapturedItemRow(
        id: id, kind: .frame, source: .watcher, tStart: at(start), tEnd: at(start),
        app: app, path: path, imageState: .present, ocrState: .pending, extraJSON: extra))
}
write("text-A", to: root, path: "watcher/a.jpg")
write("text-B", to: root, path: "watcher/b.jpg")
write("text-C", to: root, path: "watcher/c.jpg")
write("text-D", to: root, path: "watcher/d.jpg")
write("text-E", to: root, path: "watcher/e.jpg")
seed("frame:2026-09-03T10-00-00", "2026-09-03T10:00:00+03:00", app: "Google Chrome", path: "watcher/a.jpg")
seed("frame:2026-09-02T10-00-00", "2026-09-02T10:00:00+03:00", app: "Google Chrome", path: "watcher/b.jpg")
seed("frame:2026-09-01T10-00-00", "2026-09-01T10:00:00+03:00", app: "Google Chrome", path: "watcher/c.jpg")
seed("frame:2026-08-31T10-00-00", "2026-08-31T10:00:00+03:00", app: "1Password", path: "watcher/d.jpg")
seed("frame:2026-08-30T10-00-00", "2026-08-30T10:00:00+03:00", app: "Google Chrome",
     path: "watcher/e.jpg", extra: "{\"private\":true}")

let fake = FakeRecognizer()
fake.failFor = "text-B"
let backlog = TextRecognitionBacklog(index: index, root: root, recognizer: fake,
                                     conditions: .always)
let result = backlog.run(limit: 10)
expect(result.recognised == 2, "the backlog recognised \(result.recognised), not 2")
expect(result.failed == 1, "the backlog did not record the one failure")
expect(result.skipped == 2, "the backlog did not skip the two private pictures")
expect(!result.stopped, "the backlog stopped with work left")
expect(fake.calls == ["text-A", "text-B", "text-C"],
       "the backlog did not work newest first, skipping the private ones: \(fake.calls)")

expect(try index.item(id: "frame:2026-09-03T10-00-00")?.ocr == "text of text-A",
       "a recognised picture did not keep its text")
expect(try index.item(id: "frame:2026-09-03T10-00-00")?.ocrState == .done,
       "a recognised picture is not done")
expect(try index.item(id: "frame:2026-09-02T10-00-00")?.ocrState == .failed,
       "a failed picture is not marked failed, so it would never be retried")
expect(try index.item(id: "frame:2026-08-31T10-00-00")?.ocrState == .skippedPrivate,
       "a private picture is not marked skipped_private")
expect(try index.item(id: "frame:2026-08-31T10-00-00")?.ocr == nil,
       "a private picture was given recognised text")
expect(try index.item(id: "frame:2026-08-30T10-00-00")?.ocrState == .skippedPrivate,
       "a picture whose line says private was not skipped")

// A failure stays pending until the next run, and a second run does only what is left.
let second = TextRecognitionBacklog(index: index, root: root, recognizer: fake,
                                    conditions: .always)
let secondResult = second.run(limit: 10)
expect(secondResult.failed == 1, "the failed picture was not retried at the next run")
expect(try index.item(id: "frame:2026-09-02T10-00-00")?.ocrState == .failed,
       "a failure that fails again is not left failed")

// ── pausing leaves the rest pending, untouched ────────────────────────────
let pausedRoot = makeRoot("paused")
let pausedPool = try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: pausedRoot))
let pausedIndex = CapturedIndex(pool: pausedPool)
for (n, marker) in ["p1", "p2", "p3"].enumerated() {
    write(marker, to: pausedRoot, path: "watcher/\(marker).jpg")
    _ = try! pausedIndex.upsert(CapturedItemRow(
        id: "frame:2026-09-0\(n + 1)T10-00-00", kind: .frame, source: .watcher,
        tStart: at("2026-09-0\(n + 1)T10:00:00+03:00"), tEnd: at("2026-09-0\(n + 1)T10:00:00+03:00"),
        app: "Google Chrome", path: "watcher/\(marker).jpg", imageState: .present, ocrState: .pending))
}
var allowed = true
let pauseFake = FakeRecognizer()
let pausedBacklog = TextRecognitionBacklog(
    index: pausedIndex, root: pausedRoot, recognizer: pauseFake,
    conditions: TextRecognitionConditions(allowsRun: {
        let was = allowed
        allowed = false          // the machine says stop after the first picture
        return was
    }, pauseReason: { allowed ? nil : "battery" }))
let pausedResult = pausedBacklog.run(limit: 10)
expect(pausedResult.recognised == 1, "the pause did not stop after the first picture")
expect(pausedResult.stopped, "a paused run does not say it stopped")
expect(pauseFake.calls.count == 1, "a paused run read more than one picture")
expect(try pausedIndex.item(id: "frame:2026-09-02T10-00-00")?.ocrState == .pending,
       "a picture left for later was not left pending")

finish("text recognizer")
