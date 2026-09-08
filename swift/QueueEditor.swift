import Cocoa

final class QueueEditorView: NSView {
    private let store: QueueEditorStore
    private let input = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let list = NSStackView()
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
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = FlippedView()
        document.addSubview(list)
        scroll.documentView = document
        status.font = .systemFont(ofSize: 11); status.textColor = Theme.text2
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadNow))
        reload.bezelStyle = .rounded
        let footer = NSStackView(views: [status, reload])
        footer.distribution = .fill
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [entry, scroll, footer] { content.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        list.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
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
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor)
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
        do {
            let changed = try store.reload()
            if changed || force { render() }
        } catch { status.stringValue = error.localizedDescription }
    }

    private func render() {
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        if store.items.isEmpty {
            let empty = NSTextField(labelWithString: "Your queue is empty. Add your next step above.")
            empty.textColor = Theme.text2; empty.font = .systemFont(ofSize: 12)
            list.addArrangedSubview(empty)
        }
        for (index, item) in store.items.enumerated() {
            let label = NSTextField(wrappingLabelWithString: (item.done ? "✓ " : "") + item.text)
            label.font = .systemFont(ofSize: 14); label.textColor = item.done ? Theme.text2 : Theme.text
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeItem(_:)))
            remove.tag = index; remove.bezelStyle = .rounded
            remove.setAccessibilityLabel("Remove \(item.text)")
            let row = NSStackView(views: [label, remove])
            row.distribution = .fill
            row.spacing = 12; row.alignment = .centerY
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        status.stringValue = "\(store.items.filter { !$0.done }.count) to do · Saved automatically"
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
