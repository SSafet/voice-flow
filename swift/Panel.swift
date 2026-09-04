import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Chat Panel — the conversation surface anchored to the pill
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Messages pop out of the little floating pill: read, type, snap, talk —
//  no separate window to manage.

enum ChatTab: Int {
    case inbox = 0    // everything you said, with a destination (filter chips)
    case agents = 1   // every agent talking to you: sessions + the assistant
}

final class ChatPanel {
    var onShown: (() -> Void)?
    /// Assistant-thread actions carry the conversation id they were tapped in.
    var onSnap: ((String) -> Void)?
    var onToggleSession: (() -> Void)?
    var onToggleAnnotate: (() -> Void)?
    var onToggleVoiceReplies: ((Bool) -> Void)?
    var onToggleControl: ((Bool) -> Void)?
    var onStop: ((String) -> Void)?
    var onClear: (() -> Void)?
    var onNewAssistant: (() -> Void)?
    var onOpenAssistantSession: ((String) -> Void)?
    var onSelectAssistantRuntime: ((AgentRuntimeKind, String) -> Void)?
    var onEscape: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSession: ((String) -> Void)?
    /// Continue tapped on a Dictations row (ticket #36) — entry id to append to.
    var onContinueDictation: ((String) -> Void)?
    /// Supplied by AppDelegate from the actual FloatingIndicator window.
    var panelAnchorProvider: (() -> PanelAnchor?)?
    var onTTSSpeak: ((TTSRequest) -> Void)?
    var onTTSSeek: ((Double) -> Void)?
    var onTTSStop: (() -> Void)?

    private let width: CGFloat = 440
    // One hardcoded panel size for every view — no adaptive growing or
    // shrinking per destination.
    private let maxHeight: CGFloat = 520
    private var height: CGFloat = 520

    private var panel: KeyablePanel!
    private var inboxTabButton: NSButton!
    private var agentsTabButton: NSButton!
    private var messagesView: MessagesView!    // messages.json archive — store only, no longer a tab
    private var dictationsView: DictationsView!
    private var agentsView: AgentsView!
    private var speechButton: NSButton!
    private var ttsView: TTSView!
    private var currentTab: ChatTab = .agents
    /// The ♪ toggle — the Speech drawer covers whichever tab is current.
    private var speechOpen = false
    private var sessionButton: NSButton!
    private var annotateButton: NSButton!
    private var voiceButton: NSButton!
    private var controlButton: NSButton!
    private var clearButton: NSButton!

    private var lastActivity: AgentActivity = .idle
    private var voiceRepliesOn = false
    private var controlOn = false
    private var sessionActive = false
    private var clickOutsideMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// The MCP thread the Agents tab currently shows, read or not — history
    /// pruning must never pull a thread out from under the reader.
    var openAgentThreadId: String? {
        guard isVisible, currentTab == .agents, !speechOpen,
              let id = agentsView.openThreadID, id.source == .mcp else { return nil }
        return id.value
    }

    /// Delivery context is intentionally derived from what is visibly open,
    /// never from the last selected/picker target after this panel disappears.
    var conversationFocus: ConversationFocus {
        guard isVisible, currentTab == .agents, !speechOpen else { return .none }
        if agentsView.openAssistantThreadClaimsFocus { return .assistant }
        if let id = agentsView.openSessionId { return .session(id) }
        return .none
    }

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
            // Accessory app + nonactivating panel: the panel can be key while
            // another app stays active, and synthetic keystrokes from clipboard
            // managers (Maccy's auto-paste, expanders) go to the ACTIVE app —
            // so a paste aimed at the composer landed in whatever was behind.
            // An explicit open is user-initiated, so take activation here. The
            // focusInput: false paths — a push, settings, restore — never do,
            // which is what keeps an agent message from stealing the screen.
            NSApp.activate(ignoringOtherApps: true)
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

#if VOICE_FLOW_QA
    var qaControlState: [String: Any] {
        let controls: [NSControl] = [
            sessionButton, annotateButton, voiceButton, controlButton, clearButton,
        ].compactMap { $0 }
        let assistant = agentsView.qaAssistantControlState
        var labels = controls.compactMap {
            $0.accessibilityLabel()?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        labels.append(contentsOf: assistant["accessibility_labels"] as? [String] ?? [])
        return [
            "runtime_present": assistant["runtime_present"] ?? false,
            "runtime_enabled": assistant["runtime_enabled"] ?? false,
            "runtime_title": assistant["runtime_title"] ?? "",
            "accessibility_labels": labels,
        ]
    }

    /// Render the signed AppKit hierarchy itself. This remains valid on test
    /// machines where macOS denies desktop capture to an ad-hoc QA bundle.
    func qaSnapshot() throws -> (path: String, width: Int, height: Int) {
        precondition(Thread.isMainThread)
        guard let view = panel.contentView else {
            throw NSError(
                domain: "VoiceFlowQA", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ChatPanel has no content view."])
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw NSError(
                domain: "VoiceFlowQA", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ChatPanel bitmap allocation failed."])
        }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "VoiceFlowQA", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "ChatPanel PNG encoding failed."])
        }
        let directory = VoiceFlowPaths.shared.directory("qa-artifacts")
        let url = directory.appendingPathComponent("agents-panel.png")
        try png.write(to: url, options: .atomic)
        return (url.path, bitmap.pixelsWide, bitmap.pixelsHigh)
    }
#endif

