import Cocoa
import CoreGraphics

/// Immutable identity + geometry for one attached display. Capture runs keep
/// this value so later pointer, window, or session changes cannot reroute them.
struct DisplayContext: Equatable {
    let id: CGDirectDisplayID
    let frame: NSRect
    let visibleFrame: NSRect
    let backingScaleFactor: CGFloat
    /// One-based display index accepted by `/usr/sbin/screencapture -D`.
    let captureIndex: Int

    var shotGeometry: (width: Int, height: Int) {
        let scale = min(1.0, 1440.0 / frame.width)
        return (
            Int((frame.width * scale).rounded()),
            Int((frame.height * scale).rounded())
        )
    }

    var annotationPointScale: CGFloat {
        let width = shotGeometry.width
        return width > 0 ? frame.width / CGFloat(width) : 1.0
    }

    /// Convert an AppKit global point (bottom-left origin) into screenshot
    /// pixels (top-left origin) for this display.
    func screenshotPoint(forGlobalPoint point: NSPoint) -> CGPoint {
        let scale = annotationPointScale
        return CGPoint(
            x: (point.x - frame.minX) / scale,
            y: (frame.maxY - point.y) / scale
        )
    }
}

enum DisplayTopology {
    static var displays: [DisplayContext] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return DisplayContext(
                id: CGDirectDisplayID(number.uint32Value),
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                backingScaleFactor: screen.backingScaleFactor,
                captureIndex: index + 1
            )
        }
    }

    /// macOS places the primary display at the global menu-bar origin.
    static var primary: DisplayContext? {
        primary(in: displays)
    }

    static var underMouse: DisplayContext? {
        let point = NSEvent.mouseLocation
        return displays.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? primary
    }

    static func display(id: CGDirectDisplayID) -> DisplayContext? {
        displays.first(where: { $0.id == id })
    }

    static var virtualFrame: NSRect {
        virtualFrame(for: displays.map(\.frame))
    }

    // Pure helpers retained for deterministic multi-display tests.
    static func primary(in displays: [DisplayContext]) -> DisplayContext? {
        displays.first(where: { $0.frame.origin == .zero }) ?? displays.first
    }

    static func virtualFrame(for frames: [NSRect]) -> NSRect {
        guard let first = frames.first else { return .zero }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}
