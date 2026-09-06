import AppKit
import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private func png(red: UInt8, green: UInt8, blue: UInt8,
                 width: Int = 32, height: Int = 24) -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor(
        calibratedRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let destination = NSMutableData()
    let writer = CGImageDestinationCreateWithData(
        destination, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, image, nil)
    expect(CGImageDestinationFinalize(writer), "could not make image fixture")
    return destination as Data
}

private func waitFor(_ message: String, timeout: TimeInterval = 4,
                     _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    expect(false, message)
}

let red = png(red: 240, green: 20, blue: 20)
let redAgain = png(red: 240, green: 20, blue: 20)
let blue = png(red: 20, green: 20, blue: 240)
expect(CaptureFrameDeduplicator.shouldKeep(previous: nil, candidate: red),
       "first capture frame was rejected")
expect(!CaptureFrameDeduplicator.shouldKeep(previous: red, candidate: redAgain),
       "equivalent capture frame was not deduplicated")
expect(CaptureFrameDeduplicator.shouldKeep(previous: red, candidate: blue),
       "materially changed capture frame was deduplicated")

let store = CaptureStore()
var finalized: CaptureSummary?
store.onFinalized = { finalized = $0 }
store.beginSession(runId: UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
store.addFrame(red)
store.addFrame(blue)
let summary = store.endSession(transcript: "ordered narration")
expect(summary?.frameCount == 2, "capture summary lost ordered frames")
waitFor("capture metadata was not serialized") {
    guard let directory = summary?.directory,
          let meta = CaptureStore.readMeta(in: directory) else { return false }
    return meta.transcript == "ordered narration" && meta.frames.count == 2
        && meta.frames.map(\.file) == meta.frames.map(\.file).sorted()
}
waitFor("capture finalization event did not fire") { finalized?.id == summary?.id }
let latest = CaptureStore.latestBundle()
expect(latest?.meta.id == summary?.id, "latest capture retrieval did not return newest bundle")
expect(CaptureStore.listBundles(limit: 1).count == 1,
       "bounded capture listing ignored its limit")
let markdown = try String(contentsOf: summary!.directory.appendingPathComponent("transcript.md"))
expect(markdown.contains("ordered narration") && markdown.contains("frame-01"),
       "capture transcript omitted narration or frame index")

// Pruning is exercised through the real finalize queue. Each seeded bundle
// has valid metadata so list/retrieval behavior is also checked after prune.
let encoder = JSONEncoder()
for index in 0..<42 {
    let id = String(format: "2000-01-01_00-00-%02d-prune", index)
    let directory = CaptureStore.baseDir.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let meta = CaptureBundleMeta(
        id: id, startedAt: "2000-01-01T00:00:00Z",
        endedAt: "2000-01-01T00:00:01Z", durationSeconds: 1,
        transcript: "seed", frames: [])
    try encoder.encode(meta).write(
        to: directory.appendingPathComponent("meta.json"), options: .atomic)
}
let pruningStore = CaptureStore()
pruningStore.beginSession(runId: UUID())
_ = pruningStore.endSession(transcript: "prune now")
waitFor("capture bundle retention did not converge to 40") {
    CaptureStore.listBundles(limit: 100).count == 40
}

// A pasted image is not a screen frame: it keeps its own aspect ratio and
// only has its long edge bounded, or a wide screenshot pasted into the
// composer would reach the agent squashed.
let wide = png(red: 10, green: 200, blue: 90, width: 640, height: 160)
guard let pastedPath = CaptureStore.savePastedImage(wide) else {
    fputs("FAIL: pasted image was not saved\n", stderr); exit(1)
}
expect(FileManager.default.fileExists(atPath: pastedPath),
       "pasted image path does not exist on disk")
expect((pastedPath as NSString).lastPathComponent.hasPrefix("pasted-"),
       "pasted image did not land under its own name")
guard let saved = NSImage(contentsOfFile: pastedPath),
      let rep = saved.representations.first else {
    fputs("FAIL: pasted image is not readable\n", stderr); exit(1)
}
let ratio = Double(rep.pixelsWide) / Double(rep.pixelsHigh)
expect(abs(ratio - 4.0) < 0.05,
       "pasted image lost its aspect ratio (got \(rep.pixelsWide)x\(rep.pixelsHigh))")

// The durable capture event must describe only frames actually saved, and
// both files must already be readable when a capture-triggered job starts.
let durableStore = CaptureStore()
var durableCallbacks = 0
var durableEventWasReadable = false
durableStore.onFinalized = { final in
    durableCallbacks += 1
    let meta = CaptureStore.readMeta(in: final.directory)
    let markdown = try? String(contentsOfFile: final.transcriptPath)
    durableEventWasReadable = meta?.transcript == "durable narration"
        && markdown?.contains("durable narration") == true
        && final.frameCount == 0 && final.framePaths.isEmpty
        && meta?.frames.isEmpty == true
}
durableStore.beginSession(runId: UUID())
durableStore.addFrame(Data("not an image".utf8))
_ = durableStore.endSession(transcript: "durable narration")
waitFor("durable capture event did not arrive") { durableCallbacks == 1 }
expect(durableEventWasReadable, "capture event preceded durable files or included a failed frame")

var revisedEventWasReadable = false
let provisionalStore = CaptureStore()
provisionalStore.onFinalized = { final in
    let meta = CaptureStore.readMeta(in: final.directory)
    let markdown = try? String(contentsOfFile: final.transcriptPath)
    revisedEventWasReadable = meta?.transcript == "revised narration"
        && markdown?.contains("revised narration") == true
}
provisionalStore.beginSession(runId: UUID())
let provisional = provisionalStore.endSession(transcript: nil, keepEmpty: true)!
_ = provisionalStore.updateTranscript("revised narration", in: provisional)
waitFor("revised capture event preceded durable narration") { revisedEventWasReadable }

// A persistence failure must not launch a capture job for narration that
// was never saved. A later successful close drains the same serial queue.
let failingStore = CaptureStore()
var completedIDs: [String] = []
failingStore.onFinalized = { completedIDs.append($0.id) }
failingStore.beginSession(runId: UUID())
let failing = failingStore.endSession(transcript: nil, keepEmpty: true)!
waitFor("provisional failure fixture was not saved") {
    CaptureStore.readMeta(in: failing.directory) != nil
}
try FileManager.default.removeItem(atPath: failing.transcriptPath)
try FileManager.default.createDirectory(atPath: failing.transcriptPath, withIntermediateDirectories: true)
_ = failingStore.updateTranscript("unsaved narration", in: failing)
failingStore.beginSession(runId: UUID())
let barrier = failingStore.endSession(transcript: "next successful capture")!
waitFor("successful capture did not follow failed persistence") { completedIDs.contains(barrier.id) }
expect(completedIDs == [barrier.id], "failed persistence emitted a capture-completed event")

// Existing screenshots must not outrank a fresh pasted attachment just
// because their names begin with "shot-" instead of "pasted-".
let shots = CaptureStore.baseDir.appendingPathComponent("shots")
for existing in try FileManager.default.contentsOfDirectory(at: shots, includingPropertiesForKeys: nil) {
    try FileManager.default.removeItem(at: existing)
}
for index in 0..<60 {
    let old = shots.appendingPathComponent("shot-2000-01-01-\(index).jpg")
    try red.write(to: old)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))],
                                         ofItemAtPath: old.path)
}
guard let retainedPaste = CaptureStore.savePastedImage(wide) else {
    fputs("FAIL: could not save retention fixture\n", stderr); exit(1)
}
expect(FileManager.default.fileExists(atPath: retainedPaste),
       "new pasted attachment was pruned behind older screenshots")
expect(!FileManager.default.fileExists(atPath: shots.appendingPathComponent("shot-2000-01-01-0.jpg").path),
       "oldest screenshot was not pruned")
let retainedImages = try FileManager.default.contentsOfDirectory(at: shots, includingPropertiesForKeys: nil)
expect(retainedImages.count == 60,
       "mixed screenshot retention exceeded its limit")

print("capture store tests passed")