    private func position() {
        let anchor: PanelAnchor?
        if let exact = panelAnchorProvider?() {
            anchor = exact
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                ?? NSScreen.main ?? NSScreen.screens.first
            anchor = screen.map {
                PanelAnchor(
                    frame: NSRect(x: $0.frame.midX - 26, y: $0.frame.minY + 5,
                                  width: 52, height: 18),
                    visibleFrame: $0.visibleFrame)
            }
        }
        guard let anchor else { return }
        let target = AnchoredPanelPlacement.frame(
            size: NSSize(width: width, height: height), anchor: anchor)
        panel.setFrame(target, display: true)
    }

    // ── Content updates ─────────────────────────────────

    // ── The assistant conversation ─────────────────────
    // One surface: the Agents thread view. The panel only routes.

    /// Show this conversation as the open thread (deep link, new/cleared
    /// conversation, runtime switch). `open: false` just repaints.
    func restoreAssistantConversation(_ conversation: AssistantConversation, open: Bool = false) {
        if open { openAssistantConversation(conversation.id) } else { refreshAgents() }
    }

    func openAssistantConversation(_ id: String) {
        speechOpen = false
        agentsView.openThread(AgentsThreadID(source: .assistant, value: id))
        applyTab(.agents)
        // The old chat put the caret in its input whenever it came up.
        DispatchQueue.main.async { [weak self] in self?.agentsView.focusComposer() }
    }

    /// App-level notice ("Sent to Claude.", "Stopped by Escape"): a brief
    /// strip on the Agents surface. Errors the agent itself raises are
    /// persisted as notes in the conversation and render in the thread.
    func addNote(_ text: String) {
        agentsView.showTransientNote(text)
    }

    func setActivity(_ activity: AgentActivity, detail: String? = nil, conversationID: String) {
        lastActivity = activity
        agentsView.setAssistantActivity(activity, detail: detail, conversationID: conversationID)
    }

    func setToolDetail(_ text: String, conversationID: String) {
        agentsView.setAssistantActivity(lastActivity, detail: text, conversationID: conversationID)
    }

