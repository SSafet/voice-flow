import Foundation
import GRDB

// CapturedQuery.get (07 §3.6). One item comes back whole — its text from an
// offset, its marks, its children, its links, its picture and, when the item
// carries one, its context. A picture removed by retention is `picture_gone`
// and the text is still returned.

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
let root = VoiceFlowPaths.shared.configRoot.appendingPathComponent("get", isDirectory: true)
try? files.removeItem(at: root)
try! files.createDirectory(at: root, withIntermediateDirectories: true)
// A real file for the item whose picture is present.
try! files.createDirectory(at: root.appendingPathComponent("captures/shots"), withIntermediateDirectories: true)
try! Data("not really a jpeg".utf8).write(to: root.appendingPathComponent("captures/shots/shot-2026-09-12_14-03-22-118.jpg"))

let pool = try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root))
let index = CapturedIndex(pool: pool)
let tz = TimeZone(secondsFromGMT: 3 * 3600)!
let iso = ISO8601DateFormatter()
iso.timeZone = tz
iso.formatOptions = [.withInternetDateTime]
func at(_ s: String) -> Int { Int(iso.date(from: s)!.timeIntervalSince1970) }
func seed(_ row: CapturedItemRow) { _ = try! index.upsert(row) }

let contextJSON = """
{"app":"Google Chrome","bundleId":"com.google.Chrome","windowTitle":"Pantrella · Admin",
 "url":"pantrella.com/admin/cart",
 "display":{"uuid":"D1","index":2,"widthPt":1440,"heightPt":900,"scale":1},
 "windowBox":[0,0,1440,900],"pointer":[412,220],"private":false}
"""
seed(CapturedItemRow(
    id: "shot:2026-09-12_14-03-22-118", kind: .shot, source: .shot,
    tStart: at("2026-09-12T14:03:22+03:00"), tEnd: at("2026-09-12T14:03:22+03:00"),
    app: "Google Chrome", bundleID: "com.google.Chrome", title: "Pantrella · Admin",
    url: "pantrella.com/admin/cart", display: "2", imgW: 1440, imgH: 900,
    path: "captures/shots/shot-2026-09-12_14-03-22-118.jpg",
    pathClean: "captures/shots/shot-2026-09-12_14-03-22-118.clean.jpg",
    imageState: .present, ocr: "Pantrella cart POST /api/cart 200", ocrState: .done,
    marksJSON: "[{\"n\":1,\"kind\":\"ellipse\",\"color\":\"red\",\"box\":[812,340,220,90],\"stroke\":3,\"underText\":\"upstream request timeout\"},{\"n\":2,\"kind\":\"badge\",\"color\":\"amber\",\"box\":[412,220,24,24],\"center\":[412,220],\"label\":1,\"stroke\":3}]",
    extraJSON: "{\"context\":\(contextJSON.replacingOccurrences(of: "\n", with: ""))}"))
seed(CapturedItemRow(
    id: "activity:2026-08-18T00-00-01", kind: .activity, source: .watcher,
    tStart: at("2026-08-18T00:00:01+03:00"), tEnd: at("2026-08-18T00:02:00+03:00"),
    app: "Google Chrome", title: "Disney+ · Watch", url: "disneyplus.com/browse",
    display: "1", imgW: 1568, imgH: 1014, imageState: .none, ocrState: .na))
for n in 6...8 {
    seed(CapturedItemRow(
        id: "frame:2026-08-18T00-00-\(String(format: "%02d", n))", kind: .frame, source: .watcher,
        tStart: at("2026-08-18T00:00:06+03:00") + (n - 6) * 5,
        tEnd: at("2026-08-18T00:00:06+03:00") + (n - 6) * 5,
        parentID: "activity:2026-08-18T00-00-01", app: "Google Chrome",
        title: "Disney+ · Watch", path: "watcher/2026-08-18/frame-00-00-\(String(format: "%02d", n)).jpg",
        imageState: .present, ocr: "Disney line \(n)", ocrState: .done))
}
// A picture removed by retention: no file, the text still there.
seed(CapturedItemRow(
    id: "frame:2026-07-01T12-00-00", kind: .frame, source: .watcher,
    tStart: at("2026-07-01T12:00:00+03:00"), tEnd: at("2026-07-01T12:00:00+03:00"),
    app: "Ghostty", title: "~/repos/atika", path: "watcher/2026-07-01/frame-12-00-00.jpg",
    imageState: .thinned, ocr: "the text that survives", ocrState: .done))
// A long dictation, for the offset window.
seed(CapturedItemRow(
    id: "dictation:LONG-1", kind: .dictation, source: .dictation,
    tStart: at("2026-09-01T09:00:00+03:00"), tEnd: at("2026-09-01T09:00:00+03:00"),
    body: String(repeating: "a", count: 8_500), ocrState: .na,
    extraJSON: "{\"destination\":\"kept\"}"))
