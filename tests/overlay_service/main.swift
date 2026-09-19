import Cocoa
import CoreGraphics

// OverlayService — the one way an agent puts anything on the screen (07 §3.8).
// Validation is all-or-nothing and reports the refused mark by number; owner-
// ship is the thread id; display identity comes from the shot, never from a
// per-session variable; only OverlayService's own files are ever drawn, so a
// JSON file written into overlays/ by hand does nothing.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("s3-overlays-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

// The primary is 800×600 px (800 pt at scale 1); the laptop is 1024×768 px
// (512 pt at scale 2).
let primary = OverlayDisplay(uuid: "A", index: 1, widthPt: 800, heightPt: 600, scale: 1,
                             visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600))
let laptop = OverlayDisplay(uuid: "B", index: 2, widthPt: 512, heightPt: 384, scale: 2,
                            visibleFrame: NSRect(x: 800, y: 0, width: 512, height: 384))
var attached = [primary, laptop]
let service = OverlayService(directory: root, displays: { attached }, host: HeadlessOverlayWindowHost())

let shotA = OverlayShot(id: "shot:2026-09-18_14-03-22-118", width: 800, height: 600, displayUUID: "A")
let shotB = OverlayShot(id: "shot:2026-09-18_14-03-25-001", width: 1024, height: 768, displayUUID: "B")

let t1 = OverlayOwner(threadID: "01J8ZK3F9A2C00000000000000")
let t2 = OverlayOwner(threadID: "01J8ZK3F9A2C00000000000001")

func rect(_ box: [Int], n: Int? = nil, color: TPMarkColor = .red) -> TPDrawMark {
    TPDrawMark(box: box, center: nil, color: color, from: nil, kind: .rect, label: nil, n: n,
               note: nil, origin: nil, points: nil, stroke: 4, to: nil, underText: nil)
}
func arrow(from: [Int]?, to: [Int]?, n: Int? = nil) -> TPDrawMark {
    TPDrawMark(box: [50, 50, 100, 80], center: nil, color: .red, from: from, kind: .arrow,
               label: nil, n: n, note: nil, origin: nil, points: nil, stroke: 4, to: to, underText: nil)
}
func drawInput(_ marks: [TPDrawMark], on: String) -> TPScreenDrawInput {
    TPScreenDrawInput(layer: nil, marks: marks, on: on, replace: nil)
}
func shapesOverlays(_ owner: OverlayOwner) -> [TPOverlaySummary] {
    service.list(owner: owner).overlays.filter { $0.kind == .shapes }
}

// A valid draw lands on the shot's display, at the shot's scale.
let first = service.draw(drawInput([arrow(from: [50, 50], to: [150, 130])], on: shotA.id), shot: shotA, owner: t1)
guard case let .success(firstOutput) = first else { fail("a valid arrow is drawn: \(first)") }
expect(firstOutput.drawn == 1 && firstOutput.totalInLayer == 1, "one mark drawn, one in the layer")
expect(firstOutput.visible && firstOutput.display == "A", "the shape lands on the shot's display: \(firstOutput.display)")
expect(shapesOverlays(t1).count == 1, "one shapes overlay exists")
expect(service.visibleIDs.count == 1, "one overlay is visible")
expect(shapesOverlays(t1).first?.display == "A", "the overlay records the shot's display")
guard let layerID = shapesOverlays(t1).first?.id else { fail("the layer has an id") }

// Adding to the layer appends; replace replaces.
let second = service.draw(drawInput([rect([200, 200, 60, 60])], on: shotA.id), shot: shotA, owner: t1)
guard case let .success(secondOutput) = second else { fail("a second mark is drawn: \(second)") }
expect(secondOutput.drawn == 1 && secondOutput.totalInLayer == 2, "the second mark joins the layer: \(secondOutput.totalInLayer)")
let replaceInput = TPScreenDrawInput(layer: nil, marks: [rect([10, 10, 20, 20])], on: shotA.id, replace: true)
guard case let .success(replaced) = service.draw(replaceInput, shot: shotA, owner: t1) else {
    fail("replace is accepted")
}
expect(replaced.totalInLayer == 1, "replace leaves one mark in the layer: \(replaced.totalInLayer)")

// A coordinate outside the picture is refused, nothing is drawn, and the
// refusal names the mark by number.
let beforeRefusal = service.list(owner: t1).overlays.count
let outside = service.draw(drawInput([rect([900, 900, 10, 10])], on: shotA.id), shot: shotA, owner: t1)
guard case let .failure(outsideError) = outside else { fail("a coordinate outside the picture is refused") }
expect(outsideError.code == .invalidArguments, "the refusal is invalid_arguments: \(outsideError.code)")
expect(outsideError.problems?.contains(where: { $0.n == 1 }) == true,
       "the refusal names mark 1: \(String(describing: outsideError.problems))")
