import Cocoa

struct Theme {
    static let bg = NSColor(calibratedRed: 28/255, green: 26/255, blue: 24/255, alpha: 1)
    static let text = NSColor(calibratedRed: 240/255, green: 230/255, blue: 214/255, alpha: 1)
    static let text2 = NSColor(calibratedRed: 176/255, green: 160/255, blue: 144/255, alpha: 1)
}
class FlippedView: NSView { override var isFlipped: Bool { true } }
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-queue-editor-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let url = root.appendingPathComponent("queue.json")
let store = QueueEditorStore(url: url)
try store.reload()
try store.add("  First step  ")
try store.add("Second step")
let reopened = QueueEditorStore(url: url)
try reopened.reload()
expect(reopened.items.map(\.text) == ["First step", "Second step"], "add must persist")
try reopened.remove(at: 0)
try store.reload()
expect(store.items.map(\.text) == ["Second step"], "remove must persist")
let external = Data(#"{"extra":"keep","items":[{"id":"a","text":"Changed externally","custom":42},"duplicate","duplicate"]}"#.utf8)
try external.write(to: url, options: .atomic)
do { try store.remove(at: 0); fatalError("stale delete must fail") }
catch QueueEditorStore.EditError.changed {}
expect((try? Data(contentsOf: url)) == external, "conflict must preserve external edit")
try store.reload()
try store.remove(at: 1)
expect(store.items.count == 2, "duplicate strings must remove independently")
let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
expect(saved["extra"] as? String == "keep", "unknown top-level metadata must survive")
expect((saved["items"] as! [[String: Any]])[0]["custom"] as? Int == 42, "item metadata must survive")
try Data("broken".utf8).write(to: url)
do { try store.reload(); fatalError("malformed file must fail") } catch {}
do { try store.add("No data loss"); fatalError("malformed file must not be overwritten") } catch {}
expect((try? String(contentsOf: url, encoding: .utf8)) == "broken", "invalid input must survive")
try Data(#"{"items":[]}"#.utf8).write(to: url)
try store.reload()
do { try store.add("   "); fatalError("blank item must fail") } catch QueueEditorStore.EditError.empty {}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let editor = QueueEditorView(url: url)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
window.contentView = editor
window.makeKeyAndOrderFront(nil)
editor.activate()
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let content = editor
let input = descendants(content).compactMap { $0 as? NSTextField }.first { $0.placeholderString != nil }!
let add = descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Add" }!
input.stringValue = "Finish the focused work block"
add.performClick(nil)
input.stringValue = "Take a walk"
add.performClick(nil)
try store.reload()
expect(store.items.count == 2, "real Add button must save")
let remove = descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Remove" }!
remove.performClick(nil)
try store.reload()
expect(store.items.map(\.text) == ["Take a walk"], "real Remove button must save")
input.stringValue = "Draft stays while the list refreshes"
try store.add("Plan tomorrow’s first step")
let reload = descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Reload" }!
reload.performClick(nil)
expect(input.stringValue == "Draft stays while the list refreshes", "refresh must retain typing")
window.setContentSize(NSSize(width: 440, height: 420))
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
content.layoutSubtreeIfNeeded()
if let path = ProcessInfo.processInfo.environment["VF_QUEUE_SCREENSHOT"] {
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
    try capture.run(); capture.waitUntilExit()
    expect(capture.terminationStatus == 0, "window screenshot must succeed")
}
window.close()
print("queue editor: store persistence, stale-delete protection, malformed-file protection, metadata preservation, Add/Remove buttons and draft retention passed")
