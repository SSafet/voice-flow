import Foundation
import GRDB

// The link table in the captured index, the reverse path lookup, the bundle
// frame read, and the rebuild from the thread store's attachment rows.
// CapturedIndex.link, CapturedIndex.itemID(forPath:dataRoot:),
// CapturedIndex.attachmentFrames(bundleID:), CapturedLinkRebuilder.
// The thread side is a fake, so this suite needs S1's index and GRDB only.

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

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("attachment-links-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let pool = try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root))
let index = CapturedIndex(pool: pool)

let shotID = "shot:2026-09-12_14-03-22-118"
let shotPath = "captures/shots/shot-2026-09-12_14-03-22-118.jpg"
let shotClean = "captures/shots/shot-2026-09-12_14-03-22-118.clean.jpg"
let bundleID = "capture:2026-08-05_01-37-43"
let frameOne = "capture:2026-08-05_01-37-43/07"
let frameTwo = "capture:2026-08-05_01-37-43/08"

try index.upsert(CapturedItemRow(
    id: shotID, kind: .shot, source: .shot, tStart: 100, tEnd: 100,
    path: shotPath, pathClean: shotClean, bytes: 10, imageState: .present))
try index.upsert(CapturedItemRow(
    id: bundleID, kind: .capture, source: .bundle, tStart: 200, tEnd: 260))
try index.upsert(CapturedItemRow(
    id: frameOne, kind: .frame, source: .bundle, tStart: 200, tEnd: 200,
    parentID: bundleID, path: "captures/2026-08-05_01-37-43/frames/frame-01-t000s.jpg",
    bytes: 20, imageState: .present))
try index.upsert(CapturedItemRow(
    id: frameTwo, kind: .frame, source: .bundle, tStart: 230, tEnd: 230,
    parentID: bundleID, path: "captures/2026-08-05_01-37-43/frames/frame-02-t030s.jpg",
    bytes: 30, imageState: .present))

// ── link writes one row, and the same tuple twice is one row ────────────────
try index.link(itemIDs: [shotID], threadID: "t1", turnID: "u1", role: .sent, at: 100)
expect(try index.links(itemID: shotID).count == 1, "one link after link()")
ok("link writes one row")
try index.link(itemIDs: [shotID], threadID: "t1", turnID: "u1", role: .sent, at: 100)
expect(try index.links(itemID: shotID).count == 1, "linking the same tuple twice is still one row")
ok("link is idempotent for the same tuple")

try index.link(itemIDs: [shotID], threadID: "t2", turnID: "u9", role: .attached, at: 101)
let shotLinks = try index.links(itemID: shotID)
expect(shotLinks.count == 2, "a second thread adds a second link, not replaces the first")
expect(shotLinks.contains { $0.threadID == "t1" && $0.turnID == "u1" && $0.role == .sent },
       "the sent link keeps its role and turn")
expect(shotLinks.contains { $0.threadID == "t2" && $0.role == .attached }, "the attached link is there")
ok("a second thread keeps both links")

try index.link(itemIDs: [frameOne, frameTwo], threadID: "t2", turnID: "u9", role: .attached, at: 102)
expect(try index.linkedItemIDs().contains(shotID), "linkedItemIDs has a linked shot")
expect(try index.linkedItemIDs().contains(frameOne), "linkedItemIDs has a linked frame")
expect(try index.linkedItemIDs().contains("activity:2026-08-18T00-00-01") == false,
       "linkedItemIDs has nothing that was never linked")
ok("linkedItemIDs is the exemption set")

// ── unlink removes one thread, never another's rows ─────────────────────────
try index.unlink(threadID: "t1")
expect(try index.links(itemID: shotID).count == 1, "unlink removes only the named thread's links")
expect(try index.links(itemID: shotID).first?.threadID == "t2", "the other thread's link survives")
try index.unlink(threadID: "t1")
expect(try index.links(itemID: shotID).count == 1, "unlink is idempotent")
ok("unlink removes exactly one thread's links, idempotently")

// ── an invalid id is refused, and nothing is written ────────────────────────
var refusedInvalid = false
do {
    try index.link(itemIDs: ["frame-not-an-id"], threadID: "t1", turnID: "u1", role: .sent, at: 1)
} catch let error as CapturedStoreError {
    if case .invalidItemID = error { refusedInvalid = true }
} catch {
    FileHandle.standardError.write(Data("not ok - link threw the wrong error: \(error)\n".utf8))
    exit(1)
}
expect(refusedInvalid, "link refuses an item id that fails CapturedItemID.isValid")
expect(try index.links(itemID: "frame-not-an-id").isEmpty, "the refused link wrote nothing")
ok("link refuses an invalid item id by name")

// ── the reverse path lookup ─────────────────────────────────────────────────
expect(try index.itemID(forPath: shotPath, dataRoot: root) == shotID,
       "the marked path resolves to its shot")
expect(try index.itemID(forPath: shotClean, dataRoot: root) == shotID,
       "the clean path resolves to the same shot")
expect(try index.itemID(forPath: root.appendingPathComponent(shotPath).path, dataRoot: root) == shotID,
       "an absolute path under the data root resolves")
expect(try index.itemID(forPath: "captures/shots/absent.jpg", dataRoot: root) == nil,
       "an unknown path resolves to nothing rather than throwing")
expect(try index.itemID(forPath: "not/even/under/the/root.jpg", dataRoot: root) == nil,
       "a path outside the data root resolves to nothing")
ok("itemID(forPath:dataRoot:) resolves marked, clean, absolute and unknown paths")

// ── the bundle frame read, in frame order ───────────────────────────────────
let frames = try index.attachmentFrames(bundleID: bundleID)
expect(frames.map(\.id) == [frameOne, frameTwo], "bundle frames come back in id order")
expect(try index.attachmentFrames(bundleID: shotID).isEmpty, "a shot has no frames")
ok("attachmentFrames returns only the bundle's frames, in frame order")

// ── rebuild replaces the link table with the thread store's set ─────────────
struct FakeSource: ThreadAttachmentSource {
    var live: [String: [ThreadAttachmentRef]]
    func liveThreadIDs() throws -> [String] { live.keys.sorted() }
    func attachments(threadID: String) throws -> [ThreadAttachmentRef] { live[threadID] ?? [] }
}

let shotRef = ThreadAttachmentRef(threadID: "t7", itemID: "m1", captureID: shotID, turnID: nil)
let frameRef = ThreadAttachmentRef(threadID: "t7", itemID: nil, captureID: frameOne, turnID: nil)
var source = FakeSource(live: ["t7": [shotRef, frameRef]])

let first = try CapturedLinkRebuilder.rebuild(index: index, source: source)
expect(first.linked == 2, "rebuild links the two attachments of the live thread")
expect(try index.linkedItemIDs() == Set([shotID, frameOne]),
       "rebuild replaces the whole link table with the derived set")
ok("rebuild derives the link table from the thread store")

let afterFirst = try index.links(itemID: shotID)
let second = try CapturedLinkRebuilder.rebuild(index: index, source: source)
expect(second.linked == 2 && second.removed == 2,
       "a rebuild after a rebuild replaces the two rows it wrote, not more")
expect(second.threads == 1, "the rebuild reports the one live thread")
expect(try index.links(itemID: shotID) == afterFirst,
       "rebuild run twice leaves the same rows")
ok("rebuild is idempotent")

source.live = ["t7": [frameRef]]
_ = try CapturedLinkRebuilder.rebuild(index: index, source: source)
expect(try index.linkedItemIDs() == Set([frameOne]),
       "an attachment removed from the store loses its link on the next rebuild")
ok("rebuild removes a link whose attachment is gone")

try CapturedLinkRebuilder.threadDeleted(threadID: "t7", index: index)
expect(try index.linkedItemIDs().isEmpty, "the thread-deleted signal removes that thread's links")
ok("threadDeleted unlinks the thread")

print("attachment links tests passed")
