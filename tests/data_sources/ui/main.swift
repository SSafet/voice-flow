import Cocoa

// The Sources pane is tested in isolation against its real store and collector.
// Only the app-wide palette and flipped container are supplied here.
enum Theme {
    static let bg = NSColor.windowBackgroundColor
    static let bgLighter = NSColor.controlBackgroundColor
    static let text = NSColor.labelColor
    static let text2 = NSColor.secondaryLabelColor
    static let accent = NSColor.systemOrange
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { child in
        (child as? T).map { [$0] } ?? []
    } + view.subviews.flatMap { descendants(type, in: $0) }
}
let app = NSApplication.shared
let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-source-ui-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let store = DataSourceStore(root: root)
let collector = SourceCollector(store: store)
var source = SourceDefinition(name: "Source UI fixture", kind: .website, location: "https://example.test", instructions: "Original instructions")
try store.save(source)
try store.commitCollection(sourceID: source.id, result: SourceCollectionResult(documents: (1...80).map { CollectedSourceDocument(title: "Evidence \($0)", text: "Fixture document \($0)") }))
let view = SourcesView(store: store, collector: collector)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = view
// Filtering must keep the live AppKit search field and its field editor.
let search = descendants(NSSearchField.self, in: view)[0]
expect(window.makeFirstResponder(search), "Search field cannot receive keyboard focus")
search.stringValue = "Source UI"
let searchEditor = search.currentEditor() as? NSTextView
expect(searchEditor != nil, "Search did not obtain an AppKit field editor")
searchEditor?.setSelectedRange(NSRange(location: 6, length: 2))
_ = search.sendAction(search.action, to: search.target)
expect(descendants(NSSearchField.self, in: view).first === search, "Filtering replaced the active search control")
expect(search.currentEditor() === searchEditor && searchEditor?.selectedRange() == NSRange(location: 6, length: 2), "Filtering lost search focus or selection")
search.stringValue = "no matching source name"
_ = search.sendAction(search.action, to: search.target)
expect(descendants(NSTextField.self, in: view).contains { $0.stringValue == "No matching connected sources." }, "A filtered empty inventory must explain that no sources match")
window.makeFirstResponder(nil)

view.qaAction(["action": "connect"])
view.qaAction(["action": "save"])
expect(!(view.qaState()["error"] as? String ?? "").isEmpty, "Submitting the untouched connection form silently did nothing")
expect(store.listSources().count == 5, "An invalid connection form created a source")
// Failed validation stays beside Save and keeps the existing editor alive.
let connectionEditor = descendants(NSTextView.self, in: view).first { $0.isEditable }!
window.makeFirstResponder(connectionEditor)
connectionEditor.string = "Keep this source guidance"
view.textDidChange(Notification(name: NSText.didChangeNotification, object: connectionEditor))
connectionEditor.setSelectedRange(NSRange(location: 5, length: 4))
view.qaAction(["action": "save"])
expect(descendants(NSTextView.self, in: view).contains { $0 === connectionEditor }, "Validation replaced the source instructions editor")
expect(window.firstResponder === connectionEditor && connectionEditor.selectedRange() == NSRange(location: 5, length: 4), "Validation moved the source instructions cursor")
let inlineFeedback = descendants(NSTextField.self, in: view).first { $0.identifier?.rawValue == "source-form-feedback" }!
let formScroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
let feedbackFrame = formScroll.documentView!.convert(inlineFeedback.bounds, from: inlineFeedback)
expect(formScroll.documentVisibleRect.intersects(feedbackFrame), "Validation feedback is outside the visible form")
expect(inlineFeedback.stringValue == view.qaState()["error"] as? String, "Validation error is not shown beside the form action")
window.makeFirstResponder(nil)
view.showInventory()
expect(formScroll.contentView.bounds.origin.y == 0, "Returning from a deep form leaves the inventory scrolled offscreen")
expect(view.qaState()["error"] as? String == "", "Form error leaked into the inventory")

