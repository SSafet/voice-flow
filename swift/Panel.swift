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
    case inbox = 0    // everything you said, with a destination (filter chips)
    case agents = 1   // every agent talking to you: sessions + the assistant
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
    private var inboxTabButton: NSButton!
    private var agentsTabButton: NSButton!
    private var messagesView: MessagesView!    // messages.json archive — store only, no longer a tab
    private var dictationsView: DictationsView!
    private var agentsView: AgentsView!
    private var assistantHeader: NSView!
    private var speechButton: NSButton!
    private var ttsView: TTSView!
    private var currentTab: ChatTab = .agents
    /// Inside the Agents tab: the assistant thread (the old Chat) is open.
    private var assistantOpen = false
    /// The ♪ toggle — the Speech drawer covers whichever tab is current.
    private var speechOpen = false
    private var lastAssistantText = ""
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
            selectTab(.agents)             // the panel lands on the agent list
            panel.makeKey()
        }
        agentsView.refresh()
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
        if !fullText.isEmpty { lastAssistantText = fullText }
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

    @objc private func inboxTabTapped() {
        speechOpen = false
        applyTab(.inbox)
    }

    @objc private func agentsTabTapped() {
        speechOpen = false
        applyTab(.agents)
    }

    func selectTab(_ tab: ChatTab) {
        speechOpen = false   // an explicit tab request always closes the ♪ drawer
        applyTab(tab)
    }

    private func tabButton(action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        // Fill the strip like the mock's full-width tabs, don't hug the text.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    /// Amber active tab, quiet inactive; unread counts ride along.
    private func styleTabs() {
        guard inboxTabButton != nil, agentsTabButton != nil else { return }
        let inboxCount = dictationsView?.unrevisitedCount ?? 0
        let agentsCount = agentsView?.dataSource?.agentSessionRows()
            .filter { $0.unread }.count ?? 0
        styleTab(inboxTabButton, title: "Inbox", count: inboxCount, active: currentTab == .inbox)
        styleTab(agentsTabButton, title: "Agents", count: agentsCount, active: currentTab == .agents)
    }

    private func styleTab(_ button: NSButton, title: String, count: Int, active: Bool) {
        let dark = NSColor(r: 23, g: 21, b: 15)
        let text = count > 0 ? "\(title)  \(count)" : title
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: active ? dark : Theme.text2,
        ])
        if count > 0 {
            let countRange = NSRange(location: title.count + 2, length: text.count - title.count - 2)
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: active ? NSColor(r: 23, g: 21, b: 15, a: 190) : Theme.accent,
            ], range: countRange)
        }
        button.attributedTitle = attributed
        button.layer?.backgroundColor = active ? Theme.accent.cgColor : NSColor.clear.cgColor
    }

    /// Show the Speech surface (♪) over whatever tab is current.
    func openSpeech() {
        speechOpen = true
        applyTab(currentTab)
    }

    private func applyTab(_ tab: ChatTab) {
        currentTab = tab
        let assistant = tab == .agents && assistantOpen && !speechOpen
        let agentsList = tab == .agents && !assistantOpen && !speechOpen
        scrollView.isHidden = !assistant
        statusRow.isHidden = !assistant
        inputRow.isHidden = !assistant
        assistantHeader.isHidden = !assistant
        agentsView.isHidden = !agentsList
        dictationsView.isHidden = !(tab == .inbox && !speechOpen)
        ttsView.isHidden = !speechOpen
        speechButton.contentTintColor = speechOpen ? Theme.accent : Theme.text3
        styleTabs()
        updateEmptyLabel()
        if assistant {
            panel.makeFirstResponder(inputField)
            scrollToBottom()
        }
        if agentsList { agentsView.refresh() }
    }

    private func updateEmptyLabel() {
        let hasMessages = !bubbleStack.arrangedSubviews.isEmpty
        let assistant = currentTab == .agents && assistantOpen && !speechOpen
        emptyLabel.isHidden = !assistant || hasMessages
    }

    // ── Messages + Dictations + Speech passthroughs ─────

    /// Everything an agent pushes (notify / ask / speak) lands here — the
    /// permanent history (messages.json), independent of what the pill
    /// showed — and the Agents surface repaints if it's on screen.
    func addAgentMessage(time: String, session: String, text: String, isAsk: Bool) {
        messagesView.addEntry(time: time, session: session, text: text, isAsk: isAsk)
        refreshAgents()
    }

    /// The Agents tab reads sessions/threads through this — wired to
    /// AppDelegate, which owns the push stacks and the MCP registry.
    var agentsDataSource: AgentsDataSource? {
        get { agentsView.dataSource }
        set { agentsView.dataSource = newValue }
    }

    /// Repaint the Agents surface from fresh data (no-op when hidden).
    func refreshAgents() {
        if isVisible, !agentsView.isHidden { agentsView.refresh() }
        styleTabs()
    }

    /// Recompute the tab unread counts without touching the surfaces.
    func refreshTabBadges() { styleTabs() }

    /// ⌃⌥N while the panel is open: deep-link straight into that session's
    /// thread instead of growing the pill behind the panel.
    func openAgentThread(_ sessionId: String) {
        assistantOpen = false
        speechOpen = false
        applyTab(.agents)
        agentsView.openThread(sessionId)
    }

    private func openAssistant() {
        assistantOpen = true
        applyTab(.agents)
    }

    @objc private func assistantBackTapped() {
        assistantOpen = false
        applyTab(.agents)
    }

    @objc private func assistantSpeakTapped() {
        guard !lastAssistantText.isEmpty else { return }
        var request = ttsView.currentTTSRequest()
        request.text = lastAssistantText
        onTTSSpeak?(request)
    }

    @objc private func speechTapped() {
        speechOpen.toggle()
        applyTab(currentTab)
    }

    func addDictation(text: String, time: String,
                      destination: CaptureDestination = .pasted, seen: Bool? = nil) {
        dictationsView.addEntry(text: text, time: time, destination: destination, seen: seen)
        styleTabs()
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

        // Solid dark, per the approved mock — the HUD blur washed the text
        // out over bright pages (Safet's Instagram screenshot). A whisper of
        // translucency keeps it feeling native without costing legibility.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.bg.withAlphaComponent(0.98).cgColor
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

        // "Start session" lives on the pill/menu/hotkey — not in the panel
        // header (design remark, ticket #15). The button object stays alive
        // for setSessionActive() state but is never added to the view.
        let header = NSStackView(views: [
            title, headerSpacer,
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

        emptyLabel = NSTextField(wrappingLabelWithString: "Talk, type, or snap your screen.")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Theme.text3
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        // Status row ----------------------------------------------------------
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Theme.accent
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        // Long tool detail must truncate, never widen the panel window.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        inputField.placeholderString = "message the assistant… (or hold ⌃⌥ and talk)"
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

        // Tabs: two content surfaces + the ♪ speech toggle — custom warm strip
        // (the mock's full-width amber tabs with unread counts; never the
        // system-blue segmented control).
        inboxTabButton = tabButton(action: #selector(inboxTabTapped))
        agentsTabButton = tabButton(action: #selector(agentsTabTapped))

        speechButton = NSButton(title: "♪", target: self, action: #selector(speechTapped))
        speechButton.isBordered = false
        speechButton.font = .systemFont(ofSize: 13, weight: .medium)
        speechButton.contentTintColor = Theme.text3
        speechButton.toolTip = "Speech — paste text and play it aloud"
        speechButton.translatesAutoresizingMaskIntoConstraints = false
        speechButton.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let strip = NSStackView(views: [inboxTabButton, agentsTabButton, speechButton])
        strip.orientation = .horizontal
        strip.distribution = .fill   // stretch the low-hugging tabs to fill
        strip.spacing = 4
        strip.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        strip.wantsLayer = true
        strip.layer?.cornerRadius = 9
        strip.layer?.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10).cgColor
        strip.translatesAutoresizingMaskIntoConstraints = false
        inboxTabButton.widthAnchor.constraint(equalTo: agentsTabButton.widthAnchor).isActive = true

        let tabBar = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 12),
            strip.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -12),
            strip.topAnchor.constraint(equalTo: tabBar.topAnchor, constant: 2),
            strip.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: -6),
        ])

        // Surfaces (hidden until selected) ------------------------------------
        messagesView = MessagesView()   // archive store; not in the hierarchy
        dictationsView = DictationsView()
        dictationsView.isHidden = true
        dictationsView.setContentHuggingPriority(.defaultLow, for: .vertical)
        dictationsView.onUnreadChanged = { [weak self] _ in self?.styleTabs() }
        agentsView = AgentsView()
        agentsView.isHidden = true
        agentsView.setContentHuggingPriority(.defaultLow, for: .vertical)
        agentsView.onOpenAssistant = { [weak self] in self?.openAssistant() }
        ttsView = TTSView()
        ttsView.isHidden = true
        ttsView.setContentHuggingPriority(.defaultLow, for: .vertical)
        ttsView.onSpeak = { [weak self] request in self?.onTTSSpeak?(request) }
        ttsView.onSeek = { [weak self] position in self?.onTTSSeek?(position) }
        ttsView.onStop = { [weak self] in self?.onTTSStop?() }

        assistantHeader = buildAssistantHeader()
        assistantHeader.isHidden = true

        // Assemble ------------------------------------------------------------
        let column = NSStackView(views: [header, headerLine, tabBar, assistantHeader, scrollView, agentsView, dictationsView, ttsView, statusRow, inputRow])
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
        for view in [header, headerLine, tabBar, assistantHeader, scrollView, agentsView, dictationsView, ttsView, statusRow, inputRow] as [NSView] {
            view.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        }
        documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor).isActive = true

        panel.contentView = root
        setVoiceReplies(false)
        setControlAllowed(false)
        setSessionActive(false)
        selectTab(.agents)
    }

    /// Nav bar over the assistant thread: ‹ back, waveform + name centered,
    /// 🔊 reads the last reply aloud.
    private func buildAssistantHeader() -> NSView {
        let headerView = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false

        let back = NSButton(title: "‹", target: self, action: #selector(assistantBackTapped))
        back.isBordered = false
        back.font = .systemFont(ofSize: 16, weight: .medium)
        back.contentTintColor = Theme.text2

        let icon = WaveformIconView()
        let name = NSTextField(labelWithString: "assistant")
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = Theme.text

        let mid = NSStackView(views: [icon, name])
        mid.orientation = .horizontal
        mid.spacing = 7

        let speak = NSButton(image: symbol("speaker.wave.2") ?? NSImage(),
                             target: self, action: #selector(assistantSpeakTapped))
        speak.isBordered = false
        speak.contentTintColor = Theme.text3

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor

        for v in [back, mid, speak, line] {
            v.translatesAutoresizingMaskIntoConstraints = false
            headerView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            headerView.heightAnchor.constraint(equalToConstant: 30),
            back.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 14),
            back.centerYAnchor.constraint(equalTo: headerView.centerYAnchor, constant: -3),
            mid.centerXAnchor.constraint(equalTo: headerView.centerXAnchor),
            mid.centerYAnchor.constraint(equalTo: headerView.centerYAnchor, constant: -3),
            speak.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -14),
            speak.centerYAnchor.constraint(equalTo: headerView.centerYAnchor, constant: -3),
            line.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            line.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return headerView
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
            // Flat thread (design remarks 14/16): no cards, no bubbles —
            // the ↳ marks the user's words, everything else is the assistant.
            let isUser = kind == .user
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false

            if isUser {
                label.font = .systemFont(ofSize: 11.5)
                label.textColor = Theme.text2
                let arrow = NSTextField(labelWithString: "↳")
                arrow.font = .systemFont(ofSize: 11.5, weight: .bold)
                arrow.textColor = Theme.accent
                arrow.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(arrow)
                row.addSubview(label)
                NSLayoutConstraint.activate([
                    arrow.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
                    arrow.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                    label.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
                    label.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 7),
                    label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
                    label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -3),
                ])
            } else {
                label.font = .systemFont(ofSize: 12.5)
                label.textColor = Theme.text
                row.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
                    label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
                    label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
                ])
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
