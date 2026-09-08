import Cocoa

final class QueueEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: QueueEditorStore
    private let input = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let empty = NSTextField(labelWithString: "Your queue is empty. Add your next step above.")
    private static let dragType = NSPasteboard.PasteboardType("com.voiceflow.queue-row")
    private var dragging = false
    private var dragError: String?
    private var timer: Timer?
    var onChange: (() -> Void)?

    init(url: URL) {
        store = QueueEditorStore(url: url)
        super.init(frame: .zero)
        let content = self
        input.placeholderString = "Add something to do…"
        input.setAccessibilityLabel("New queue item")
        input.target = self; input.action = #selector(addItem)
        input.font = .systemFont(ofSize: 14)
        let add = NSButton(title: "Add", target: self, action: #selector(addItem))
        add.bezelStyle = .rounded
        let entry = NSStackView(views: [input, add])
        entry.distribution = .fill
        entry.spacing = 8
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityLabel("Queue items; drag to reorder")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = table
        empty.textColor = Theme.text2; empty.font = .systemFont(ofSize: 12)
        status.font = .systemFont(ofSize: 11); status.textColor = Theme.text2
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadNow))
        reload.bezelStyle = .rounded
        let footer = NSStackView(views: [status, reload])
        footer.distribution = .fill
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [entry, scroll, footer, empty] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            entry.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            entry.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            entry.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: entry.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: entry.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: entry.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: entry.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: entry.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            empty.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 4),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.isHiddenOrHasHiddenAncestor else { return }
            self.refresh()
        }
    }

    func activate() { refresh(force: true) }
    deinit { timer?.invalidate() }
    @objc private func reloadNow() { refresh(force: true) }

    private func refresh(force: Bool = false) {
        guard !dragging else { return }
        do {
            let changed = try store.reload()
            if changed || force { render() }
        } catch { status.stringValue = error.localizedDescription }
    }

    private func render() {
        empty.isHidden = !store.items.isEmpty
        table.reloadData()
        status.stringValue = "\(store.items.filter { !$0.done }.count) to do · Saved automatically"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let item = store.items[index]
        let grip = NSTextField(labelWithString: "≡")
        grip.font = .systemFont(ofSize: 18)
        grip.textColor = Theme.text2
        grip.toolTip = "Drag to reorder"
        grip.setAccessibilityLabel("Drag to reorder \(item.text)")
        let label = NSTextField(wrappingLabelWithString: (item.done ? "✓ " : "") + item.text)
        label.font = .systemFont(ofSize: 14); label.textColor = item.done ? Theme.text2 : Theme.text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeItem(_:)))
        remove.tag = index; remove.bezelStyle = .rounded
        remove.setAccessibilityLabel("Remove \(item.text)")
        let row = NSStackView(views: [grip, label, remove])
        row.distribution = .fill
        row.spacing = 12; row.alignment = .centerY
        return row
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let text = store.items[row].text as NSString
        let size = text.boundingRect(with: NSSize(width: max(80, tableView.bounds.width - 140),
                                                 height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                     attributes: [.font: NSFont.systemFont(ofSize: 14)])
        return max(32, ceil(size.height) + 10)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<store.items.count))
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragging = true
        dragError = nil
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        refresh(force: true)
        if let dragError { status.stringValue = dragError }
        dragError = nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard dragging, (info.draggingSource as? NSTableView) === table else { return [] }
        table.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard dragging, (info.draggingSource as? NSTableView) === table,
              let value = info.draggingPasteboard.string(forType: Self.dragType),
              let source = Int(value) else { return false }
        do {
            try store.move(from: source, to: row)
            render()
            onChange?()
            return true
        } catch {
            // Keep the snapshot frozen through the drag. Refresh only after it ends.
            dragError = error.localizedDescription
            return false
        }
    }

    @objc private func addItem() {
        perform {
            try store.add(input.stringValue)
            input.stringValue = ""
            window?.makeFirstResponder(input)
        }
    }
    @objc private func removeItem(_ sender: NSButton) { perform { try store.remove(at: sender.tag) } }
    private func perform(_ action: () throws -> Void) {
        do { try action(); render(); onChange?() }
        catch { refresh(force: true); status.stringValue = error.localizedDescription }
    }
}
