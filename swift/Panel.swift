import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Chat Panel — the conversation surface anchored to the pill
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Messages pop out of the little floating pill: read, type, snap, talk —
//  no separate window to manage.

enum ChatBubbleKind {
    case user
    case assistant
    case note      // small centered status/error text
}

enum ChatTab: Int {
    case messages = 0    // the main tab: everything agents pushed over MCP
    case chat = 1
    case dictations = 2
    case speech = 3
}

final class ChatPanel {
    var onShown: (() -> Void)?
    var onSendText: ((String) -> Void)?
    var onSnap: (() -> Void)?
    var onToggleSession: (() -> Void)?
    var onToggleAnnotate: (() -> Void)?
    var onToggleVoiceReplies: ((Bool) -> Void)?
    var onToggleControl: ((Bool) -> Void)?
    var onStop: (() -> Void)?
    var onClear: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onTTSSpeak: ((TTSRequest) -> Void)?
    var onTTSSeek: ((Double) -> Void)?
    var onTTSStop: (() -> Void)?

    private let width: CGFloat = 400
    private let height: CGFloat = 520

    private var panel: KeyablePanel!
    private var tabControl: NSSegmentedControl!
    private var messagesView: MessagesView!
    private var dictationsView: DictationsView!
    private var ttsView: TTSView!
    private var currentTab: ChatTab = .messages
    private var statusRow: NSStackView!
    private var inputRow: NSStackView!
    private var bubbleStack: NSStackView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var inputField: ChatInputField!
    private var sendButton: NSButton!
    private var statusLabel: NSTextField!
    private var stopButton: NSButton!
    private var sessionButton: NSButton!
    private var annotateButton: NSButton!
    private var voiceButton: NSButton!
    private var controlButton: NSButton!

    private var streamingLabel: NSTextField?
    private var voiceRepliesOn = false
    private var controlOn = false
    private var sessionActive = false
    private var clickOutsideMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    init() {
        build()
    }

    // ── Show / hide ─────────────────────────────────────