    // ── State reflection ────────────────────────────────

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        sessionButton.title = active ? "● End capture" : "● Start continuous capture"
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
        let agentsList = tab == .agents && !speechOpen
        agentsView.isHidden = !agentsList
        dictationsView.isHidden = !(tab == .inbox && !speechOpen)
        ttsView.isHidden = !speechOpen
        speechButton.contentTintColor = speechOpen ? Theme.accent : Theme.text3
        styleTabs()
        updateHeaderScope()
        if agentsList {
            agentsView.refresh()
        } else {
            setPreferredAgentsContentHeight(maxHeight - 136)
        }
    }

    /// Voice replies, computer control, and Clear act on the assistant
    /// conversation only. Showing them over the Inbox, the session list, or
    /// an MCP thread (which has its own trash) is noise at best and a
    /// misfire at worst — so they appear only while that conversation is
    /// what the panel shows. Annotate and Settings are global and stay.
    private func updateHeaderScope() {
        let assistantVisible = currentTab == .agents && !speechOpen
            && agentsView.openThreadID?.source == .assistant
        for button in [voiceButton, controlButton, clearButton] as [NSButton?] {
            button?.isHidden = !assistantVisible
        }
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
        speechOpen = false
        applyTab(.agents)
        agentsView.openThread(sessionId)
    }

    func openAgentThread(_ id: AgentsThreadID) {
        speechOpen = false
        applyTab(.agents)
        agentsView.openThread(id)
    }

    func beginAssistantThreadStream(conversationID: String) {
        agentsView.beginAssistantThreadStream(conversationID: conversationID)
    }

    func appendAssistantThreadDelta(_ delta: String, conversationID: String) {
        agentsView.appendAssistantThreadDelta(delta, conversationID: conversationID)
    }

    func finishAssistantThreadStream(conversationID: String) {
        agentsView.finishAssistantThreadStream(conversationID: conversationID)
    }

    func showAgentsList() {
        speechOpen = false
        agentsView.showList()
        applyTab(.agents)
    }

    @discardableResult
    func handleMissionControlEscape() -> Bool {
        guard isVisible, currentTab == .agents else { return false }
        if speechOpen {
            speechOpen = false
            applyTab(.agents)
            return true
        }
        return agentsView.handleMissionControlEscape()
    }

#if VOICE_FLOW_QA
    @discardableResult
    func qaShowAgents(destination: String, automationAction: String?, jobID: String?,
                      threadSource: String?, threadID: String?,
                      threadFilter: String?, systemAgent: String? = nil) -> Bool {
        showAgentsList()
        return agentsView.qaNavigate(
            destination: destination, automationAction: automationAction, jobID: jobID,
            threadSource: threadSource, threadID: threadID,
            threadFilter: threadFilter, systemAgent: systemAgent)
    }

    func qaSystemAgentState() -> [String: Any] { agentsView.qaSystemAgentState() }

    func qaSystemAgentEdit(model: String?, effort: String?, instructions: String?) -> Bool {
        agentsView.qaSystemAgentEdit(model: model, effort: effort, instructions: instructions)
    }

    func qaSystemAgentAction(_ action: String) -> Bool { agentsView.qaSystemAgentAction(action) }

    var qaAgentsNavigationState: [String: Any] { agentsView.qaNavigationState }

    func qaThreadUIAction(_ action: String) -> Bool { agentsView.qaThreadUIAction(action) }

    func qaSetAgentsComposerText(_ text: String) -> Bool { agentsView.qaSetComposerText(text) }