expect(service.list(owner: t1).overlays.count == beforeRefusal, "the refusal drew nothing")

// The `on` id must be a shot: id; a watcher frame has a different geometry.
let frameShot = OverlayShot(id: "frame:2026-08-18T00-00-06", width: 800, height: 600, displayUUID: "A")
let notAShot = service.draw(drawInput([rect([10, 10, 20, 20])], on: frameShot.id), shot: frameShot, owner: t1)
guard case let .failure(shotError) = notAShot else { fail("a frame id is refused") }
expect(shotError.message.contains("shot:"), "the refusal says on must be a shot: id: \(shotError.message)")

// A kind missing its own fields is refused by the mark rule.
let badArrow = service.draw(drawInput([arrow(from: nil, to: [150, 130])], on: shotA.id), shot: shotA, owner: t1)
guard case let .failure(arrowError) = badArrow else { fail("an arrow without from is refused") }
expect(arrowError.problems?.contains(where: { $0.n == 1 }) == true,
       "the arrow refusal names mark 1: \(String(describing: arrowError.problems))")

// More than 40 marks is refused all together.
let many = service.draw(drawInput((1...41).map { rect([$0, 10, 5, 5]) }, on: shotA.id), shot: shotA, owner: t1)
guard case let .failure(manyError) = many else { fail("41 marks are refused") }
expect(manyError.code == .invalidArguments, "the batch refusal is invalid_arguments")

// Ownership: t2 sees nothing, removes nothing, and cannot remove t1's overlay.
expect(service.list(owner: t2).overlays.isEmpty, "another thread sees no overlays")
guard case let .success(t2Remove) = service.remove(TPScreenRemoveInput(allMine: true, id: nil, layer: nil), owner: t2) else {
    fail("removing nothing is not an error")
}
expect(t2Remove.removed == 0, "another thread removes nothing")
guard case let .success(t2ByID) = service.remove(TPScreenRemoveInput(allMine: nil, id: layerID, layer: nil), owner: t2) else {
    fail("removing by id is answered")
}
expect(t2ByID.removed == 0, "another thread cannot remove t1's overlay")
expect(service.list(owner: t1).overlays.count == beforeRefusal, "t1's overlay is untouched")

// Exactly one of id, layer and allMine is required.
guard case .failure = service.remove(TPScreenRemoveInput(allMine: nil, id: layerID, layer: "default"), owner: t1) else {
    fail("id and layer together are refused")
}
guard case .failure = service.remove(TPScreenRemoveInput(allMine: nil, id: nil, layer: nil), owner: t1) else {
    fail("removing nothing by name is refused")
}
guard case let .success(removedOwn) = service.remove(TPScreenRemoveInput(allMine: true, id: nil, layer: nil), owner: t1) else {
    fail("allMine removes t1's own overlay")
}
expect(removedOwn.removed == 1, "t1's one overlay is removed: \(removedOwn.removed)")
expect(service.list(owner: t1).overlays.isEmpty, "nothing of t1's is left")
expect(service.visibleIDs.isEmpty, "nothing is visible after removal")

// A JSON file written into overlays/ by hand draws nothing: only OverlayService
// writes and reads overlay files (07 §3.8).
let handWritten = """
{"type":"annotations","visible":true,"items":[{"type":"rect","rect":[10,10,200,200],"color":"red"}]}
"""
try Data(handWritten.utf8).write(to: root.appendingPathComponent("hand.json"))
service.reload()
expect(service.list(owner: t1).overlays.isEmpty, "a hand-written file is not an overlay")
expect(!service.visibleIDs.contains("hand"), "a hand-written file is not visible")
expect(!service.visibleIDs.contains(where: { $0.contains("hand") }), "no hand-written overlay is drawn")
try? FileManager.default.removeItem(at: root.appendingPathComponent("hand.json"))
service.reload()

// Display identity comes from the shot: a draw on the secondary display stays
// on the secondary display, without a per-session variable.
let onLaptop = service.draw(drawInput([arrow(from: [100, 100], to: [400, 400])], on: shotB.id), shot: shotB, owner: t2)
guard case let .success(laptopOutput) = onLaptop else { fail("drawing on the second display is accepted") }
expect(laptopOutput.display == "B", "the arrow lands on the secondary display: \(laptopOutput.display)")
expect(service.list(owner: t2).overlays.first?.display == "B", "the overlay records B")

