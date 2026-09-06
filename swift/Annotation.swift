import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Annotation Overlay — the screen as a whiteboard
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Independent of agent sessions: the user can mark up the screen at any
//  time, take their time, and the marks simply stay on screen. Because
//  they're real windows, they are visible in every screenshot the agent
//  receives — no extra plumbing.
//
//  While annotate mode is on, the keyboard drives everything so the mouse can
//  stay on the thing being marked: P/H/L/A/R/C/N/T/E pick a tool, 1–6 a
//  colour, [ and ] the size, ⌘Z/⇧⌘Z undo/redo, ⌫ undoes the last mark, ⌘⌫
//  clears (undoable), Escape commits a note and leaves. Typing inside a text
//  note never reaches these bindings — the editor is first responder.

let AnnotationColors: [NSColor] = [
    NSColor(r: 255, g: 82, b: 82),    // red
    NSColor(r: 255, g: 194, b: 75),   // amber
    NSColor(r: 92, g: 214, b: 120),   // green
    NSColor(r: 86, g: 156, b: 255),   // blue
    NSColor(r: 232, g: 96, b: 220),   // magenta
    NSColor(r: 250, g: 250, b: 250),  // white
]
private let AnnotationColorNames = ["Red", "Amber", "Green", "Blue", "Magenta", "White"]

/// One size dial drives every tool, so S/M/L means the same thing whether the
/// user is drawing, highlighting, stamping numbers, or typing.
enum AnnotationSize: Int, Codable, CaseIterable {
    case small, medium, large

    var penWidth: CGFloat { [3, 5, 8][rawValue] }
    var highlightWidth: CGFloat { [14, 22, 32][rawValue] }
    var fontSize: CGFloat { [16, 22, 32][rawValue] }
    var badgeDiameter: CGFloat { [24, 30, 38][rawValue] }
    var label: String { ["S", "M", "L"][rawValue] }
    var name: String { ["Small", "Medium", "Large"][rawValue] }

    static func closest(fontSize: CGFloat) -> AnnotationSize {
        allCases.min(by: { abs($0.fontSize - fontSize) < abs($1.fontSize - fontSize) }) ?? .medium
    }
}

enum AnnotationShapeKind: String, Codable {
    case line, arrow, rect, ellipse
}

enum AnnotationItem {
    case stroke(points: [CGPoint], color: NSColor, width: CGFloat)
    case highlight(points: [CGPoint], color: NSColor, width: CGFloat)
    case shape(kind: AnnotationShapeKind, from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case number(value: Int, center: CGPoint, color: NSColor, diameter: CGFloat)
    case text(string: String, origin: CGPoint, color: NSColor, fontSize: CGFloat, width: CGFloat)
}

/// Plain, versioned data: never archive AppKit views or their undo targets.
struct AnnotationSnapshot: Codable {
    static let currentVersion = 2

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
        case stroke([CGPoint], Color, CGFloat)
        case highlight([CGPoint], Color, CGFloat)
        case shape(AnnotationShapeKind, CGPoint, CGPoint, Color, CGFloat)
        case number(Int, CGPoint, Color, CGFloat)
        case text(String, CGPoint, Color, CGFloat, CGFloat)
        init(_ item: AnnotationItem) {
            switch item {
            case let .stroke(points, color, width): self = .stroke(points, Color(color), width)
            case let .highlight(points, color, width): self = .highlight(points, Color(color), width)
            case let .shape(kind, from, to, color, width): self = .shape(kind, from, to, Color(color), width)
            case let .number(value, center, color, diameter): self = .number(value, center, Color(color), diameter)
            case let .text(text, origin, color, size, width):
                self = .text(text, origin, Color(color), size, width)
            }
        }
        var value: AnnotationItem {
            switch self {
            case let .stroke(points, color, width): return .stroke(points: points, color: color.value, width: width)
            case let .highlight(points, color, width): return .highlight(points: points, color: color.value, width: width)
            case let .shape(kind, from, to, color, width):
                return .shape(kind: kind, from: from, to: to, color: color.value, width: width)
            case let .number(value, center, color, diameter):
                return .number(value: value, center: center, color: color.value, diameter: diameter)
            case let .text(text, origin, color, size, width):
                return .text(string: text, origin: origin, color: color.value, fontSize: size, width: width)
            }
        }
    }
    var version = AnnotationSnapshot.currentVersion
    let items: [Item]
}

