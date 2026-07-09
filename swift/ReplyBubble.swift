import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Reply Bubble — the agent answers without opening the panel
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  When the ChatPanel is closed, agent replies stream into this small
//  bubble anchored above the pill. It stays until dismissed with ✕.

final class ReplyBubble {
    /// Fired when the user dismisses the bubble with ✕ (used to cancel a
    /// pending ask from Claude).
    var onClosed: (() -> Void)?
    /// The bubble replaces the pill while visible ("the pill expands") —
    /// the app hides/restores the indicator on this signal.
    var onVisibilityChanged: ((Bool) -> Void)?

    private let maxWidth: CGFloat = 400
    private let maxTextHeight: CGFloat = 320
    private let headerHeight: CGFloat = 26
    private let bottomInset: CGFloat = 9
    private let actionRowHeight: CGFloat = 34

    private var panel: NSPanel?
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!
    private var closeButton: NSButton!
    private var actionButton: NSButton!
    private var actionHandler: (() -> Void)?
    private var stateDot: NSView!
    private var streaming = false
    private var suppressed = false
    private var autoHideTimer: Timer?

    var isVisible: Bool { panel?.isVisible ?? false }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.text]
    }

    private var echoAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.text3]
    }

    /// A new request is on its way — allow the bubble to appear again even
    /// if the user dismissed the previous reply.
    func resetSuppression() {
        suppressed = false
    }

    /// Show the bubble with a dim echo of what the user just asked.
    func showThinking(echo: String?) {
        suppressed = false
        cancelAutoHide()
        ensurePanel()
        streaming = false
        if let echo, !echo.isEmpty {
            setText("You: \(echo)", attributes: echoAttributes)
        } else {
            setText("", attributes: textAttributes)
        }
        statusLabel.stringValue = "Thinking…"
        configureAction(title: nil, handler: nil)
        reveal()
    }

    func beginStreaming() {
        guard !suppressed else { return }
        cancelAutoHide()
        ensurePanel()
        streaming = true
        setText("", attributes: textAttributes)
        statusLabel.stringValue = "Replying…"
        configureAction(title: nil, handler: nil)
        reveal()
    }

    func appendDelta(_ delta: String) {
        guard streaming, isVisible else { return }
        textView.textStorage?.append(NSAttributedString(string: delta, attributes: textAttributes))
        relayout()
        textView.scrollToEndOfDocument(nil)
    }

    func finishStreaming(_ fullText: String) {
        guard streaming, isVisible else { streaming = false; return }
        streaming = false
        setText(fullText, attributes: textAttributes)
        statusLabel.stringValue = ""
        relayout()
    }

    func showNote(_ text: String) {
        showNote(text, actionTitle: nil, action: nil)
    }

    /// A note with an optional action button underneath (e.g. "Copy prompt
    /// for Claude" after a capture is saved).
    func showNote(_ text: String, actionTitle: String?, action: (() -> Void)?) {
        suppressed = false
        cancelAutoHide()
        ensurePanel()
        streaming = false
        setText(text, attributes: echoAttributes)
        statusLabel.stringValue = ""
        configureAction(title: actionTitle, handler: action)
        reveal()
    }

    /// A short-lived confirmation ("Answer sent to …") that fades out on
    /// its own; any newer content cancels the pending auto-hide.
    func showTransient(_ text: String, seconds: TimeInterval = 4,
                       actionTitle: String? = nil, action: (() -> Void)? = nil) {
        showNote(text, actionTitle: actionTitle, action: action)
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    /// A question from Claude waiting for the user — prompt in the body,
    /// how-to-answer hint in the status line, optional acknowledge button
    /// ("Seen — I'll answer later").
    func showAsk(prompt: String, hint: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        suppressed = false
        cancelAutoHide()
        ensurePanel()
        streaming = false
        setText(prompt, attributes: textAttributes)
        statusLabel.stringValue = hint
        configureAction(title: actionTitle, handler: action)
        reveal()
    }

    private func configureAction(title: String?, handler: (() -> Void)?) {
        actionHandler = handler
        if let title {
            actionButton.title = title
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        relayout()
    }

    func setStatus(_ text: String) {
        guard isVisible else { return }
        statusLabel.stringValue = text
        relayout()   // a status line changes the whole geometry
    }

    /// Mini pill: the bubble hides the real pill while visible, so it
    /// carries the app state itself — a small dot that pulses while the
    /// mic records and dims when idle.
    func setAppState(_ state: AppState) {
        guard stateDot != nil else { return }
        let color: NSColor
        var pulsing = false
        switch state {
        case .recording, .handsFree:
            color = NSColor(r: 255, g: 96, b: 96)
            pulsing = true
        case .processing, .loading:
            color = NSColor(r: 255, g: 194, b: 75)
            pulsing = true
        case .done:
            color = NSColor(r: 110, g: 215, b: 130)
        case .idle:
            color = Theme.text3.withAlphaComponent(0.5)
        }
        stateDot.layer?.backgroundColor = color.cgColor
        stateDot.layer?.removeAnimation(forKey: "pulse")
        if pulsing {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            stateDot.layer?.add(pulse, forKey: "pulse")
        }
    }

    private func cancelAutoHide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
    }

    func hide() {
        streaming = false
        cancelAutoHide()
        guard let panel, panel.isVisible else { return }
        onVisibilityChanged?(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // ── Internals ───────────────────────────────────────

    private func setText(_ text: String, attributes: [NSAttributedString.Key: Any]) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        relayout()
    }

    private func reveal() {
        guard let panel else { return }
        relayout()
        if panel.isVisible {
            panel.orderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.orderFront(nil)
        onVisibilityChanged?(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    @objc private func closeTapped() {
        suppressed = true
        hide()
        onClosed?()
    }

    @objc private func actionTapped() {
        actionHandler?()
    }

    private func relayout() {
        guard let panel, let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        let hasStatus = !statusLabel.stringValue.isEmpty || streaming
        let hasAction = !actionButton.isHidden
        let actionSpace: CGFloat = hasAction ? actionRowHeight : 0

        // Bare notes shrink to their text; anything with a status line or a
        // streaming reply keeps the full width.
        var width = maxWidth
        if !hasStatus {
            let natural = ceil(textView.textStorage?.size().width ?? maxWidth)
            var ideal = natural + 66   // dot(14) + 10 + text + 4 + ✕(20) + 10
            if hasAction {
                ideal = max(ideal, actionButton.intrinsicContentSize.width + 56)
            }
            width = min(maxWidth, max(200, ideal))
        }

        // In compact mode the dot leads and the ✕ trails the text row.
        let scrollWidth = width - (hasStatus ? 20 : 60)
        scrollView.frame.size.width = scrollWidth
        textView.frame.size.width = scrollWidth
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let textHeight = min(max(used + 6, 22), maxTextHeight)

        let topSpace: CGFloat = hasStatus ? headerHeight : 7
        let bottomPad: CGFloat = hasStatus ? bottomInset : 7
        let totalHeight = topSpace + textHeight + actionSpace + bottomPad

        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let frame = screen.frame
        let x = frame.midX - width / 2
        let y = frame.minY + 6  // the pill hides while we're up — take its spot
        panel.setFrame(NSRect(x: x, y: y, width: width, height: totalHeight), display: true)

        scrollView.frame = NSRect(x: hasStatus ? 10 : 24, y: bottomPad + actionSpace, width: scrollWidth, height: textHeight)
        statusLabel.isHidden = !hasStatus
        statusLabel.frame = NSRect(x: 24, y: totalHeight - headerHeight + 5, width: width - 64, height: 16)
        if hasStatus {
            // Dot leads the status line in the header.
            stateDot.frame = NSRect(x: 10, y: totalHeight - headerHeight + 9, width: 8, height: 8)
            closeButton.frame = NSRect(x: width - 30, y: totalHeight - headerHeight + 3, width: 20, height: 20)
        } else {
            // Dot and ✕ flank the text row — no empty header band above.
            let rowCenter = bottomPad + actionSpace + textHeight / 2
            stateDot.frame = NSRect(x: 10, y: rowCenter - 4, width: 8, height: 8)
            closeButton.frame = NSRect(x: width - 30, y: rowCenter - 10, width: 20, height: 20)
        }
        if hasAction {
            let buttonWidth = min(width - 32, max(140, actionButton.intrinsicContentSize.width + 24))
            actionButton.frame = NSRect(x: 16, y: 8, width: buttonWidth, height: 22)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        // KeyablePanel: borderless windows refuse key status by default,
        // which breaks scrolling long content inside the bubble.
        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: maxWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        newPanel.level = .floating + 1
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: maxWidth, height: 120))
        root.material = .hudWindow
        root.state = .active
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = Theme.border.cgColor
        root.autoresizingMask = [.width, .height]

        // Same size as the body so the "title" never looks smaller than
        // the text under it.
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        statusLabel.textColor = Theme.accent
        statusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusLabel)

        closeButton = BubbleCloseButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage(),
            target: self, action: #selector(closeTapped)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = Theme.text2
        closeButton.toolTip = "Dismiss"
        root.addSubview(closeButton)

        stateDot = NSView(frame: NSRect(x: 10, y: 0, width: 8, height: 8))
        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 4
        stateDot.layer?.backgroundColor = Theme.text3.withAlphaComponent(0.5).cgColor
        root.addSubview(stateDot)

        actionButton = NSButton(title: "", target: self, action: #selector(actionTapped))
        actionButton.bezelStyle = .inline
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11, weight: .semibold)
        actionButton.contentTintColor = Theme.accent
        actionButton.isHidden = true
        root.addSubview(actionButton)

        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: maxWidth - 24, height: 24))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.textContainer?.lineFragmentPadding = 0   // no hidden side gutters
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        root.addSubview(scrollView)

        newPanel.contentView = root
        panel = newPanel
    }
}

private final class BubbleCloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