// An unplugged display removes the shapes computed for it, and a stale shot is
// refused with advice to take a new screenshot.
attached = [primary]
service.reload()
expect(service.list(owner: t2).overlays.isEmpty, "unplugging the display removes its shapes")
expect(service.visibleIDs.isEmpty, "nothing stays visible for the unplugged display")
let stale = service.draw(drawInput([rect([10, 10, 20, 20])], on: shotB.id), shot: shotB, owner: t2)
guard case let .failure(staleError) = stale else { fail("a shot on an unplugged display is refused") }
expect(staleError.message.contains("take a new screenshot"),
       "the refusal says to take a new screenshot: \(staleError.message)")

// A display that changed size invalidates the shot's geometry too.
attached = [primary, OverlayDisplay(uuid: "B", index: 2, widthPt: 640, heightPt: 480, scale: 2,
                                    visibleFrame: NSRect(x: 800, y: 0, width: 640, height: 480))]
let resized = service.draw(drawInput([rect([10, 10, 20, 20])], on: shotB.id), shot: shotB, owner: t2)
guard case let .failure(resizedError) = resized else { fail("a resized display invalidates the shot") }
expect(resizedError.message.contains("take a new screenshot"), "the resize refusal says so: \(resizedError.message)")
attached = [primary, OverlayDisplay(uuid: "B", index: 2, widthPt: 512, heightPt: 384, scale: 2,
                                    visibleFrame: NSRect(x: 800, y: 0, width: 512, height: 384))]

// Guides and panels: a guide carries steps, a panel carries blocks, fields
// omitted on an update stay, and a panel is placed on its own display.
let guideInput = TPScreenPanelInput(
    activeStep: 1, blocks: nil, display: nil, id: "g1", kind: .guide, note: "first",
    position: nil, steps: [TPPanelStep(detail: nil, text: "one"), TPPanelStep(detail: "why", text: "two")],
    title: "Guide")
guard case let .success(guide) = service.panel(guideInput, owner: t1) else { fail("a guide is shown") }
expect(guide.id == "g1" && guide.visible && guide.display == "A", "the guide is on the primary: \(guide.display)")
expect(service.list(owner: t1).overlays.count == 1, "the guide is listed")
let update = TPScreenPanelInput(
    activeStep: nil, blocks: nil, display: nil, id: "g1", kind: .guide, note: "second",
    position: nil, steps: nil, title: nil)
guard case .success = service.panel(update, owner: t1) else { fail("a guide update is accepted") }
expect(service.list(owner: t1).overlays.count == 1, "the update replaces rather than adds")
let files = (try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
    .filter { $0.pathExtension == "json" }
let guideFile = files.first { url in
    guard let data = try? Data(contentsOf: url),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
    return object["id"] as? String == "g1" && object["owner"] as? String == t1.threadID
}
guard let guideFile else { fail("the guide is persisted") }
let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: guideFile)) as? [String: Any]
guard let persisted else { fail("the guide file is readable") }
expect((persisted["steps"] as? [Any])?.count == 2, "omitted fields stay: \(String(describing: persisted["steps"]))")
expect(persisted["note"] as? String == "second", "given fields replace")

guard case .failure = service.panel(TPScreenPanelInput(
    activeStep: nil, blocks: [TPPanelBlock(items: nil, kind: .heading, text: "x")], display: nil,
    id: "g1", kind: .guide, note: nil, position: nil, steps: nil, title: nil), owner: t1) else {
    fail("a guide carrying blocks is refused")
}
guard case .failure = service.panel(TPScreenPanelInput(
    activeStep: 1, blocks: nil, display: nil, id: "p1", kind: .panel, note: nil, position: nil,
    steps: [TPPanelStep(detail: nil, text: "x")], title: nil), owner: t1) else {
    fail("a panel carrying steps is refused")
}
guard case .failure = service.panel(TPScreenPanelInput(
    activeStep: nil, blocks: [TPPanelBlock(items: nil, kind: .bullets, text: nil)], display: nil,
    id: "p1", kind: .panel, note: nil, position: nil, steps: nil, title: nil), owner: t1) else {
    fail("a bullets block without items is refused")
}
guard case let .success(panelOnB) = service.panel(TPScreenPanelInput(
    activeStep: nil, blocks: [TPPanelBlock(items: ["one", "two"], kind: .bullets, text: nil)], display: "B",
    id: "p1", kind: .panel, note: nil, position: .topRight, steps: nil, title: "Panel"), owner: t1) else {
    fail("a panel on the secondary display is shown")
}
expect(panelOnB.display == "B", "the panel is placed on its own display: \(panelOnB.display)")

// Reloading is idempotent: the store is the source of truth, and reloading
// twice changes nothing.
let visibleBefore = service.visibleIDs
service.reload()
service.reload()
expect(service.visibleIDs == visibleBefore, "reloading twice changes nothing")

print("overlay service: validation by number, ownership, one path, displays")
