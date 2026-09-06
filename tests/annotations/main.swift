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

// The checkpoint includes a stroke before mouse-up, and one copy after it.
canvas.tool = .pen
canvas.mouseDown(with: mouse(.leftMouseDown))
canvas.mouseDragged(with: mouse(.leftMouseDragged, 120, 220))
expect(try! store.load().count == 1, "in-flight stroke missing from disk")
canvas.mouseUp(with: mouse(.leftMouseUp, 150, 250))
expect(try! store.load().count == 1, "completed stroke was duplicated")
if case let .stroke(points, _) = try store.load()[0] {
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