view.showSource(source.id)
view.qaAction(["instructions": "Unsaved source instructions"])
view.refresh()
expect(view.qaState()["instructions"] as? String == "Unsaved source instructions", "Collector refresh destroyed unsaved instructions")
view.qaAction(["action": "history", "source_id": source.id])
expect((view.qaState()["route"] as? String)?.contains("snapshots") == true, "In-app collection history route")
_ = view.goBack()
expect(view.qaState()["instructions"] as? String == "Unsaved source instructions", "Navigation destroyed draft")
view.qaAction(["action": "save"])
expect(store.source(id: source.id)?.instructions == "Unsaved source instructions", "Save did not persist draft")
expect((view.qaState()["feedback"] as? String)?.hasPrefix("Saved.") == true, "Save feedback is missing")
let savedEditor = descendants(NSTextView.self, in: view).first { $0.isEditable }!
window.makeFirstResponder(savedEditor)
savedEditor.string = "More unsaved guidance"
view.textDidChange(Notification(name: NSText.didChangeNotification, object: savedEditor))
savedEditor.setSelectedRange(NSRange(location: 3, length: 2))
expect(view.qaState()["feedback"] as? String == "Unsaved changes", "Saved feedback remained after an unsaved edit")
view.refresh()
expect(window.firstResponder === savedEditor && savedEditor.selectedRange() == NSRange(location: 3, length: 2), "Collector update moved the active instructions cursor")
// Returning to the persisted value must remove the draft, so a later external
// change is visible instead of being hidden behind a stale copy of saved text.
savedEditor.string = "Unsaved source instructions"
view.textDidChange(Notification(name: NSText.didChangeNotification, object: savedEditor))
expect(view.qaState()["feedback"] as? String == "", "Reverting to saved text kept a stale unsaved indicator")
window.makeFirstResponder(nil)
view.refresh()
source = store.source(id: source.id)!
source.instructions = "Updated from another editor"
try store.save(source)
view.refresh()
expect(view.qaState()["instructions"] as? String == "Updated from another editor", "Saved draft was restashed and masked new store instructions")
view.qaAction(["action": "items", "source_id": source.id])
expect((view.qaState()["route"] as? String)?.contains("items") == true, "Browse all items stays in app")
view.layoutSubtreeIfNeeded()
let lastItem = descendants(NSButton.self, in: view).first { $0.title == "Evidence 80  ›" }!
lastItem.scrollToVisible(lastItem.bounds)
let listScroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
let listPosition = listScroll.contentView.bounds.origin
expect(listPosition.y > 100, "List scroll fixture did not move beyond the first viewport")
lastItem.performClick(nil)
expect((view.qaState()["route"] as? String)?.contains("item(") == true, "Collected-item link did not open its document")
_ = view.goBack()
expect(abs(listScroll.contentView.bounds.origin.y - listPosition.y) < 1, "Back lost the collection list reading position")
view.qaAction(["action": "item", "source_id": source.id])
expect((view.qaState()["route"] as? String)?.contains("item") == true, "Inspect individual document route")
view.showSource("builtin-dictations")
expect(!descendants(NSTextField.self, in: view).contains { $0.stringValue == "Folder" }, "Built-in source exposes a meaningless Folder field")
view.qaAction(["instructions": "Built-in draft"])
view.refresh()
expect(view.qaState()["instructions"] as? String == "Built-in draft", "Built-in instructions survive refresh")
view.qaAction(["action": "save"])
expect(store.source(id: "builtin-dictations")?.instructions == "Built-in draft", "Built-in instructions persist")
window.setContentSize(NSSize(width: 380, height: 500))
view.layoutSubtreeIfNeeded()
expect(view.bounds.width > 0, "Pane lays out at a narrow width")
for field in descendants(NSTextField.self, in: view) {
    let frame = view.convert(field.bounds, from: field)
    expect(frame.minX >= 0 && frame.maxX <= view.bounds.width + 1, "Source text or form field overflows the narrow pane")
}
collector.stop()
print("PASS: Sources keeps search/editor focus and selections, validates untouched forms inline, tracks unsaved/reverted edits, restores list scroll, preserves drafts and external updates, hides built-in connection fields, and lays out at narrow width")
