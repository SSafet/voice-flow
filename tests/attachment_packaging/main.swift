import Foundation

// AttachmentPackager.package(captureId:base:provider:) and BundleModelText.
// The capture side is a fake provider, so this suite needs no database and no
// GRDB; it needs S3's MarkModelText for a shot's modelText.

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
        if try !condition() {
            FileHandle.standardError.write(Data(("not ok - " + message + "\n").utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data(("not ok - \(message): \(error)\n").utf8))
        exit(1)
    }
}
func ok(_ message: String) { print("ok - " + message) }

final class FakeProvider: CapturedItemProvider {
    var items: [String: CapturedAttachmentItem] = [:]
    var bundleFrames: [String: [CapturedAttachmentItem]] = [:]
    var files: [String: Data] = [:]
    var derived: [String: Data] = [:]

    func item(id: String) throws -> CapturedAttachmentItem? {
        guard id.contains(":") else { throw CapturedPackagingError.invalidItem(id) }
        return items[id]
    }
    func frames(bundleID: String) throws -> [CapturedAttachmentItem] { bundleFrames[bundleID] ?? [] }
    func data(relativePath: String) throws -> Data {
        guard let data = files[relativePath] else { throw CapturedPackagingError.notFound(relativePath) }
        return data
    }
    func writeDerived(relativePath: String, data: Data) throws { derived[relativePath] = data }
}

let base = "http://localhost:8792/captured"
let display = TPContextDisplay(heightPt: 1080, index: 1, scale: 2, uuid: "D-1", widthPt: 1920)
func context(app: String = "Chrome", title: String? = "pantrella.com/admin", url: String? = "https://pantrella.com/admin") -> TPContext {
    TPContext(app: app, bundleID: "com.google.Chrome", display: display,
              pointer: nil, contextPrivate: false, url: url, windowBox: nil, windowTitle: title)
}
func mark(n: Int, label: Int) -> TPMark {
    TPMark(box: [10, 10, 30, 30], center: [25, 25], color: .red, from: nil,
           kind: .badge, label: label, n: n, note: nil, origin: nil, points: nil,
           stroke: 3, to: nil, underText: nil)
}

let shotID = "shot:2026-09-12_14-03-22-118"
let shotPath = "captures/shots/shot-2026-09-12_14-03-22-118.jpg"
let shotClean = "captures/shots/shot-2026-09-12_14-03-22-118.clean.jpg"

let provider = FakeProvider()
provider.items[shotID] = CapturedAttachmentItem(
    id: shotID, kind: .shot, source: .shot, path: shotPath, pathClean: shotClean,
    bytes: 4096, width: 3840, height: 2160,
    marks: [mark(n: 1, label: 2), mark(n: 2, label: 3)],
    context: context(), text: nil, app: "Chrome", title: "pantrella.com/admin",
    url: "https://pantrella.com/admin", imageState: .present, tStart: 100, parentID: nil)
provider.files[shotPath] = Data(repeating: 0x01, count: 4096)

let shotDrafts = try AttachmentPackager.package(captureId: shotID, base: base, provider: provider)
expect(shotDrafts.count == 1, "a shot becomes one draft")
let shotDraft = shotDrafts[0]
expect(shotDraft.kind == .annotatedScreenshot, "a shot's draft kind is annotated_screenshot")
expect(shotDraft.captureID == shotID, "the draft carries the shot's captureId")
expect(shotDraft.id == shotID, "a draft's id is its captureId")
expect(shotDraft.name == "shot-2026-09-12_14-03-22-118.jpg", "the draft name is the file's name")
expect(shotDraft.mime == "image/jpeg", "a shot's draft is image/jpeg")
expect(shotDraft.bytes == 4096, "the draft carries the file's byte count")
expect(shotDraft.width == 3840 && shotDraft.height == 2160, "the draft carries the picture's size")
expect(shotDraft.marks?.count == 2, "the draft carries the shot's marks")
expect(shotDraft.forModel == nil, "a shot's forModel is absent, which means true")
expect(shotDraft.url == "\(base)/picture?id=shot%3A2026-09-12_14-03-22-118&variant=marked",
       "the draft url is the item's picture address with an encoded id, got \(shotDraft.url)")
expect(shotDraft.modelText?.contains(shotID) == true, "the shot's modelText names the shot")
expect(shotDraft.modelText?.contains("badge") == true, "the shot's modelText describes its marks")
ok("package turns a shot into one annotated_screenshot draft")

