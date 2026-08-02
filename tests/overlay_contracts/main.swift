import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let guide = OverlayDoc.parse(id: "guide", dict: [
    "type": "guide", "title": "Steps", "session": "session-a",
    "position": "center-right", "active_step": 2,
    "steps": [
        ["text": "First", "detail": "one"],
        ["text": "Second"],
    ],
])
expect(guide?.kind == .guide && guide?.session == "session-a",
       "guide document lost kind or owner")
expect(guide?.steps.count == 2 && guide?.activeStep == 2,
       "guide document lost ordered steps")

let panel = OverlayDoc.parse(id: "panel", dict: [
    "type": "panel", "position": [120, 80], "width": 420,
    "blocks": [
        ["kind": "heading", "text": "Heading"],
        ["kind": "text", "text": "Body"],
        ["kind": "code", "text": "echo ok"],
        ["kind": "bullets", "items": ["a", "b"]],
    ],
])
expect(panel?.kind == .panel && panel?.blocks.count == 4,
       "panel document did not preserve all block kinds")
expect(panel?.topLeftPx == CGPoint(x: 120, y: 80) && panel?.widthPx == 420,
       "panel pixel placement changed")

let annotations = OverlayDoc.parse(id: "marks", dict: [
    "type": "annotations", "display_id": 77,
    "items": [
        ["type": "circle", "center": [100, 200], "radius": 30],
        ["type": "rect", "rect": [10, 20, 30, 40]],
        ["type": "arrow", "from": [1, 2], "to": [3, 4]],
        ["type": "line", "from": [5, 6], "to": [7, 8]],
        ["type": "label", "position": [9, 10], "text": "nonce", "size": 64],
        ["type": "circle", "center": [1]],
    ],
])
expect(annotations?.kind == .annotations && annotations?.shapes.count == 5,
       "annotation parser accepted malformed or dropped valid shape kinds")
expect(annotations?.displayID == 77, "annotation document lost display identity")
if case .circle(let center, let radius, _)? = annotations?.shapes.first {
    expect(center == CGPoint(x: 100, y: 200) && radius == 30,
           "circle screenshot-pixel coordinates changed")
} else { expect(false, "first annotation was not a circle") }
if case .label(_, _, let size, _)? = annotations?.shapes.dropFirst(4).first {
    expect(size == 48, "annotation label size was not bounded")
} else { expect(false, "label annotation missing") }
expect(OverlayDoc.parse(id: "bad", dict: ["type": "unknown"]) == nil,
       "unknown overlay document kind was accepted")

let display = DisplayContext(
    id: 1, frame: NSRect(x: 0, y: 0, width: 2880, height: 1800),
    visibleFrame: NSRect(x: 0, y: 0, width: 2880, height: 1760),
    backingScaleFactor: 2, captureIndex: 1)
expect(CaptureStore.shotGeometry(for: display) == (1440, 900),
       "overlay screenshot geometry changed")
expect(CaptureStore.annotationPointScale(for: display) == 2,
       "overlay coordinate scale no longer maps screenshot pixels to points")

let manager = OverlayManager()
expect(OverlayManager.sanitize(id: "  A/B? C_1 ") == "abc_1",
       "overlay id sanitization changed")
let guidePath = manager.write(id: "owned-guide", dict: [
    "type": "guide", "session": "session-a",
    "steps": [["text": "live"]],
])
let panelPath = manager.write(id: "owned-panel", dict: [
    "type": "panel", "session": "session-b",
    "blocks": [["kind": "text", "text": "live"]],
])
expect(guidePath != nil && panelPath != nil && manager.list().count == 2,
       "overlay manager did not write and list live documents")
expect(manager.read(id: "owned-guide")?["session"] as? String == "session-a",
       "overlay manager read changed owning session")
expect(manager.sessionsWithOverlays() == Set(["session-a", "session-b"]),
       "overlay owner inventory changed")
expect(manager.removeAll(forSession: "session-a") == 1,
       "session-scoped overlay removal removed wrong count")
expect(manager.list().map(\.id) == ["owned-panel"],
       "session-scoped overlay removal crossed owners")
expect(manager.remove(id: "owned-panel") && manager.list().isEmpty,
       "user close/remove did not delete the live overlay file")

print("overlay contract tests passed")
