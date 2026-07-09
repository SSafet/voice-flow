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

    private let width: CGFloat = 400
    private let maxTextHeight: CGFloat = 320
    private let headerHeight: CGFloat = 28
    private let bottomInset: CGFloat = 12
    private let actionRowHeight: CGFloat = 34

    private var panel: NSPanel?
    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!
    private var closeButton: NSButton!
    private var actionButton: NSButton!
    private var actionHandler: (() -> Void)?
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
    func showTransient(_ text: String, seconds: TimeInterval = 4) {
        showNote(text, actionTitle: nil, action: nil)
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
    }

    private func cancelAutoHide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
    }

    func hide() {
        streaming = false
        cancelAutoHide()
        guard let panel, panel.isVisible else { return }
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
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let textHeight = min(max(used + 8, 24), maxTextHeight)
        let actionSpace: CGFloat = actionButton.isHidden ? 0 : actionRowHeight
        let totalHeight = headerHeight + textHeight + actionSpace + bottomInset

        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let frame = screen.frame
        let x = frame.midX - width / 2
        let y = frame.minY + 30  // just above the pill, same anchor as the panel
        panel.setFrame(NSRect(x: x, y: y, width: width, height: totalHeight), display: true)

        scrollView.frame = NSRect(x: 12, y: bottomInset + actionSpace, width: width - 24, height: textHeight)
        statusLabel.frame = NSRect(x: 16, y: totalHeight - headerHeight + 5, width: width - 60, height: 16)
        closeButton.frame = NSRect(x: width - 32, y: totalHeight - headerHeight + 3, width: 20, height: 20)
        if !actionButton.isHidden {
            let buttonWidth = min(width - 32, max(140, actionButton.intrinsicContentSize.width + 24))
            actionButton.frame = NSRect(x: 16, y: 8, width: buttonWidth, height: 22)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        newPanel.level = .floating + 1
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        root.material = .hudWindow
        root.state = .active
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = Theme.border.cgColor
        root.autoresizingMask = [.width, .height]

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
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

        actionButton = NSButton(title: "", target: self, action: #selector(actionTapped))
        actionButton.bezelStyle = .inline
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11, weight: .semibold)
        actionButton.contentTintColor = Theme.accent
        actionButton.isHidden = true
        root.addSubview(actionButton)

        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width - 24, height: 24))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
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
