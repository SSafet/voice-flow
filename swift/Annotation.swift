import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Annotation Overlay — the screen as a whiteboard
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Independent of agent sessions: the user can mark up the screen at any
//  time, take their time, and the marks simply stay on screen. Because
//  they're real windows, they are visible in every screenshot the agent
//  receives — no extra plumbing.

private let AnnotationColors: [NSColor] = [
    NSColor(r: 255, g: 82, b: 82),    // red
    NSColor(r: 255, g: 194, b: 75),   // amber
    NSColor(r: 86, g: 156, b: 255),   // blue
]

private enum AnnotationItem {
    case stroke(points: [CGPoint], color: NSColor)
    case text(string: String, origin: CGPoint, color: NSColor)
}

final class AnnotationOverlay {
    var onEditingChanged: ((Bool) -> Void)?

    private(set) var isEditing = false
    private var panel: OverlayPanel?
    private var canvas: AnnotationCanvas?
    private var toolbar: AnnotationToolbar?

    var hasContent: Bool { !(canvas?.items.isEmpty ?? true) }

    func toggleEditing() {
        if isEditing { endEditing() } else { beginEditing() }
    }

    func beginEditing() {
        guard !isEditing else { return }
        vflog("annotate: beginEditing")
        ensurePanel()
        isEditing = true
        panel?.ignoresMouseEvents = false
        canvas?.isEditing = true
        showToolbar()
        panel?.makeKeyAndOrderFront(nil)
        vflog("annotate: overlay visible=\(panel?.isVisible ?? false) frame=\(panel?.frame ?? .zero)")
        onEditingChanged?(true)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        canvas?.commitPendingText()
        canvas?.isEditing = false
        panel?.ignoresMouseEvents = true
        toolbar?.hide()
        if !hasContent {
            panel?.orderOut(nil)
        }
        onEditingChanged?(false)
    }

    func clear() {
        canvas?.items.removeAll()
        canvas?.needsDisplay = true
        if !isEditing {
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let frame = screen?.frame ?? .zero

        if let panel {
            panel.setFrame(frame, display: true)
            panel.orderFront(nil)
            return
        }

        let newPanel = OverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.ignoresMouseEvents = true
        newPanel.isReleasedWhenClosed = false

        let newCanvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: frame.size))
        newCanvas.onRequestEndEditing = { [weak self] in self?.endEditing() }
        newPanel.contentView = newCanvas

        panel = newPanel
        canvas = newCanvas
        newPanel.orderFront(nil)
    }

    private func showToolbar() {
        if toolbar == nil {
            toolbar = AnnotationToolbar()
            toolbar?.onToolChanged = { [weak self] tool in self?.canvas?.tool = tool }
            toolbar?.onColorChanged = { [weak self] color in self?.canvas?.color = color }
            toolbar?.onUndo = { [weak self] in self?.canvas?.undo() }
            toolbar?.onClear = { [weak self] in self?.clear() }
            toolbar?.onDone = { [weak self] in self?.endEditing() }
        }
        toolbar?.show(currentTool: canvas?.tool ?? .pen, color: canvas?.color ?? AnnotationColors[0])
    }
}

// A borderless panel that can take keyboard focus (for the text tool)
// without activating the app.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// ── Canvas ──────────────────────────────────────────────

enum AnnotationTool {
    case pen, text
}

private final class AnnotationCanvas: NSView {
    var items: [AnnotationItem] = []
    var tool: AnnotationTool = .pen
    var color: NSColor = AnnotationColors[0]
    var isEditing = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onRequestEndEditing: (() -> Void)?

    private var activeStroke: [CGPoint] = []
    private var textEditor: NSTextField?
    private var textEditorOrigin: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Receive the first click even when the overlay isn't the key window —
    // without this, the first stroke is silently swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isEditing {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape ends annotate mode
            onRequestEndEditing?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditing else { return }
        commitPendingText()
        let point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .pen:
            activeStroke = [point]
        case .text:
            beginTextEntry(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditing, tool == .pen, !activeStroke.isEmpty else { return }
        activeStroke.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditing, tool == .pen, !activeStroke.isEmpty else { return }
        activeStroke.append(convert(event.locationInWindow, from: nil))
        if activeStroke.count > 1 {
            items.append(.stroke(points: activeStroke, color: color))
        }
        activeStroke = []
        needsDisplay = true
    }

    func undo() {
        commitPendingText()
        if !items.isEmpty {
            items.removeLast()
            needsDisplay = true
        }
    }