final class AnnotationStore {
    let url: URL
    init(url: URL = VoiceFlowPaths.shared.file("annotations.json")) { self.url = url }

    func load() throws -> [AnnotationItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let snapshot = try JSONDecoder().decode(AnnotationSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == AnnotationSnapshot.currentVersion else {
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
        newCanvas.onSelectionChanged = { [weak self] in self?.syncToolbar() }
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
            toolbar?.onSizeChanged = { [weak self] size in self?.canvas?.size = size }
            toolbar?.onUndo = { [weak self] in self?.canvas?.undo() }
            toolbar?.onRedo = { [weak self] in self?.canvas?.redo(nil) }
            toolbar?.onClear = { [weak self] in self?.clear() }
            toolbar?.onDone = { [weak self] in self?.endEditing() }
        }
        toolbar?.show()
        syncToolbar()
    }

    private func syncToolbar() {
        guard let canvas else { return }
        toolbar?.sync(tool: canvas.tool, color: canvas.color, size: canvas.size)
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

enum AnnotationTool: CaseIterable {
    case pen, highlighter, line, arrow, rect, ellipse, number, text, eraser

    var key: String {
        switch self {
        case .pen: return "p"
        case .highlighter: return "h"
        case .line: return "l"
        case .arrow: return "a"
        case .rect: return "r"
        case .ellipse: return "c"
        case .number: return "n"
        case .text: return "t"
        case .eraser: return "e"
        }
    }

    var name: String {
        switch self {
        case .pen: return "Draw"
        case .highlighter: return "Highlight"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rect: return "Rectangle"
        case .ellipse: return "Circle"
        case .number: return "Number"
        case .text: return "Text"
        case .eraser: return "Eraser"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .number: return "1.circle"
        case .text: return "textformat"
        case .eraser: return "eraser"
        }
    }

    var shapeKind: AnnotationShapeKind? {
        switch self {
        case .line: return .line
        case .arrow: return .arrow
        case .rect: return .rect
        case .ellipse: return .ellipse
        default: return nil
        }
    }

    static func forKey(_ key: String) -> AnnotationTool? {
        allCases.first { $0.key == key }
    }
}

final class AnnotationCanvas: NSView, NSUserInterfaceValidations {
    var items: [AnnotationItem] = []
    var tool: AnnotationTool = .pen {
        didSet {
            guard tool != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            onSelectionChanged?()
            invalidateCursorRing()
        }
    }
    var color: NSColor = AnnotationColors[0] {
        didSet {
            textEditor?.textColor = color
            textEditor?.insertionPointColor = color
            onContentChanged?()
            onSelectionChanged?()
            invalidateCursorRing()
        }
    }
    var size: AnnotationSize = .medium {
        didSet {
            textEditor?.font = Self.annotationFont(ofSize: size.fontSize)
            onContentChanged?()
            onSelectionChanged?()
            invalidateCursorRing()
        }
    }
    /// Text size as a point value; setting it snaps to the nearest preset.
    var fontSize: CGFloat {
        get { size.fontSize }
        set { size = AnnotationSize.closest(fontSize: newValue) }
    }
    var isEditing = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            if !isEditing { cursorPoint = nil }
            needsDisplay = true
        }
    }
    var onRequestEndEditing: (() -> Void)?
    var onContentChanged: (() -> Void)?
    /// Tool, colour, or size changed (from a key or programmatically).
    var onSelectionChanged: (() -> Void)?

    private enum Edit {
        case add(AnnotationItem)
        case remove(AnnotationItem, Int)
        case clear([AnnotationItem])
    }

    private var activeStroke: [CGPoint] = []
    private var activeShape: (from: CGPoint, to: CGPoint)?
    private var textEditor: AnnotationTextEditor?
    private var textEditorOrigin: CGPoint = .zero
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private var cursorPoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // Include in-flight work in every atomic checkpoint. After relaunch a draft
    // is restored as a normal note, without resurrecting an NSTextView.
    var recoverableItems: [AnnotationItem] {
        var result = items
        if activeStroke.count > 1 { result.append(makeFreehandItem(activeStroke)) }
        if let shape = activeShape, let item = makeShapeItem(from: shape.from, to: shape.to) {
            result.append(item)
        }
        if let editor = textEditor, !editor.string.isEmpty {
            result.append(.text(string: editor.string, origin: textEditorOrigin,
                                color: editor.textColor ?? color,
                                fontSize: editor.font?.pointSize ?? size.fontSize,
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
        guard isEditing else { return }
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // ── Keys ────────────────────────────────────────────

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape ends annotate mode
            onRequestEndEditing?()
            return
        }
        guard isEditing else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 51 {  // Backspace
            if command { clear() } else { undo() }
            return
        }
        if command {
            if chars == "z" { if shift { redo(nil) } else { undo() } }
            return  // other ⌘ combos belong to the menu bar, never to a tool
        }
        if let tool = AnnotationTool.forKey(chars) {
            self.tool = tool
            return
        }
        if let index = Int(chars), (1...AnnotationColors.count).contains(index) {
            color = AnnotationColors[index - 1]
            return
        }
        switch chars {
        case "[": stepSize(-1)
        case "]": stepSize(1)
        default: break  // swallow silently: a drawing surface has no beep to give
        }
    }

    private func stepSize(_ delta: Int) {
        let next = size.rawValue + delta
        guard let stepped = AnnotationSize(rawValue: next) else { return }
        size = stepped
    }

    // ── Mouse ───────────────────────────────────────────

    override func mouseMoved(with event: NSEvent) {
        guard isEditing else { return }
        moveCursor(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        moveCursor(to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditing else { return }
        commitPendingText()
        let point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .pen, .highlighter:
            activeStroke = [point]
        case .line, .arrow, .rect, .ellipse:
            activeShape = (point, point)
        case .number:
            let value = (items.compactMap { item -> Int? in
                if case let .number(value, _, _, _) = item { return value }
                return nil
            }.max() ?? 0) + 1
            append(.number(value: value, center: point, color: color, diameter: size.badgeDiameter))
        case .text:
            beginTextEntry(at: point)
        case .eraser:
            erase(at: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditing else { return }
        let point = convert(event.locationInWindow, from: nil)
        moveCursor(to: point)
        if let shape = activeShape {
            let constrained = event.modifierFlags.contains(.shift)
            activeShape = (shape.from, constrained ? Self.constrain(from: shape.from, to: point, kind: tool.shapeKind) : point)
            needsDisplay = true
            onContentChanged?()
            return
        }
        guard !activeStroke.isEmpty else { return }
        activeStroke.append(point)
        needsDisplay = true
        onContentChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let shape = activeShape {
            let end = event.modifierFlags.contains(.shift)
                ? Self.constrain(from: shape.from, to: point, kind: tool.shapeKind) : point
            activeShape = nil
            if hypot(end.x - shape.from.x, end.y - shape.from.y) >= 3, let item = makeShapeItem(from: shape.from, to: end) {
                append(item)
            } else {
                needsDisplay = true
                onContentChanged?()
            }
            return
        }
        guard !activeStroke.isEmpty else { return }
        activeStroke.append(point)
        if activeStroke.count > 1 {
            append(makeFreehandItem(activeStroke))
        }
        activeStroke = []
        needsDisplay = true
        onContentChanged?()
    }

    private func makeFreehandItem(_ points: [CGPoint]) -> AnnotationItem {
        tool == .highlighter
            ? .highlight(points: points, color: color, width: size.highlightWidth)
            : .stroke(points: points, color: color, width: size.penWidth)
    }

    private func makeShapeItem(from: CGPoint, to: CGPoint) -> AnnotationItem? {
        guard let kind = tool.shapeKind else { return nil }
        return .shape(kind: kind, from: from, to: to, color: color, width: size.penWidth)
    }

    /// Shift: lines and arrows snap to 45°, rectangles become squares,
    /// ellipses become circles.
    static func constrain(from: CGPoint, to: CGPoint, kind: AnnotationShapeKind?) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        switch kind {
        case .line?, .arrow?:
            let angle = atan2(dy, dx)
            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: from.x + cos(snapped) * length, y: from.y + sin(snapped) * length)
        case .rect?, .ellipse?:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: from.x + side * (dx < 0 ? -1 : 1), y: from.y + side * (dy < 0 ? -1 : 1))
        case nil:
            return to
        }
    }

    // ── Edits, undo, redo ───────────────────────────────

    private func append(_ item: AnnotationItem) {
        items.append(item)
        undoStack.append(.add(item))
        redoStack.removeAll()
        needsDisplay = true
        onContentChanged?()
    }

    private func erase(at point: CGPoint) {
        guard let index = items.lastIndex(where: { Self.hitTest($0, at: point) }) else { return }
        let item = items.remove(at: index)
        undoStack.append(.remove(item, index))
        redoStack.removeAll()
        needsDisplay = true
        onContentChanged?()
    }

    func undo() {
        if let editor = textEditor {
            editor.undoManager?.undo()
            return
        }
        guard let edit = undoStack.popLast() else { return }
        switch edit {
        case .add:
            _ = items.popLast()
        case let .remove(item, index):
            items.insert(item, at: min(index, items.count))
        case let .clear(saved):
            items = saved
        }
        redoStack.append(edit)
        needsDisplay = true
        onContentChanged?()
    }

    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) {
        if let editor = textEditor {
            editor.undoManager?.redo()
            return
        }
        guard let edit = redoStack.popLast() else { return }
        switch edit {
        case let .add(item):
            items.append(item)
        case let .remove(_, index):
            if items.indices.contains(index) { items.remove(at: index) }
        case .clear:
            items.removeAll()
        }
        undoStack.append(edit)
        needsDisplay = true
        onContentChanged?()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            return textEditor?.undoManager?.canUndo ?? canUndo
        }
        if item.action == #selector(redo(_:)) {
            return textEditor?.undoManager?.canRedo ?? canRedo
        }
        return true
    }