try pool.write { db in
    try db.execute(sql: "INSERT INTO link (item_id, thread_id, turn_id, role, at) VALUES (?,?,?,?,?)",
                   arguments: ["shot:2026-09-12_14-03-22-118", "thr_1", "trn_9", "attached", 5])
}

let query = CapturedQuery(index: index, root: root, timeZone: tz)
let agent = CapturedLimits.agent

enum GetOutcome {
    case item(TPCapturedItem)
    case pictureGone(TPCapturedItem)
    case notFound
}

func get(_ id: String, picture: Bool? = nil, region: [Int]? = nil, offset: Int? = nil,
         includePath: Bool = true) -> GetOutcome? {
    do {
        let output = try query.get(TPCapturedGetInput(id: id, picture: picture, region: region,
                                                      textOffset: offset, variant: nil),
                                   limits: agent, includePath: includePath)
        return .item(output.item)
    } catch let failure as CapturedQueryFailure where failure.error.code == .pictureGone {
        guard let item = failure.item else { failures.append("picture_gone came without the item's text"); return nil }
        return .pictureGone(item)
    } catch let failure as CapturedQueryFailure where failure.error.code == .notFound {
        return .notFound
    } catch {
        failures.append("get threw \(error)")
        return nil
    }
}

func item(_ outcome: GetOutcome?) -> TPCapturedItem? {
    if case .item(let value) = outcome { return value }
    return nil
}

// ── a shot comes back with marks, links, context and a path ───────────────
if let shotValue = item(get("shot:2026-09-12_14-03-22-118")) {
    expect(shotValue.kind == .shot, "the shot's kind came back wrong")
    expect(shotValue.marks.count == 2, "the shot's two marks did not come back")
    expect(shotValue.marks.first?.kind == .ellipse, "a mark's kind did not come back")
    expect(shotValue.marks.first?.underText == "upstream request timeout",
           "the text under a mark did not come back")
    expect(shotValue.marks.last?.label == 1, "a badge's label did not come back")
    expect(shotValue.links.count == 1 && shotValue.links.first?.threadID == "thr_1"
            && shotValue.links.first?.role == .attached,
           "the threads the item is linked to did not come back")
    expect(shotValue.context?.app == "Google Chrome", "the item's context did not come back")
    expect(shotValue.context?.display.index == 2, "the context's display index did not come back")
    expect(shotValue.picture?.width == 1440 && shotValue.picture?.height == 900,
           "the picture's size did not come back")
    expect(shotValue.picture?.state == .present, "the picture's state did not come back")
    expect(shotValue.picture?.path?.hasPrefix(root.path) == true,
           "a caller on the Mac got a picture path that is not absolute: \(shotValue.picture?.path ?? "none")")
    expect(shotValue.text?.contains("Pantrella cart") == true, "the shot's recognised text did not come back")
}

// ── an item with no picture is not asked for one ──────────────────────────
if let plain = item(get("activity:2026-08-18T00-00-01")) {
    expect(plain.picture == nil, "a text-only item grew a picture block")
    expect(plain.durationSeconds == 119, "a span's duration did not come back")
}

// ── children: a span's frames, bounded by the caller's limit ──────────────
if let span = item(get("activity:2026-08-18T00-00-01")) {
    expect(span.children.count == 3, "a span's three frames did not come back: \(span.children.count)")
    expect(span.children.first?.elapsedSeconds == 0, "a child's elapsed seconds did not come back")
    expect(span.children.first?.id == "frame:2026-08-18T00-00-06", "the children are not in order")
}

// ── a caller with no file access gets no path ─────────────────────────────
if let remote = item(get("shot:2026-09-12_14-03-22-118", includePath: false)) {
    expect(remote.picture?.path == nil, "an off-Mac caller was handed a file path")
    expect(remote.picture?.state == .present, "the picture's state is still reported without a path")
}

// ── text is windowed from an offset ───────────────────────────────────────
if let first = item(get("dictation:LONG-1", offset: 0)), let later = item(get("dictation:LONG-1", offset: 8_000)) {
    expect(first.textTotal == 8_500, "textTotal is not the whole text's length")
    expect(first.text?.count == 8_000, "text is not cut at 8,000 characters")
    expect(later.text?.count == 500, "an offset did not continue the text")
    expect(later.text != first.text, "the offset returned the same text")
}

// ── a picture removed by retention is picture_gone, with its text ─────────
if case .pictureGone(let gone)? = get("frame:2026-07-01T12-00-00") {
    expect(gone.text?.contains("the text that survives") == true,
           "picture_gone did not still return the text")
    expect(gone.picture?.state == .thinned, "picture_gone did not say why the picture is gone")
} else {
    failures.append("a thinned picture was returned as a picture")
}

// ── an item that does not exist is not_found ──────────────────────────────
if case .notFound? = get("frame:2020-01-01T00-00-00") {
    // the named refusal, as it must be
} else {
    failures.append("not_found did not come back as a named refusal")
}

finish("captured get")
