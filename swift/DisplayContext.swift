import Cocoa
import CoreGraphics

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
