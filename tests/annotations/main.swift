import Cocoa

// UI-independent helpers normally supplied by Core/UI.swift.
func vflog(_ message: String) { print(message) }
extension NSColor {
    convenience init(r: Int, g: Int, b: Int) {
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                  blue: CGFloat(b) / 255, alpha: 1)
    }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let crashWriter = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--crash-writer"
let root = crashWriter ? URL(fileURLWithPath: CommandLine.arguments[2])
    : FileManager.default.temporaryDirectory.appendingPathComponent("annotation-tests-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let store = AnnotationStore(url: root.appendingPathComponent("annotations.json"))
let app = NSApplication.shared
final class TestPanel: NSPanel { override var canBecomeKey: Bool { true } }
let window = TestPanel(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
let canvas = AnnotationCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
window.contentView = canvas
window.makeKeyAndOrderFront(nil)
expect(app.keyWindow === window, "test panel did not become key")
let editMenu = NSMenu(title: "Edit")
let menuUndo = editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
menuUndo.keyEquivalentModifierMask = [.command]
let menuRedo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
menuRedo.keyEquivalentModifierMask = [.command, .shift]
func menuKey(redo: Bool = false) {
    if redo {
        editMenu.update()
        expect(menuRedo.isEnabled, "native Redo menu was disabled")
        editMenu.performActionForItem(at: 1)
        return
    }
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                modifierFlags: redo ? [.command, .shift] : [.command],
                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                characters: "z", charactersIgnoringModifiers: "z",
                                isARepeat: false, keyCode: 6)!
    expect(editMenu.performKeyEquivalent(with: event), "menu shortcut was not handled (redo=\(redo))")
}
canvas.isEditing = true
canvas.onContentChanged = { try! store.save(canvas.recoverableItems) }
func mouse(_ type: NSEvent.EventType, _ x: CGFloat = 100, _ y: CGFloat = 200) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                       eventNumber: 1, clickCount: 1, pressure: 1)!
}
func startText(_ text: String) -> AnnotationTextEditor {
    canvas.tool = .text
    canvas.mouseDown(with: mouse(.leftMouseDown))
    let editor = canvas.subviews.compactMap { $0 as? AnnotationTextEditor }.first!
    editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.breakUndoCoalescing()
    // Let AppKit close its event group naturally before invoking the menu.
    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    return editor
}
func savedText() throws -> String? {
    if case let .text(string, _, _, _, _)? = try store.load().last { return string }
    return nil
}

// A separate process dies with an open draft, without shutdown or a flush.
if crashWriter {
    canvas.tool = .pen
    canvas.mouseDown(with: mouse(.leftMouseDown))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, 120, 220))
    canvas.mouseUp(with: mouse(.leftMouseUp, 150, 250))
    _ = startText("draft survived SIGKILL")
    kill(getpid(), SIGKILL)
    exit(2)
}

// Real NSTextView editing: drafts are already on disk before commit or shutdown.
autoreleasepool {
    let editor = startText("first line\nunfinished second line")
    expect(try! savedText() == editor.string, "uncommitted draft was not saved")
    expect(editor.undoManager !== window.undoManager, "text undo leaked into window manager")
    expect(editor.undoManager?.canUndo == true, "live editor lost native text Undo")
    menuKey()
    expect(editor.string.isEmpty, "native text Undo failed")
    expect(try! store.load().isEmpty, "text Undo failed to checkpoint the empty draft")
    menuKey(redo: true)
    expect(try! savedText() == editor.string, "text Redo did not checkpoint")
    canvas.fontSize = 32
    canvas.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 0.9)
    let undo = editor.undoManager!
    editor.cancelOperation(nil) // Escape commits.
    expect(canvas.items.count == 1 && editor.superview == nil, "Escape did not commit/detach")
    expect(!undo.canUndo && !undo.canRedo, "detached editor left stale undo targets")
    expect(window.firstResponder === canvas, "focus stayed on detached editor")
}
menuKey()
expect(canvas.items.isEmpty && (try! store.load()).isEmpty, "mark Undo did not persist")
menuKey(redo: true)
expect(canvas.items.count == 1, "mark Redo failed")
if case let .text(text, origin, color, size, width) = try store.load()[0] {
    expect(text == "first line\nunfinished second line" && size == 32 && width == 440,
           "snapshot lost text/typography")
    expect(origin.x == 100 && abs(color.alphaComponent - 0.9) < 0.001, "snapshot lost geometry/color")
} else { fatalError("text changed kind") }