    // ── Text entry ──────────────────────────────────────

    private func beginTextEntry(at point: CGPoint) {
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 14, width: 360, height: 30))
        field.font = Self.annotationFont
        field.textColor = color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        field.isBezeled = false
        field.focusRingType = .none
        field.placeholderString = "Type, then press Return"
        field.target = self
        field.action = #selector(textEntryCommitted)
        addSubview(field)
        window?.makeFirstResponder(field)
        textEditor = field
        textEditorOrigin = point
    }

    @objc private func textEntryCommitted() {
        commitPendingText()
    }

    func commitPendingText() {
        guard let field = textEditor else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textEditorOrigin
        let itemColor = field.textColor ?? color
        field.removeFromSuperview()
        textEditor = nil
        if !string.isEmpty {
            items.append(.text(string: string, origin: origin, color: itemColor))
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    // ── Drawing ─────────────────────────────────────────

    private static let annotationFont = NSFont.systemFont(ofSize: 22, weight: .semibold)

    override func draw(_ dirtyRect: NSRect) {
        for item in items {
            render(item)
        }
        if activeStroke.count > 1 {
            render(.stroke(points: activeStroke, color: color))
        }
    }

    private func render(_ item: AnnotationItem) {
        switch item {
        case .stroke(let points, let strokeColor):
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.line(to: point)
            }
            // Subtle halo so marks stay readable on any background
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 6
            path.stroke()
            strokeColor.setStroke()
            path.lineWidth = 4
            path.stroke()

        case .text(let string, let origin, let textColor):
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.annotationFont,
                .foregroundColor: textColor,
                .shadow: shadow,
            ]
            NSString(string: string).draw(at: NSPoint(x: origin.x, y: origin.y - 14), withAttributes: attributes)
        }
    }
}

// ── Toolbar ─────────────────────────────────────────────

private final class AnnotationToolbar {
    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?
    var onDone: (() -> Void)?

    private var panel: NSPanel?
    private var penButton: NSButton!
    private var textButton: NSButton!
    private var colorButtons: [NSButton] = []

    func show(currentTool: AnnotationTool, color: NSColor) {
        if panel == nil {
            build()
        }
        select(tool: currentTool)
        select(color: color)
        position()
        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func position() {
        guard let panel, let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let frame = screen.frame
        let x = frame.midX - panel.frame.width / 2
        let y = frame.maxY - panel.frame.height - 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func build() {
        let height: CGFloat = 40
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        newPanel.level = .floating + 1
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: height))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = height / 2
        background.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        penButton = toolButton(title: "✏️ Draw", action: #selector(penTapped))
        textButton = toolButton(title: "🅣 Text", action: #selector(textTapped))
        stack.addArrangedSubview(penButton)
        stack.addArrangedSubview(textButton)

        stack.addArrangedSubview(divider())

        for (index, swatch) in AnnotationColors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = swatch.cgColor
            button.layer?.cornerRadius = 9
            button.tag = index
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons.append(button)
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(toolButton(title: "↩︎", action: #selector(undoTapped)))
        stack.addArrangedSubview(toolButton(title: "Clear", action: #selector(clearTapped)))

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(doneButton)

        newPanel.contentView = background
        newPanel.setContentSize(NSSize(width: stack.fittingSize.width, height: height))
        background.frame = NSRect(origin: .zero, size: newPanel.frame.size)
        panel = newPanel
    }

    private func toolButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .white
        return button
    }

    private func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }

    private func select(tool: AnnotationTool) {
        penButton?.contentTintColor = tool == .pen ? NSColor(r: 255, g: 194, b: 75) : .white
        textButton?.contentTintColor = tool == .text ? NSColor(r: 255, g: 194, b: 75) : .white
    }

    private func select(color: NSColor) {
        for button in colorButtons {
            let isSelected = AnnotationColors[button.tag] == color
            button.layer?.borderWidth = isSelected ? 2 : 0
            button.layer?.borderColor = NSColor.white.cgColor
        }
    }

    @objc private func penTapped() {
        select(tool: .pen)
        onToolChanged?(.pen)
    }

    @objc private func textTapped() {
        select(tool: .text)
        onToolChanged?(.text)
    }

    @objc private func colorTapped(_ sender: NSButton) {
        let color = AnnotationColors[sender.tag]
        select(color: color)
        onColorChanged?(color)
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func clearTapped() { onClear?() }
    @objc private func doneTapped() { onDone?() }
}
