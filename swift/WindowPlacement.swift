import Cocoa

/// The pill's actual on-screen geometry at the moment another surface opens.
/// Carrying the visible frame with it avoids re-resolving a different display.
struct PanelAnchor {
    let frame: NSRect
    let visibleFrame: NSRect
}

enum AnchoredPanelPlacement {
    static func frame(
        size: NSSize,
        anchor: PanelAnchor,
        gap: CGFloat = 8,
        margin: CGFloat = 8
    ) -> NSRect {
        let bounds = anchor.visibleFrame.insetBy(dx: margin, dy: margin)
        let idealX = anchor.frame.midX - size.width / 2
        let idealY = anchor.frame.maxY + gap
        let maxX = max(bounds.minX, bounds.maxX - size.width)
        let maxY = max(bounds.minY, bounds.maxY - size.height)
        return NSRect(
            x: min(max(idealX, bounds.minX), maxX).rounded(),
            y: min(max(idealY, bounds.minY), maxY).rounded(),
            width: min(size.width, bounds.width),
            height: min(size.height, bounds.height))
    }
}
