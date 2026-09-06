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

private let AnnotationFontSizes: [CGFloat] = [16, 22, 32]

enum AnnotationItem {
    case stroke(points: [CGPoint], color: NSColor)
    case text(string: String, origin: CGPoint, color: NSColor, fontSize: CGFloat, width: CGFloat)
}

/// Plain, versioned data: never archive AppKit views or their undo targets.
struct AnnotationSnapshot: Codable {
    struct Color: Codable {
        let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
        init(_ color: NSColor) {
            let rgb = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            red = rgb.redComponent; green = rgb.greenComponent
            blue = rgb.blueComponent; alpha = rgb.alphaComponent
        }
        var value: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    }
    enum Item: Codable {
        case stroke([CGPoint], Color)
        case text(String, CGPoint, Color, CGFloat, CGFloat)
        init(_ item: AnnotationItem) {
            switch item {
            case let .stroke(points, color): self = .stroke(points, Color(color))
            case let .text(text, origin, color, size, width):
                self = .text(text, origin, Color(color), size, width)
            }
        }
        var value: AnnotationItem {
            switch self {
            case let .stroke(points, color): return .stroke(points: points, color: color.value)
            case let .text(text, origin, color, size, width):
                return .text(string: text, origin: origin, color: color.value, fontSize: size, width: width)
            }
        }
    }
    var version = 1
    let items: [Item]
}

final class AnnotationStore {
    let url: URL
    init(url: URL = VoiceFlowPaths.shared.file("annotations.json")) { self.url = url }

    func load() throws -> [AnnotationItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let snapshot = try JSONDecoder().decode(AnnotationSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot.items.map(\.value)
    }

    func save(_ items: [AnnotationItem]) throws {
        let data = try JSONEncoder().encode(AnnotationSnapshot(items: items.map(AnnotationSnapshot.Item.init)))
        try data.write(to: url, options: .atomic)
    }
}

final class AnnotationOverlay {
    var onEditingChanged: ((Bool) -> Void)?
    var onSaveError: (() -> Void)?

    private(set) var isEditing = false
    private var panel: OverlayPanel?
    private var canvas: AnnotationCanvas?
    private var toolbar: AnnotationToolbar?
    private let store: AnnotationStore
    private var reportedSaveFailure = false

    init(store: AnnotationStore = AnnotationStore()) {
        self.store = store
        do {
            let restored = try store.load()
            if !restored.isEmpty {
                ensurePanel()
                canvas?.items = restored
                canvas?.needsDisplay = true
                vflog("annotate: restored \(restored.count) marks")
            }
        } catch {
            // Preserve unreadable data before a later edit writes a new snapshot.
            let backup = store.url.appendingPathExtension("unreadable-\(UUID().uuidString)")
            do { try FileManager.default.copyItem(at: store.url, to: backup) }
            catch { vflog("annotate: could not preserve unreadable snapshot: \(error)") }
            vflog("annotate: could not restore snapshot: \(error)")
        }
    }

    private func save() {
        guard let canvas else { return }
        do {
            try store.save(canvas.recoverableItems)
            reportedSaveFailure = false
        } catch {
            if !reportedSaveFailure {
                vflog("annotate: autosave failed: \(error)")
                onSaveError?()
                reportedSaveFailure = true
            }
        }
    }

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
        if let canvas { panel?.makeFirstResponder(canvas) }
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
        canvas?.clear()
        if !isEditing {
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        // One canvas across the virtual desktop keeps a single undo stack and
        // allows drawing on any attached display without changing context.
        let frame = DisplayTopology.virtualFrame

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
        newPanel.onEscape = { [weak self] in self?.endEditing() }
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.ignoresMouseEvents = true
        newPanel.isReleasedWhenClosed = false

        let newCanvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: frame.size))
        newCanvas.onRequestEndEditing = { [weak self] in self?.endEditing() }
        newCanvas.onContentChanged = { [weak self] in self?.save() }
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
            toolbar?.onFontSizeChanged = { [weak self] size in self?.canvas?.fontSize = size }
            toolbar?.onUndo = { [weak self] in self?.canvas?.undo() }
            toolbar?.onClear = { [weak self] in self?.clear() }
            toolbar?.onDone = { [weak self] in self?.endEditing() }
        }
        toolbar?.show(
            currentTool: canvas?.tool ?? .pen,
            color: canvas?.color ?? AnnotationColors[0],
            fontSize: canvas?.fontSize ?? AnnotationFontSizes[1]
        )
    }
}