// Many editor lifetimes, undo/redo, and an independent neighboring editor.
let neighbor = NSTextView(frame: .zero)
window.contentView?.addSubview(neighbor)
neighbor.allowsUndo = true
neighbor.insertText("unrelated", replacementRange: NSRange(location: NSNotFound, length: 0))
neighbor.breakUndoCoalescing()
let neighboringUndo = neighbor.undoManager!
for _ in 0..<30 {
    autoreleasepool {
        let editor = startText("next note")
        let manager = editor.undoManager!
        canvas.commitPendingText()
        expect(!manager.canUndo, "stale Undo survived commit")
    }
    canvas.undo()
    canvas.redo(nil)
}
expect(neighboringUndo.canUndo, "annotation cleanup erased another editor's Undo")

// Clear discards an active draft; Done/commit cannot resurrect it later.
autoreleasepool {
    let editor = startText("must stay cleared")
    let undo = editor.undoManager!
    canvas.clear()
    canvas.commitPendingText()
    canvas.redo(nil)
    expect(!undo.canUndo && editor.superview == nil, "Clear retained the live editor")
    expect(canvas.items.isEmpty && (try! store.load()).isEmpty, "Clear resurrected data")
}

// Keyboard control: tools, colours, sizes, undo/redo/clear — never while typing.
func key(_ chars: String, keyCode: UInt16 = 0, _ flags: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    canvas.keyDown(with: event)
}
func shiftMouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [.shift],
                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                       eventNumber: 1, clickCount: 1, pressure: 1)!
}
func drag(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
    canvas.mouseDown(with: mouse(.leftMouseDown, x1, y1))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, (x1 + x2) / 2, (y1 + y2) / 2))
    canvas.mouseUp(with: mouse(.leftMouseUp, x2, y2))
}
canvas.clear()
canvas.tool = .pen; canvas.size = .medium; canvas.color = AnnotationColors[0]
var selectionChanges = 0
canvas.onSelectionChanged = { selectionChanges += 1 }
key("a"); expect(canvas.tool == .arrow, "A did not pick the arrow tool")
key("3"); expect(canvas.color == AnnotationColors[2], "3 did not pick the third colour")
key("9"); expect(canvas.color == AnnotationColors[2], "an unbound digit changed the colour")
key("]"); expect(canvas.size == .large, "] did not step the size up")
key("]"); expect(canvas.size == .large, "size stepped past large")
key("["); key("["); expect(canvas.size == .small, "[ did not step the size down")
expect(selectionChanges == 5, "toolbar sync fired \(selectionChanges) times, expected 5")
key("r")
canvas.mouseDown(with: mouse(.leftMouseDown, 100, 100))
canvas.mouseDragged(with: shiftMouse(.leftMouseDragged, 200, 150))
expect(try! store.load().count == 1, "in-flight shape missing from disk")
canvas.mouseUp(with: shiftMouse(.leftMouseUp, 200, 150))
if case let .shape(kind, from, to, _, width) = canvas.items[0] {
    let side = to.x - from.x  // the canvas is flipped: window y runs the other way
    expect(kind == .rect && from == canvas.convert(NSPoint(x: 100, y: 100), from: nil)
           && side == 100 && abs(to.y - from.y) == side,
           "shift did not constrain the rectangle to a square: \(from) → \(to)")
    expect(width == AnnotationSize.small.penWidth, "shape ignored the size dial")
} else { fatalError("rectangle changed kind") }
expect(try! store.load().count == 1, "completed shape was duplicated")
key("a")
canvas.mouseDown(with: mouse(.leftMouseDown, 0, 0))
canvas.mouseUp(with: mouse(.leftMouseUp, 1, 1))
expect(canvas.items.count == 1, "a click without a drag produced a shape")
key("h"); drag(50, 400, 250, 400)
if case let .highlight(_, _, width) = canvas.items[1] {
    expect(width == AnnotationSize.small.highlightWidth, "highlighter ignored the size dial")
} else { fatalError("highlight changed kind") }
key("n")
canvas.mouseDown(with: mouse(.leftMouseDown, 300, 300)); canvas.mouseUp(with: mouse(.leftMouseUp, 300, 300))
canvas.mouseDown(with: mouse(.leftMouseDown, 340, 300)); canvas.mouseUp(with: mouse(.leftMouseUp, 340, 300))
func numbers() -> [Int] {
    canvas.items.compactMap { if case let .number(value, _, _, _) = $0 { return value }; return nil }
}
expect(numbers() == [1, 2], "number stamps did not count up: \(numbers())")
canvas.undo()
canvas.mouseDown(with: mouse(.leftMouseDown, 380, 300)); canvas.mouseUp(with: mouse(.leftMouseUp, 380, 300))
expect(numbers() == [1, 2], "the counter did not follow undo: \(numbers())")
key("e")
let countBeforeErase = canvas.items.count
canvas.mouseDown(with: mouse(.leftMouseDown, 302, 298))
expect(canvas.items.count == countBeforeErase - 1 && numbers() == [2], "eraser did not remove only the mark under the click")
canvas.mouseDown(with: mouse(.leftMouseDown, 700, 550))
expect(canvas.items.count == countBeforeErase - 1, "eraser removed something on an empty click")
canvas.undo()
expect(numbers() == [1, 2], "undo did not put the erased mark back in order: \(numbers())")
canvas.mouseDown(with: mouse(.leftMouseDown, 150, 100))  // on the square's top edge
expect(canvas.items.count == countBeforeErase - 1, "eraser missed the rectangle edge")
canvas.undo()
let countBeforeClear = canvas.items.count
key("\u{8}", keyCode: 51, [.command])
expect(canvas.items.isEmpty, "⌘⌫ did not clear")
key("z", keyCode: 6, [.command])
expect(canvas.items.count == countBeforeClear, "⌘Z did not undo Clear")
key("z", keyCode: 6, [.command, .shift])
expect(canvas.items.isEmpty, "⇧⌘Z did not redo Clear")
key("z", keyCode: 6, [.command])
key("\u{8}", keyCode: 51)
expect(canvas.items.count == countBeforeClear - 1, "⌫ did not undo the last mark")
key("z", keyCode: 6, [.command, .shift])
expect(canvas.items.count == countBeforeClear, "⇧⌘Z did not redo after ⌫")
autoreleasepool {
    let editor = startText("typed")
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: "p",
                                 charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
    editor.keyDown(with: event)
    expect(canvas.tool == .text && editor.string == "typedp", "a tool key fired while typing a note")
    canvas.commitPendingText()
}
// The text box: opaque, outlined, draggable by its header, resizable by its
// corner, with A−/A+ and ⌘[ ⌘] stepping the shared size dial.
autoreleasepool {
    canvas.size = .medium
    let editor = startText("boxed note")
    let chrome = canvas.subviews.compactMap { $0 as? AnnotationTextChrome }.first!
    expect(!editor.drawsBackground, "text area is not see-through")
    expect(editor.outlineWidth > 0 && editor.outlineColor == NSColor.white, "typed text has no white outline")
    expect(canvas.subviews.firstIndex(of: chrome)! < canvas.subviews.firstIndex(of: editor)!,
           "chrome sits above the editor")
    func chromeMouse(_ type: NSEvent.EventType, _ chromePoint: NSPoint, dx: CGFloat = 0, dy: CGFloat = 0) -> NSEvent {
        var canvasPoint = chrome.convert(chromePoint, to: canvas)
        canvasPoint.x += dx; canvasPoint.y += dy
        let windowPoint = canvas.convert(canvasPoint, to: nil)
        return NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    let originBefore = editor.frame.origin
    let header = NSPoint(x: 60, y: 10)
    chrome.mouseDown(with: chromeMouse(.leftMouseDown, header))
    chrome.mouseDragged(with: chromeMouse(.leftMouseDragged, header, dx: 40, dy: 30))
    chrome.mouseUp(with: chromeMouse(.leftMouseUp, header, dx: 40, dy: 30))
    expect(editor.frame.origin == CGPoint(x: originBefore.x + 40, y: originBefore.y + 30),
           "header drag did not move the box: \(editor.frame.origin) vs \(originBefore)")
    expect(chrome.frame == AnnotationTextChrome.frame(around: editor.frame), "chrome did not follow the editor")
    let widthBefore = editor.frame.width
    let corner = NSPoint(x: chrome.handleRect.midX, y: chrome.handleRect.midY)
    chrome.mouseDown(with: chromeMouse(.leftMouseDown, corner))
    chrome.mouseDragged(with: chromeMouse(.leftMouseDragged, corner, dx: -60, dy: 20))
    chrome.mouseUp(with: chromeMouse(.leftMouseUp, corner, dx: -60, dy: 20))
    expect(editor.frame.width == widthBefore - 60, "corner drag did not resize the box: \(editor.frame.width)")
    expect(editor.frame.height >= editor.minSize.height && editor.minSize.height > editor.font!.pointSize + 12,
           "corner drag did not make the box taller")
    let bigger = chrome.rect(for: .bigger)
    chrome.mouseDown(with: chromeMouse(.leftMouseDown, NSPoint(x: bigger.midX, y: bigger.midY)))
    expect(canvas.size == .large && editor.font?.pointSize == 32, "A+ did not step the size")
    let cmdBracket = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "[",
                                      charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33)!
    editor.keyDown(with: cmdBracket)
    expect(canvas.size == .medium && editor.string == "boxed note", "⌘[ did not step the size down without typing")
    let movedOrigin = editor.frame.origin, movedWidth = editor.frame.width
    let done = chrome.rect(for: .done)
    chrome.mouseDown(with: chromeMouse(.leftMouseDown, NSPoint(x: done.midX, y: done.midY)))
    expect(editor.superview == nil && chrome.superview == nil, "✓ did not commit and remove the box")
    if case let .text(text, origin, _, pointSize, width) = canvas.items.last! {
        expect(text == "boxed note" && origin == movedOrigin && width == movedWidth && pointSize == 22,
               "committed note lost the moved/resized geometry")
    } else { fatalError("boxed note changed kind") }
}
let roundTrip = try store.load()
expect(roundTrip.count == canvas.items.count, "new mark kinds did not round-trip: \(roundTrip.count)")
canvas.clear()
canvas.onSelectionChanged = nil
canvas.tool = .pen; canvas.size = .medium

