import Foundation

// AttachmentPackager.record(from:provider:threadID:at:newID:). A draft becomes
// the thread store's Attachment record, and the bytes stay on this Mac: the
// state is on_home, never uploaded, because upload happens when the carrying
// item is mirrored. The capture side is a fake provider; no database is used.

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
    var files: [String: Data] = [:]
    func item(id: String) throws -> CapturedAttachmentItem? {
        guard id.contains(":") else { throw CapturedPackagingError.invalidItem(id) }
        return items[id]
    }
    func frames(bundleID: String) throws -> [CapturedAttachmentItem] { [] }
    func data(relativePath: String) throws -> Data {
        guard let data = files[relativePath] else { throw CapturedPackagingError.notFound(relativePath) }
        return data
    }
    func writeDerived(relativePath: String, data: Data) throws { files[relativePath] = data }
}

let hello = Data("hello".utf8)
let helloHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
let base = "http://localhost:8792/captured"
let display = TPContextDisplay(heightPt: 1080, index: 1, scale: 2, uuid: "D-1", widthPt: 1920)
let context = TPContext(app: "Chrome", bundleID: "com.google.Chrome", display: display,
                        pointer: nil, contextPrivate: false, url: nil, windowBox: nil,
                        windowTitle: "pantrella")
let mark = TPMark(box: [1, 2, 3, 4], center: nil, color: .amber, from: nil, kind: .rect,
                  label: nil, n: 1, note: nil, origin: nil, points: nil, stroke: 2, to: nil, underText: nil)

let provider = FakeProvider()
let shotID = "shot:2026-09-12_14-03-22-118"
let shotPath = "captures/shots/shot-2026-09-12_14-03-22-118.jpg"
provider.items[shotID] = CapturedAttachmentItem(
    id: shotID, kind: .shot, source: .shot, path: shotPath, pathClean: nil, bytes: hello.count,
    width: 3840, height: 2160, marks: [mark], context: context, text: nil,
    app: "Chrome", title: "pantrella", url: nil, imageState: .present, tStart: 1, parentID: nil)
provider.files[shotPath] = hello

let shotDrafts = try AttachmentPackager.package(captureId: shotID, base: base, provider: provider)
let at = Date(timeIntervalSince1970: 1_700_000_000)
let record = try AttachmentPackager.record(
    from: shotDrafts[0], provider: provider, threadID: "thread-1", at: at, newID: { "attachment-1" })

expect(record.id == "attachment-1", "the record takes the id the caller mints")
expect(record.threadID == "thread-1", "the record carries the thread it was made for")
expect(record.sha256 == helloHash, "the record carries the SHA-256 of the file's bytes")
expect(record.sizeBytes == 5, "the record carries the file's byte count")
expect(record.createdAt.hasSuffix("Z"), "createdAt is an ISO 8601 UTC timestamp")
expect(record.bytes.state == .onHome, "bytes are on this Mac before the item is mirrored")
expect(record.bytes.artifactID == nil, "no artifact is named before an upload")
expect(record.kind == .annotatedScreenshot, "the kind travels from the draft")
expect(record.captureID == shotID, "the captureId travels from the draft")
expect(record.marks == [mark], "the marks travel from the draft")
expect(record.context == context, "the context travels from the draft")
expect(record.width == 3840 && record.height == 2160, "the picture's size travels from the draft")
expect(record.forModel == nil, "an absent forModel stays absent, which means true")
ok("record turns a draft into an on_home Attachment with the file's hash")

// A bundle's manifest draft resolves to the derived file written for it.
let bundleID = "capture:2026-08-05_01-37-43"
provider.items[bundleID] = CapturedAttachmentItem(
    id: bundleID, kind: .capture, source: .bundle, path: nil, pathClean: nil, bytes: nil, width: nil,
    height: nil, marks: [], context: nil, text: "narration", app: nil, title: nil,
    url: nil, imageState: .present, tStart: 1, parentID: nil)
let bundleDrafts = try AttachmentPackager.package(captureId: bundleID, base: base, provider: provider)
let derivedPath = AttachmentPackager.derivedPath(for: bundleDrafts[0])
provider.files[derivedPath] = hello
let manifestRecord = try AttachmentPackager.record(
    from: bundleDrafts[0], provider: provider, threadID: "thread-1", at: at, newID: { "attachment-2" })
expect(manifestRecord.sha256 == helloHash, "a manifest record hashes the derived manifest file")
expect(manifestRecord.bytes.state == .onHome, "a manifest's bytes are on this Mac too")

// A draft whose file cannot be read is refused by name.
let missing = TPAttachmentDraft(
    bytes: 5, captureID: "shot:2026-01-01_00-00-00-000", context: nil, forModel: nil, height: nil,
    id: "shot:2026-01-01_00-00-00-000", kind: .image, marks: nil, mime: "image/jpeg",
    modelText: nil, name: "gone.jpg", url: "\(base)/picture?id=x", width: nil)
var refused = false
do { _ = try AttachmentPackager.record(from: missing, provider: provider, threadID: "t", at: at, newID: { "a" }) }
catch let error as CapturedPackagingError {
    if case .notFound = error { refused = true }
} catch {}
expect(refused, "a draft whose item is gone is refused with notFound")
ok("record refuses a draft whose item is gone")

print("attachment records tests passed")
