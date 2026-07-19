import Cocoa
import CoreGraphics

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let laptop = DisplayContext(
    id: 1,
    frame: NSRect(x: 2560, y: 0, width: 1728, height: 1117),
    visibleFrame: NSRect(x: 2560, y: 0, width: 1728, height: 1092),
    backingScaleFactor: 2,
    captureIndex: 2)
let primary = DisplayContext(
    id: 2,
    frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
    visibleFrame: NSRect(x: 0, y: 0, width: 2560, height: 1415),
    backingScaleFactor: 1,
    captureIndex: 1)

expect(DisplayTopology.primary(in: [laptop, primary])?.id == primary.id,
       "primary selection must use the menu-bar origin, not array order")

let virtual = DisplayTopology.virtualFrame(for: [primary.frame, laptop.frame])
expect(virtual == NSRect(x: 0, y: 0, width: 4288, height: 1440),
       "virtual annotation canvas must cover both displays")

let cursor = laptop.screenshotPoint(forGlobalPoint: NSPoint(x: 2992, y: 558.5))
expect(abs(cursor.x - 360) < 0.01, "secondary cursor x must subtract display origin")
expect(abs(cursor.y - 465.4167) < 0.01, "secondary cursor y must flip within that display")

print("display context tests passed")