// A borderless panel that can take keyboard focus (for the text tool)
// without activating the app. Escape exits annotate mode no matter which
// view is first responder.
private final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

// ── Canvas ──────────────────────────────────────────────

enum AnnotationTool {
    case pen, text
}

final class AnnotationCanvas: NSView, NSUserInterfaceValidations {
    var items: [AnnotationItem] = []
    var tool: AnnotationTool = .pen
    var color: NSColor = AnnotationColors[0] {
        didSet {
            textEditor?.textColor = color
            textEditor?.insertionPointColor = color
            onContentChanged?()
        }
    }
    var fontSize: CGFloat = AnnotationFontSizes[1] {
        didSet {
            textEditor?.font = Self.annotationFont(ofSize: fontSize)
            onContentChanged?()
        }
    }
    var isEditing = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onRequestEndEditing: (() -> Void)?
    var onContentChanged: (() -> Void)?

    private var activeStroke: [CGPoint] = []
    private var textEditor: AnnotationTextEditor?
    private var textEditorOrigin: CGPoint = .zero
    private var redoItems: [AnnotationItem] = []

    // Include in-flight work in every atomic checkpoint. After relaunch a draft
    // is restored as a normal note, without resurrecting an NSTextView.
    var recoverableItems: [AnnotationItem] {
        var result = items
        if activeStroke.count > 1 { result.append(.stroke(points: activeStroke, color: color)) }
        if let editor = textEditor, !editor.string.isEmpty {
            result.append(.text(string: editor.string, origin: textEditorOrigin,
                                color: editor.textColor ?? color,
                                fontSize: editor.font?.pointSize ?? fontSize,
                                width: editor.frame.width))
        }
        return result
    }

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
        onContentChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditing, tool == .pen, !activeStroke.isEmpty else { return }
        activeStroke.append(convert(event.locationInWindow, from: nil))
        if activeStroke.count > 1 {
            items.append(.stroke(points: activeStroke, color: color))
            redoItems.removeAll()
        }
        activeStroke = []
        needsDisplay = true
        onContentChanged?()
    }

    func undo() {
        if let editor = textEditor {
            editor.undoManager?.undo()
            return
        }
        guard let item = items.popLast() else { return }
        redoItems.append(item)
        needsDisplay = true
        onContentChanged?()
    }

    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) {
        if let editor = textEditor {
            editor.undoManager?.redo()
            return
        }
        guard let item = redoItems.popLast() else { return }
        items.append(item)
        needsDisplay = true
        onContentChanged?()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            return textEditor?.undoManager?.canUndo ?? !items.isEmpty
        }
        if item.action == #selector(redo(_:)) {
            return textEditor?.undoManager?.canRedo ?? !redoItems.isEmpty
        }
        return true
    }

    func clear() {
        discardTextEditor()
        activeStroke.removeAll()
        items.removeAll()
        redoItems.removeAll()
        needsDisplay = true
        onContentChanged?()
    }

    // ── Text entry ──────────────────────────────────────

    private func beginTextEntry(at point: CGPoint) {
        let editorWidth = min(440, max(180, bounds.width - point.x - 24))
        let editor = AnnotationTextEditor(frame: NSRect(
            x: point.x, y: point.y - fontSize * 0.7,
            width: editorWidth, height: fontSize + 12
        ))
        editor.font = Self.annotationFont(ofSize: fontSize)
        editor.textColor = color
        editor.insertionPointColor = color
        editor.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        editor.drawsBackground = true
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.textContainer?.lineFragmentPadding = 3
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: editorWidth, height: fontSize + 12)
        editor.maxSize = NSSize(width: editorWidth, height: bounds.height - point.y)
        editor.onCommit = { [weak self] in self?.commitPendingText() }
        editor.onChange = { [weak self] in self?.onContentChanged?() }
        addSubview(editor)
        window?.makeFirstResponder(editor)
        textEditor = editor
        textEditorOrigin = editor.frame.origin
    }

    func commitPendingText() {
        guard let editor = textEditor else { return }
        let string = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textEditorOrigin
        let itemColor = editor.textColor ?? color
        let size = editor.font?.pointSize ?? fontSize
        let width = editor.frame.width
        discardTextEditor()
        if !string.isEmpty {
            items.append(.text(string: string, origin: origin, color: itemColor, fontSize: size, width: width))
            redoItems.removeAll()
        }
        needsDisplay = true
        onContentChanged?()
    }

    private func discardTextEditor() {
        guard let editor = textEditor else { return }
        // Undo operations contain non-owning AppKit text targets. They must not
        // escape this editor's lifetime or be invoked after it is detached.
        editor.onChange = nil
        editor.onCommit = nil
        editor.breakUndoCoalescing()
        window?.makeFirstResponder(self)
        editor.undoManager?.removeAllActions()
        editor.allowsUndo = false
        editor.removeFromSuperview()
        textEditor = nil
    }

    // ── Drawing ─────────────────────────────────────────

    static func annotationFont(ofSize size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

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

        case .text(let string, let origin, let textColor, let size, let width):
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.annotationFont(ofSize: size),
                .foregroundColor: textColor,
                .shadow: shadow,
            ]
            // Same geometry as the editor: wrap at its width, draw from its origin.
            let rect = NSRect(
                x: origin.x + 3, y: origin.y + 2,
                width: width - 6, height: max(bounds.height - origin.y, 40)
            )
            NSString(string: string).draw(in: rect, withAttributes: attributes)
        }
    }
}