#endif

    @objc private func speechTapped() {
        speechOpen.toggle()
        applyTab(currentTab)
    }

    func addDictation(text: String, time: String, timestamp: String? = nil,
                      destination: CaptureDestination = .pasted, seen: Bool? = nil,
                      capability: CaptureCapability? = nil,
                      attachments: [String] = [], captureId: String? = nil) {
        dictationsView.addEntry(text: text, time: time, timestamp: timestamp,
                               destination: destination, seen: seen,
                               capability: capability, attachments: attachments, captureId: captureId)
        styleTabs()
    }

    /// Continue-append (ticket #36): new transcript joins an existing entry.
    func appendDictation(entryId: String, text: String) {
        dictationsView.appendToEntry(id: entryId, text: text)
        styleTabs()
    }

    func setContinuationActive(entryId: String?) {
        dictationsView.setContinuationActive(entryId: entryId)
    }

    /// Sync upsert (ticket #36): add, or update-in-place when the id is known.
    func upsertDictation(id: String?, text: String, time: String, timestamp: String? = nil,
                         destination: CaptureDestination = .kept, seen: Bool? = nil) {
        dictationsView.upsertEntry(id: id, text: text, time: time, timestamp: timestamp,
                                   destination: destination, seen: seen)
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
        panel.onEscape = { [weak self] in self?.onEscape?() }

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

        sessionButton = NSButton(title: "● Start continuous capture", target: self, action: #selector(sessionTapped))
        sessionButton.isBordered = false
        sessionButton.font = .systemFont(ofSize: 12, weight: .semibold)
        sessionButton.contentTintColor = NSColor(r: 120, g: 200, b: 120)

        annotateButton = iconButton("pencil.tip", action: #selector(annotateTapped), tip: "Annotate the screen")
        voiceButton = iconButton("speaker.slash", action: #selector(voiceTapped), tip: "Voice replies off")
        controlButton = iconButton("hand.raised.slash", action: #selector(controlTapped), tip: "Computer control off")
        clearButton = iconButton("trash", action: #selector(clearTapped), tip: "Clear conversation")
        let settingsButton = iconButton("gearshape", action: #selector(settingsTapped), tip: "Settings")

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Continuous capture lives on the pill/menu/hotkey — not in the panel
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
        dictationsView.onContinueRequested = { [weak self] id in self?.onContinueDictation?(id) }
        agentsView = AgentsView()
        agentsView.onModeChanged = { [weak self] in self?.updateHeaderScope() }
        agentsView.isHidden = true
        agentsView.setContentHuggingPriority(.defaultLow, for: .vertical)
        agentsView.onNewAssistant = { [weak self] in self?.onNewAssistant?() }
        agentsView.onOpenAssistantSession = { [weak self] id in self?.onOpenAssistantSession?(id) }
        agentsView.onOpenSession = { [weak self] id in self?.onOpenSession?(id) }
        agentsView.onPreferredHeightChanged = { [weak self] contentHeight in
            self?.setPreferredAgentsContentHeight(contentHeight)
        }
        agentsView.onSnap = { [weak self] id in self?.onSnap?(id.value) }
        agentsView.onStop = { [weak self] id in self?.onStop?(id.value) }
        agentsView.onSelectAssistantRuntime = { [weak self] runtime, id in
            self?.onSelectAssistantRuntime?(runtime, id.value)
        }
        panel.onCommand = { [weak self] key in
            guard let self,
                  self.agentsView.handleMissionControlCommand(key) else { return false }
            self.speechOpen = false
            self.applyTab(.agents)
            return true
        }
        ttsView = TTSView()
        ttsView.isHidden = true
        ttsView.setContentHuggingPriority(.defaultLow, for: .vertical)
        ttsView.onSpeak = { [weak self] request in self?.onTTSSpeak?(request) }
        ttsView.onSeek = { [weak self] position in self?.onTTSSeek?(position) }
        ttsView.onStop = { [weak self] in self?.onTTSStop?() }

        // Assemble ------------------------------------------------------------
        let column = NSStackView(views: [header, headerLine, tabBar, agentsView, dictationsView, ttsView])
        column.orientation = .vertical
        column.spacing = 4
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        for view in [header, headerLine, tabBar, agentsView, dictationsView, ttsView] as [NSView] {
            view.leadingAnchor.constraint(equalTo: column.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        }

        panel.contentView = root
        setVoiceReplies(false)
        setControlAllowed(UserSettings.shared.assistantComputerUse)
        setSessionActive(false)
        selectTab(.agents)
    }

    private func setPreferredAgentsContentHeight(_ contentHeight: CGFloat) {
        // Fixed-height panel: content taller than the frame scrolls; shorter
        // content leaves quiet space. The panel itself never resizes.
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
    // ── Actions ─────────────────────────────────────────

    @objc private func sessionTapped() { onToggleSession?() }
    @objc private func annotateTapped() { onToggleAnnotate?() }
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
    var onEscape: (() -> Void)?
    var onCommand: ((String) -> Bool)?
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           let key = event.charactersIgnoringModifiers,
           onCommand?(key) == true {
            return true
        }
        if let action = KeyablePanel.editingAction(for: event),
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// This is a `.nonactivatingPanel` in an `.accessory` app: it takes key
    /// focus without activating us, so the frontmost app keeps the menu bar
    /// and our own Edit menu's ⌘V / ⌘C / ⌘X / ⌘A / ⌘Z never fires. Typing
    /// works (keys go to the key window), pasting did not. Send the standard
    /// editing actions down the responder chain ourselves instead.
    private static func editingAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let shifted = flags.contains(.shift)
        switch key {
        case "v" where !shifted: return #selector(NSText.paste(_:))
        case "c" where !shifted: return #selector(NSText.copy(_:))
        case "x" where !shifted: return #selector(NSText.cut(_:))
        case "a" where !shifted: return #selector(NSResponder.selectAll(_:))
        case "z": return Selector((shifted ? "redo:" : "undo:"))
        default: return nil
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}