    func show(focusInput: Bool = true) {
        position()
        if panel.isVisible {
            panel.orderFront(nil)          // already up — don't re-fade
        } else {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        if focusInput {
            selectTab(.messages)           // the panel lands on the agent-message history
            panel.makeKey()
        }
        installClickOutsideMonitor()
        onShown?()
    }

    func hide() {
        vflog("chat panel: hide()")
        removeClickOutsideMonitor()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.orderOut(nil)
        })
    }

    // A mouse-down anywhere outside the panel dismisses it. A *global* monitor
    // only sees clicks headed to other apps or the desktop — never our own panel
    // or pill — so clicks inside keep it open and the pill keeps its toggle.
    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    private func position() {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let frame = screen.frame
        let x = frame.midX - width / 2
        let y = frame.minY + 30  // just above the pill
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    // ── Content updates ─────────────────────────────────

    func addUserMessage(_ text: String, attachmentNote: String? = nil) {
        finishStreaming()
        var display = text
        if let attachmentNote, !attachmentNote.isEmpty {
            display = display.isEmpty ? attachmentNote : "\(display)\n\(attachmentNote)"
        }
        appendBubble(kind: .user, text: display)
    }

    func beginAssistantMessage() {
        finishStreaming()
        streamingLabel = appendBubble(kind: .assistant, text: "")
    }

    func appendAssistantDelta(_ delta: String) {
        if streamingLabel == nil {
            beginAssistantMessage()
        }
        guard let label = streamingLabel else { return }
        label.stringValue += delta
        scrollToBottom()
    }

    func finishAssistantMessage(_ fullText: String) {
        if let label = streamingLabel {
            label.stringValue = fullText
        } else if !fullText.isEmpty {
            appendBubble(kind: .assistant, text: fullText)
        }
        streamingLabel = nil
        scrollToBottom()
    }

    func addNote(_ text: String) {
        finishStreaming()
        appendBubble(kind: .note, text: text)
    }

    func clearConversation() {
        streamingLabel = nil
        bubbleStack.arrangedSubviews.forEach { view in
            bubbleStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        updateEmptyLabel()
    }

    private func finishStreaming() {
        streamingLabel = nil
    }

    // ── State reflection ────────────────────────────────

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        sessionButton.title = active ? "● End session" : "● Start session"
        sessionButton.contentTintColor = active
            ? NSColor(r: 255, g: 110, b: 100)
            : NSColor(r: 120, g: 200, b: 120)
    }

    func setAnnotating(_ active: Bool) {
        annotateButton.contentTintColor = active ? Theme.accent : Theme.text2
    }

    func setVoiceReplies(_ on: Bool) {
        voiceRepliesOn = on
        voiceButton.image = symbol(on ? "speaker.wave.2.fill" : "speaker.slash")
        voiceButton.contentTintColor = on ? Theme.accent : Theme.text2
        voiceButton.toolTip = on ? "Voice replies on" : "Voice replies off"
    }

    func setControlAllowed(_ on: Bool) {
        controlOn = on
        controlButton.image = symbol(on ? "hand.raised.fill" : "hand.raised.slash")
        controlButton.contentTintColor = on ? NSColor(r: 255, g: 110, b: 100) : Theme.text2
        controlButton.toolTip = on
            ? "The agent may control this Mac"
            : "Computer control off — the agent can only look"
    }

    func setActivity(_ activity: AgentActivity, detail: String? = nil) {
        switch activity {
        case .idle:
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            stopButton.isHidden = true
        case .thinking:
            statusLabel.stringValue = detail ?? "Thinking…"
            statusLabel.isHidden = false
            stopButton.isHidden = false
        case .responding:
            statusLabel.stringValue = detail ?? "Replying…"
            statusLabel.isHidden = false
            stopButton.isHidden = false
        case .acting:
            statusLabel.stringValue = detail ?? "Working on your screen…"
            statusLabel.isHidden = false
            stopButton.isHidden = false
        }
    }

    func setToolDetail(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }

    func focusInput() {
        panel.makeKey()
        panel.makeFirstResponder(inputField)
    }

    // ── Tabs ────────────────────────────────────────────

    @objc private func tabTapped() {
        let tab = ChatTab(rawValue: tabControl.selectedSegment) ?? .messages
        applyTab(tab)
        if tab == .chat { panel.makeFirstResponder(inputField) }
    }

    func selectTab(_ tab: ChatTab) {
        tabControl.selectedSegment = tab.rawValue
        applyTab(tab)
    }

    private func applyTab(_ tab: ChatTab) {
        currentTab = tab
        let isChat = tab == .chat
        scrollView.isHidden = !isChat
        statusRow.isHidden = !isChat
        inputRow.isHidden = !isChat
        messagesView.isHidden = tab != .messages
        dictationsView.isHidden = tab != .dictations
        ttsView.isHidden = tab != .speech
        updateEmptyLabel()
        if isChat { scrollToBottom() }
    }

    private func updateEmptyLabel() {
        let hasMessages = !bubbleStack.arrangedSubviews.isEmpty
        emptyLabel.isHidden = currentTab != .chat || hasMessages
    }

    // ── Messages + Dictations + Speech passthroughs ─────

    /// Everything an agent pushes (notify / ask / speak) lands here — the
    /// permanent history, independent of what the pill showed.
    func addAgentMessage(time: String, session: String, text: String, isAsk: Bool) {
        messagesView.addEntry(time: time, session: session, text: text, isAsk: isAsk)
    }

    func addDictation(text: String, time: String) {
        dictationsView.addEntry(text: text, time: time)
    }

    func currentTTSRequest() -> TTSRequest { ttsView.currentTTSRequest() }
    func applyTTSRequest(_ request: TTSRequest) { ttsView.applyTTSRequest(request) }
    func setTTSStatus(_ snapshot: TTSStatusSnapshot) { ttsView.setTTSStatus(snapshot) }
    func setTTSServerLabel(_ text: String) { ttsView.setTTSServerLabel(text) }

    // ── Building the UI ─────────────────────────────────

    private func build() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.material = .hudWindow
        root.state = .active
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = Theme.border.cgColor

        // Header ------------------------------------------------------------
        let title = NSTextField(labelWithString: "Voice Flow")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text

        sessionButton = NSButton(title: "● Start session", target: self, action: #selector(sessionTapped))
        sessionButton.isBordered = false
        sessionButton.font = .systemFont(ofSize: 12, weight: .semibold)
        sessionButton.contentTintColor = NSColor(r: 120, g: 200, b: 120)

        annotateButton = iconButton("pencil.tip", action: #selector(annotateTapped), tip: "Annotate the screen")
        voiceButton = iconButton("speaker.slash", action: #selector(voiceTapped), tip: "Voice replies off")
        controlButton = iconButton("hand.raised.slash", action: #selector(controlTapped), tip: "Computer control off")
        let clearButton = iconButton("trash", action: #selector(clearTapped), tip: "Clear conversation")
        let settingsButton = iconButton("gearshape", action: #selector(settingsTapped), tip: "Settings")

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [
            title, sessionButton, headerSpacer,
            annotateButton, voiceButton, controlButton, clearButton, settingsButton,
        ])
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 8, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false

        let headerLine = NSView()
        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = Theme.border.cgColor
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        headerLine.heightAnchor.constraint(equalToConstant: 1).isActive = true

        // Conversation --------------------------------------------------------
        bubbleStack = NSStackView()
        bubbleStack.orientation = .vertical
        bubbleStack.alignment = .leading
        bubbleStack.spacing = 8
        bubbleStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        bubbleStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(bubbleStack)
        NSLayoutConstraint.activate([
            bubbleStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            bubbleStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            bubbleStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            bubbleStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(wrappingLabelWithString: "Talk, type, or snap your screen.\nStart a session and I'll follow along as you work.")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Theme.text3
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        // Status row ----------------------------------------------------------
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Theme.accent
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true

        stopButton = NSButton(title: "Stop", target: self, action: #selector(stopTapped))
        stopButton.bezelStyle = .inline
        stopButton.controlSize = .small
        stopButton.font = .systemFont(ofSize: 11, weight: .semibold)
        stopButton.isHidden = true

        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusRow = NSStackView(views: [statusLabel, statusSpacer, stopButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 14)
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.heightAnchor.constraint(equalToConstant: 18).isActive = true

        // Input row -----------------------------------------------------------
        inputField = ChatInputField()
        inputField.placeholderString = "Message the agent…"
        inputField.font = .systemFont(ofSize: 13)
        inputField.textColor = Theme.text
        inputField.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10)
        inputField.isBezeled = false
        inputField.focusRingType = .none
        inputField.wantsLayer = true
        inputField.layer?.cornerRadius = 8
        inputField.target = self
        inputField.action = #selector(sendTapped)
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let snapButton = iconButton("camera.viewfinder", action: #selector(snapTapped), tip: "Snap the screen and send")
        sendButton = iconButton("arrow.up.circle.fill", action: #selector(sendTapped), tip: "Send")
        sendButton.contentTintColor = Theme.accent

        inputRow = NSStackView(views: [snapButton, inputField, sendButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        inputRow.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 12, right: 12)
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        // Tabs ----------------------------------------------------------------
        tabControl = NSSegmentedControl(
            labels: ["Messages", "Chat", "Dictations", "Speech"],
            trackingMode: .selectOne,
            target: self, action: #selector(tabTapped)
        )
        tabControl.selectedSegment = ChatTab.messages.rawValue
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        let tabBar = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabControl)
        NSLayoutConstraint.activate([
            tabControl.centerXAnchor.constraint(equalTo: tabBar.centerXAnchor),
            tabControl.topAnchor.constraint(equalTo: tabBar.topAnchor, constant: 2),
            tabControl.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: -6),
        ])

        // Messages + Dictations + Speech surfaces (hidden until selected)
        messagesView = MessagesView()
        messagesView.isHidden = true
        messagesView.setContentHuggingPriority(.defaultLow, for: .vertical)
        dictationsView = DictationsView()
        dictationsView.isHidden = true
        dictationsView.setContentHuggingPriority(.defaultLow, for: .vertical)
        ttsView = TTSView()
        ttsView.isHidden = true
        ttsView.setContentHuggingPriority(.defaultLow, for: .vertical)
        ttsView.onSpeak = { [weak self] request in self?.onTTSSpeak?(request) }
        ttsView.onSeek = { [weak self] position in self?.onTTSSeek?(position) }
        ttsView.onStop = { [weak self] in self?.onTTSStop?() }

        // Assemble ------------------------------------------------------------
        let column = NSStackView(views: [header, headerLine, tabBar, scrollView, messagesView, dictationsView, ttsView, statusRow, inputRow])
        column.orientation = .vertical
        column.spacing = 4
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: width - 60),
        ])
        for view in [header, headerLine, tabBar, scrollView, messagesView, dictationsView, ttsView, statusRow, inputRow] as [NSView] {
            view.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        }
        documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor).isActive = true

        panel.contentView = root
        setVoiceReplies(false)
        setControlAllowed(false)
        setSessionActive(false)
        selectTab(.messages)
    }

    private func iconButton(_ symbolName: String, action: Selector, tip: String) -> NSButton {
        let button = NSButton(image: symbol(symbolName) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = Theme.text2
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    }

    // ── Bubbles ─────────────────────────────────────────

    @discardableResult
    private func appendBubble(kind: ChatBubbleKind, text: String) -> NSTextField {
        emptyLabel.isHidden = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = Theme.text
        label.isSelectable = true
        label.preferredMaxLayoutWidth = width - 112

        switch kind {
        case .note:
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.text3
            label.alignment = .center
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
                label.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2),
                label.widthAnchor.constraint(lessThanOrEqualToConstant: width - 80),
            ])
            bubbleStack.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: bubbleStack.widthAnchor, constant: -24).isActive = true
            scrollToBottom()
            return label

        case .user, .assistant:
            let isUser = kind == .user
            let bubble = NSView()
            bubble.wantsLayer = true
            bubble.layer?.cornerRadius = 12
            bubble.layer?.backgroundColor = isUser
                ? NSColor(r: 92, g: 70, b: 40, a: 200).cgColor
                : NSColor(r: 52, g: 50, b: 48, a: 200).cgColor
            bubble.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
                label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
                label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 11),
                label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -11),
            ])

            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(bubble)
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: row.topAnchor),
                bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                bubble.widthAnchor.constraint(lessThanOrEqualToConstant: width - 90),
            ])
            if isUser {
                bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
                bubble.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor).isActive = true
            } else {
                bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
                bubble.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
            }

            bubbleStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: bubbleStack.widthAnchor, constant: -24).isActive = true
            scrollToBottom()
            return label
        }
    }

    private func scrollToBottom() {
        DispatchQueue.main.async {
            guard let documentView = self.scrollView.documentView else { return }
            documentView.layoutSubtreeIfNeeded()
            let height = documentView.frame.height
            let clipHeight = self.scrollView.contentView.bounds.height
            if height > clipHeight {
                documentView.scroll(NSPoint(x: 0, y: height - clipHeight))
            }
        }
    }

    // ── Actions ─────────────────────────────────────────

    @objc private func sendTapped() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""
        onSendText?(text)
    }

    @objc private func snapTapped() { onSnap?() }
    @objc private func sessionTapped() { onToggleSession?() }
    @objc private func annotateTapped() { onToggleAnnotate?() }
    @objc private func stopTapped() { onStop?() }
    @objc private func clearTapped() { onClear?() }
    @objc private func settingsTapped() { onOpenSettings?() }

    @objc private func voiceTapped() {
        voiceRepliesOn.toggle()
        setVoiceReplies(voiceRepliesOn)
        onToggleVoiceReplies?(voiceRepliesOn)
    }

    @objc private func controlTapped() {
        controlOn.toggle()
        setControlAllowed(controlOn)
        onToggleControl?(controlOn)
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class ChatInputField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            currentEditor()?.selectedRange = NSRange(location: stringValue.count, length: 0)
        }
        return result
    }
}
