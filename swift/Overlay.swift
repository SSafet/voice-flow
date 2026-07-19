import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Overlays — on-screen elements as live JSON files
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Every element an agent places on the screen (step guides, info panels,
//  annotation shapes) is a JSON document in ~/.config/voice-flow/overlays/.
//  OverlayManager watches the directory and re-renders within ~0.5s of any
//  change, so both the MCP tools *and* direct file edits (Claude Code's
//  native strength) update the screen live. Deleting a file removes the
//  element; the ✕ button on a panel deletes its file.
//
//  All coordinates in overlay files are pixels in the take_screenshot image
//  space (≤1440 wide) — the same numbers the agent reads off screenshots.
//  The schema is documented in overlays/_schema.md, written on startup.

// ── Colors ──────────────────────────────────────────────

private let OverlayColors: [String: NSColor] = [
    "red": NSColor(r: 255, g: 82, b: 82),
    "amber": NSColor(r: 255, g: 194, b: 75),
    "blue": NSColor(r: 86, g: 156, b: 255),
    "green": NSColor(r: 110, g: 215, b: 130),
    "white": NSColor(r: 245, g: 245, b: 245),
]

private func overlayColor(_ name: Any?) -> NSColor {
    OverlayColors[(name as? String) ?? "red"] ?? OverlayColors["red"]!
}

private func overlayPoint(_ raw: Any?) -> CGPoint? {
    guard let pair = raw as? [Any], pair.count == 2,
          let x = (pair[0] as? NSNumber)?.doubleValue,
          let y = (pair[1] as? NSNumber)?.doubleValue else { return nil }
    return CGPoint(x: x, y: y)
}

// ── Parsed document model ───────────────────────────────

enum OverlayShape {
    case circle(center: CGPoint, radius: CGFloat, color: NSColor)
    case rect(CGRect, NSColor)
    case arrow(from: CGPoint, to: CGPoint, color: NSColor)
    case line(from: CGPoint, to: CGPoint, color: NSColor)
    case label(origin: CGPoint, text: String, size: CGFloat, color: NSColor)

    /// Parse one item dict (screenshot-pixel coordinates kept as-is).
    /// Returns nil for malformed items — used both for rendering and for
    /// validating annotate_screen tool input.
    static func parse(_ dict: [String: Any]) -> OverlayShape? {
        let color = overlayColor(dict["color"])
        switch dict["type"] as? String {
        case "circle":
            guard let center = overlayPoint(dict["center"]) else { return nil }
            let radius = CGFloat((dict["radius"] as? NSNumber)?.doubleValue ?? 60)
            return .circle(center: center, radius: max(6, radius), color: color)
        case "rect":
            guard let values = dict["rect"] as? [Any], values.count == 4,
                  let x = (values[0] as? NSNumber)?.doubleValue,
                  let y = (values[1] as? NSNumber)?.doubleValue,
                  let w = (values[2] as? NSNumber)?.doubleValue,
                  let h = (values[3] as? NSNumber)?.doubleValue else { return nil }
            return .rect(CGRect(x: x, y: y, width: w, height: h), color)
        case "arrow":
            guard let from = overlayPoint(dict["from"]),
                  let to = overlayPoint(dict["to"]) else { return nil }
            return .arrow(from: from, to: to, color: color)
        case "line":
            guard let from = overlayPoint(dict["from"]),
                  let to = overlayPoint(dict["to"]) else { return nil }
            return .line(from: from, to: to, color: color)
        case "label":
            guard let origin = overlayPoint(dict["position"]),
                  let text = dict["text"] as? String, !text.isEmpty else { return nil }
            let size = CGFloat(min(max((dict["size"] as? NSNumber)?.doubleValue ?? 22, 12), 48))
            return .label(origin: origin, text: text, size: size, color: color)
        default:
            return nil
        }
    }
}

enum OverlayBlock {
    case heading(String)
    case text(String)
    case code(String)
    case bullets([String])

    static func parse(_ dict: [String: Any]) -> OverlayBlock? {
        switch dict["kind"] as? String {
        case "heading":
            guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
            return .heading(text)
        case "text":
            guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
            return .text(text)
        case "code":
            guard let text = dict["text"] as? String, !text.isEmpty else { return nil }
            return .code(text)
        case "bullets":
            guard let items = dict["items"] as? [String], !items.isEmpty else { return nil }
            return .bullets(items)
        default:
            return nil
        }
    }
}

struct OverlayStep {
    let text: String
    let detail: String?
}

struct OverlayDoc {
    enum Kind: String {
        case guide, panel, annotations
    }

    let id: String
    let kind: Kind
    let visible: Bool
    /// Owning MCP session — the element renders only while that session is
    /// the user's active one. nil = always visible (hand-written files).
    let session: String?
    /// Display whose `take_screenshot` pixel space the document uses.
    let displayID: CGDirectDisplayID?
    let title: String
    let note: String?
    // guide
    let steps: [OverlayStep]
    let activeStep: Int
    // panel
    let blocks: [OverlayBlock]
    // annotations
    let shapes: [OverlayShape]
    // placement (panels + guides)
    let anchor: String?          // "top-left" … "center-right", "center"
    let topLeftPx: CGPoint?      // explicit position, screenshot px
    let widthPx: CGFloat?

    static func parse(id: String, dict: [String: Any]) -> OverlayDoc? {
        guard let kind = Kind(rawValue: dict["type"] as? String ?? "") else { return nil }

        var anchor: String?
        var topLeft: CGPoint?
        if let name = dict["position"] as? String {
            anchor = name
        } else if let point = overlayPoint(dict["position"]) {
            topLeft = point
        }

        let steps = (dict["steps"] as? [[String: Any]] ?? []).compactMap { step -> OverlayStep? in
            guard let text = step["text"] as? String, !text.isEmpty else { return nil }
            return OverlayStep(text: text, detail: step["detail"] as? String)
        }

        return OverlayDoc(
            id: id,
            kind: kind,
            visible: dict["visible"] as? Bool ?? true,
            session: dict["session"] as? String,
            displayID: (dict["display_id"] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) },
            title: dict["title"] as? String ?? "",
            note: dict["note"] as? String,
            steps: steps,
            activeStep: max(1, (dict["active_step"] as? NSNumber)?.intValue ?? 1),
            blocks: (dict["blocks"] as? [[String: Any]] ?? []).compactMap(OverlayBlock.parse),
            shapes: (dict["items"] as? [[String: Any]] ?? []).compactMap(OverlayShape.parse),
            anchor: anchor,
            topLeftPx: topLeft,
            widthPx: (dict["width"] as? NSNumber).map { CGFloat($0.doubleValue) }
        )
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Shape overlay — full-screen click-through canvas for annotations
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private final class OverlayShapeView: NSView {
    var pointScale: CGFloat = 1.0 {
        didSet { needsDisplay = true }
    }
    var shapes: [OverlayShape] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // File coordinates are screenshot pixels; scale to screen points.
        let k = pointScale

        for shape in shapes {
            switch shape {
            case .circle(let center, let radius, let color):
                let rect = NSRect(
                    x: (center.x - radius) * k, y: (center.y - radius) * k,
                    width: radius * 2 * k, height: radius * 2 * k
                )
                strokeWithHalo(NSBezierPath(ovalIn: rect), color: color)

            case .rect(let rect, let color):
                let scaled = NSRect(
                    x: rect.origin.x * k, y: rect.origin.y * k,
                    width: rect.width * k, height: rect.height * k
                )
                let path = NSBezierPath(roundedRect: scaled, xRadius: 6, yRadius: 6)
                strokeWithHalo(path, color: color)

            case .line(let from, let to, let color):
                let path = NSBezierPath()
                path.move(to: NSPoint(x: from.x * k, y: from.y * k))
                path.line(to: NSPoint(x: to.x * k, y: to.y * k))
                strokeWithHalo(path, color: color)

            case .arrow(let from, let to, let color):
                let start = NSPoint(x: from.x * k, y: from.y * k)
                let end = NSPoint(x: to.x * k, y: to.y * k)
                let path = NSBezierPath()
                path.move(to: start)
                path.line(to: end)
                let angle = atan2(end.y - start.y, end.x - start.x)
                let headLength: CGFloat = 16
                let spread: CGFloat = .pi / 7
                for side in [angle + .pi - spread, angle + .pi + spread] {
                    path.move(to: end)
                    path.line(to: NSPoint(
                        x: end.x + headLength * cos(side),
                        y: end.y + headLength * sin(side)
                    ))
                }
                strokeWithHalo(path, color: color)

            case .label(let origin, let text, let size, let color):
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = NSSize(width: 0, height: 1)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: color,
                    .shadow: shadow,
                ]
                let point = NSPoint(x: origin.x * k, y: origin.y * k)
                let width = max(120, bounds.width - point.x - 16)
                let rect = NSRect(x: point.x, y: point.y, width: width,
                                  height: max(bounds.height - point.y, 40))
                NSString(string: text).draw(in: rect, withAttributes: attributes)
            }
        }
    }

    private func strokeWithHalo(_ path: NSBezierPath, color: NSColor) {
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 6
        path.stroke()
        color.setStroke()
        path.lineWidth = 4
        path.stroke()
    }
}

