import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Agents tab — every agent talking to you, in one place
//  (panel redesign, ticket #15; spec: design/panel-redesign.html)
//
//  Root: a minimal latest-first list — the assistant pinned first wearing
//  the VoiceFlow waveform mark, then every connected/ghost session with a
//  plain muted number (≡ the pill picker ⌃⌥1–6). Unread rows read bright.
//  Clicking a row pushes its flat thread over the list: no cards, no
//  timestamps, no repeated names. The composer attaches to an unanswered
//  ask; answers attach beneath (↳); otherwise one composer at the bottom.
//  The pill's ⌃⌥ flow stays the primary notification surface — this tab is
//  the browsable archive of the same per-session stacks.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct AgentSessionRow {
    let id: String
    let number: Int?         // ≡ pill picker / ⌃⌥ numbering; nil = consumed
                             // thread kept as history, no ⌃⌥ slot (ticket #17)
    let name: String
    let preview: String      // newest push, one line ("asks: …" when waiting)
    let time: String         // the only timestamps in the whole panel
    let unread: Bool
    /// Consumed thread kept as history (ticket #17) — tagged "completed".
    let completed: Bool
    /// Session died with the stack still active — tagged "ghost".
    let ghost: Bool
}

protocol AgentsDataSource: AnyObject {
    func agentSessionRows() -> [AgentSessionRow]
    func agentThread(for sessionId: String) -> [AppDelegate.SessionPush]
    func markThreadSeen(_ sessionId: String)
    /// True when this session has a blocked ask waiting for the user.
    func hasPendingAsk(for sessionId: String) -> Bool
    /// Route a typed message: resolves the pending ask if one waits,
    /// otherwise queues it in the session's inbox.
    func sendMessage(toSession sessionId: String, text: String)
    func speakThread(_ sessionId: String)
    /// User marked the thread done — delete its stack, session, overlays.
    func completeThread(_ sessionId: String)
}

final class AgentsView: NSView, NSTextFieldDelegate {
    weak var dataSource: AgentsDataSource?
    /// The assistant row was chosen — ChatPanel swaps in the chat surface.
    var onOpenAssistant: (() -> Void)?

    private enum Mode {
        case list
        case thread(String)
    }
    private var mode: Mode = .list

    private var contentStack: NSView!          // flipped document view
    private var scrollView: NSScrollView!
    private var composerField: NSTextField?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupUI()
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    private func setupUI() {
        contentStack = FlippedView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = contentStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    // ── Public surface ──────────────────────────────────

    func showList() {
        mode = .list
        rebuild()
    }

    func openThread(_ sessionId: String) {
        mode = .thread(sessionId)
        dataSource?.markThreadSeen(sessionId)
        rebuild()
    }

    /// Re-render whatever is on screen from fresh data. An in-progress
    /// composer draft (and its focus) survives the rebuild — pushes from
    /// other sessions must never eat what the user is typing.
    func refresh() {
        if case .thread(let sid) = mode {
            // A session with zero pushes is still a valid, messageable
            // thread — fall back to the list only when the session is gone.
            let known = dataSource?.agentSessionRows().contains { $0.id == sid } ?? false
            if !known, dataSource?.agentThread(for: sid).isEmpty ?? true {
                mode = .list
            }
        }
        let draft = composerField?.stringValue ?? ""
        let hadFocus = composerField.map { field in
            (field.window?.firstResponder as? NSText)?.delegate === field
        } ?? false
        rebuild()
        if let field = composerField {
            if !draft.isEmpty { field.stringValue = draft }
            if hadFocus { field.window?.makeFirstResponder(field) }
        }
    }

    // ── Rendering ───────────────────────────────────────

    private func rebuild() {
        contentStack.subviews.forEach { $0.removeFromSuperview() }
        composerField = nil
        switch mode {
        case .list: buildList()
        case .thread(let sid): buildThread(sid)
        }
    }

    private func buildList() {
        var top = contentStack.topAnchor

        // Assistant — persistent first row, never a number.
        let assistantRow = makeRow(
            leading: WaveformIconView(),
            name: "assistant", unread: false, completed: false, ghost: false,
            preview: "talk · type · snap — the in-app agent", time: "")
        assistantRow.identifier = NSUserInterfaceItemIdentifier("assistant")
        place(assistantRow, below: &top, gap: 2)

        for row in dataSource?.agentSessionRows() ?? [] {
            let number = NSTextField(labelWithString: row.number.map(String.init) ?? "")
            number.font = .systemFont(ofSize: 10.5, weight: .semibold)
            number.textColor = Theme.text3
            let view = makeRow(leading: number, name: row.name, unread: row.unread,
                               completed: row.completed, ghost: row.ghost,
                               preview: row.preview, time: row.time)
            view.identifier = NSUserInterfaceItemIdentifier(row.id)
            place(view, below: &top, gap: 2)
        }

        let bottom = top.constraint(equalTo: contentStack.bottomAnchor, constant: -12)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    private func makeRow(leading: NSView, name: String, unread: Bool, completed: Bool,
                         ghost: Bool, preview: String, time: String) -> NSView {
        let row = HoverRowView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 8

        let tag = completed ? "  completed" : ghost ? "  ghost" : ""
        let nameLabel = NSTextField(labelWithString: name + tag)
        nameLabel.font = .systemFont(ofSize: 12.5, weight: unread ? .semibold : .regular)
        nameLabel.textColor = unread ? Theme.text : Theme.text2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        // Long titles/previews must truncate, never stretch the panel.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let previewLabel = NSTextField(labelWithString: preview)
        previewLabel.font = .systemFont(ofSize: 10.5)
        previewLabel.textColor = Theme.text3
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let timeLabel = NSTextField(labelWithString: time)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = Theme.text3
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [leading, nameLabel, previewLabel, timeLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 9),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leading.widthAnchor.constraint(equalToConstant: 18),

            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 34),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),

            previewLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            previewLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            previewLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7),

            timeLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -9),
            timeLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        row.addGestureRecognizer(click)
        return row
    }

    @objc private func rowClicked(_ gesture: NSClickGestureRecognizer) {
        guard let id = gesture.view?.identifier?.rawValue else { return }
        if id == "assistant" {
            onOpenAssistant?()
        } else {
            openThread(id)
        }
    }

    private func buildThread(_ sessionId: String) {
        guard let dataSource else { return }
        let pushes = dataSource.agentThread(for: sessionId)
        let rows = dataSource.agentSessionRows()
        let title = rows.first { $0.id == sessionId }?.name ?? "Claude"
        let pendingAsk = dataSource.hasPendingAsk(for: sessionId)

        var top = contentStack.topAnchor

        // Nav bar: ‹ back — centered title — 🔊, hairline below.
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let back = NSButton(title: "‹", target: self, action: #selector(backTapped))
        back.isBordered = false
        back.font = .systemFont(ofSize: 16, weight: .medium)
        back.contentTintColor = Theme.text2

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.alignment = .center

        let speak = NSButton(image: NSImage(systemSymbolName: "speaker.wave.2",
                                            accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: #selector(speakTapped))
        speak.isBordered = false
        speak.contentTintColor = Theme.text3
        speak.identifier = NSUserInterfaceItemIdentifier(sessionId)

        // ✓ — mark the thread complete: history is kept until the user
        // says it's done, then it goes away entirely (ticket QA).
        let complete = NSButton(image: NSImage(systemSymbolName: "checkmark.circle",
                                               accessibilityDescription: nil) ?? NSImage(),
                                target: self, action: #selector(completeTapped))
        complete.isBordered = false
        complete.contentTintColor = Theme.text3
        complete.toolTip = "Mark complete — remove this thread"
        complete.identifier = NSUserInterfaceItemIdentifier(sessionId)

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor

        for v in [back, titleLabel, complete, speak, line] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            back.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: back.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: complete.leadingAnchor, constant: -8),
            complete.trailingAnchor.constraint(equalTo: speak.leadingAnchor, constant: -8),
            complete.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            speak.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            speak.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            header.heightAnchor.constraint(equalToConstant: 34),
        ])
        place(header, below: &top, gap: 0)

        // Flat blocks — one per push, question or not.
        var attachedComposer = false
        for (index, push) in pushes.enumerated() {
            let block = NSView()
            block.translatesAutoresizingMaskIntoConstraints = false

            let text = NSTextField(wrappingLabelWithString: push.text)
            text.font = .systemFont(ofSize: 12.5)
            text.textColor = push.isAsk ? Theme.text : Theme.text2
            text.maximumNumberOfLines = 0
            text.isSelectable = true
            text.translatesAutoresizingMaskIntoConstraints = false
            block.addSubview(text)

            var lastAnchor = text.bottomAnchor
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: block.topAnchor, constant: 9),
                text.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -4),
            ])

            if let answer = push.answer {
                // The user's reply lives attached to what it answered.
                let arrow = NSTextField(labelWithString: "↳")
                arrow.font = .systemFont(ofSize: 11.5, weight: .bold)
                arrow.textColor = Theme.accent
                let answerLabel = NSTextField(wrappingLabelWithString: answer)
                answerLabel.font = .systemFont(ofSize: 11.5)
                answerLabel.textColor = Theme.text2
                answerLabel.maximumNumberOfLines = 0
                for v in [arrow, answerLabel] {
                    v.translatesAutoresizingMaskIntoConstraints = false
                    block.addSubview(v)
                }
                NSLayoutConstraint.activate([
                    arrow.topAnchor.constraint(equalTo: lastAnchor, constant: 6),
                    arrow.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 16),
                    answerLabel.topAnchor.constraint(equalTo: arrow.topAnchor),
                    answerLabel.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 7),
                    answerLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -4),
                ])
                lastAnchor = answerLabel.bottomAnchor
            } else if push.isAsk, pendingAsk, index == pushes.lastIndex(where: { $0.isAsk && $0.answer == nil }) {
                // The attached composer IS the ask signal.
                let (row, field) = makeComposer(placeholder: "answer…", sessionId: sessionId)
                row.translatesAutoresizingMaskIntoConstraints = false
                block.addSubview(row)
                NSLayoutConstraint.activate([
                    row.topAnchor.constraint(equalTo: lastAnchor, constant: 10),
                    row.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 4),
                    row.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -4),
                ])
                lastAnchor = row.bottomAnchor
                composerField = field
                attachedComposer = true
            }

            lastAnchor.constraint(equalTo: block.bottomAnchor, constant: -9).isActive = true

            if index < pushes.count - 1 {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = Theme.border.cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                block.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: block.leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: block.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: block.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
            place(block, below: &top, gap: 0)
        }

        if !attachedComposer {
            let (row, field) = makeComposer(placeholder: "message this session…", sessionId: sessionId)
            place(row, below: &top, gap: 10)
            composerField = field
        }

        let bottom = top.constraint(equalTo: contentStack.bottomAnchor, constant: -12)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    private func makeComposer(placeholder: String, sessionId: String) -> (NSView, NSTextField) {
        let row = NSView()

        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Theme.text
        field.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10)
        field.isBezeled = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.identifier = NSUserInterfaceItemIdentifier(sessionId)
        field.target = self
        field.action = #selector(composerSent(_:))
        field.lineBreakMode = .byWordWrapping
        field.cell?.usesSingleLineMode = false
        // Multiline cells swallow Return instead of firing the action —
        // the delegate turns Return back into SEND (Option+Return = newline).
        field.delegate = self

        let send = NSButton(image: NSImage(systemSymbolName: "arrow.up.circle.fill",
                                           accessibilityDescription: nil) ?? NSImage(),
                            target: self, action: #selector(sendTapped(_:)))
        send.isBordered = false
        send.contentTintColor = Theme.accent
        send.identifier = NSUserInterfaceItemIdentifier(sessionId)

        for v in [field, send] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: row.topAnchor),
            field.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            send.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            send.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            send.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
        return (row, field)
    }

    private func place(_ view: NSView, below top: inout NSLayoutYAxisAnchor, gap: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: top, constant: gap),
            view.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])
        top = view.bottomAnchor
    }

    // ── Actions ─────────────────────────────────────────

    @objc private func backTapped() { showList() }

    @objc private func speakTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        dataSource?.speakThread(id)
    }

    @objc private func completeTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        dataSource?.completeThread(id)
        showList()
    }

    @objc private func composerSent(_ sender: NSTextField) { submit(sender) }

    /// Return sends; Option+Return inserts a newline.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let field = control as? NSTextField else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        submit(field)
        return true
    }

    @objc private func sendTapped(_ sender: NSButton) {
        if let field = composerField { submit(field) }
    }

    private func submit(_ field: NSTextField) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = field.identifier?.rawValue else { return }
        field.stringValue = ""
        dataSource?.sendMessage(toSession: id, text: text)
        // The answer attaches to its ask (or queues) — re-render to show it.
        DispatchQueue.main.async { self.refresh() }
    }
}