// ── a capture bundle is one manifest plus one image per frame ───────────────
let bundleID = "capture:2026-08-05_01-37-43"
let frameIDs = (1...3).map { String(format: "capture:2026-08-05_01-37-43/%02d", $0) }
let frames = frameIDs.enumerated().map { index, id in
    CapturedAttachmentItem(
        id: id, kind: .frame, source: .bundle,
        path: "captures/2026-08-05_01-37-43/frames/frame-\(index + 1).jpg",
        pathClean: nil, bytes: 100 + index, width: 1568, height: 1014,
        marks: index == 0 ? [mark(n: 1, label: 1)] : [],
        context: context(title: "window \(index + 1)"),
        text: nil, app: "Chrome", title: "window \(index + 1)", url: nil,
        imageState: .present, tStart: 200 + index * 30, parentID: bundleID)
}
provider.items[bundleID] = CapturedAttachmentItem(
    id: bundleID, kind: .capture, source: .bundle, path: nil, pathClean: nil, bytes: nil,
    width: nil, height: nil, marks: [], context: context(), text: "we fixed the deploy",
    app: "Chrome", title: "pantrella.com/admin", url: nil,
    imageState: .present, tStart: 200, parentID: nil)
provider.bundleFrames[bundleID] = frames
for frame in frames { provider.files[frame.path!] = Data(repeating: 0x02, count: frame.bytes ?? 0) }

let bundleDrafts = try AttachmentPackager.package(captureId: bundleID, base: base, provider: provider)
expect(bundleDrafts.count == 4, "a three-frame bundle is one manifest plus three images")
let manifest = bundleDrafts[0]
expect(manifest.kind == .captureBundle, "the first draft is the manifest, kind capture_bundle")
expect(manifest.mime == "application/json", "the manifest is JSON")
expect(manifest.name == "capture:2026-08-05_01-37-43-manifest.json", "the manifest is named for the bundle")
expect(manifest.captureID == bundleID, "the manifest carries the bundle's captureId")
let images = Array(bundleDrafts.dropFirst())
expect(images.map(\.captureID) == frameIDs, "the frame drafts come in frame order")
expect(images.allSatisfy { $0.kind == .image }, "every frame draft is an image")
expect(images[0].marks?.count == 1, "a frame's marks travel on its own draft")
expect(bundleDrafts.allSatisfy { $0.forModel != false },
       "no frame of a three-frame bundle is kept from the model")
let manifestPath = "captures/derived/capture:2026-08-05_01-37-43/manifest.json"
let manifestData = provider.derived[manifestPath]
expect(manifestData != nil, "the manifest is written under captures/derived/")
if let manifestData, let object = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] {
    expect(object["narration"] as? String == "we fixed the deploy", "the manifest carries the narration")
    expect((object["frames"] as? [Any])?.count == 3, "the manifest carries one entry per frame")
} else {
    expect(false, "the manifest is a JSON object")
}
expect(manifest.modelText?.contains("we fixed the deploy") == true, "the bundle modelText carries the narration")
expect(images[0].url == "\(base)/picture?id=capture%3A2026-08-05_01-37-43%2F01&variant=marked",
       "a frame's url encodes the slash in its id, got \(images[0].url)")
ok("a capture bundle is one manifest attachment plus one image per frame")

// ── at most twelve frames go to the model, chosen by context change first ────
let many = (1...20).map { index in
    CapturedAttachmentItem(
        id: String(format: "capture:2026-08-05_01-37-43/%02d", index), kind: .frame, source: .bundle,
        path: "captures/2026-08-05_01-37-43/frames/frame-\(index).jpg",
        pathClean: nil, bytes: 10, width: 10, height: 10, marks: [],
        context: context(title: "same", url: nil), text: nil,
        app: "Chrome", title: "same", url: nil, imageState: .present,
        tStart: index, parentID: bundleID)
}
let chosen = BundleModelText.forModelFrames(frames: many)
expect(chosen.count == 12, "exactly twelve of twenty frames go to the model, got \(chosen.count)")
expect(chosen.first == many[0].id, "the first frame always goes to the model")
expect(chosen.last == many[19].id, "even spacing reaches the last frame")
expect(Set(chosen).count == 12, "no frame is chosen twice")

let changing = (1...15).map { index in
    CapturedAttachmentItem(
        id: String(format: "capture:2026-08-05_01-37-43/%02d", index), kind: .frame, source: .bundle,
        path: nil, pathClean: nil, bytes: 10, width: 10, height: 10, marks: [],
        context: context(title: index == 15 ? "different" : "same", url: nil), text: nil,
        app: "Chrome", title: index == 15 ? "different" : "same", url: nil,
        imageState: .present, tStart: index, parentID: bundleID)
}
let changingChosen = BundleModelText.forModelFrames(frames: changing)
expect(changingChosen.contains(changing[0].id), "the first frame of a changing bundle goes to the model")
expect(changingChosen.contains(changing[14].id),
       "the frame where the context first changes goes to the model")
