import Cocoa

struct SourceConsumerLink {
    let title: String
    let open: () -> Void
}

/// Source browsing and editing share one pane. Drafts survive navigation and
/// collector updates never rebuild an active text editor.
final class SourcesView: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    private enum Route: Equatable {
        case inventory, connect, detail(String), items(String, String), snapshots(String), item(String, String, String)
    }
    private struct Draft: Equatable {
        var name = ""
        var location = ""
        var instructions = ""
        var kind = SourceKind.website
        var interval = "15"
        var retention = "30"
    }
    let store: DataSourceStore
    let collector: SourceCollector
    var consumers: ((String) -> [SourceConsumerLink])?
    var onOpenSettings: (() -> Void)?
    private var route: Route = .inventory
    private var history: [Route] = []
    private var drafts: [String: Draft] = [:]
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var nameField: NSTextField?
    private var locationField: NSTextField?
    private var intervalField: NSTextField?
    private var retentionField: NSTextField?
    private var instructionsView: NSTextView?
    private var kindPicker: NSPopUpButton?
    private var statusLabel: NSTextField?
    private var feedbackLabel: NSTextField?
    private var filter = ""
    private var error: String?
    private var deleteConfirmation = false
    private var deferredRefresh = false
    private var renderedDraft: Draft?
    private var renderedDraftKey: String?
    private var savedMessage: String?

    init(store: DataSourceStore, collector: SourceCollector) {
        self.store = store
        self.collector = collector
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var draftKey: String {
        if case .detail(let id) = route { return id }
        return "new"
    }
    private func stashDraft() {
        guard let nameField, let locationField, let instructionsView else { return }
        var value = drafts[draftKey] ?? renderedDraft ?? Draft()
        value.name = nameField.stringValue
        value.location = locationField.stringValue
        value.instructions = instructionsView.string
        value.interval = intervalField?.stringValue ?? value.interval
        value.retention = retentionField?.stringValue ?? value.retention
        if let kindPicker, (0..<3).contains(kindPicker.indexOfSelectedItem) { value.kind = [.website, .localFolder, .emailCopies][kindPicker.indexOfSelectedItem] }
        // Only user edits create a draft. Repainting unchanged fields must not
        // resurrect a draft after Save or hide a later store update.
        if renderedDraftKey == draftKey && value != renderedDraft { drafts[draftKey] = value }
    }
    private func navigate(_ next: Route) {
        stashDraft()
        history.append(route)
        route = next
        savedMessage = nil
        error = nil
        deleteConfirmation = false
        rebuild()
        scroll.contentView.scroll(to: .zero)
    }
    @discardableResult func goBack() -> Bool {
        guard let prior = history.popLast() else { return false }
        stashDraft()
        route = prior
        savedMessage = nil
        error = nil
        deleteConfirmation = false
        rebuild()
        return true
    }
    func showSource(_ id: String) { navigate(.detail(id)) }
    func showInventory() { stashDraft(); route = .inventory; history = []; savedMessage = nil; rebuild() }
    func refresh() {
        if case .detail(let id) = route { statusLabel?.stringValue = statusText(id) }
        // Async data arrivals may not erase a selection, move a cursor, or
        // replace the fields someone is editing. A saved draft is never lost.
        if isEditingText {
            deferredRefresh = true
            return
        }
        deferredRefresh = false
        stashDraft()
        rebuild()
    }
    private var isEditingText: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.isDescendant(of: self) || (editor.delegate as? NSView)?.isDescendant(of: self) == true
    }
    func textDidEndEditing(_ notification: Notification) { applyDeferredRefresh() }
    func controlTextDidEndEditing(_ notification: Notification) { applyDeferredRefresh() }
    private func applyDeferredRefresh() {
        guard deferredRefresh else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isEditingText else { return }
            self.deferredRefresh = false
            self.refresh()
        }
    }
    private func label(_ text: String, size: CGFloat = 13, color: NSColor = Theme.text2) -> NSTextField {
        let v = NSTextField(wrappingLabelWithString: text)
        v.font = .systemFont(ofSize: size)
        v.textColor = color
        v.isSelectable = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }
    private func add(_ view: NSView, full: Bool = true) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        if !full { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        if full { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    private func heading(_ title: String, subtitle: String) {
        add(label(title, size: 26, color: Theme.text))
        add(label(subtitle))
    }
    private func section(_ title: String) {
        let line = NSBox(); line.boxType = .separator; add(line)
        add(label(title.uppercased(), size: 11, color: Theme.accent))
    }
    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = SourceActionButton(title: title, action: action)
        b.bezelStyle = .rounded
        b.lineBreakMode = .byTruncatingTail
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        b.setAccessibilityLabel(title)
        return b
    }
    /// AppKit's inline bezel draws the unselected title with its own subdued
    /// palette. A normal borderless button with explicit attributed text keeps
    /// these navigation links readable against Voice Flow's custom dark view.
    private func linkButton(_ title: String, size: CGFloat = 14,
                            _ action: @escaping () -> Void) -> NSButton {
        let link = button(title, action)
        link.bezelStyle = .regularSquare
        link.isBordered = false
        link.alignment = .left
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        link.font = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        link.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Theme.text, .font: font, .paragraphStyle: paragraph,
        ])
        link.attributedAlternateTitle = link.attributedTitle
        return link
    }
    private func actions(_ buttons: [NSButton]) {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal; row.spacing = 8
        add(row, full: false)
    }
    private func kindLabel(_ kind: SourceKind) -> String {
        switch kind {
        case .website: return "Website"
        case .localFolder: return "Local folder"
        case .emailCopies: return "Email files"
        case .desktop: return "Desktop activity"
        case .dictations: return "Dictations"
        case .captures: return "Capture bundles"
        case .assistantHistory: return "Assistant history"
        }
    }
    private func date(_ value: Date?) -> String {
        guard let value else { return "Never" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }
    private func statusText(_ id: String) -> String {
        let value = store.status(sourceID: id)
        let enabled = store.source(id: id)?.enabled ?? false
        let latest = store.snapshots(sourceID: id).first
        let stale = value.nextRefresh.map { $0 < Date() } ?? false
        let state = value.refreshing ? "Collecting…" : !enabled ? "Paused" : value.lastError != nil ? "Needs attention" : latest == nil ? (value.lastSuccess == nil ? "Not collected yet" : "Copies expired") : stale ? "Refresh due" : "Ready"
        return "\(state) · \(latest?.items.count ?? 0) available items · Last collected \(date(value.lastSuccess))"
    }
    private func rebuild() {
        let position = scroll.contentView.bounds.origin
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        nameField = nil; locationField = nil; intervalField = nil; retentionField = nil
        instructionsView = nil; kindPicker = nil; statusLabel = nil; feedbackLabel = nil
        renderedDraft = nil; renderedDraftKey = nil
        if !history.isEmpty { add(button("‹ Back") { [weak self] in _ = self?.goBack() }, full: false) }
        if let error { add(label(error, color: .systemOrange)) }
        switch route {
        case .inventory: buildInventory()
        case .connect: buildConnect()
        case .detail(let id): buildDetail(id)
        case .items(let id, let snapshot): buildItems(id, snapshot)
        case .snapshots(let id): buildSnapshots(id)
        case .item(let source, let snapshot, let item): buildItem(source, snapshot, item)
        }
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: position)
    }
    private func buildInventory() {
        heading("Your data", subtitle: "See what Voice Flow collects. Give your agents useful context before they run.")
        actions([button("Connect source") { [weak self] in self?.navigate(.connect) }])
        let search = NSSearchField(); search.placeholderString = "Filter sources"
        search.stringValue = filter
        search.target = self; search.action = #selector(filterChanged(_:))
        add(search)
        let sources = store.listSources().filter { filter.isEmpty || ($0.name + " " + kindLabel($0.kind)).localizedCaseInsensitiveContains(filter) }
        for builtIn in [false, true] {
            let group = sources.filter { $0.builtIn == builtIn }
            section(builtIn ? "From Voice Flow" : "Connected sources")
            if group.isEmpty {
                add(label(builtIn ? "No matching sources." : "Connect a website, a folder of documents, or exported email files. Collection runs while Voice Flow is open."))
            }
            for source in group {
                let open = linkButton(source.name + "  ›", size: 16) { [weak self] in self?.showSource(source.id) }
                add(open, full: false)
                add(label("\(kindLabel(source.kind)) · \(statusText(source.id))", size: 12))
                if !source.instructions.isEmpty { add(label(String(source.instructions.prefix(180)), size: 12)) }
                if let failure = store.status(sourceID: source.id).lastError { add(label(String(failure.prefix(220)), size: 12, color: .systemOrange)) }
            }
        }
    }
    @objc private func filterChanged(_ sender: NSSearchField) { filter = sender.stringValue; rebuild() }

    private func field(_ title: String, value: String, placeholder: String = "") -> NSTextField {
        add(label(title, size: 12))
        let field = NSTextField(string: value); field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13); field.setAccessibilityLabel(title)
        field.delegate = self
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        add(field)
        return field
    }
    private func editor(_ text: String, height: CGFloat = 130, editable: Bool = true) -> NSTextView {
        let textScroll = NSScrollView(); textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: max(100, bounds.width - 56), height: height)); view.isRichText = false; view.isEditable = editable
        view.delegate = self
        view.minSize = NSSize(width: 0, height: height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.font = .systemFont(ofSize: 13); view.textColor = Theme.text; view.backgroundColor = Theme.bgLighter
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.string = text
        textScroll.documentView = view
        textScroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        add(textScroll)
        return view
    }
    private func buildConnect() {
        heading("Connect a source", subtitle: "Copies are stored on this Mac. Selected text and source instructions are sent to the model when an agent runs.")
        let d = drafts["new"] ?? Draft()
        let picker = NSPopUpButton(); picker.addItems(withTitles: ["Website", "Local folder", "Email files"])
        picker.selectItem(at: [.website, .localFolder, .emailCopies].firstIndex(of: d.kind) ?? 0)
        picker.target = self; picker.action = #selector(kindChanged)
        kindPicker = picker; add(picker, full: false)
        buildFields(d, builtIn: false)
        add(button("Connect and collect") { [weak self] in self?.saveConnection() }, full: false)
    }
    @objc private func kindChanged() { stashDraft(); rebuild() }
    private func buildFields(_ d: Draft, builtIn: Bool) {
        nameField = field("Name", value: d.name, placeholder: "A name you and your agents recognize")
        locationField = field(d.kind == .website ? "Website URL" : "Folder", value: d.location,
                              placeholder: d.kind == .website ? "https://example.com" : "/path/to/folder")
        locationField?.isEnabled = !builtIn
        if !builtIn && d.kind != .website {
            add(button("Choose folder…") { [weak self] in self?.chooseFolder() }, full: false)
        }
        if !builtIn {
            add(label(d.kind == .website ? "Readable text is fetched directly with HTTP; browser logins and JavaScript rendering are not available. Maximum response: 2 MB." : d.kind == .emailCopies ? "Choose a folder containing exported .eml or .mbox files. Voice Flow reads copies; it does not connect to or change a live mailbox." : "Readable text and code files are copied. Hidden files, packages, unsupported formats, and symlinks are skipped.", size: 12))
            intervalField = field("Collect every (minutes)", value: d.interval)
            retentionField = field("Keep copies for (days)", value: d.retention)
            add(label("At most 100 snapshots per source. Folder imports keep up to 200 documents, 2 MB per file, and 12 MB of original data; traversal stops after 5 levels or 5,000 entries.", size: 12))
        }
        add(label("Instructions for agents", size: 12))
        instructionsView = editor(d.instructions)
        instructionsView?.setAccessibilityLabel("Source instructions")
        add(label("Explain what this source means, which changes matter, and how to use it. These instructions accompany its data whenever selected. Imported content is evidence, not instructions.", size: 12))
        renderedDraft = d
        renderedDraftKey = draftKey
    }
    private func buildDetail(_ id: String) {
        guard let source = store.source(id: id) else {
            heading("Source unavailable", subtitle: "The connection was removed. Return to Data to connect it again.")
            return
        }
        heading(source.name, subtitle: kindLabel(source.kind))
        let status = label(statusText(id)); statusLabel = status; add(status)
        let state = store.status(sourceID: id)
        if let lastError = state.lastError { add(label("Collection failed: \(lastError) Saved copies remain available until their retention expires.", color: .systemOrange)) }
        if state.skippedCount > 0 { add(label("At least \(state.skippedCount) items or folders were skipped because of format, size, or traversal limits. Choose a narrower folder for a fuller collection.", color: .systemOrange)) }
        let refresh = button(state.lastError == nil ? "Collect now" : "Retry collection") { [weak self] in
            self?.collector.refresh(sourceID: id) { [weak self] _ in self?.refresh() }
            self?.refresh()
        }
        refresh.isEnabled = !state.refreshing
        var buttons = [refresh]
        if !source.builtIn {
            buttons.append(button(source.enabled ? "Pause" : "Resume") { [weak self] in
                do { try self?.collector.pause(sourceID: id, paused: source.enabled); self?.refresh() }
                catch { self?.showError(error) }
            })
        }
        actions(buttons)
        section("Latest collected copy")
        if let snapshot = store.snapshots(sourceID: id).first {
            add(label("\(date(snapshot.collectedAt)) · \(snapshot.items.count) items", size: 12))
            if snapshot.items.isEmpty { add(label("No supported items found. Check the source folder or URL.")) }
            for item in snapshot.items.prefix(3) {
                add(linkButton(item.title + "  ›") { [weak self] in self?.navigate(.item(id, snapshot.id, item.id)) }, full: false)
                if !item.preview.isEmpty { add(label(String(item.preview.prefix(200)), size: 12)) }
            }
            if !snapshot.items.isEmpty {
                add(linkButton("Browse all collected items (\(snapshot.items.count))") { [weak self] in self?.navigate(.items(id, snapshot.id)) }, full: false)
            }
            if let url = store.snapshotURL(sourceID: id, snapshotID: snapshot.id) {
                add(button("Open collected folder") { NSWorkspace.shared.open(url) }, full: false)
            }
        } else { add(label("No saved copies are available. Collect now to make this source available to agents.")) }
        let snapshotCount = store.snapshots(sourceID: id).count
        if snapshotCount > 0 { add(linkButton("Collection history (\(snapshotCount))") { [weak self] in self?.navigate(.snapshots(id)) }, full: false) }
        section("Used by")
        let links = consumers?(id) ?? []
        if links.isEmpty { add(label("No assignments yet. Select this source in an Assistant’s settings or an Automation’s Data section.")) }
        for link in links { add(linkButton(link.title + "  ›", link.open), full: false) }
        section("Source settings")
        let d = drafts[id] ?? Draft(name: source.name, location: source.location, instructions: source.instructions,
                                    kind: source.kind, interval: String(source.intervalSeconds / 60), retention: String(source.retentionDays))
        buildFields(d, builtIn: source.builtIn)
        add(button("Save source settings") { [weak self] in self?.saveConnection() }, full: false)
        let feedback = label(savedMessage ?? "", color: Theme.accent); feedbackLabel = feedback; add(feedback)
        if source.builtIn {
            add(label("These snapshots read existing Voice Flow stores once a minute; they do not enable the recorder. Original capture and retention settings remain in app settings. Snapshot copies expire after \(source.retentionDays) days or 100 collections.", size: 12))
            add(button("Open app settings") { [weak self] in self?.onOpenSettings?() }, full: false)
        } else {
            section("Connection")
            add(label("Disconnecting stops collection and keeps saved copies on disk. Existing agent assignments will report the missing source.", size: 12))
            add(button("Disconnect source") { [weak self] in
                do { try self?.store.remove(sourceID: id); self?.showInventory() }
                catch { self?.showError(error) }
            }, full: false)
        }
    }
    private func buildItems(_ sourceID: String, _ snapshotID: String) {
        guard let snapshot = store.snapshots(sourceID: sourceID).first(where: { $0.id == snapshotID }) else {
            heading("Copy unavailable", subtitle: "This collection may have expired. Go back to inspect the latest copy.")
            return
        }
        heading(store.source(id: sourceID)?.name ?? "Collected source", subtitle: "All \(snapshot.items.count) items · collected \(date(snapshot.collectedAt))")
        if snapshot.skippedCount > 0 { add(label("At least \(snapshot.skippedCount) entries were skipped during this collection.", color: .systemOrange)) }
        for item in snapshot.items {
            add(linkButton(item.title + "  ›") { [weak self] in self?.navigate(.item(sourceID, snapshot.id, item.id)) }, full: false)
            add(label("Recorded \(date(item.capturedAt)) · " + String(item.preview.prefix(180)), size: 12))
        }
        if snapshot.items.isEmpty { add(label("This collection contains no supported documents.")) }
    }
    private func buildSnapshots(_ sourceID: String) {
        heading("Collection history", subtitle: store.source(id: sourceID)?.name ?? "Saved source copies")
        add(label("Every row is an immutable collection. A failed refresh does not replace previous evidence."))
        let snapshots = store.snapshots(sourceID: sourceID)
        for snapshot in snapshots {
            add(linkButton("\(date(snapshot.collectedAt)) · \(snapshot.items.count) items  ›") { [weak self] in self?.navigate(.items(sourceID, snapshot.id)) }, full: false)
            add(label("\(ByteCountFormatter.string(fromByteCount: Int64(snapshot.bytes), countStyle: .file)) · at least \(snapshot.skippedCount) skipped", size: 12))
        }
        if snapshots.isEmpty { add(label("No saved collections remain under this source’s retention policy.")) }
    }
    private func buildItem(_ sourceID: String, _ snapshotID: String, _ itemID: String) {
        guard let snapshot = store.snapshots(sourceID: sourceID).first(where: { $0.id == snapshotID }),
              let item = snapshot.items.first(where: { $0.id == itemID }) else {
            heading("Copy unavailable", subtitle: "It may have expired under this source’s retention policy.")
            return
        }
        heading(item.title, subtitle: "Recorded \(date(item.capturedAt)) · collected \(date(snapshot.collectedAt)) · \(item.contentType)")
        do { _ = editor(try store.readItem(sourceID: sourceID, snapshotID: snapshotID, itemID: itemID), height: 400, editable: false) }
        catch { add(label(error.localizedDescription, color: .systemOrange)) }
        add(label("This is a local collected copy. The original source is unchanged.", size: 12))
    }
    private func chooseFolder() {
        guard let window else { return }
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false; picker.prompt = "Use folder"
        picker.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.locationField?.stringValue = picker.url?.path ?? ""; self?.stashDraft() }
        }
    }
    private func saveConnection() {
        stashDraft()
        guard let d = drafts[draftKey] else { return }
        do {
            let isExisting: String? = { if case .detail(let id) = route { return id }; return nil }()
            var definition = isExisting.flatMap { store.source(id: $0) }
                ?? SourceDefinition(name: d.name, kind: d.kind, location: d.location)
            definition.name = d.name; definition.instructions = d.instructions
            if !definition.builtIn {
                guard let interval = Int(d.interval), (1...1440).contains(interval),
                      let retention = Int(d.retention), (1...365).contains(retention) else {
                    throw NSError(domain: "Source", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use 1–1440 minutes and 1–365 retention days."])
                }
                definition.location = d.location
                definition.intervalSeconds = interval * 60; definition.retentionDays = retention
            }
            try store.save(definition)
            drafts.removeValue(forKey: draftKey)
            renderedDraft = d
            savedMessage = "Saved. Agents use these instructions on their next turn."
            error = nil
            if isExisting == nil {
                route = .detail(definition.id); drafts.removeValue(forKey: "new")
                rebuild()
                collector.refresh(sourceID: definition.id) { [weak self] _ in self?.refresh() }
            } else {
                window?.makeFirstResponder(nil)
                deferredRefresh = false
                rebuild()
            }
        } catch { showError(error) }
    }
    private func showError(_ failure: Error) { error = failure.localizedDescription; stashDraft(); rebuild() }

#if VOICE_FLOW_QA
    func qaState() -> [String: Any] {
        ["route": String(describing: route), "error": error ?? "", "source_count": store.listSources().count,
         "name": nameField?.stringValue ?? "", "location": locationField?.stringValue ?? "",
         "instructions": instructionsView?.string ?? ""]
    }
    func qaAction(_ payload: [String: Any]) {
        switch payload["action"] as? String {
        case "connect": navigate(.connect)
        case "open": if let id = payload["source_id"] as? String { showSource(id) }
        case "item": if let id = payload["source_id"] as? String,
                        let snapshot = store.snapshots(sourceID: id).first,
                        let item = snapshot.items.first { navigate(.item(id, snapshot.id, item.id)) }
        case "items": if let id = payload["source_id"] as? String, let snapshot = store.snapshots(sourceID: id).first { navigate(.items(id, snapshot.id)) }
        case "history": if let id = payload["source_id"] as? String { navigate(.snapshots(id)) }
        case "snapshot": if let id = payload["source_id"] as? String, let snapshot = payload["snapshot_id"] as? String { navigate(.items(id, snapshot)) }
        case "back": _ = goBack()
        case "inventory": showInventory()
        default: break
        }
        if let kind = payload["kind"] as? String, let parsed = SourceKind(rawValue: kind),
           let index = [.website, .localFolder, .emailCopies].firstIndex(of: parsed) {
            kindPicker?.selectItem(at: index); kindChanged()
        }
        if let value = payload["name"] as? String { nameField?.stringValue = value }
        if let value = payload["location"] as? String { locationField?.stringValue = value }
        if let value = payload["instructions"] as? String { instructionsView?.string = value }
        if payload["action"] as? String == "save" { saveConnection() }
    }
#endif
}

private final class SourceActionButton: NSButton {
    private let performAction: () -> Void
    init(title: String, action: @escaping () -> Void) {
        performAction = action
        super.init(frame: .zero)
        self.title = title; target = self; self.action = #selector(tapped)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tapped() { performAction() }
}