// Multiline text entry for the text tool. Return adds a line; Escape (or
// clicking elsewhere) commits the note.
final class AnnotationTextEditor: NSTextView {
    var onCommit: (() -> Void)?
    var onChange: (() -> Void)?
    private lazy var textUndoManager: UndoManager = {
        let manager = UndoManager()
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, NSNotification.Name.NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoFinished),
                                                   name: name, object: manager)
        }
        return manager
    }()
    override var undoManager: UndoManager? { textUndoManager }

    // AppKit can call didChangeText before an undo operation has finished
    // restoring storage. Checkpoint the final text after the group completes.
    @objc private func undoFinished(_ notification: Notification) { onChange?() }

    override func didChangeText() {
        super.didChangeText()
        if !textUndoManager.isUndoing && !textUndoManager.isRedoing { onChange?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape commits the note, stays in annotate mode
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCommit?()
    }
}

// ── Toolbar ─────────────────────────────────────────────

private final class AnnotationToolbar {
    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?
    var onDone: (() -> Void)?

    private var panel: NSPanel?
    private var penButton: NSButton!
    private var textButton: NSButton!
    private var colorButtons: [NSButton] = []
    private var sizeButtons: [NSButton] = []

    func show(currentTool: AnnotationTool, color: NSColor, fontSize: CGFloat) {
        if panel == nil {
            build()
        }
        select(tool: currentTool)
        select(color: color)
        select(fontSize: fontSize)
        position()
        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func position() {
        guard let panel, let display = DisplayTopology.underMouse ?? DisplayTopology.primary else { return }
        let frame = display.visibleFrame
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

        // Text size presets (small / medium / large)
        let sizeLabelFonts: [CGFloat] = [10, 13, 16]
        for (index, labelSize) in sizeLabelFonts.enumerated() {
            let button = NSButton(title: "Aa", target: self, action: #selector(sizeTapped(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: labelSize, weight: .semibold)
            button.contentTintColor = .white
            button.tag = index
            button.toolTip = ["Small text", "Medium text", "Large text"][index]
            sizeButtons.append(button)
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

    private func select(fontSize: CGFloat) {
        for button in sizeButtons {
            let isSelected = AnnotationFontSizes[button.tag] == fontSize
            button.contentTintColor = isSelected ? NSColor(r: 255, g: 194, b: 75) : .white
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

    @objc private func sizeTapped(_ sender: NSButton) {
        let size = AnnotationFontSizes[sender.tag]
        select(fontSize: size)
        onFontSizeChanged?(size)
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func clearTapped() { onClear?() }
    @objc private func doneTapped() { onDone?() }
}
