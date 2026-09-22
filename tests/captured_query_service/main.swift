import Foundation
import GRDB
import AppKit
import CryptoKit

func vflog(_ message: String) {}
// Unrelated app collaborators needed by the production S1 sources compiled here.
final class PendingInteraction { var sessionId: String? }
struct CaptureSummary {}
final class UserSettings {
    static let shared = UserSettings()
    var watcherKeepDays = 30
    var watcherDenseApps: Set<String> = []
}
var failures: [String] = []
var assertions = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    assertions += 1
    do { if try !condition() { failures.append(message) } } catch { failures.append("\(message): \(error)") }
}
func refused(_ code: TPCapturedErrorCode, _ label: String, _ body: () throws -> Void) {
    assertions += 1
    do { try body(); failures.append("\(label): expected \(code.rawValue)") }
    catch let error as CapturedQueryFailure { if error.error.code != code { failures.append("\(label): got \(error.error.code.rawValue)") } }
    catch { failures.append("\(label): unexpected \(error)") }
}
guard VoiceFlowPaths.shared.isIsolated else { fatalError("isolated root required") }
let root = VoiceFlowPaths.shared.configRoot
let fm = FileManager.default
let pool = try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root))
let index = CapturedIndex(pool: pool)
let tz = TimeZone(secondsFromGMT: 3 * 3600)!
var access = true
var progress = CapturedProgress(state: .ready, daysDone: 1, daysTotal: 1)
let query = CapturedQuery(index: index, root: root, timeZone: tz, indexProgress: { progress }, mayRead: { access })
let service = CapturedReadService(query: query)
func at(_ text: String) -> Int { try! query.epoch(text) }
func write(_ data: Data, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
func png(_ width: Int, _ height: Int) -> Data {
    let color = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: color,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 20, y: 10, width: 20, height: 20))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}
let sourcePNG = png(400, 200)
let sourcePath = "captures/shots/source.png"
try write(sourcePNG, sourcePath)
let sourceHash = SHA256.hash(data: sourcePNG).description
let base = at("2026-09-18 10:00")
func seed(_ row: CapturedItemRow) throws { try index.upsert(row) }
func search(_ text: String? = nil, limit: Int? = nil, cursor: String? = nil, apps: [String]? = nil,
            from: String? = nil, to: String? = nil, kinds: [TPCapturedKind]? = nil, thread: String? = nil,
            limits: CapturedLimits = .agent) throws -> TPCapturedSearchOutput {
    try query.search(.init(apps: apps, cursor: cursor, from: from, kinds: kinds, limit: limit, text: text, threadID: thread, to: to), limits: limits)
}
func get(_ id: String, picture: Bool? = nil, offset: Int? = nil, variant: TPPictureVariant? = nil,
         limits: CapturedLimits = .agent) throws -> TPCapturedGetOutput {
    try query.get(.init(id: id, picture: picture, region: nil, textOffset: offset, variant: variant), limits: limits, includePath: true)
}
let context = #"{"app":"Browser","bundleId":"org.browser","windowTitle":"secret sk-live-ABCDEFGHIJKLMNOPQRSTUV","url":"https://user:pass@example.com/path?token=secret#fragment","display":{"uuid":"D1","index":1,"widthPt":400,"heightPt":200,"scale":1},"private":false}"#
let marks = #"[{"n":1,"kind":"ellipse","color":"red","box":[20,10,20,20],"stroke":3,"note":"sk-live-ABCDEFGHIJKLMNOPQRSTUV","underText":"Marked word"}]"#
try seed(.init(id: "activity:a", kind: .activity, source: .watcher, tStart: base, tEnd: base + 120,
               app: "Browser", bundleID: "org.browser", title: "Delta project", url: "example.com/path?secret=1"))
for n in 0..<4 {
    let path = "watcher/2026-09-18/frame-\(n).png"
    try write(sourcePNG, path)
    try seed(.init(id: "frame:f\(n)", kind: .frame, source: .watcher, tStart: base + n * 10, tEnd: base + n * 10,
        parentID: "activity:a", app: "Browser", bundleID: "org.browser", title: "Delta project", path: path,
        imageState: .present, ocr: "Delta project invoice", ocrState: .done, extraJSON: "{\"chg\":[0,0,\(n+1),10]}"))
}
try seed(.init(id: "shot:s", kind: .shot, source: .shot, tStart: base + 60, tEnd: base + 60,
    app: "Browser", title: String(repeating: "😀", count: 100), url: "https://user:pass@example.com/path?token=x#private", imgW: 400, imgH: 200,
    path: sourcePath, imageState: .present, ocr: "Delta screenshot", ocrState: .done, marksJSON: marks, extraJSON: "{\"context\":\(context)}"))