/// List row hover: quiet by default, card tint under the pointer.
final class HoverRowView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Theme.cardHover.cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// The VoiceFlow waveform mark — a dot, a wave, a dot. Marks the assistant,
/// which is not a session and never wears a number.
final class WaveformIconView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 12) }

    override func draw(_ dirtyRect: NSRect) {
        let color = Theme.text2
        color.setStroke()
        color.setFill()

        let midY = bounds.midY
        let dotR: CGFloat = 1.8
        NSBezierPath(ovalIn: NSRect(x: 0, y: midY - dotR, width: dotR * 2, height: dotR * 2)).fill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width - dotR * 2, y: midY - dotR, width: dotR * 2, height: dotR * 2)).fill()

        let wave = NSBezierPath()
        wave.lineWidth = 1.8
        wave.lineCapStyle = .round
        let x0 = dotR * 2 + 1.5
        let x1 = bounds.width - dotR * 2 - 1.5
        let w = x1 - x0
        wave.move(to: NSPoint(x: x0, y: midY))
        wave.curve(to: NSPoint(x: x0 + w / 2, y: midY),
                   controlPoint1: NSPoint(x: x0 + w * 0.2, y: midY + 5),
                   controlPoint2: NSPoint(x: x0 + w * 0.3, y: midY + 5))
        wave.curve(to: NSPoint(x: x1, y: midY),
                   controlPoint1: NSPoint(x: x0 + w * 0.7, y: midY - 5),
                   controlPoint2: NSPoint(x: x0 + w * 0.8, y: midY - 5))
        wave.stroke()
    }
}