private final class ShapeOverlayWindow {
    private var panel: NSPanel?
    private var view: OverlayShapeView?

    func setShapes(_ shapes: [OverlayShape], on display: DisplayContext) {
        guard !shapes.isEmpty else {
            panel?.orderOut(nil)
            view?.shapes = []
            return
        }
        let frame = display.frame
        if panel == nil {
            let newPanel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            newPanel.level = .floating
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.ignoresMouseEvents = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            newPanel.isReleasedWhenClosed = false
            let newView = OverlayShapeView(frame: NSRect(origin: .zero, size: frame.size))
            newPanel.contentView = newView
            panel = newPanel
            view = newView
        }
        panel?.setFrame(frame, display: true)
        view?.frame = NSRect(origin: .zero, size: frame.size)
        view?.pointScale = display.annotationPointScale
        view?.shapes = shapes
        panel?.orderFront(nil)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Panel window — renders guide and panel documents
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private final class OverlayPanelWindow {
    let id: String
    var onClose: ((String) -> Void)?    // ✕ → delete the backing file

    /// Tallest a panel may grow before it scrolls — capped to the screen.
    private var maxBodyHeight: CGFloat {
        let screenHeight = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame.height ?? 900
        return min(560, screenHeight - 80)
    }
    private var panel: NSPanel?
    private var userMoved = false
    /// Height the user chose by dragging an edge — honored over the cap.
    private var userHeight: CGFloat?
    private var repositioning = false
    private var lastPositionKey = ""
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?

    init(id: String) {
        self.id = id
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }

    func render(_ doc: OverlayDoc) {
        guard doc.visible else {
            panel?.orderOut(nil)
            return
        }
        let width = doc.widthPx.map { min(max($0 * CaptureStore.annotationPointScale(), 240), 620) } ?? 340
        let panel = ensurePanel()

        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.state = .active
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = Theme.border.cgColor

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 9
        column.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 14)
        let contentWidth = width - 30

        // Header: title + close
        // Every wrapping label needs preferredMaxLayoutWidth — without it
        // fittingSize measures the text unwrapped and the panel comes out
        // too short for its content.
        let titleLabel = NSTextField(wrappingLabelWithString: doc.title.isEmpty ? " " : doc.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.preferredMaxLayoutWidth = contentWidth - 28
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage(),
            target: self, action: #selector(closeTapped)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.text2
        closeButton.toolTip = "Dismiss (removes the overlay)"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [titleLabel, closeButton])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 8
        column.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        if let note = doc.note, !note.isEmpty {
            let noteLabel = NSTextField(wrappingLabelWithString: note)
            noteLabel.font = .systemFont(ofSize: 11)
            noteLabel.textColor = Theme.accent
            noteLabel.preferredMaxLayoutWidth = contentWidth
            column.addArrangedSubview(noteLabel)
            noteLabel.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }

        switch doc.kind {
        case .guide:
            for (index, step) in doc.steps.enumerated() {
                let row = makeStepRow(step, number: index + 1, activeStep: doc.activeStep, width: contentWidth)
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            }
        case .panel:
            for block in doc.blocks {
                let view = makeBlock(block, width: contentWidth)
                column.addArrangedSubview(view)
                view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            }
        case .annotations:
            break   // rendered by ShapeOverlayWindow, never here
        }

        column.translatesAutoresizingMaskIntoConstraints = false
        let fitting = column.fittingSize
        // Viewport: content height, capped by the screen and any height the
        // user chose by dragging an edge.
        let cap = min(maxBodyHeight, userHeight ?? .greatestFiniteMagnitude)
        let bodyHeight = min(fitting.height, max(160, cap))

        root.frame = NSRect(x: 0, y: 0, width: width, height: bodyHeight)
        if fitting.height > bodyHeight {
            // Frame-based document view (autolayout documentViews scroll
            // unreliably); the column is pinned to its top-left.
            let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: fitting.height))
            document.addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: document.topAnchor),
                column.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                column.widthAnchor.constraint(equalToConstant: width),
            ])
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: bodyHeight))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.verticalScrollElasticity = .allowed
            scroll.documentView = document
            scroll.autoresizingMask = [.width, .height]
            root.addSubview(scroll)
        } else {
            root.addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: root.topAnchor),
                column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
        }

        // Position: honor the doc's placement on first show or when it
        // changes; otherwise keep where it is (including user drags).
        let positionKey = "\(doc.anchor ?? "")|\(doc.topLeftPx.map { "\($0.x),\($0.y)" } ?? "")|\(Int(width))"
        let shouldPlace = !panel.isVisible || (positionKey != lastPositionKey) || !userMoved
        let previousFrame = panel.frame
        panel.contentView = root
        // Height-only resizing: width comes from the overlay doc.
        panel.minSize = NSSize(width: width, height: min(160, bodyHeight))
        panel.maxSize = NSSize(width: width, height: max(fitting.height, bodyHeight))
        repositioning = true
        if shouldPlace {
            panel.setFrame(frameFor(doc: doc, width: width, height: bodyHeight), display: true)
            if positionKey != lastPositionKey {
                userMoved = false
            }
        } else {
            let origin = NSPoint(x: previousFrame.minX, y: previousFrame.maxY - bodyHeight)
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: bodyHeight)), display: true)
        }
        repositioning = false
        lastPositionKey = positionKey

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFront(nil)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    // ── Content pieces ──────────────────────────────────

    private func makeStepRow(_ step: OverlayStep, number: Int, activeStep: Int, width: CGFloat) -> NSView {
        let state: (symbol: String, color: NSColor)
        if number < activeStep {
            state = ("checkmark.circle.fill", NSColor(r: 120, g: 200, b: 120))
        } else if number == activeStep {
            state = ("arrow.right.circle.fill", Theme.accent)
        } else {
            state = ("circle", Theme.text3)
        }

        let icon = NSImageView(image:
            NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage())
        icon.contentTintColor = state.color
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let isActive = number == activeStep
        let isDone = number < activeStep
        let textWidth = width - 26   // icon 18 + spacing 8
        let textLabel = NSTextField(wrappingLabelWithString: step.text)
        textLabel.font = .systemFont(ofSize: 12.5, weight: isActive ? .semibold : .regular)
        textLabel.textColor = isDone ? Theme.text3 : (isActive ? Theme.text : Theme.text2)
        textLabel.preferredMaxLayoutWidth = textWidth
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textColumn = NSStackView(views: [textLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 2
        if let detail = step.detail, !detail.isEmpty {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            detailLabel.textColor = Theme.text3
            detailLabel.preferredMaxLayoutWidth = textWidth
            textColumn.addArrangedSubview(detailLabel)
            detailLabel.widthAnchor.constraint(equalTo: textColumn.widthAnchor).isActive = true
        }

        let row = NSStackView(views: [icon, textColumn])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        textLabel.widthAnchor.constraint(equalTo: textColumn.widthAnchor).isActive = true
        return row
    }

    private func makeBlock(_ block: OverlayBlock, width: CGFloat) -> NSView {
        switch block {
        case .heading(let text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12.5, weight: .semibold)
            label.textColor = Theme.text
            label.preferredMaxLayoutWidth = width
            return label

        case .text(let text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = Theme.text2
            label.preferredMaxLayoutWidth = width
            return label

        case .code(let text):
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(r: 20, g: 18, b: 16, a: 210).cgColor
            container.layer?.cornerRadius = 7
            container.layer?.borderWidth = 1
            container.layer?.borderColor = Theme.border.cgColor

            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = Theme.text
            label.isSelectable = true
            label.preferredMaxLayoutWidth = width - 20   // 10px insets each side
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            ])
            return container

        case .bullets(let items):
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 3
            for item in items {
                let label = NSTextField(wrappingLabelWithString: "•  \(item)")
                label.font = .systemFont(ofSize: 12)
                label.textColor = Theme.text2
                label.preferredMaxLayoutWidth = width
                stack.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            return stack
        }
    }

    // ── Placement ───────────────────────────────────────

    private func frameFor(doc: OverlayDoc, width: CGFloat, height: CGFloat) -> NSRect {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let full = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = screen?.visibleFrame ?? full

        // Explicit [x, y]: screenshot px, top-left of the panel, y from top.
        if let topLeft = doc.topLeftPx {
            let k = CaptureStore.annotationPointScale()
            let x = full.minX + topLeft.x * k
            let y = full.maxY - topLeft.y * k - height
            return NSRect(x: x, y: y, width: width, height: height)
        }

        let margin: CGFloat = 18
        let anchor = doc.anchor ?? "center-right"
        let x: CGFloat
        let y: CGFloat
        switch anchor {
        case "top-left", "bottom-left", "center-left":
            x = visible.minX + margin
        case "center":
            x = visible.midX - width / 2
        default:
            x = visible.maxX - width - margin
        }
        switch anchor {
        case "top-left", "top-right":
            y = visible.maxY - height - margin
        case "bottom-left", "bottom-right":
            y = visible.minY + margin
        default:
            y = visible.midY - height / 2
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        // KeyablePanel: borderless windows refuse key status by default,
        // which breaks interactive scrolling inside the panel. .resizable
        // lets the user drag the bottom edge to see more.
        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        newPanel.level = .floating + 1
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        newPanel.isMovableByWindowBackground = true
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: newPanel, queue: .main
        ) { [weak self] _ in
            guard let self, !self.repositioning else { return }
            self.userMoved = true
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: newPanel, queue: .main
        ) { [weak self, weak newPanel] _ in
            guard let self, let newPanel, !self.repositioning else { return }
            self.userHeight = newPanel.frame.height
        }
        panel = newPanel
        return newPanel
    }

    @objc private func closeTapped() {
        onClose?(id)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Overlay Manager — watches the directory, renders, exposes file ops
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class OverlayManager {
    static let dir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice-flow/overlays")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var schemaPath: String {
        dir.appendingPathComponent("_schema.md").path
    }

    private var panels: [String: OverlayPanelWindow] = [:]
    private var shapeWindows: [CGDirectDisplayID: ShapeOverlayWindow] = [:]
    private var pollTimer: Timer?
    private var lastSignature = ""
    /// The user's active MCP session — session-owned overlays render only
    /// while their owner is active. Main thread.
    private var activeSession: String?

    /// Swap which session's overlays are on screen. Main thread.
    func setActiveSession(_ id: String?) {
        guard id != activeSession else { return }
        activeSession = id
        rescan(force: true)
    }

    /// Main thread. Writes the schema doc and begins watching.
    func start() {
        try? Data(Self.schemaText.utf8).write(
            to: Self.dir.appendingPathComponent("_schema.md"), options: .atomic)
        rescan(force: true)
        // Polling (not FSEvents): survives editors that write in place,
        // atomic replaces, and deletes alike. A handful of stats per tick.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.rescan(force: false)
        }
    }

    // ── File operations (used by the MCP tool handlers) ──

    static func sanitize(id rawId: String?) -> String? {
        guard let rawId else { return nil }
        let cleaned = rawId.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return cleaned.isEmpty ? nil : String(cleaned.prefix(60))
    }

    func fileURL(id: String) -> URL {
        Self.dir.appendingPathComponent("\(id).json")
    }

    /// Write an overlay document and render immediately. Returns its path.
    @discardableResult
    func write(id: String, dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        let url = fileURL(id: id)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            vflog("overlay: write failed for \(id): \(error)")
            return nil
        }
        DispatchQueue.main.async { self.rescan(force: true) }
        return url.path
    }

    func read(id: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL(id: id)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @discardableResult
    func remove(id: String) -> Bool {
        let url = fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        DispatchQueue.main.async { self.rescan(force: true) }
        return true
    }

    /// Remove every overlay owned by one MCP session — called when the user
    /// trashes that session so its annotations can't outlive the message
    /// they belonged to (ticket #14). Returns count.
    @discardableResult
    func removeAll(forSession session: String) -> Int {
        var removed = 0
        for (id, dict) in allDocsRaw() where (dict["session"] as? String) == session {
            try? FileManager.default.removeItem(at: fileURL(id: id))
            removed += 1
        }
        if removed > 0 {
            DispatchQueue.main.async { self.rescan(force: true) }
        }
        return removed
    }

    /// Sessions whose overlays are currently on disk (nil-owned excluded).
    func sessionsWithOverlays() -> Set<String> {
        Set(allDocsRaw().compactMap { $0.1["session"] as? String })
    }

    /// Remove every overlay file (or only annotation ones). Returns count.
    func removeAll(annotationsOnly: Bool) -> Int {
        var removed = 0
        for (id, dict) in allDocsRaw() {
            if annotationsOnly && (dict["type"] as? String) != "annotations" { continue }
            try? FileManager.default.removeItem(at: fileURL(id: id))
            removed += 1
        }
        DispatchQueue.main.async { self.rescan(force: true) }
        return removed
    }

    func list() -> [(id: String, type: String, path: String, visible: Bool)] {
        allDocsRaw().map { id, dict in
            (id, dict["type"] as? String ?? "?", fileURL(id: id).path, dict["visible"] as? Bool ?? true)
        }.sorted { $0.id < $1.id }
    }

    private func allDocsRaw() -> [(String, [String: Any])] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.dir, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return nil
                }
                return (url.deletingPathExtension().lastPathComponent, dict)
            }
    }

    // ── Watching + rendering ────────────────────────────

    private func signature() -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return ""
        }
        return entries
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .compactMap { url -> String? in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                return "\(url.lastPathComponent):\(mtime):\(values?.fileSize ?? 0)"
            }
            .sorted()
            .joined(separator: ";")
    }

    private func rescan(force: Bool) {
        let current = signature()
        if !force && current == lastSignature { return }
        lastSignature = current

        var docs: [String: OverlayDoc] = [:]
        for (id, dict) in allDocsRaw() {
            // Malformed / mid-write files are skipped; the next tick retries.
            guard let doc = OverlayDoc.parse(id: id, dict: dict) else { continue }
            // Another session's elements stay off screen until the user
            // switches to it — never draw over what they're doing now.
            if let owner = doc.session, owner != activeSession { continue }
            docs[id] = doc
        }

        // Panels + guides
        for (id, doc) in docs where doc.kind != .annotations {
            let window = panels[id] ?? {
                let created = OverlayPanelWindow(id: id)
                created.onClose = { [weak self] closedId in
                    self?.remove(id: closedId)
                }
                panels[id] = created
                return created
            }()
            window.render(doc)
        }
        for (id, window) in panels where docs[id] == nil || docs[id]?.kind == .annotations {
            window.close()
            panels.removeValue(forKey: id)
        }

        // Annotation coordinates belong to the display that produced their
        // screenshot. Legacy files without an id remain on the primary.
        let primaryId = DisplayTopology.primary?.id
        let annotationDocs = docs.values.filter { $0.kind == .annotations && $0.visible }
        let grouped = Dictionary(grouping: annotationDocs) { $0.displayID ?? primaryId ?? 0 }
        for (displayId, displayDocs) in grouped {
            guard let display = DisplayTopology.display(id: displayId) else { continue }
            let window = shapeWindows[displayId] ?? {
                let created = ShapeOverlayWindow()
                shapeWindows[displayId] = created
                return created
            }()
            window.setShapes(displayDocs.flatMap { $0.shapes }, on: display)
        }
        for (displayId, window) in shapeWindows where grouped[displayId] == nil {
            if let display = DisplayTopology.display(id: displayId) {
                window.setShapes([], on: display)
            }
            shapeWindows.removeValue(forKey: displayId)
        }
    }

    // ── Schema documentation (written to overlays/_schema.md) ──

    private static let schemaText = """
    # Voice Flow overlays

    Every `*.json` file in this directory is a live on-screen element — Voice Flow
    re-renders within ~0.5s of any file change. Create, edit, or delete files
    directly (or via the voice-flow MCP tools; both are equivalent). The ✕ button
    on a panel deletes its file.

    **All coordinates are pixels in the `take_screenshot` image space** (the
    screenshot Voice Flow returns, ≤1440 px wide) — the same numbers you read off
    screenshots. Colors: `red`, `amber`, `blue`, `green`, `white`.

    ## Common fields

    - `type` (required): `"guide"` | `"panel"` | `"annotations"`
    - `visible`: bool, default true (false hides without deleting)
    - `session`: string, optional — owning MCP session id (the tools stamp it
      automatically). The element renders only while that session is the
      user's active one; omit it for elements that should always show.
    - `display_id`: integer, optional — the display returned by `take_screenshot`;
      annotation coordinates are interpreted in that display's image space.
    - `position` (guide/panel): anchor string — `top-left`, `top-right`,
      `bottom-left`, `bottom-right`, `center-left`, `center-right`, `center` —
      or `[x, y]` (top-left corner of the panel, y measured from the top).
    - `width` (guide/panel): px, optional.

    ## Guide — a step-by-step checklist

    ```json
    {
      "type": "guide",
      "title": "Set up the Cloudflare tunnel",
      "note": "optional highlighted line under the title",
      "steps": [
        {"text": "Install cloudflared", "detail": "brew install cloudflared"},
        {"text": "Authenticate", "detail": "cloudflared tunnel login"}
      ],
      "active_step": 2,
      "position": "center-right"
    }
    ```
    Steps before `active_step` render as done ✓; set `active_step` past the end
    to mark everything done.

    ## Panel — formatted reference information

    ```json
    {
      "type": "panel",
      "title": "Staging credentials",
      "blocks": [
        {"kind": "heading", "text": "Account section"},
        {"kind": "text", "text": "Use these values:"},
        {"kind": "code", "text": "API_KEY=sk-test-123\\nREGION=eu-west-1"},
        {"kind": "bullets", "items": ["Tick 'remember me'", "Skip 2FA on staging"]}
      ],
      "position": [900, 140],
      "width": 380
    }
    ```

    ## Annotations — shapes drawn over the whole screen

    ```json
    {
      "type": "annotations",
      "items": [
        {"type": "circle", "center": [720, 460], "radius": 70, "color": "red"},
        {"type": "arrow", "from": [500, 300], "to": [660, 430], "color": "blue"},
        {"type": "label", "position": [430, 250], "text": "Click here", "size": 22, "color": "amber"},
        {"type": "rect", "rect": [100, 100, 300, 80], "color": "green"},
        {"type": "line", "from": [0, 500], "to": [1440, 500], "color": "white"}
      ]
    }
    ```
    Annotation overlays are click-through and appear in screenshots.
    """
}