ok("forModelFrames honours the context change before even spacing")

provider.bundleFrames[bundleID] = many
for frame in many { provider.files[frame.path!] = Data(repeating: 0x04, count: 10) }
let manyDrafts = try AttachmentPackager.package(captureId: bundleID, base: base, provider: provider)
let manyFrames = Array(manyDrafts.dropFirst())
expect(manyDrafts.count == 21, "a twenty-frame bundle is one manifest plus twenty images")
expect(manyFrames.filter { $0.forModel != false }.count == 12,
       "at most twelve frames go to the model")
expect(manyFrames.filter { $0.forModel == false }.count == 8, "the rest are kept from the model")
if let firstFalse = manyFrames.first(where: { $0.forModel == false }) {
    expect(manyDrafts[0].modelText?.contains(firstFalse.captureID) == true,
           "a frame kept from the model is listed in the manifest's modelText with its id")
} else {
    expect(false, "twenty frames leave eight out of the model")
}
ok("a bundle sends twelve frames at most and lists the rest with their ids")

// ── a plain picture, and an item with no picture ────────────────────────────
let frameID = "frame:2026-08-18T00-00-06"
provider.items[frameID] = CapturedAttachmentItem(
    id: frameID, kind: .frame, source: .watcher, path: "watcher/2026-08-18/frame-00-00-06.jpg",
    pathClean: nil, bytes: 10, width: 1568, height: 1014, marks: [],
    context: nil, text: nil, app: "Ghostty", title: nil, url: nil,
    imageState: .present, tStart: 1, parentID: nil)
provider.files["watcher/2026-08-18/frame-00-00-06.jpg"] = Data(repeating: 0x03, count: 10)
let frameDrafts = try AttachmentPackager.package(captureId: frameID, base: base, provider: provider)
expect(frameDrafts.count == 1 && frameDrafts[0].kind == .image, "a watcher frame is one image draft")
expect(frameDrafts[0].context == nil, "a frame with no stored context carries none")

let dictationID = "dictation:0f5a9c1e"
provider.items[dictationID] = CapturedAttachmentItem(
    id: dictationID, kind: .dictation, source: .dictation, path: nil, pathClean: nil, bytes: nil,
    width: nil, height: nil, marks: [], context: nil, text: "ask Georgi about the VAT threshold",
    app: nil, title: nil, url: nil, imageState: .none, tStart: 5, parentID: nil)
let textDrafts = try AttachmentPackager.package(captureId: dictationID, base: base, provider: provider)
expect(textDrafts.count == 1 && textDrafts[0].kind == .file, "a dictation is one file draft")
expect(textDrafts[0].mime == "text/markdown", "a text item's draft is text/markdown")
expect(textDrafts[0].modelText == nil, "a text item carries no modelText of its own")
expect(textDrafts[0].url == "\(base)/text?id=dictation%3A0f5a9c1e",
       "a text item's url is its text address, got \(textDrafts[0].url)")
expect(provider.derived["captures/derived/dictation:0f5a9c1e.md"] != nil,
       "the text item's file is written under captures/derived/")
ok("a picture becomes an image draft and a picture-less item a text file draft")

// ── refusals by name ────────────────────────────────────────────────────────
let goneID = "shot:2026-01-01_00-00-00-000"
provider.items[goneID] = CapturedAttachmentItem(
    id: goneID, kind: .shot, source: .shot, path: "captures/shots/gone.jpg", pathClean: nil,
    bytes: 1, width: 1, height: 1, marks: [], context: nil, text: nil,
    app: nil, title: nil, url: nil, imageState: .missing, tStart: 0, parentID: nil)
var refusedGone = false
do { _ = try AttachmentPackager.package(captureId: goneID, base: base, provider: provider) }
catch let error as CapturedPackagingError {
    if case .pictureGone(let id) = error { refusedGone = id == goneID }
} catch {}
expect(refusedGone, "a thinned or missing picture is refused with pictureGone")
var refusedMissing = false
do { _ = try AttachmentPackager.package(captureId: shotID + "-x", base: base, provider: provider) }
catch let error as CapturedPackagingError {
    if case .notFound = error { refusedMissing = true }
} catch {}
expect(refusedMissing, "an unknown item is refused with notFound")
ok("package refuses a gone picture and an unknown item by name")

print("attachment packaging tests passed")
