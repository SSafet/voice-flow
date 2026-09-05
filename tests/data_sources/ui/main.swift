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
let app = NSApplication.shared
let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-source-ui-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let store = DataSourceStore(root: root)
let collector = SourceCollector(store: store)
var source = SourceDefinition(name: "Source UI fixture", kind: .website, location: "https://example.test", instructions: "Original instructions")
try store.save(source)
try store.commitCollection(sourceID: source.id, result: SourceCollectionResult(documents: (1...8).map { CollectedSourceDocument(title: "Evidence \($0)", text: "Fixture document \($0)") }))
let view = SourcesView(store: store, collector: collector)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.contentView = view
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
view.refresh()
source = store.source(id: source.id)!
source.instructions = "Updated from another editor"
try store.save(source)
view.refresh()
expect(view.qaState()["instructions"] as? String == "Updated from another editor", "Saved draft was restashed and masked new store instructions")
view.qaAction(["action": "items", "source_id": source.id])
expect((view.qaState()["route"] as? String)?.contains("items") == true, "Browse all items stays in app")
view.qaAction(["action": "item", "source_id": source.id])
expect((view.qaState()["route"] as? String)?.contains("item") == true, "Inspect individual document route")
view.showSource("builtin-dictations")
view.qaAction(["instructions": "Built-in draft"])
view.refresh()
expect(view.qaState()["instructions"] as? String == "Built-in draft", "Built-in instructions survive refresh")
view.qaAction(["action": "save"])
expect(store.source(id: "builtin-dictations")?.instructions == "Built-in draft", "Built-in instructions persist")
window.setContentSize(NSSize(width: 380, height: 500))
view.layoutSubtreeIfNeeded()
expect(view.bounds.width > 0, "Pane lays out at a narrow width")
collector.stop()
print("PASS: Sources pane preserves unsaved drafts across updates/navigation, clears saved drafts, reveals external edits, browses all items/history in app, saves built-in instructions, and lays out at narrow width")