// The checkpoint includes a stroke before mouse-up, and one copy after it.
canvas.tool = .pen
canvas.mouseDown(with: mouse(.leftMouseDown))
canvas.mouseDragged(with: mouse(.leftMouseDragged, 120, 220))
expect(try! store.load().count == 1, "in-flight stroke missing from disk")
canvas.mouseUp(with: mouse(.leftMouseUp, 150, 250))
expect(try! store.load().count == 1, "completed stroke was duplicated")
if case let .stroke(points, _, _) = try store.load()[0] {
    expect(points.count == 3, "stroke geometry did not round-trip")
} else { fatalError("stroke changed kind") }

// Simulate abrupt process loss: a fresh store reads the draft without a flush.
autoreleasepool { _ = startText("recover after crash") }
let freshStore = AnnotationStore(url: store.url)
expect(try! freshStore.load().count == 2, "restart lost stroke or uncommitted draft")
let restored = AnnotationOverlay(store: freshStore)
expect(restored.hasContent && !restored.isEditing, "launch did not restore click-through marks")
restored.clear()
expect(try! freshStore.load().isEmpty, "restored Clear did not save")
try Data("corrupt".utf8).write(to: store.url)
let corrupt = AnnotationOverlay(store: freshStore)
expect(!corrupt.hasContent, "corrupt snapshot fabricated marks")
expect(try! FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("unreadable-") },
       "unreadable snapshot was not preserved")
let killedRoot = root.appendingPathComponent("killed-process")
let writer = Process()
writer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
writer.arguments = ["--crash-writer", killedRoot.path]
try writer.run()
writer.waitUntilExit()
expect(writer.terminationReason == .uncaughtSignal && writer.terminationStatus == SIGKILL,
       "crash recovery probe did not exit abruptly")
let recovered = try AnnotationStore(url: killedRoot.appendingPathComponent("annotations.json")).load()
expect(recovered.count == 2, "hard-killed process lost drawings or draft")
if case let .text(text, _, _, _, _) = recovered[1] {
    expect(text == "draft survived SIGKILL", "hard-killed process lost draft text")
} else { fatalError("hard-killed draft changed kind") }
print("annotation regression tests passed (including native menu routing and SIGKILL recovery)")