    /// Drops everything, drafts included; one ⌘Z brings the completed marks back.
    func clear() {
        discardTextEditor()
        activeStroke.removeAll()
        activeShape = nil
        if !items.isEmpty {
            undoStack.append(.clear(items))
        }
        items.removeAll()
        redoStack.removeAll()
        needsDisplay = true
        onContentChanged?()
    }

    // ── Text entry ──────────────────────────────────────

    private func beginTextEntry(at point: CGPoint) {
        let fontSize = size.fontSize
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
        cursorPoint = nil
        needsDisplay = true
    }

    func commitPendingText() {
        guard let editor = textEditor else { return }
        let string = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textEditorOrigin
        let itemColor = editor.textColor ?? color
        let pointSize = editor.font?.pointSize ?? size.fontSize
        let width = editor.frame.width
        discardTextEditor()
        if !string.isEmpty {
            append(.text(string: string, origin: origin, color: itemColor, fontSize: pointSize, width: width))
            return
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

    // ── Cursor ring ─────────────────────────────────────

    /// Diameter of the ring that previews the active colour and width.
    private var cursorRingDiameter: CGFloat {
        switch tool {
        case .pen, .line, .arrow, .rect, .ellipse: return size.penWidth + 6
        case .highlighter: return size.highlightWidth
        case .number: return size.badgeDiameter
        case .text: return size.fontSize * 0.7
        case .eraser: return 18
        }
    }

    private func cursorRingRect(at point: CGPoint) -> NSRect {
        let d = cursorRingDiameter + 6
        return NSRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d)
    }

    private func moveCursor(to point: CGPoint?) {
        guard point != cursorPoint else { return }
        if let old = cursorPoint { setNeedsDisplay(cursorRingRect(at: old)) }
        cursorPoint = point
        if let point { setNeedsDisplay(cursorRingRect(at: point)) }
    }

    private func invalidateCursorRing() {
        guard let point = cursorPoint else { return }
        setNeedsDisplay(cursorRingRect(at: point).insetBy(dx: -40, dy: -40))
    }

    // ── Drawing ─────────────────────────────────────────

    static func annotationFont(ofSize size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEditing { drawEditingFrame() }
        for item in items {
            render(item)
        }
        if activeStroke.count > 1 {
            render(makeFreehandItem(activeStroke))
        }
        if let shape = activeShape, let item = makeShapeItem(from: shape.from, to: shape.to) {
            render(item)
        }
        if isEditing, textEditor == nil, let point = cursorPoint {
            drawCursorRing(at: point)
        }
    }

    /// A thin amber frame inside every display says "annotate mode is on"
    /// without the toolbar having to be in view.
    private func drawEditingFrame() {
        guard let window else { return }
        for display in DisplayTopology.displays {
            let local = convert(window.convertFromScreen(display.frame), from: nil)
            let path = NSBezierPath(rect: local.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            NSColor(r: 255, g: 194, b: 75).withAlphaComponent(0.55).setStroke()
            path.stroke()
        }
    }

    private func drawCursorRing(at point: CGPoint) {
        let d = cursorRingDiameter
        let rect = NSRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d)
        let ring = NSBezierPath(ovalIn: rect)
        NSColor.black.withAlphaComponent(0.45).setStroke()
        ring.lineWidth = 3.5
        ring.stroke()
        color.setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
        if tool == .highlighter {
            color.withAlphaComponent(0.25).setFill()
            ring.fill()
        }
    }

    private static func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.line(to: last) }
            return path
        }
        // Quadratic curves through segment midpoints, promoted to cubics.
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let start = path.currentPoint
            let end = CGPoint(x: (points[index].x + points[index + 1].x) / 2,
                              y: (points[index].y + points[index + 1].y) / 2)
            let c1 = CGPoint(x: start.x + 2 / 3 * (control.x - start.x), y: start.y + 2 / 3 * (control.y - start.y))
            let c2 = CGPoint(x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y))
            path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
        }
        path.line(to: points[points.count - 1])
        return path
    }

    /// Colour on top of a soft black halo: the mark reads on any background.
    private static func strokeWithHalo(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.lineWidth = width + 2
        path.stroke()
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    static func shapePath(kind: AnnotationShapeKind, from: CGPoint, to: CGPoint, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        switch kind {
        case .line:
            path.move(to: from)
            path.line(to: to)
        case .arrow:
            let headLength = max(14, width * 3.5)
            let angle = atan2(to.y - from.y, to.x - from.x)
            let spread: CGFloat = .pi / 7
            let shaftEnd = CGPoint(x: to.x - cos(angle) * headLength * 0.6,
                                   y: to.y - sin(angle) * headLength * 0.6)
            path.move(to: from)
            path.line(to: shaftEnd)
            let left = CGPoint(x: to.x - cos(angle - spread) * headLength, y: to.y - sin(angle - spread) * headLength)
            let right = CGPoint(x: to.x - cos(angle + spread) * headLength, y: to.y - sin(angle + spread) * headLength)
            path.move(to: left)
            path.line(to: to)
            path.line(to: right)
            path.close()
        case .rect:
            path.appendRect(NSRect(x: min(from.x, to.x), y: min(from.y, to.y),
                                   width: abs(to.x - from.x), height: abs(to.y - from.y)))
        case .ellipse:
            path.appendOval(in: NSRect(x: min(from.x, to.x), y: min(from.y, to.y),
                                       width: abs(to.x - from.x), height: abs(to.y - from.y)))
        }
        return path
    }

    private func render(_ item: AnnotationItem) {
        switch item {
        case .stroke(let points, let strokeColor, let width):
            guard points.count > 1 else { return }
            Self.strokeWithHalo(Self.smoothPath(points), color: strokeColor, width: width)

        case .highlight(let points, let highlightColor, let width):
            guard points.count > 1 else { return }
            let path = Self.smoothPath(points)
            path.lineCapStyle = .square
            path.lineJoinStyle = .round
            path.lineWidth = width
            highlightColor.withAlphaComponent(0.4).setStroke()
            path.stroke()

        case .shape(let kind, let from, let to, let shapeColor, let width):
            let path = Self.shapePath(kind: kind, from: from, to: to, width: width)
            Self.strokeWithHalo(path, color: shapeColor, width: width)
            if kind == .arrow {
                shapeColor.setFill()
                path.fill()
            }

        case .number(let value, let center, let badgeColor, let diameter):
            let rect = NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            let circle = NSBezierPath(ovalIn: rect)
            NSColor.black.withAlphaComponent(0.35).setStroke()
            circle.lineWidth = 3
            circle.stroke()
            badgeColor.setFill()
            circle.fill()
            let label = "\(value)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: diameter * 0.55, weight: .bold),
                .foregroundColor: Self.contrastingText(on: badgeColor),
            ]
            let labelSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: center.x - labelSize.width / 2, y: center.y - labelSize.height / 2),
                       withAttributes: attributes)

        case .text(let string, let origin, let textColor, let pointSize, let width):
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.annotationFont(ofSize: pointSize),
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

    private static func contrastingText(on color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? NSColor(r: 30, g: 28, b: 26) : .white
    }

    // ── Hit testing (eraser) ────────────────────────────

    static func hitTest(_ item: AnnotationItem, at point: CGPoint) -> Bool {
        switch item {
        case let .stroke(points, _, width):
            return distance(from: point, toPolyline: points) <= width / 2 + 6
        case let .highlight(points, _, width):
            return distance(from: point, toPolyline: points) <= width / 2 + 4
        case let .shape(kind, from, to, _, width):
            let outline: [CGPoint]
            switch kind {
            case .line, .arrow:
                outline = [from, to]
            case .rect:
                outline = [from, CGPoint(x: to.x, y: from.y), to, CGPoint(x: from.x, y: to.y), from]
            case .ellipse:
                let center = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                let rx = abs(to.x - from.x) / 2, ry = abs(to.y - from.y) / 2
                outline = (0...48).map { step -> CGPoint in
                    let angle = CGFloat(step) / 48 * 2 * .pi
                    return CGPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry)
                }
            }
            return distance(from: point, toPolyline: outline) <= width / 2 + 6
        case let .number(_, center, _, diameter):
            return hypot(point.x - center.x, point.y - center.y) <= diameter / 2 + 2
        case let .text(string, origin, _, pointSize, width):
            let bounding = NSString(string: string).boundingRect(
                with: NSSize(width: width - 6, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: annotationFont(ofSize: pointSize)]
            )
            return NSRect(x: origin.x, y: origin.y, width: width, height: bounding.height + 6).contains(point)
        }
    }

    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        if points.count == 1 { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.infinity
        for index in 0..<(points.count - 1) {
            best = min(best, distance(from: point, toSegment: points[index], points[index + 1]))
        }
        return best
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - projection.x, p.y - projection.y)
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