try seed(.init(id: "dictation:d", kind: .dictation, source: .dictation, tStart: base + 70, tEnd: base + 70,
    body: "Delta weekly invoice sk-live-ABCDEFGHIJKLMNOPQRSTUV", extraJSON: #"{"destination":"thread"}"#, originDevice: "phone"))
try seed(.init(id: "dictation:long", kind: .dictation, source: .dictation, tStart: base + 80, tEnd: base + 80,
    body: String(repeating: "界", count: 9_000)))
try pool.write { db in
    try db.execute(sql: "INSERT INTO link (item_id,thread_id,turn_id,role,at) VALUES (?,?,?,?,?)", arguments: ["dictation:d", "thread-1", "turn-1", "sent", base])
}

// Exact time grammar, offset round trips, impossible dates and DST gaps.
expect(try query.epoch("2026-09-18T07:00:00Z") == base, "UTC conversion")
expect(try query.epoch("2026-09-18T10:00:00+03:00") == base, "offset conversion")
expect(query.stamp(base) == "2026-09-18T10:00:00+03:00", "local result offset")
for bad in ["2026-02-30 10:00", "2026-02-30T10:00:00Z", "2026-09-18", "2026-09-18T10:00:00", "garbage", "2026-09-18T10:00:00+25:00"] {
    refused(.invalidArguments, "invalid time \(bad)") { _ = try query.epoch(bad) }
}
refused(.invalidArguments, "DST nonexistent local minute") { _ = try CapturedTime.parse("2026-03-29 03:30", in: TimeZone(identifier: "Europe/Sofia")!) }
let plain = try search(limit: 20)
expect(plain.hits.first?.id == "dictation:long", "newest-first order")
expect(plain.hits.filter { $0.kind == .frame }.count == 4, "browse preserves all frames")
let found = try search("delt inv")
expect(found.hits.filter { $0.kind == .frame }.count == 1, "FTS prefix AND + activity collapse")
expect(found.hits.first { $0.kind == .frame }?.sameSpanMatches == 4, "collapse counts all sibling matches")
expect(found.hits.first { $0.kind == .frame }?.id == "frame:f3", "rank tie newest frame wins")
expect(found.hits.contains { $0.snippet.contains("«Delta»") }, "matched prefix highlighting")
expect(try search("invoice nope").hits.isEmpty, "every search word must match")
expect(try search("\" OR * NEAR(").hits.isEmpty, "FTS operator input is literal tokens")
expect(try search(apps: ["bRoWsEr"]).hits.count == 6, "case-insensitive app name")
expect(try search(apps: ["org.browser"]).hits.count == 5, "bundle id filter")
expect(try search(thread: "thread-1").hits.map(\.id) == ["dictation:d"], "linked thread filter")
expect(try search(kinds: [.dictation]).hits.count == 2, "kind filter")
expect(try search(from: "2026-09-18 10:01", to: "2026-09-18 10:02").hits.count == 3, "half-open time filter")
let page = try search(limit: 2)
expect(page.truncated && page.nextCursor == "c_2", "search pagination")
let second = try search(limit: 2, cursor: page.nextCursor)
expect(Set(page.hits.map(\.id)).isDisjoint(with: Set(second.hits.map(\.id))), "pages do not repeat")
for cursor in ["-1", "c_-1", "c_1x", "c_99999999999999999999"] { refused(.invalidArguments, "bad cursor") { _ = try search(cursor: cursor) } }
refused(.invalidArguments, "zero limit") { _ = try search(limit: 0) }
refused(.invalidArguments, "too many apps") { _ = try search(apps: Array(repeating: "x", count: 6)) }
expect(try search("Delta", limit: Int.max).hits.count <= 20, "oversized requested limit clamps")
let secret = try search(thread: "thread-1").hits[0]
expect(secret.snippet.contains("[REDACTED]") && !secret.snippet.contains("sk-live"), "secret redaction before snippets")
let shot = try get("shot:s")
expect(shot.item.context?.url == "example.com/path", "stored context URL normalized")
expect(shot.item.context?.windowTitle?.contains("sk-live") == false, "context title secret redaction")
expect(shot.item.marks.first?.note == "[REDACTED]" && shot.item.marks.first?.underText == "Marked word", "marks preserved and scrubbed")
expect(shot.item.picture?.path == root.appendingPathComponent(sourcePath).path, "local original path")
expect(plain.hits.first { $0.id == "shot:s" }?.title?.utf16.count == 120, "UTF-16 title ceiling")
expect(try get("activity:a").item.children.map(\.id) == ["frame:f0", "frame:f1", "frame:f2", "frame:f3"], "children sorted")
let long = try get("dictation:long")
expect(try JSONEncoder().encode(long).count <= 12_000 && long.truncated == true, "UTF-8 byte ceiling")
expect(long.item.textTotal == 9_000, "whole text length survives truncation")
expect(try get("dictation:long", offset: 8_000, limits: .interface).item.text?.count == 1_000, "text offset continuation")
refused(.notFound, "unusable id") { _ = try get("../../etc/passwd") }
refused(.invalidArguments, "negative text offset") { _ = try get("shot:s", offset: -1) }

// Historical private flags, password managers and descendants never escape.
for (id, fields) in [("private", #"{"private":true}"#), ("nested", #"{"context":{"private":true}}"#)] {
    try seed(.init(id: "activity:\(id)", kind: .activity, source: .watcher, tStart: base, tEnd: base + 30,
        app: "Browser", title: "Hidden private marker", extraJSON: fields))
    try seed(.init(id: "frame:\(id)", kind: .frame, source: .watcher, tStart: base, tEnd: base,
        parentID: "activity:\(id)", path: sourcePath, imageState: .present, ocr: "Hidden private marker", ocrState: .done))
    refused(.notFound, "private descendant direct get") { _ = try get("frame:\(id)") }
    refused(.notFound, "private original bytes") { _ = try query.originalPicture(id: "frame:\(id)") }
}
try seed(.init(id: "shot:password", kind: .shot, source: .shot, tStart: base, tEnd: base,
    app: "1Password", path: sourcePath, imageState: .present, ocr: "Hidden private marker"))
expect(try search("Hidden").hits.isEmpty, "private FTS exclusions")
access = false
refused(.permissionDenied, "revoked query") { _ = try search() }
refused(.permissionDenied, "revoked bytes") { _ = try query.originalPicture(id: "shot:s") }
let denied = try service.read(.search, arguments: Data("{}".utf8))
expect(denied.isError && denied.pictures.isEmpty, "denied service refusal")
access = true
progress = .init(state: .rebuilding, daysDone: 2, daysTotal: 5)
refused(.indexBuilding, "rebuild gate") { _ = try search() }
expect(try query.status().index.daysDone == 2, "status visible during rebuild")
progress = .init(state: .ready, daysDone: 5, daysTotal: 5)

// Native thumbnail/crop, clean variant, immutable original bytes and safe reads.
expect(try query.originalPicture(id: "shot:s") == sourcePNG, "original image bytes exact")
let thumb = try query.picture(.init(id: "shot:s", maxPx: 80, region: nil, variant: nil))
expect(thumb.width == 80 && thumb.height == 40 && thumb.mimeType == "image/jpeg", "native aspect-correct thumbnail")
let crop = try query.picture(.init(id: "shot:s", maxPx: nil, region: [20, 10, 20, 20], variant: nil), byteLimit: 400_000)
expect(crop.width == 20 && crop.height == 20 && crop.data.count <= 400_000, "full-resolution crop")
for region in [[1], [-1,0,10,10], [0,0,0,10], [400,0,1,1], [399,0,Int.max,2]] {
    refused(.invalidArguments, "bad crop") { _ = try query.picture(.init(id: "shot:s", maxPx: nil, region: region, variant: nil)) }
}
refused(.pictureGone, "missing clean never falls back to marked") { _ = try query.originalPicture(id: "shot:s", variant: .clean) }
let outside = root.deletingLastPathComponent().appendingPathComponent("outside.png")
try sourcePNG.write(to: outside)
try fm.createSymbolicLink(atPath: root.appendingPathComponent("escape.png").path, withDestinationPath: outside.path)
for (id, path) in [("escape", "escape.png"), ("traversal", "../outside.png"), ("absolute", outside.path), ("directory", "captures")] {
    try seed(.init(id: "shot:\(id)", kind: .shot, source: .shot, tStart: base, tEnd: base, path: path, imageState: .present, ocr: "Retained text"))
    refused(.pictureGone, "unsafe path \(id)") { _ = try query.originalPicture(id: "shot:\(id)") }
    expect(try get("shot:\(id)", picture: false).item.picture?.state == .missing, "unsafe metadata is unavailable")
}
try write(Data("not an image".utf8), "captures/shots/broken.jpg")
try seed(.init(id: "shot:broken", kind: .shot, source: .shot, tStart: base, tEnd: base, path: "captures/shots/broken.jpg", imageState: .present, ocr: "Retained broken picture text"))
let broken = try service.read(.get, arguments: Data(#"{"id":"shot:broken"}"#.utf8), delivery: .imageBytes)
let brokenResult = try JSONDecoder().decode(TPCapturedErrorResult.self, from: broken.json)
expect(broken.isError && brokenResult.error.code == .pictureGone && brokenResult.item?.text == "Retained broken picture text", "decode failure preserves indexed text")
try write(Data("recording bytes".utf8), "pending-audio/pending.wav")
try RecordingIngester(index: index, root: root).ingest(fileName: "pending.wav")
expect(try query.sourceStatus(id: "recording:pending").state == .available, "recording availability checked")
try fm.removeItem(at: root.appendingPathComponent("pending-audio/pending.wav"))
expect(try query.sourceStatus(id: "recording:pending").state == .missing, "removed recording never resurrects")
expect(try query.status().recordingsAvailable == 0 && query.status().recordingsMissing == 1, "status avoids stale undelivered recording")
expect(try index.item(id: "recording:pending") != nil, "missing recording history is retained")
try fm.removeItem(at: root.appendingPathComponent("watcher/2026-09-18/frame-3.png"))
let missing = try service.read(.get, arguments: Data(#"{"id":"frame:f3"}"#.utf8), delivery: .imageBytes)
let missingResult = try JSONDecoder().decode(TPCapturedErrorResult.self, from: missing.json)
expect(missingResult.error.code == .pictureGone && missingResult.item?.text?.contains("Delta") == true, "removed picture retains indexed text")
expect(try get("frame:f3", picture: false).item.picture?.state == .missing, "metadata-only reflects vanished file")

// Range selection, clipped totals, chronological around and calendar day splitting.
try seed(.init(id: "activity:b", kind: .activity, source: .watcher, tStart: base + 180, tEnd: base + 300, app: "Editor", title: "Build"))
try write(sourcePNG, "watcher/2026-09-18/second.png")
try seed(.init(id: "frame:b", kind: .frame, source: .watcher, tStart: base + 180, tEnd: base + 180, parentID: "activity:b", app: "Editor",
    path: "watcher/2026-09-18/second.png", imageState: .present, extraJSON: #"{"chg":[0,0,900,900]}"#))
let range = try query.frames(.init(apps: nil, from: "2026-09-18 10:00", maxPictures: 2, to: "2026-09-18 10:06"), limits: .agent, includePath: false)
expect(range.pictures.map(\.id) == ["frame:f0", "frame:b"], "first-of-span deterministic sampling")
expect(range.omitted == 3 && range.truncated == true, "sampling and missing picture omitted count")
expect(range.pictures.allSatisfy { $0.path == nil }, "device range never emits file paths")
let around = try query.around(.init(at: "2026-09-18 10:01", id: nil, windowMinutes: 5), limits: .agent)
expect(around.frameBefore == "frame:f2" && around.frameAfter == "frame:b", "nearest available pictures")
refused(.invalidArguments, "ambiguous around") { _ = try query.around(.init(at: "2026-09-18 10:00", id: "shot:s", windowMinutes: nil), limits: .agent) }
refused(.rangeTooLong, "long frames range") { _ = try query.frames(.init(apps: nil, from: "2026-09-18 00:00", maxPictures: nil, to: "2026-09-20 00:00"), limits: .agent, includePath: false) }
refused(.rangeTooLong, "long summary range") { _ = try query.summary(.init(from: "2026-01-01 00:00", groupBy: nil, to: "2026-03-01 00:00"), limits: .agent) }
let summary = try query.summary(.init(from: "2026-09-18 10:01", groupBy: .app, to: "2026-09-18 10:04"), limits: .agent)
expect(summary.activeSeconds == 120 && summary.switches == 1, "summary clips span boundaries")
expect(abs(summary.groups.reduce(0) { $0 + $1.share } - 1) < 0.0001, "untruncated shares total one")
expect(summary.counts.dictations == 2 && summary.counts.shots == 1, "summary counts range items without private rows")
let midnight = at("2026-09-19 23:30")
try seed(.init(id: "activity:midnight", kind: .activity, source: .watcher, tStart: midnight, tEnd: midnight + 7_200, app: "Editor"))
let midnightSummary = try query.summary(.init(from: "2026-09-19 00:00", groupBy: .day, to: "2026-09-21 00:00"), limits: .interface)
expect(midnightSummary.groups.first { $0.key == "2026-09-19" }?.seconds == 1_800, "midnight split first day")
expect(midnightSummary.groups.first { $0.key == "2026-09-20" }?.seconds == 5_400, "midnight split second day")
expect(try query.day("2026-09-19").activeSeconds == 1_800, "day uses same query")
var sofia = query; sofia.timeZone = TimeZone(identifier: "Europe/Sofia")!
let dstStart = try sofia.epoch("2026-10-25 00:00"), dstEnd = try sofia.epoch("2026-10-26 00:00")
try seed(.init(id: "activity:dst", kind: .activity, source: .watcher, tStart: dstStart, tEnd: dstEnd, app: "Editor"))
let dstDay = try sofia.day("2026-10-25")
expect(dstDay.activeSeconds == 25 * 3600 && dstDay.groups.count == 25, "25-hour DST day is not truncated to 24h")
expect(Set(dstDay.groups.map(\.key)).count == 25, "repeated DST hour has distinct offset key")

// One service result for SDK/shared client, strict byte/image limits and immutability.
let encodedInput = Data(#"{"id":"shot:s","region":[20,10,20,20]}"#.utf8)
let remote = try service.read(.get, arguments: encodedInput, delivery: .imageBytes)
let remoteOutput = try JSONDecoder().decode(TPCapturedGetOutput.self, from: remote.json)
expect(!remote.isError && remote.pictures.map(\.id) == ["shot:s"] && remote.pictures[0].data.count <= 400_000, "SDK-ready picture bytes identify capture")
expect(remoteOutput.item.picture?.path == nil && remoteOutput.item.picture?.width == 20, "remote crop has no path and correct dimensions")
let local = try service.read(.get, arguments: encodedInput, delivery: .localFiles)
let localOutput = try JSONDecoder().decode(TPCapturedGetOutput.self, from: local.json)
expect(local.pictures.isEmpty && localOutput.item.picture?.path?.contains("/captures/derived/") == true, "local tool gets disposable path")
expect(localOutput.item.picture?.path != root.appendingPathComponent(sourcePath).path, "crop never overwrites original")
expect(try Data(contentsOf: URL(fileURLWithPath: localOutput.item.picture!.path!)).count <= 400_000, "local crop byte cap")
expect(try SHA256.hash(data: Data(contentsOf: root.appendingPathComponent(sourcePath))).description == sourceHash, "original source hash unchanged")
let badInput = try service.read(.search, arguments: Data(#"{"limit":"bad"}"#.utf8))
expect(badInput.isError && badInput.json.count <= 12_000, "typed schema refusal")
let ui = try service.read(.get, arguments: Data(#"{"id":"frame:f3","picture":true}"#.utf8), limits: .interface)
expect(!ui.isError && ui.pictures.isEmpty, "UI metadata ignores picture request")
expect(try query.status().picturesMissing >= 5, "status detects missing and unsafe sources")
expect(try pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM item_fts WHERE item_fts MATCH 'Delta'")! } >= 4, "reads leave FTS intact")

// Limits that require actual truncation/compression, not a tiny happy-path image.
let oldTime = base - 200_000
try seed(.init(id: "capture:large", kind: .capture, source: .bundle, tStart: oldTime, tEnd: oldTime + 1_100, body: "Bundle"))
try index.transaction { tx in
    for n in 0..<1_100 {
        try tx.upsert(.init(id: "capture:large/\(n)", kind: .frame, source: .bundle, tStart: oldTime + n, tEnd: oldTime + n, parentID: "capture:large"))
    }
}
let bundle = try search(kinds: [.capture]).hits[0]
expect(bundle.previewIDS == ["capture:large/0", "capture:large/550", "capture:large/1099"], "preview samples the real last frame beyond 1,000 children")
expect(try get("capture:large").item.children.count == 50 && get("capture:large").truncated == true, "agent children cap")
expect(try get("capture:large", limits: .interface).item.children.count == 1_000, "UI children cap")
try index.transaction { tx in
    for n in 0..<30 {
        try tx.upsert(.init(id: "dictation:limits-\(n)", kind: .dictation, source: .dictation, tStart: oldTime, tEnd: oldTime,
            app: String(repeating: "界", count: 1_000), body: "SizeBoundary " + String(repeating: "界", count: 400)))
    }
}
let bounded = try search("SizeBoundary", limit: 20)
expect(!bounded.hits.isEmpty && bounded.hits.count < 20 && bounded.nextCursor == "c_\(bounded.hits.count)", "byte truncation advances cursor by returned hits")
expect(try JSONEncoder().encode(bounded).count <= 12_000, "large hit list respects UTF-8 bytes")
let noiseWidth = 1_000, noiseHeight = 1_000
var pixels = [UInt8](repeating: 255, count: noiseWidth * noiseHeight * 4)
var random: UInt32 = 42
for n in 0..<pixels.count where n % 4 != 3 {
    random = random &* 1_664_525 &+ 1_013_904_223; pixels[n] = UInt8(truncatingIfNeeded: random >> 24)
}
let provider = CGDataProvider(data: Data(pixels) as CFData)!
let noisyImage = CGImage(width: noiseWidth, height: noiseHeight, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: noiseWidth * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let noisy = NSBitmapImageRep(cgImage: noisyImage).representation(using: .png, properties: [:])!
expect(noisy.count > 400_000, "large image fixture actually exceeds tool budget")
try write(noisy, "captures/shots/noisy.png")
try seed(.init(id: "shot:noisy", kind: .shot, source: .shot, tStart: oldTime, tEnd: oldTime, imgW: 1_000, imgH: 1_000, path: "captures/shots/noisy.png", imageState: .present))
let limitedPicture = try query.picture(.init(id: "shot:noisy", maxPx: nil, region: nil, variant: nil), byteLimit: 400_000)
expect(limitedPicture.data.count <= 400_000 && limitedPicture.width > 0, "noisy image meets tool byte budget")
expect(try query.originalPicture(id: "shot:noisy") == noisy, "compression leaves large original untouched")
for n in 0..<15 {
    try seed(.init(id: "frame:many-\(n)", kind: .frame, source: .watcher, tStart: oldTime + n, tEnd: oldTime + n, path: sourcePath, imageState: .present))
}
let manyArguments = try JSONEncoder().encode(TPCapturedFramesInput(apps: nil, from: query.stamp(oldTime), maxPictures: 720, to: query.stamp(oldTime + 16)))
let many = try service.read(.frames, arguments: manyArguments, limits: .interface, delivery: .imageBytes)
let manyOutput = try JSONDecoder().decode(TPCapturedFramesOutput.self, from: many.json)
expect(many.pictures.count <= 12 && many.pictures.map(\.id) == manyOutput.pictures.map(\.id), "device picture cap and id order")
expect(many.pictures.reduce(0) { $0 + $1.data.count } <= 4_800_000, "total picture budget")
let forbidden = "captures/shots/denied.png"
try write(sourcePNG, forbidden)
try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: root.appendingPathComponent(forbidden).path)
try seed(.init(id: "shot:denied", kind: .shot, source: .shot, tStart: oldTime, tEnd: oldTime, path: forbidden, imageState: .present))
refused(.permissionDenied, "filesystem permission denial") { _ = try query.originalPicture(id: "shot:denied") }
let deniedFileReply = try service.read(.get, arguments: Data(#"{"id":"shot:denied"}"#.utf8), delivery: .imageBytes)
let deniedFileError = try JSONDecoder().decode(TPCapturedErrorResult.self, from: deniedFileReply.json)
expect(deniedFileError.error.code == .permissionDenied && deniedFileReply.pictures.isEmpty, "tool preserves named filesystem denial")
try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(forbidden).path)

// The same website groups together whether legacy ingestion stored a full
// URL or its already-sanitized host/path form.
try seed(.init(id: "activity:host-full", kind: .activity, source: .watcher, tStart: oldTime - 120, tEnd: oldTime - 90,
    app: "Browser", url: "https://person:pass@example.com/first?token=hidden#fragment"))
try seed(.init(id: "activity:host-stored", kind: .activity, source: .watcher, tStart: oldTime - 90, tEnd: oldTime - 60,
    app: "Browser", url: "example.com/second?token=hidden"))
let hostSummary = try query.summary(.init(from: query.stamp(oldTime - 120), groupBy: .urlHost, to: query.stamp(oldTime)), limits: .agent)
expect(hostSummary.groups.count == 1 && hostSummary.groups[0].key == "example.com" && hostSummary.groups[0].seconds == 60,
       "urlHost grouping accepts full URLs and stored host/path without a scheme or query")

// Exercise the central PEM scrubber through real wire replies. A block longer
// than the text window must be removed before pagination, including its body
// and footer; indexed search must not expose that body in a snippet either.
let pemBody = "SYNTHETICPEMBODY" + String(repeating: "QUJD", count: 3_000)
let pem = "before PEM\n-----BEGIN PRIVATE KEY-----\n" + pemBody + "\n-----END PRIVATE KEY-----\nafter PEM"
try seed(.init(id: "dictation:pem", kind: .dictation, source: .dictation, tStart: oldTime, tEnd: oldTime, body: pem))
let pemReply = try service.read(.get, arguments: Data(#"{"id":"dictation:pem"}"#.utf8))
let pemResult = try JSONDecoder().decode(TPCapturedGetOutput.self, from: pemReply.json)
expect(pemResult.item.text?.contains("before PEM") == true && pemResult.item.text?.contains("after PEM") == true
    && pemResult.item.text?.contains("SYNTHETICPEMBODY") == false && pemResult.item.text?.contains("QUJD") == false
    && pemResult.item.text?.contains("PRIVATE KEY") == false, "query get redacts complete PEM before the 8,000-character text window")
let pemSearch = try service.read(.search, arguments: Data(#"{"text":"SYNTHETICPEMBODY"}"#.utf8))
let pemHits = try JSONDecoder().decode(TPCapturedSearchOutput.self, from: pemSearch.json)
expect(pemHits.hits.map(\.id) == ["dictation:pem"] && !String(decoding: pemSearch.json, as: UTF8.self).contains("SYNTHETICPEMBODY")
    && !String(decoding: pemSearch.json, as: UTF8.self).contains("QUJD"), "search reply does not disclose the indexed PEM body")
try seed(.init(id: "dictation:pem-incomplete", kind: .dictation, source: .dictation, tStart: oldTime, tEnd: oldTime,
    body: "before incomplete\n-----BEGIN RSA PRIVATE KEY-----\nSYNTHETICINCOMPLETEPEM"))
let incompleteReply = try service.read(.get, arguments: Data(#"{"id":"dictation:pem-incomplete"}"#.utf8))
let incompleteResult = try JSONDecoder().decode(TPCapturedGetOutput.self, from: incompleteReply.json)
expect(incompleteResult.item.text?.contains("before incomplete") == true
    && incompleteResult.item.text?.contains("SYNTHETICINCOMPLETEPEM") == false
    && incompleteResult.item.text?.contains("PRIVATE KEY") == false, "query get redacts an incomplete PEM block")

if let path = ProcessInfo.processInfo.environment["VF_CAPTURED_QUERY_FIXTURE"] {
    guard path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else { fatalError("fixture output must be temporary") }
    let fixture: [String: Any] = ["json": String(decoding: remote.json, as: UTF8.self),
        "pictures": remote.pictures.map { ["id": $0.id, "data": $0.data.base64EncodedString(), "mimeType": $0.mimeType] },
        "isError": remote.isError]
    try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
}
if failures.isEmpty { print("captured query service: \(assertions) assertions passed; isolated root, GRDB FTS5, native ImageIO, exact source SHA-256 preserved") }
else { failures.forEach { fputs("FAIL: \($0)\n", stderr) }; exit(1) }
