import Cocoa

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let leftDisplay = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
let centered = AnchoredPanelPlacement.frame(
    size: NSSize(width: 400, height: 520),
    anchor: PanelAnchor(
        frame: NSRect(x: -986, y: 5, width: 52, height: 18),
        visibleFrame: leftDisplay))
expect(leftDisplay.contains(centered), "panel must remain wholly on the pill's negative-origin display")
expect(centered.midX == -960, "panel must remain centered over the pill")

let edge = AnchoredPanelPlacement.frame(
    size: NSSize(width: 400, height: 520),
    anchor: PanelAnchor(
        frame: NSRect(x: -1918, y: 5, width: 52, height: 18),
        visibleFrame: leftDisplay))
expect(edge.minX == leftDisplay.minX + 8, "left-edge anchor must clamp to the visible frame margin")
expect(leftDisplay.contains(edge), "clamped panel must remain on the source display")

let top = AnchoredPanelPlacement.frame(
    size: NSSize(width: 400, height: 520),
    anchor: PanelAnchor(
        frame: NSRect(x: 900, y: 1000, width: 52, height: 18),
        visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080)))
expect(top.maxY == 1072, "top-edge anchor must clamp below the visible-frame margin")

print("window placement tests passed")