/// A draggable HUD strip: icon on top, its key underneath, so the bindings
/// teach themselves. Lands on the display under the mouse; once the user has
/// dragged it somewhere it stays there while it remains on a screen.
final class AnnotationToolbar {
    var onToolChanged: ((AnnotationTool) -> Void)?
    var onColorChanged: ((NSColor) -> Void)?
    var onSizeChanged: ((AnnotationSize) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onClear: (() -> Void)?
    var onDone: (() -> Void)?

    private static let accent = NSColor(r: 255, g: 194, b: 75)
    private static let height: CGFloat = 54

    private var panel: NSPanel?
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var sizeButtons: [NSButton] = []
    private var lastAutoOrigin: NSPoint?

    /// The strip's content, for offscreen rendering in tests and proofs.
    var contentView: NSView? { panel?.contentView }

    func show() {
        if panel == nil {
            build()
        }
        position()
        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func sync(tool: AnnotationTool, color: NSColor, size: AnnotationSize) {
        select(tool: tool)
        select(color: color)
        select(size: size)
    }

    private func position() {
        guard let panel, let display = DisplayTopology.underMouse ?? DisplayTopology.primary else { return }
        let movedByUser = lastAutoOrigin != nil && panel.frame.origin != lastAutoOrigin
        let stillVisible = DisplayTopology.displays.contains { $0.visibleFrame.intersects(panel.frame) }
        if movedByUser && stillVisible { return }
        let frame = display.visibleFrame
        let origin = NSPoint(x: frame.midX - panel.frame.width / 2,
                             y: frame.maxY - panel.frame.height - 12)
        panel.setFrameOrigin(origin)
        lastAutoOrigin = origin
    }

    private func build() {
        let height = Self.height
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        newPanel.level = .floating + 1
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.isMovableByWindowBackground = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])

        for tool in AnnotationTool.allCases {
            let button = iconButton(symbol: tool.symbol, action: #selector(toolTapped(_:)),
                                    tip: "\(tool.name) (\(tool.key.uppercased()))")
            button.tag = AnnotationTool.allCases.firstIndex(of: tool) ?? 0
            toolButtons[tool] = button
            stack.addArrangedSubview(captioned(button, key: tool.key.uppercased()))
        }

        stack.addArrangedSubview(divider())

        for (index, swatch) in AnnotationColors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = swatch.cgColor
            button.layer?.cornerRadius = 8
            button.tag = index
            button.toolTip = "\(AnnotationColorNames[index]) (\(index + 1))"
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 16).isActive = true
            button.heightAnchor.constraint(equalToConstant: 16).isActive = true
            colorButtons.append(button)
            stack.addArrangedSubview(captioned(button, key: "\(index + 1)", width: 24))
        }

        stack.addArrangedSubview(divider())

        for size in AnnotationSize.allCases {
            let button = NSButton(title: "", target: self, action: #selector(sizeTapped(_:)))
            button.isBordered = false
            button.wantsLayer = true
            let dot: CGFloat = [7, 10, 14][size.rawValue]
            button.layer?.backgroundColor = NSColor.white.cgColor
            button.layer?.cornerRadius = dot / 2
            button.tag = size.rawValue
            button.toolTip = "\(size.name) ([ and ] step)"
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: dot).isActive = true
            button.heightAnchor.constraint(equalToConstant: dot).isActive = true
            sizeButtons.append(button)
            stack.addArrangedSubview(captioned(button, key: size.label, width: 24))
        }

        stack.addArrangedSubview(divider())

        stack.addArrangedSubview(captioned(
            iconButton(symbol: "arrow.uturn.backward", action: #selector(undoTapped), tip: "Undo (⌘Z, ⌫)"), key: "⌘Z"))
        stack.addArrangedSubview(captioned(
            iconButton(symbol: "arrow.uturn.forward", action: #selector(redoTapped), tip: "Redo (⇧⌘Z)"), key: "⇧⌘Z"))
        stack.addArrangedSubview(captioned(
            iconButton(symbol: "trash", action: #selector(clearTapped), tip: "Clear all (⌘⌫, undoable)"), key: "⌘⌫"))

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .small
        doneButton.toolTip = "Leave annotate mode (Escape)"
        stack.addArrangedSubview(captioned(doneButton, key: "esc", width: 60))

        newPanel.contentView = background
        newPanel.setContentSize(NSSize(width: stack.fittingSize.width, height: height))
        background.frame = NSRect(origin: .zero, size: newPanel.frame.size)
        panel = newPanel
    }

    private func iconButton(symbol: String, action: Selector, tip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.toolTip = tip
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    /// Control on top, its key printed underneath.
    private func captioned(_ control: NSView, key: String, width: CGFloat = 30) -> NSView {
        let caption = NSTextField(labelWithString: key)
        caption.font = .monospacedSystemFont(ofSize: 8, weight: .medium)
        caption.textColor = NSColor.white.withAlphaComponent(0.55)
        caption.alignment = .center
        let column = NSStackView(views: [control, caption])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 1
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: width).isActive = true
        return column
    }

    private func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }

    private func select(tool: AnnotationTool) {
        for (candidate, button) in toolButtons {
            let selected = candidate == tool
            button.contentTintColor = selected ? Self.accent : .white
            button.layer?.backgroundColor = selected
                ? NSColor.white.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        }
    }

    private func select(color: NSColor) {
        for button in colorButtons {
            let isSelected = AnnotationColors[button.tag] == color
            button.layer?.borderWidth = isSelected ? 2.5 : 0
            button.layer?.borderColor = NSColor.white.cgColor
            button.layer?.transform = isSelected
                ? CATransform3DMakeScale(1.15, 1.15, 1) : CATransform3DIdentity
        }
    }

    private func select(size: AnnotationSize) {
        for button in sizeButtons {
            let isSelected = button.tag == size.rawValue
            button.layer?.backgroundColor = (isSelected ? Self.accent : NSColor.white.withAlphaComponent(0.7)).cgColor
        }
    }

    @objc private func toolTapped(_ sender: NSButton) {
        let tool = AnnotationTool.allCases[sender.tag]
        select(tool: tool)
        onToolChanged?(tool)
    }

    @objc private func colorTapped(_ sender: NSButton) {
        let color = AnnotationColors[sender.tag]
        select(color: color)
        onColorChanged?(color)
    }

    @objc private func sizeTapped(_ sender: NSButton) {
        guard let size = AnnotationSize(rawValue: sender.tag) else { return }
        select(size: size)
        onSizeChanged?(size)
    }

    @objc private func undoTapped() { onUndo?() }
    @objc private func redoTapped() { onRedo?() }
    @objc private func clearTapped() { onClear?() }
    @objc private func doneTapped() { onDone?() }
}
