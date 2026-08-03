import Cocoa
import AVFoundation
import CoreGraphics

// ── App State ───────────────────────────────────────────
enum AppState: String {
    case idle, loading, recording, processing, done, handsFree
}

// A question Claude (over MCP) asked the user; the tool call blocks on the
// semaphore until the user answers by voice/typing/demonstration, dismisses
// the prompt, or the timeout passes.
final class PendingInteraction {
    let prompt: String
    let sessionId: String?      // MCP session that asked (routes late answers)
    let semaphore = DispatchSemaphore(value: 0)
    var responseText: String?
    var attachments: [String] = []   // absolute screenshot/frame paths
    var cancelled = false
    /// Set (on main) once the blocked tool call has returned — a late
    /// answer must go to the inbox instead of this dead interaction.
    var resolved = false

    init(prompt: String, sessionId: String?) {
        self.prompt = prompt
        self.sessionId = sessionId
    }
}

// ── App Delegate ────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarManager!
    var indicator: FloatingIndicator!
    var chatPanel: ChatPanel!
    var annotationOverlay: AnnotationOverlay!
    var settingsWindow: SettingsWindowController!
    var permissionsWindow: PermissionsWindowController!
    var hotkeyManager: HotkeyManager!
    var handsFreeHotkeyManager: HotkeyManager!
    var ttsHotkeyManager: HotkeyManager!
    var continuousCaptureHotkeyManager: HotkeyManager!
    var snapshotHotkeyManager: HotkeyManager!
    var annotateHotkeyManager: HotkeyManager!
    var recorder: AudioRecorder!
    var backend: BackendBridge!
    var paster: Paster!
    var ttsController: TTSController!
    var localAPIServer: LocalAPIServer!
    var syncServer: SyncServer!
    var replyBubble: ReplyBubble!
    var replySpeaker: AgentReplySpeaker!
    var captureStore: CaptureStore!
    var overlayManager: OverlayManager!
    var inbox: MessageInbox!
    var mcpServer: MCPServer!
    /// Set while a report_to_user `question` is blocking on the human. Main thread only.
    var pendingInteraction: PendingInteraction?
    /// Which Claude Code session the talk hotkeys feed (newest connection
    /// by default; switchable via ⌃⌥1–6 or the menu bar — the pill flashes
    /// the session title and carries the active number as a badge).
    /// Change it only through setTargetSession. Main thread only.
    var targetSessionId: String?
    var sessionSwitchHotkeyManagers: [HotkeyManager] = []
    /// Pushes waiting per session, oldest first — the stack the grown
    /// surface renders and the picker previews. A new push APPENDS; it
    /// never replaces what the user hasn't seen yet. (Sessionless tool
    /// calls are folded into the "anonymous" registry session by
    /// MCPServer, so every queue key is a real session id.) `seen` flips
    /// when the stack displays — unseen pushes light the pill's unread ring.
    struct SessionPush: Codable {
        let id = UUID()
        var at = Date()
        let title: String
        let text: String
        let hint: String?
        let isAsk: Bool
        var seen = false
        /// The user's reply, attached to the ask it answered — rendered as
        /// the ↳ line in the panel's Agents thread.
        var answer: String? = nil
        /// Read aloud already — the consumption cursor (ticket #16):
        /// consumed = spoken OR answered; read-aloud starts after it.
        var spoken: Bool? = nil
        /// Interrupted mid-listen: the sentence to resume from next time
        /// (podcast three-state, ticket VF-48). nil once fully heard.
        var resumeSentence: Int? = nil
        /// Consumed from the pill (trashed / answered / session ended read):
        /// gone from every quick surface, kept as history in the panel's
        /// Agents thread until the user ✓-completes it (ticket #17).
        var done: Bool? = nil
    }
    /// Persisted to pushes.json — unread stacks must survive app restarts,
    /// not just session deaths. A session re-adopting its old id reclaims
    /// its queue; the rest show as ghost picker entries.
    var sessionPushes: [String: [SessionPush]] = [:] {
        didSet { Self.savePushes(sessionPushes) }
    }
    /// What the player is reading right now — a session stack, the
    /// assistant's reply, or plain text (VF-48 unification): one player,
    /// many inputs. Only session stacks carry consumption bookkeeping;
    /// every source shares the band/waveform/karaoke/transport.
    private var playerContext: PlayerContext?
    /// The assistant's last finished reply — the transport's "re-read"
    /// target while its conversation is the grown surface.
    private var lastAssistantReply: String?
    // Transport-key press counting (ticket VF-48).
    private var transportPressCount = 0
    private var transportResolveTimer: Timer?
    private var transportHoldTimer: Timer?
    private var transportHoldFired = false
    private let maxQueuedPushes = 8
    /// Done pushes included — how much thread history a session keeps.
    private let maxKeptPushes = 40

    private static let pushesURL = VoiceFlowPaths.shared.file("pushes.json")

    private static func savePushes(_ pushes: [String: [SessionPush]]) {
        if let data = try? JSONEncoder().encode(pushes) {
            try? data.write(to: pushesURL, options: .atomic)
        }
    }

    /// Sticky display names: the label each session wore while alive, kept
    /// so a completed/ghost thread NEVER changes title after its session
    /// dies — the title is how the user tracks threads (ticket #14 QA).
    /// Persisted; pruned with the stacks they label.
    var sessionLabels: [String: String] = [:] {
        didSet { Self.saveLabels(sessionLabels) }
    }

    private static let labelsURL = VoiceFlowPaths.shared.file("session-names.json")

    private static func saveLabels(_ labels: [String: String]) {
        if let data = try? JSONEncoder().encode(labels) {
            try? data.write(to: labelsURL, options: .atomic)
        }
    }

    private static func loadLabels() -> [String: String] {
        guard let data = try? Data(contentsOf: labelsURL),
              let labels = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return labels
    }

    /// Record the registry label for a session so its threads keep their
    /// title once the session is gone. Main thread.
    func rememberSessionLabel(_ sessionId: String?) {
        guard let sessionId, let label = mcpServer.sessions.session(sessionId)?.label,
              sessionLabels[sessionId] != label else { return }
        sessionLabels[sessionId] = label
    }

    private static func loadPushes() -> [String: [SessionPush]] {
        guard let data = try? Data(contentsOf: pushesURL),
              let pushes = try? JSONDecoder().decode([String: [SessionPush]].self, from: data) else { return [:] }
        return pushes.mapValues { queue in
            queue.map { push in
                // An ask can't outlive its blocked tool call across a
                // restart — it degrades to a plain readable message.
                push.isAsk && push.answer == nil
                    ? SessionPush(at: push.at, title: push.title, text: push.text,
                                  hint: nil, isAsk: false, seen: push.seen,
                                  spoken: push.spoken, done: push.done)
                    : push
            }
        }
    }
    /// Which session's push is currently displayed (trash targets it).
    var currentPushSessionId: String?

    /// Consume a stack: every push becomes done history — it leaves the
    /// pill's quick surfaces (picker dot, ⌃⌥ stack, unread ring) but stays
    /// readable in the panel's Agents thread until the user ✓-completes
    /// the thread there (ticket #17). Main thread.
    private func markStackDone(_ sessionId: String) {
        guard let queue = sessionPushes[sessionId] else { return }
        sessionPushes[sessionId] = queue.map { push in
            var done = push
            done.done = true
            done.seen = true
            return done
        }
        chatPanel.refreshAgents()
    }

    // Agent session
    var screenCapture: ScreenCapture!
    var captureScheduler: CaptureScheduler!
    var workflowWatcher: WorkflowWatcher!
    var agent: AgentSession!
    private var agentJobStore: AgentJobStore?
    private var agentSupervisor: AgentSupervisor?
#if VOICE_FLOW_QA
    private weak var activeAgentJobAlert: NSAlert?
    private weak var activeAgentJobEditor: AgentJobEditorView?
    private var activeAgentJobQAWindow: NSWindow?
#endif
    private let assistantContinuityClassifier = AssistantContinuityClassifier()
    private struct PendingAssistantWakeTurn {
        let assistant: AssistantDefinition
        let displayText: String
        let agentText: String
        let screenshots: [Data]
        let attachmentNote: String?
    }
    private var pendingAssistantWakeTurns: [PendingAssistantWakeTurn] = []
    private var processingAssistantWakeTurns = false
    private var assistantWakeInFlight = false
    private var assistantPickerDismissed = false
    /// True only for an automatically routed wake turn whose full reply must
    /// not take over the closed-panel grown surface (VF-54).
    private var assistantTurnUsesReceiptPresentation = false
    private var sessionActive = false
    private var lastCaptureData: Data?
    private let diffThreshold: Double = 0.01
    private var ambientScreenshots: [Data] = []
    private let maxAmbientScreenshots = 7
    // Frames collected during a session, waiting for the end-of-session send.
    private var pendingSessionShots: [Data] = []
    private var escapeMonitor: Any?

    /// One microphone capture is active, but several stopped runs may wait on
    /// transcription. Every async callback addresses a UUID instead of shared
    /// mutable purpose/context slots.
    private var activeRunId: UUID?
    private var captureRuns: [UUID: CaptureRun] = [:]
    /// Last screenshot display per MCP session. Annotation coordinates from
    /// that session stay coupled to the image the agent actually inspected.
    private var lastMCPDisplay: [String: CGDirectDisplayID] = [:]
    private var initialPermissionsRequested = false
    private var screenGrantPollTimer: Timer?
    private var screenGrantPendingRestart = false

    // Streaming partial transcription
    var transcriptPanel: FloatingTranscriptPanel!
    private var partialTimer: Timer?
    private var partialRequestId: Int = 0
    private var latestDisplayedPartialId: Int = 0
    private var streamingViaAX = false
    private var hadPartialStream = false

    private var state: AppState = .loading {
        didSet {
            DispatchQueue.main.async { [self] in
                menuBar?.setState(state)
                let capability = activeRunId.flatMap { captureRuns[$0]?.capability } ?? .dictate
                indicator?.setState(state, recordingFor: capability)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserSettings.shared.load()

        setupUIComponents()
        setupMainMenu()
        setupCore()
        setupAgent()
        setupHotkeys()

        requestInitialPermissionsIfNeeded()
        startHotkeyWithAccessibilityCheck()

        // ── launch backend ──────────────────────────────
        state = .loading
        backend.start()
        vflog("app started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ttsController?.shutdown()
        localAPIServer?.stop()
        syncServer?.stop()
        // AppKit does not wait for unstructured Tasks launched from this
        // callback. Join runtime teardown on a detached executor before the
        // process exits so Codex/OpenCode and their tool children cannot be
        // reparented as orphans.
        let teardown = DispatchSemaphore(value: 0)
        let foregroundAgent = agent
        let backgroundSupervisor = agentSupervisor
        Task.detached {
            await foregroundAgent?.shutdown()
            await backgroundSupervisor?.stop()
            await AgentPermissionBroker.shared.rejectAll()
            await OpenCodeSupervisor.shared.stopAll()
            teardown.signal()
        }
        _ = teardown.wait(timeout: .now() + 8)
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionWindow()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Setup
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func setupUIComponents() {
        menuBar = MenuBarManager()
        menuBar.onShowHistory = { [weak self] in self?.toggleHistory() }
        menuBar.onShowPermissions = { [weak self] in self?.showPermissions() }
        menuBar.onShowSettings = { [weak self] in self?.showSettings() }
        menuBar.onToggleSession = { [weak self] in self?.toggleSession() }
        menuBar.onToggleWatcher = { [weak self] in self?.toggleWorkflowWatcher() }
        menuBar.onRunReview = { [weak self] in self?.runWatcherReviewNow() }
        menuBar.onOpenLatestReview = { [weak self] in self?.openLatestWatcherReview() }
        menuBar.onOpenWatcherFolder = { NSWorkspace.shared.open(WorkflowWatcher.baseDir) }
        menuBar.watcherStatusProvider = { [weak self] in self?.workflowWatcher?.statusLine() ?? "Off" }
        menuBar.setWatcherActive(UserSettings.shared.workflowWatcherEnabled)
        menuBar.onCopyCapturePrompt = { [weak self] in self?.copyLatestCapturePrompt() }
        menuBar.inboxCountProvider = { [weak self] in self?.inbox.pendingCount ?? 0 }
        menuBar.onCopyInbox = { [weak self] in self?.copyQueuedMessages() }
        menuBar.claudeSessionsProvider = { [weak self] in
            guard let self else { return [] }
            // Same list, order, and numbering as the picker and ⌃⌥1–9 —
            // two orderings of the same sessions would be a routing trap.
            return self.slottedSessions().map { entry in
                let age: String
                if self.isAssistantPickerSession(entry.id) {
                    age = "active \(Self.relativeAge(self.agent.currentConversation.updatedAt))"
                } else {
                    age = self.mcpServer.sessions.session(entry.id)
                        .map { "active \(Self.relativeAge($0.lastSeen))" } ?? "ended — unread"
                }
                return (entry.id,
                        "\(entry.slot) · \(entry.label) — \(age)",
                        entry.id == self.targetSessionId)
            }
        }
        menuBar.onSelectClaudeSession = { [weak self] id in
            self?.userSelectSession(id)
        }
        menuBar.onToggleAnnotate = { [weak self] in self?.annotationOverlay.toggleEditing() }
        menuBar.onShowChat = { [weak self] in self?.chatPanel.show() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        indicator = FloatingIndicator()
        indicator.onClick = { [weak self] in self?.chatPanel.toggle() }
        // EVERY collapse re-evaluates the player surface — the strip takes
        // over after ✕/click/typed-reply/flash exactly like after Esc
        // (interaction audit: only Esc used to hand off).
        indicator.onCollapsed = { [weak self] in self?.refreshPlayerSurface() }
        indicator.onGrownClick = { [weak self] in self?.handleGrownPillClick() }
        indicator.onEscape = { [weak self] in self?.handleVoiceFlowEscape() }
        indicator.onShowHistory = { [weak self] in self?.toggleHistory() }
        indicator.onToggleSession = { [weak self] in self?.toggleSession() }
        indicator.onToggleWatcher = { [weak self] in self?.toggleWorkflowWatcher() }
        indicator.onToggleAnnotate = { [weak self] in self?.annotationOverlay.toggleEditing() }
        indicator.onSessionRemovals = { [weak self] in
            self?.pickerSessions() ?? []
        }
        indicator.onRemoveSession = { [weak self] id in
            guard let self else { return }
            let label = self.pickerSessions().first { $0.id == id }?.label ?? "session"
            if self.isAssistantPickerSession(id) {
                self.assistantPickerDismissed = true
                self.agent.markCurrentAssistantRepliesSeen()
                if self.targetSessionId == id {
                    self.setTargetSession(self.firstAvailableTarget(excluding: id), announce: false)
                }
                if self.indicator.isGrownAssistantConversationVisible { self.replyBubble.hide() }
                self.refreshSessionIndicator()
                self.refreshUnreadIndicator()
                self.replyBubble.showTransient("\(label) removed", seconds: 4)
                return
            }
            _ = self.mcpServer.sessions.close(id)   // nil for a ghost — fine
            self.markStackDone(id)
            self.inbox.cancelWait(for: id)
            // Its stack may be the thing on screen right now.
            if self.currentPushSessionId == id {
                self.currentPushSessionId = nil
                self.replyBubble.hide()
            }
            if self.targetSessionId == id {
                self.setTargetSession(self.firstAvailableTarget(excluding: id), announce: false)
            }
            self.refreshSessionIndicator()
            self.refreshUnreadIndicator()
            self.replyBubble.showTransient("\(label) removed", seconds: 4)
        }
        indicator.onQuit = { NSApp.terminate(nil) }
        indicator.show()

        annotationOverlay = AnnotationOverlay()
        annotationOverlay.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            self.chatPanel.setAnnotating(editing)
            // A finished drawing is part of the session story — capture it
            // (after a beat so the toolbar has faded out).
            if !editing, self.sessionActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard self.sessionActive else { return }
                    let display = self.activeRunId
                        .flatMap { self.captureRuns[$0]?.display }
                    Task { @MainActor in
                        if let shot = try? await self.screenCapture.captureScreen(on: display) {
                            self.lastCaptureData = shot
                            self.appendSessionShot(shot)
                        }
                    }
                }
            }
        }

        // Unread stacks from before the restart come back as ghost picker
        // entries (their sessions reclaim them if they reconnect).
        sessionPushes = Self.loadPushes()
        sessionLabels = Self.loadLabels()

        replyBubble = ReplyBubble(indicator: indicator)
        // ✕ closes and keeps: a pending ask stays pending (answer whenever,
        // or it times out into the inbox); the session's stack survives.
        // If OTHER sessions queued pushes while this one held the screen,
        // flash a receipt once the collapse lands — the amber picker dots
        // are otherwise their only trace.
        replyBubble.onClosed = { [weak self] in
            guard let self else { return }
            let closed = self.currentPushSessionId
            self.currentPushSessionId = nil
            // Closing a fully-read dead session's stack is the moment it
            // retires and frees its number (ticket VF-48).
            self.retireConsumedGhosts()
            let waiting = self.unseenSessions(excluding: closed)
            guard waiting > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard !self.indicator.isGrownVisible else { return }
                self.indicator.flashMessage(
                    "\(waiting) session\(waiting == 1 ? "" : "s") waiting — ⌃⌥1–9", seconds: 4)
            }
        }
        // Trash means "I'm done with this one": it cancels a waiting ask,
        // consumes the push stack (kept as done history in the panel's
        // Agents thread — ticket #17), AND disconnects the session — its
        // picker dot goes too (a live session quietly re-adopts on its
        // next tool call, so this is always safe).
        replyBubble.onTrashed = { [weak self] in
            guard let self else { return }
            if self.indicator.isGrownAssistantConversationVisible,
               self.isAssistantPickerSession(self.targetSessionId) {
                if self.playerContext != nil { self.ttsController.stop() }
                let removed = self.assistantPickerLabel
                let id = self.targetSessionId
                self.assistantPickerDismissed = true
                self.agent.markCurrentAssistantRepliesSeen()
                self.replyBubble.hide()
                self.setTargetSession(self.firstAvailableTarget(excluding: id), announce: false)
                self.refreshSessionIndicator()
                self.refreshUnreadIndicator()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    guard !self.indicator.isGrownVisible else { return }
                    self.indicator.flashMessage("\(removed) removed", seconds: 4)
                }
                return
            }
            // Trashing the stack that is being read aloud SILENCES it
            // (Safet QA: delete didn't stop the voice).
            if self.playerContext != nil,
               self.playerContext?.sessionId == self.currentPushSessionId {
                self.ttsController.stop()
            }
            // Cancel only an ask that belongs to the trashed stack — a
            // DIFFERENT session's pending ask must survive this click.
            if let interaction = self.pendingInteraction,
               interaction.sessionId == self.currentPushSessionId {
                interaction.cancelled = true
                interaction.semaphore.signal()
            }
            if let id = self.currentPushSessionId {
                self.markStackDone(id)
                // A listener parked on this session must learn the user is
                // done — otherwise its next poll resurrects the session.
                self.inbox.cancelWait(for: id)
                // The trashed session's on-screen elements go with it —
                // annotations must not outlive their message (ticket #14).
                self.overlayManager.removeAll(forSession: id)
                if let closed = self.mcpServer.sessions.close(id) {
                    if self.targetSessionId == id {
                        self.setTargetSession(self.firstAvailableTarget(excluding: id), announce: false)
                    }
                    self.refreshSessionIndicator()
                    // The receipt has to wait for the collapse to land.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        guard !self.indicator.isGrownVisible else { return }
                        self.indicator.flashMessage("\(closed.label) removed", seconds: 4)
                    }
                }
            }
            self.currentPushSessionId = nil
            self.refreshUnreadIndicator()
        }
        replyBubble.onSpeakRequested = { [weak self] text in
            guard let self else { return }
            // Session stacks speak from the consumption cursor (ticket #16);
            // sessionless content plays the shown text through the same
            // player, under the assistant's name when it's their surface.
            if let sid = self.currentPushSessionId, self.sessionPushes[sid]?.isEmpty == false {
                self.speakSessionUnconsumed(sid)
                return
            }
            guard !text.isEmpty else { return }
            let source: PlayerContext.Source = self.indicator.isGrownAssistantConversationVisible
                ? .assistantReply(title: self.assistantPlayerTitle())
                : .text(title: "Speech")
            self.speakTextThroughPlayer(text, source: source, showSettingsOnMissingKey: false)
        }


        overlayManager = OverlayManager()
        overlayManager.start()

        chatPanel = ChatPanel()
        chatPanel.panelAnchorProvider = { [weak self] in self?.indicator.panelAnchor }
        chatPanel.onShown = { [weak self] in
            self?.replyBubble.hide()
            // The panel owns conversations now — a stale grown-session id
            // must not keep routing trash/replies (interaction audit).
            self?.currentPushSessionId = nil
        }
        chatPanel.agentsDataSource = self
        chatPanel.onOpenSession = { [weak self] id in
            self?.setTargetSession(id, announce: false)
        }
        chatPanel.onNewAssistant = { [weak self] in
            guard let self, !self.agent.isRunning else {
                self?.replyBubble.showTransient("wait for the Assistant to finish first", seconds: 4)
                return
            }
            let conversation = self.agent.createConversation()
            self.chatPanel.restoreAssistantConversation(conversation, open: true)
            self.chatPanel.refreshAgents()
        }
        chatPanel.onNewAgentJob = { [weak self] in self?.createAgentJob() }
        chatPanel.onOpenAssistantSession = { [weak self] id in
            guard let self else { return }
            guard let conversation = self.agent.activateConversation(id) else {
                self.replyBubble.showTransient("wait for the Assistant to finish first", seconds: 4)
                return
            }
            self.chatPanel.restoreAssistantConversation(conversation, open: true)
            self.agent.markCurrentAssistantRepliesSeen()
            self.refreshUnreadIndicator()
        }
        chatPanel.onDeleteAssistant = { [weak self] in
            guard let self else { return }
            guard let conversation = self.agent.deleteConversation(self.agent.currentSessionId) else {
                self.replyBubble.showTransient("wait for the Assistant to finish first", seconds: 4)
                return
            }
            self.chatPanel.restoreAssistantConversation(conversation)
            self.chatPanel.showAgentsList()
            self.chatPanel.refreshAgents()
            self.replyBubble.showTransient("Assistant session deleted", seconds: 4)
        }
        chatPanel.onSelectAssistantRuntime = { [weak self] runtime in
            guard let self else { return }
            guard let conversation = self.agent.setPreferredRuntime(runtime) else {
                self.chatPanel.setAssistantRuntime(self.agent.preferredRuntime, enabled: false)
                self.replyBubble.showTransient("wait for the Assistant to finish first", seconds: 4)
                return
            }
            self.chatPanel.setAssistantRuntime(runtime, enabled: true)
            self.chatPanel.restoreAssistantConversation(conversation, open: true)
            self.replyBubble.showTransient("Assistant will use \(runtime.label)", seconds: 3)
        }
        chatPanel.onSendText = { [weak self] text in self?.sendTypedMessage(text) }
        chatPanel.onEscape = { [weak self] in self?.handleVoiceFlowEscape() }
        chatPanel.onContinueDictation = { [weak self] entryId in
            self?.continueDictation(appendingTo: entryId)
        }
        chatPanel.onSnap = { [weak self] in self?.snapAndSend() }
        chatPanel.onToggleSession = { [weak self] in self?.toggleSession() }
        chatPanel.onToggleAnnotate = { [weak self] in self?.annotationOverlay.toggleEditing() }
        chatPanel.onToggleVoiceReplies = { on in
            UserSettings.shared.voiceRepliesEnabled = on
            UserSettings.shared.save()
        }
        chatPanel.onToggleControl = { [weak self] on in
            self?.agent.allowControl = on
        }
        chatPanel.onStop = { [weak self] in
            self?.agent.interrupt()
            self?.stopSpeechPlayback()
        }
        chatPanel.onClear = { [weak self] in
            guard let self else { return }
            let conversation = self.agent.reset()
            self.chatPanel.restoreAssistantConversation(conversation, open: true)
            self.chatPanel.setActivity(.idle)
            self.chatPanel.refreshAgents()
        }
        chatPanel.onOpenSettings = { [weak self] in self?.showSettings() }
        chatPanel.onTTSSpeak = { [weak self] request in
            self?.handleTTSSpeak(request, reveal: false, showSettingsOnMissingKey: true)
        }
        chatPanel.onTTSSeek = { [weak self] position in
            self?.ttsController.seek(to: position)
        }
        chatPanel.onTTSStop = { [weak self] in
            self?.ttsController.stop()
        }
        chatPanel.setVoiceReplies(UserSettings.shared.voiceRepliesEnabled)

        transcriptPanel = FloatingTranscriptPanel()

        settingsWindow = SettingsWindowController()
        settingsWindow.onSettingsChanged = { [weak self] in self?.syncWorkflowWatcher() }
        settingsWindow.onHotkeyChanged = { [weak self] spec in
            self?.hotkeyManager.updateSpec(spec)
        }
        settingsWindow.onHandsFreeHotkeyChanged = { [weak self] spec in
            self?.handsFreeHotkeyManager.updateSpec(spec)
        }
        settingsWindow.onTTSHotkeyChanged = { [weak self] spec in
            self?.ttsHotkeyManager.updateSpec(spec)
        }
        settingsWindow.onContinuousCaptureHotkeyChanged = { [weak self] spec in
            self?.continuousCaptureHotkeyManager.updateSpec(spec)
        }
        settingsWindow.onSnapshotHotkeyChanged = { [weak self] spec in
            self?.snapshotHotkeyManager.updateSpec(spec)
        }
        settingsWindow.onAnnotateHotkeyChanged = { [weak self] spec in
            self?.annotateHotkeyManager.updateSpec(spec)
        }
        settingsWindow.onWindowClosed = { [weak self] in self?.hideDockIfNoWindows() }
        // Clicking into Settings while the chat panel floats over it should
        // dismiss the panel — same feel as clicking anywhere else outside it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window === self.settingsWindow.window else { return }
            self.chatPanel.hide()
        }

        permissionsWindow = PermissionsWindowController()
        permissionsWindow.onRequestMicrophone = { [weak self] in self?.requestMicrophonePermission() }
        permissionsWindow.onRequestScreenCapture = { [weak self] in self?.requestScreenCapturePermission() }
        permissionsWindow.onRequestAccessibility = { [weak self] in self?.requestAccessibilityPermission() }
        permissionsWindow.onRefresh = { [weak self] in self?.refreshPermissionWindow() }
        permissionsWindow.onWindowClosed = { [weak self] in self?.hideDockIfNoWindows() }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Voice Flow")
        appMenu.addItem(withTitle: "Permissions…", action: #selector(showPermissionsMenuAction), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsMenuAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Voice Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undoItem = editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupCore() {
        ModelGatewayCredentials.shared.configure { [weak self] in
            let configured = UserSettings.shared.agentBaseURL
            let baseURL = URL(string: configured) ?? URL(string: DefaultAgentBaseURL)!
            let globalModel = UserSettings.shared.agentModel
            let catalogModels = OpenRouterModelCatalog.shared.cachedModels(
                including: [globalModel])
            var allowed = Set(catalogModels.map(\.id))
            if let store = self?.agentJobStore,
               let jobs = try? store.jobs(limit: 500) {
                allowed.formUnion(jobs.compactMap(\.modelID))
            }
            return ModelGatewayCredentialSnapshot(
                apiKey: KeychainStore.shared.loadAgentAPIKey(),
                upstreamBaseURL: baseURL,
                allowedModels: allowed,
                modelOutputTokenLimits: Dictionary(uniqueKeysWithValues:
                    catalogModels.map { ($0.id, $0.openCodeOutputLimit) }),
                dailyBudgetUSD: UserSettings.shared.agentDailyBudgetUSD)
        }
        AgentJobRuntimeConfiguration.shared.configure {
            AgentModelSelection(
                provider: "openrouter", model: UserSettings.shared.agentModel)
        }
        recorder = AudioRecorder()
        paster = Paster()
        captureStore = CaptureStore()
        inbox = MessageInbox()
        ttsController = TTSController()
        ttsController.onStatusChanged = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.indicator.setTTSStatus(snapshot)
                self?.chatPanel.setTTSStatus(snapshot)
                self?.settleSpeechConsumption(snapshot.phase)
                self?.refreshPlayerSurface()
            }
        }
        ttsController.onQueuedChunkChanged = { [weak self] index, _ in
            DispatchQueue.main.async { self?.handlePlayerChunkChange(index) }
        }
        ttsController.onQueuedSpeechFinished = { [weak self] in
            DispatchQueue.main.async { self?.handlePlayerQueueFinished() }
        }
        indicator.onPlayerToggle = { [weak self] in
            self?.ttsController.togglePause()
            self?.refreshPlayerSurface()
        }
        indicator.onPlayerSeek = { [weak self] fraction in
            self?.playerSeek(messageFraction: fraction)
        }
        indicator.onPlayerSpeed = { [weak self] delta in
            self?.playerAdjustSpeed(delta)
        }
        // The band's ✕ — a real STOP, not a pause (Safet QA): audio ends,
        // heard consumption settles, the interrupted push keeps its
        // resume point.
        indicator.onPlayerStop = { [weak self] in
            self?.playerStop()
        }
        // Typed reply from the grown pill (ticket VF-48) — same routing as
        // a voice answer: fulfills the blocked ask, queues in the inbox,
        // or — on the assistant's surface — continues its conversation.
        indicator.onGrownTypedReply = { [weak self] text in
            guard let self else { return }
            if let sid = self.currentPushSessionId {
                self.sendMessage(toSession: sid, text: text)
                self.currentPushSessionId = nil
                self.indicator.hideGrown()
                self.replyBubble.showTransient("sent ✓", seconds: 3)
            } else if self.indicator.isGrownAssistantConversationVisible {
                self.sendTypedMessage(text)
            }
        }
        AssistantsStore.shared.load()
        replySpeaker = AgentReplySpeaker(tts: ttsController)
        replySpeaker.voiceOverride = AssistantsStore.shared.base?.voice

        backend = BackendBridge()
        backend.onReady = { [weak self] in
            self?.state = .idle
            vflog("backend ready — dictation available")
        }
        backend.onResult = { [weak self] requestId, raw, cleaned in
            self?.handleTranscriptionResult(requestId: requestId, raw: raw, cleaned: cleaned)
        }
        backend.onPartialResult = { [weak self] runId, text, requestId in
            self?.handlePartialResult(runId: runId, text: text, requestId: requestId)
        }
        backend.onError = { [weak self] requestId, msg in
            vflog("backend error: \(msg)")
            guard let self else { return }
            self.handleTranscriptionError(requestId: requestId, message: msg)
        }
        backend.onStatus = { msg in vflog(msg) }

        let initialTTSRequest = TTSRequest(
            text: "",
            voice: UserSettings.shared.ttsVoice,
            speed: UserSettings.shared.ttsSpeed,
            instructions: UserSettings.shared.ttsInstructions
        )
        chatPanel.applyTTSRequest(initialTTSRequest)
        chatPanel.setTTSStatus(ttsController.status)

        setupLocalAPIServer()
        setupSyncServer()
    }

    /// Mobile sync (ticket #7): phone dictations/chat in, Mac history +
    /// settings parity out. Token-protected; see swift/Sync.swift.
    private func setupSyncServer() {
        syncServer = SyncServer()
        syncServer.onServerMessage = { message in vflog(message) }
        syncServer.onPaired = { [weak self] device in
            self?.indicator.flashMessage("\(device) paired with Voice Flow", seconds: 4)
        }
        menuBar.onPairPhone = { [weak self] in
            self?.syncServer.openPairWindow()
            self?.indicator.flashMessage("Pairing open — launch the phone app now", seconds: 6)
        }
        localAPIServer.onPairMode = { [weak self] in
            DispatchQueue.main.sync { self?.syncServer.openPairWindow() }
            return LocalAPIResponse.ok(["ok": true])
        }
        syncServer.onDictations = { [weak self] entries in
            for e in entries {
                self?.chatPanel.upsertDictation(
                    id: e.id, text: e.text, time: e.time, timestamp: e.timestamp,
                    destination: CaptureDestination(rawValue: e.destination) ?? .kept,
                    seen: e.destination == CaptureDestination.kept.rawValue ? false : nil)
            }
        }
        syncServer.start()
    }

    private func setupAgent() {
        screenCapture = ScreenCapture()
        workflowWatcher = WorkflowWatcher(screenCapture: screenCapture)
        if UserSettings.shared.workflowWatcherEnabled {
            workflowWatcher.start()
        }
        indicator.setWatcherActive(workflowWatcher.isRunning)
        captureScheduler = CaptureScheduler(
            screenCapture: screenCapture,
            interval: TimeInterval(UserSettings.shared.captureIntervalSeconds)
        )
        captureScheduler.onCapture = { [weak self] imageData in
            DispatchQueue.main.async {
                guard let self, self.sessionActive else { return }
                self.handleAmbientCapture(imageData)
            }
        }

        agent = AgentSession(screenCapture: screenCapture)
        agent.setActiveAssistant(AssistantsStore.shared.base)
        agent.onEmbeddedOverlayTool = { [weak self] arguments, conversationID in
            guard let self else { throw AgentToolError.unavailable("Voice Flow ended") }
            return try await self.handleEmbeddedOverlayTool(arguments, conversationID: conversationID)
        }
        agent.onEmbeddedUserTool = { [weak self] arguments, conversationID in
            guard let self else { throw AgentToolError.unavailable("Voice Flow ended") }
            return try await self.handleEmbeddedUserTool(arguments, conversationID: conversationID)
        }
        chatPanel.restoreAssistantConversation(agent.currentConversation)
        agent.onHistoryChanged = { [weak self] in
            guard let self else { return }
            self.replySpeaker.voiceOverride = self.agent.activeAssistant?.voice
            self.chatPanel.setAssistantTitle(self.agent.currentConversation.title)
            self.chatPanel.setAssistantRuntime(
                self.agent.preferredRuntime, enabled: !self.agent.isRunning)
            self.chatPanel.refreshAgents()
        }
        agent.onActivityChanged = { [weak self] activity in
            guard let self else { return }
#if VOICE_FLOW_QA
            QAEventRecorder.shared.append("agent_activity", ["activity": activity.rawValue])
#endif
            self.indicator.setAgentActivity(activity)
            self.chatPanel.setActivity(activity)
            switch activity {
            case .idle:
                // Safety net: turns that end without a final text (interrupt,
                // tool-only turns) must still release the live speech feed.
                self.replySpeaker.finish()
                self.replyBubble.setStatus("")
            case .thinking:
                self.replyBubble.setStatus("Thinking…")
            case .responding:
                self.replyBubble.setStatus("Replying…")
            case .acting:
                self.replyBubble.setStatus("Working on your screen…")
            }
        }
        agent.onAssistantStart = { [weak self] in
            guard let self else { return }
#if VOICE_FLOW_QA
            QAEventRecorder.shared.append("assistant_started")
#endif
            self.chatPanel.beginAssistantMessage()
            if !self.chatPanel.isVisible && !self.assistantTurnUsesReceiptPresentation {
                // The grown surface now shows a reply, not a push stack —
                // trash/double-select must not hit a stale session.
                self.currentPushSessionId = nil
                self.replyBubble.beginStreaming()
            }
            if UserSettings.shared.voiceRepliesEnabled && !self.assistantTurnUsesReceiptPresentation {
                if self.playerContext != nil { self.finalizeSpeechConsumption() }
                self.replySpeaker.begin()
                if self.replySpeaker.isActive {
                    // The reply rides the same player as everything else
                    // (VF-48 unification): band + transport from the first
                    // word, karaoke once the full text has landed.
                    let context = PlayerContext(
                        source: .assistantReply(title: self.assistantPlayerTitle()),
                        sentences: [[]])
                    context.streaming = true
                    self.playerContext = context
                }
            }
        }
        agent.onAssistantDelta = { [weak self] delta in
            guard let self else { return }
#if VOICE_FLOW_QA
            QAEventRecorder.shared.append("assistant_delta", ["text": delta])
#endif
            self.chatPanel.appendAssistantDelta(delta)
            if !self.assistantTurnUsesReceiptPresentation {
                self.replyBubble.appendDelta(delta)
            }
            if !self.assistantTurnUsesReceiptPresentation {
                self.replySpeaker.append(delta)
            }
        }
        agent.onAssistantDone = { [weak self] text in
            guard let self else { return }
#if VOICE_FLOW_QA
            QAEventRecorder.shared.append("assistant_completed", ["text": text])
#endif
            self.chatPanel.finishAssistantMessage(text)
            let receiptPresentation = self.assistantTurnUsesReceiptPresentation
            if receiptPresentation {
                if self.chatPanel.conversationFocus == .assistant {
                    self.agent.markCurrentAssistantRepliesSeen()
                    self.refreshUnreadIndicator()
                } else {
                    self.assistantReplyArrived()
                }
            } else {
                self.replyBubble.finishStreaming(text)
                if self.chatPanel.conversationFocus == .assistant
                    || self.indicator.isGrownAssistantConversationVisible {
                    self.agent.markCurrentAssistantRepliesSeen()
                    self.refreshUnreadIndicator()
                }
            }
            self.assistantTurnUsesReceiptPresentation = false
            self.replySpeaker.finish()
            self.lastAssistantReply = text
            if let context = self.playerContext, case .assistantReply = context.source {
                context.streaming = false
                self.refreshPlayerSurface(karaoke: true)
            }
        }
        agent.onToolActivity = { [weak self] detail in
#if VOICE_FLOW_QA
            QAEventRecorder.shared.append("tool_activity", ["detail": detail])
#endif
            self?.chatPanel.setToolDetail(detail)
            self?.replyBubble.setStatus(detail)
        }
        agent.onError = { [weak self] message in
            guard let self else { return }
#if VOICE_FLOW_QA
            QAEventRecorder.shared.append("agent_error", ["message": message])
#endif
            self.chatPanel.addNote(message)
            self.replySpeaker.finish()
            if self.assistantTurnUsesReceiptPresentation {
                self.assistantTurnUsesReceiptPresentation = false
                self.assistantWakeInFlight = self.processingAssistantWakeTurns
                    || !self.pendingAssistantWakeTurns.isEmpty
                self.refreshSessionIndicator()
                self.refreshUnreadIndicator()
                if !self.surfaceBusy {
                    self.indicator.flashMessage("\(self.assistantPickerLabel) · error", seconds: 6, isError: true)
                }
            } else if !self.chatPanel.isVisible {
                self.replyBubble.showNote(message)
            }
        }

        Task { [weak self] in
            await AgentPermissionBroker.shared.setHandler { [weak self] prompt in
                self?.presentAgentPermission(prompt)
            }
        }

        do {
            let store = try AgentJobStore()
            let supervisor = AgentSupervisor(
                store: store,
                executor: AgentRuntimeJobExecutor(
                    environmentProvider: { [weak agent] conversationID in
                        agent?.embeddedToolEnvironment(conversationID: conversationID)
                            ?? AgentToolEnvironment()
                    }))
            agentJobStore = store
            agentSupervisor = supervisor
            let missingJobConversations = agent.reconcileAutomationReferences(
                try store.jobReferencesByConversation())
            if !missingJobConversations.isEmpty {
                vflog("agent jobs: \(missingJobConversations.values.reduce(0) { $0 + $1.count }) job reference(s) have missing conversations")
            }
            wireAgentJobTriggers()
            Task { [weak self] in
                await supervisor.setStatusHandler { [weak self] update in
#if VOICE_FLOW_QA
                    QAEventRecorder.shared.append("job_status", [
                        "job_id": update.jobID,
                        "run_id": update.runID ?? "",
                        "state": update.state.rawValue,
                        "message": update.message,
                    ])
#endif
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.chatPanel.addNote("Agent job · \(update.state.rawValue): \(update.message)")
                        self.chatPanel.refreshAgents()
                        if update.state == .completed || update.state == .failed || update.state == .blocked {
                            self.indicator.flashMessage(
                                "agent job · \(update.state.rawValue)", seconds: 6,
                                isError: update.state == .failed || update.state == .blocked)
                        }
                    }
                }
                await supervisor.start()
                _ = self
            }
        } catch {
            vflog("agent jobs unavailable: \(error.localizedDescription)")
        }

        // Escape remains the panic button while the agent acts outside Voice
        // Flow. Focused Voice Flow panels route Escape through KeyablePanel.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.agent.activity == .acting else { return }
            self.handleVoiceFlowEscape()
        }
    }

    /// Typed product events feed the durable queue with stable idempotency
    /// keys. Watcher jobs wake on coalesced user actions, not every ambient
    /// five-second frame, so enabling one cannot accidentally create a model
    /// request loop.
    private func wireAgentJobTriggers() {
        inbox.onAdded = { [weak self] message in
            let fallback = AgentDigest.sha256(
                message.time + "\n" + message.text + "\n" + message.attachments.joined(separator: "\n"))
            self?.enqueueAgentJobs(
                trigger: .inbox, source: "inbox", eventID: message.id ?? fallback)
        }
        captureStore.onFinalized = { [weak self] summary in
            self?.enqueueAgentJobs(
                trigger: .capture, source: "capture", eventID: summary.id)
        }
        workflowWatcher.onEvent = { [weak self] stream, fields, date in
            guard stream == "actions" else { return }
            var event = fields
            event["stream"] = stream
            event["at"] = date.timeIntervalSince1970
            guard let data = try? JSONSerialization.data(
                withJSONObject: event, options: [.sortedKeys]) else { return }
            self?.enqueueAgentJobs(
                trigger: .watcher, source: "watcher",
                eventID: AgentDigest.sha256(data))
        }
    }

    private func enqueueAgentJobs(trigger: AgentJobTriggerKind,
                                  source: String, eventID: String) {
        guard let agentJobStore else { return }
        do {
            let count = try agentJobStore.enqueueTrigger(
                trigger, source: source, eventID: eventID)
            guard count > 0 else { return }
            vflog("agent jobs: queued \(count) \(trigger.rawValue) trigger(s)")
            Task { [weak self] in await self?.agentSupervisor?.wake() }
            DispatchQueue.main.async { [weak self] in self?.chatPanel.refreshAgents() }
        } catch {
            vflog("agent jobs: trigger intake failed — \(error.localizedDescription)")
        }
    }

    private func createAgentJob() {
        guard agent.activeAssistant != nil, agentJobStore != nil, !agent.isRunning else {
            replyBubble.showTransient("Agent automations are unavailable", seconds: 5)
            return
        }
        let configured = UserSettings.shared.agentBaseURL
        let baseURL = URL(string: configured) ?? URL(string: DefaultAgentBaseURL)!
        let defaultModel = UserSettings.shared.agentModel
        var fallbackIDs: Set<String> = [defaultModel]
        if let store = agentJobStore,
           let jobs = try? store.jobs(limit: 500) {
            fallbackIDs.formUnion(jobs.compactMap(\.modelID))
        }
        replyBubble.showTransient("refreshing OpenRouter models…", seconds: 3)
        Task { [weak self] in
            let result = await OpenRouterModelCatalog.shared.refresh(
                baseURL: baseURL,
                apiKey: KeychainStore.shared.loadAgentAPIKey(),
                fallbackIDs: fallbackIDs)
            await MainActor.run {
                self?.presentAgentJobEditor(models: result, defaultModel: defaultModel)
            }
        }
    }

    private func presentAgentJobEditor(models: OpenRouterModelCatalogResult,
                                       defaultModel: String) {
        guard let assistant = agent.activeAssistant,
              let agentJobStore else {
            replyBubble.showTransient("Agent automations are unavailable", seconds: 5)
            return
        }
        let alert = NSAlert()
        alert.messageText = "New automation"
        alert.informativeText = "Choose the runtime and pin the model this automation should keep using."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let editor = AgentJobEditorView(
            models: models, preferredRuntime: agent.preferredRuntime,
            defaultModelID: defaultModel)
        alert.accessoryView = editor
#if VOICE_FLOW_QA
        activeAgentJobAlert = alert
        activeAgentJobEditor = editor
        defer {
            activeAgentJobAlert = nil
            activeAgentJobEditor = nil
        }
#endif
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let task = editor.promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            replyBubble.showTransient("An automation needs a prompt", seconds: 5)
            return
        }
        let selectedRuntime = editor.selectedRuntime
        let selectedModel = editor.selectedModelID
        if selectedRuntime == .opencode, selectedModel == nil {
            replyBubble.showTransient("Choose an OpenRouter model or type its exact provider/model ID", seconds: 7)
            return
        }
        let selectedTrigger = editor.selectedTrigger
        let minutes = min(max(editor.intervalField.doubleValue, 1), 43_200)
        let dailyBudget = min(max(editor.budgetField.doubleValue, 0), 10_000)
        let now = Date()
        let nextRun: Date? = selectedTrigger == .interval
            ? now.addingTimeInterval(minutes * 60) : nil
        let jobID = UUID().uuidString
        let conversation = agent.createAutomationConversation(
            jobID: jobID, assistant: assistant)
        let job = AgentJob(
            id: jobID,
            assistantSlug: assistant.slug,
            conversationID: conversation.id,
            runtime: selectedRuntime, trigger: selectedTrigger,
            modelID: selectedModel,
            prompt: task, trustProfile: .unattended,
            state: selectedTrigger == .interval ? .queued : .completed,
            nextRunAt: nextRun,
            intervalSeconds: selectedTrigger == .interval ? minutes * 60 : nil,
            dailyBudgetUSD: dailyBudget,
            maxDurationSeconds: 900, maxAttempts: 3,
            createdAt: now, updatedAt: now)
        do {
            try agentJobStore.put(job)
            _ = agent.reconcileAutomationReferences(
                try agentJobStore.jobReferencesByConversation())
            chatPanel.refreshAgents()
            replyBubble.showTransient("automation created", seconds: 4)
        } catch {
            if let references = try? agentJobStore.jobReferencesByConversation() {
                _ = agent.reconcileAutomationReferences(references)
                _ = agent.deleteConversation(conversation.id)
            }
            replyBubble.showTransient("automation failed: \(error.localizedDescription)", seconds: 7)
        }
    }

    private func presentAgentPermission(_ prompt: AgentPermissionPrompt) {
        precondition(Thread.isMainThread)
#if VOICE_FLOW_QA
        QAEventRecorder.shared.append("permission_requested", [
            "id": prompt.id, "conversation_id": prompt.conversationID,
            "run_id": prompt.runID.uuidString,
            "title": prompt.title, "detail": prompt.detail,
        ])
        if ProcessInfo.processInfo.environment["VOICE_FLOW_QA_HEADLESS_APPROVAL"] == "1" {
            return
        }
#endif
        chatPanel.addNote("Permission requested · \(prompt.title)")
        indicator.flashMessage("Assistant needs approval", seconds: 8)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow once?"
        alert.informativeText = "\(prompt.title)\n\n\(String(prompt.detail.prefix(2_048)))"
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Deny")
        alert.buttons.first?.setAccessibilityLabel("Allow agent action once")
        alert.buttons.dropFirst().first?.setAccessibilityLabel("Deny agent action")
        NSApp.activate(ignoringOtherApps: true)
        let response: AgentPermissionResponse = alert.runModal() == .alertFirstButtonReturn
            ? .once : .reject
        Task {
            await AgentPermissionBroker.shared.resolve(id: prompt.id, response: response)
        }
    }

    private func setupHotkeys() {
        hotkeyManager = HotkeyManager(spec: UserSettings.shared.hotkey)
        hotkeyManager.onPress = { [weak self] in
            self?.beginCapture(capability: .dictate, deliveryPolicy: .contextual, handsFree: false)
        }
        hotkeyManager.onRelease = { [weak self] in
            self?.stopCapture(expectedCapability: .dictate)
        }
        hotkeyManager.onCancel = { [weak self] in
            self?.cancelCaptureForHotkeySupersession(capability: .dictate)
        }
        hotkeyManager.allowsHandsFreeDoublePress = false

        // Double-tap = brain dump: talk into Voice Flow's Inbox from anywhere,
        // no paste target involved (ticket #2).
        handsFreeHotkeyManager = HotkeyManager(spec: UserSettings.shared.handsFreeHotkey)
        handsFreeHotkeyManager.allowsHandsFreeDoublePress = true
        handsFreeHotkeyManager.onHandsFree = { [weak self] active in
            guard let self else { return }
            if active {
                self.beginCapture(capability: .dictate, deliveryPolicy: .historyOnly, handsFree: true)
            } else {
                self.stopCapture(expectedCapability: .dictate)
            }
        }

        // The read-aloud key is the transport (ticket VF-48, AirPods stem
        // grammar): 1 press = play/pause · 2 = next sentence · 3 = back ·
        // hold = stop. With no player alive a press keeps its old meaning.
        ttsHotkeyManager = HotkeyManager(spec: UserSettings.shared.ttsHotkey)
        ttsHotkeyManager.onPress = { [weak self] in self?.transportPressBegan() }
        ttsHotkeyManager.onRelease = { [weak self] in self?.transportPressEnded() }

        continuousCaptureHotkeyManager = HotkeyManager(spec: UserSettings.shared.continuousCaptureHotkey)
        continuousCaptureHotkeyManager.onPress = { [weak self] in
            self?.indicator.collapseNow()   // any other hotkey closes the picker
            self?.toggleSession()
        }

        snapshotHotkeyManager = HotkeyManager(spec: UserSettings.shared.snapshotHotkey)
        snapshotHotkeyManager.onPress = { [weak self] in
            self?.beginCapture(capability: .snapshot, deliveryPolicy: .contextual, handsFree: false)
        }
        snapshotHotkeyManager.onRelease = { [weak self] in
            self?.stopCapture(expectedCapability: .snapshot)
        }
        snapshotHotkeyManager.onCancel = { [weak self] in
            self?.cancelCaptureForHotkeySupersession(capability: .snapshot)
        }

        annotateHotkeyManager = HotkeyManager(spec: UserSettings.shared.annotateHotkey)
        annotateHotkeyManager.onPress = { [weak self] in
            self?.indicator.collapseNow()
            self?.annotationOverlay.toggleEditing()
        }

        // ⌃⌥1–9: jump straight to a Claude session by its sticky slot
        // number (ticket VF-48 — nine slots, numbers never reorder).
        let numberKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // 1…9
        sessionSwitchHotkeyManagers = numberKeyCodes.enumerated().map { index, keyCode in
            let manager = HotkeyManager(spec: HotkeySpec(
                keyCode: keyCode,
                modifiers: [.maskControl, .maskAlternate],
                label: "⌃⌥\(index + 1)"))
            manager.onPress = { [weak self] in self?.switchToSession(slot: index + 1) }
            return manager
        }
        // ⌃⌥0 — the last-session toggle: bounce between the two sessions
        // you're juggling, the highest-frequency switch there is
        // (ticket VF-48; tmux prefix-l, vim Ctrl-^).
        let lastToggle = HotkeyManager(spec: HotkeySpec(
            keyCode: 29, modifiers: [.maskControl, .maskAlternate], label: "⌃⌥0"))
        lastToggle.onPress = { [weak self] in self?.toggleLastSession() }
        sessionSwitchHotkeyManagers.append(lastToggle)
    }

    private func startHotkeyWithAccessibilityCheck() {
        if checkAccessibility() {
            startAllHotkeys()
            return
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.checkAccessibility() {
                timer.invalidate()
                self.startAllHotkeys()
                vflog("accessibility granted — hotkeys active")
            }
        }
    }

    private func startAllHotkeys() {
        hotkeyManager.start()
        handsFreeHotkeyManager.start()
        ttsHotkeyManager.start()
        continuousCaptureHotkeyManager.start()
        snapshotHotkeyManager.start()
        annotateHotkeyManager.start()
        sessionSwitchHotkeyManagers.forEach { $0.start() }
    }

    @objc private func showPermissionsMenuAction() { showPermissions() }
    @objc private func showSettingsMenuAction() { showSettings() }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Continuous capture — voice + deduped screenshots
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func toggleSession() {
        if sessionActive { endSession() } else { startSession() }
    }

    /// Ambient workflow watcher (menu bar / Settings) — logs the workday
    /// for the scheduled Claude review, independent of sessions.
    private func toggleWorkflowWatcher() {
        UserSettings.shared.workflowWatcherEnabled = !workflowWatcher.isRunning
        UserSettings.shared.save()
        syncWorkflowWatcher()
        replyBubble.showTransient(workflowWatcher.isRunning
            ? "Watching your workflow — activity log + deduped screenshots every 5s, reviewed by Claude nightly."
            : "Stopped watching your workflow.", seconds: 6)
    }

    /// Kick the nightly-review LaunchAgent by hand — same run as 21:37.
    private func runWatcherReviewNow() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["kickstart", "gui/\(getuid())/com.voiceflow.watcher-analyze"]
        do {
            try proc.run()
            replyBubble.showTransient("Workflow review started — Claude is reading today's activity; results appear on screen in a few minutes.", seconds: 8)
        } catch {
            replyBubble.showTransient("Couldn't start the review — is the com.voiceflow.watcher-analyze LaunchAgent loaded?", seconds: 8)
        }
    }

    private func openLatestWatcherReview() {
        let dir = WorkflowWatcher.baseDir.appendingPathComponent("reviews")
        let newest = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
        if let newest {
            NSWorkspace.shared.open(newest)
        } else {
            replyBubble.showTransient("No reviews yet — the first one runs tonight at 21:37, or pick Run Review Now.", seconds: 6)
        }
    }

    /// Make the running watcher match the setting (menu toggle and the
    /// Settings window both funnel through here).
    private func syncWorkflowWatcher() {
        let wanted = UserSettings.shared.workflowWatcherEnabled
        if wanted, !workflowWatcher.isRunning {
            workflowWatcher.start()
        } else if !wanted, workflowWatcher.isRunning {
            workflowWatcher.stop()
        }
        workflowWatcher.applySettings()
        menuBar.setWatcherActive(wanted)
        indicator.setWatcherActive(wanted)
    }

    private func startSession() {
        beginCapture(capability: .continuous, deliveryPolicy: .contextual, handsFree: false)
    }

    private func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        captureScheduler.stop()
        pendingSessionShots.append(contentsOf: ambientScreenshots)
        ambientScreenshots.removeAll()
        lastCaptureData = nil

        indicator.setSessionActive(false)
        menuBar.setSessionActive(false)
        chatPanel.setSessionActive(false)
        playSound("Pop")
        vflog("continuous capture ended")

        Task { @MainActor in
            // Final frame: how the screen looks the moment the session ends.
            let display = activeRunId.flatMap { captureRuns[$0]?.display }
            if let fresh = try? await screenCapture.captureScreen(on: display) {
                pendingSessionShots.append(fresh)
                captureStore.addFrame(fresh)
            }
            if let id = activeRunId, var run = captureRuns[id], run.capability == .continuous {
                run.continuousScreenshots = pendingSessionShots
                run.continuousSummary = captureStore.endSession(transcript: nil, keepEmpty: true)
                captureRuns[id] = run
                pendingSessionShots.removeAll()
            }
            stopCapture(expectedCapability: .continuous)
        }
    }

    /// Ambient screenshots build quiet context while a session runs —
    /// deduped so an unchanged screen doesn't pile up frames.
    private func handleAmbientCapture(_ imageData: Data) {
        guard CaptureFrameDeduplicator.shouldKeep(
            previous: lastCaptureData, candidate: imageData,
            threshold: diffThreshold) else { return }
        lastCaptureData = imageData
        appendSessionShot(imageData)
    }

    private func appendSessionShot(_ imageData: Data) {
        indicator.flashCapturePulse()
        captureStore.addFrame(imageData)
        ambientScreenshots.append(imageData)
        if ambientScreenshots.count > maxAmbientScreenshots {
            ambientScreenshots.removeFirst(ambientScreenshots.count - maxAmbientScreenshots)
        }
    }

    // ── Local Assistant session adapter (ticket VF-54) ─────

    private var assistantPickerSessionId: String? {
        guard let assistant = agent?.activeAssistant else { return nil }
        return LocalAssistantSessionAdapter.id(for: assistant.slug)
    }

    private func isAssistantPickerSession(_ id: String?) -> Bool {
        guard let id, let assistantId = assistantPickerSessionId else { return false }
        return id == assistantId
    }

    private var assistantPickerLabel: String {
        agent?.activeAssistant?.name ?? DefaultAssistantWakeWord
    }

    private var assistantPickerEligible: Bool {
        guard agent != nil, assistantPickerSessionId != nil, !assistantPickerDismissed else { return false }
        let conversation = agent.currentConversation
        return assistantWakeInFlight || agent.isRunning
            || !conversation.messages.isEmpty || conversation.codexThreadId != nil
    }

    private var assistantHasUnseenReply: Bool {
        agent?.currentConversation.hasUnseenAssistantReply == true
    }

    private func firstAvailableTarget(excluding excluded: String? = nil) -> String? {
        pickerSessions().first { $0.id != excluded }?.id
    }

    /// "just now" / "3m ago" / "2h ago" for the sessions submenu.
    private static func relativeAge(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        default: return "\(seconds / 3600)h ago"
        }
    }

    /// Everyone the picker can point at: live sessions in connect order,
    /// then "ghost" stacks — messages whose session ended or expired
    /// before the user read them. A ghost keeps its dot, its ⌃⌥ number,
    /// and its stack until the user reads or trashes it; nothing marked
    /// unread ever becomes unviewable. Main thread.
    private func pickerSessions() -> [(id: String, label: String)] {
        let local: [(id: String, label: String)]
        if assistantPickerEligible, let id = assistantPickerSessionId {
            local = [(id: id, label: assistantPickerLabel)]
        } else {
            local = []
        }
        // Only ENGAGED sessions are user-visible — a connected-but-silent
        // session (every Claude Code session initializes every MCP server)
        // has nothing for the user to switch to. And even engaged, a
        // session must currently OFFER something (a stack, a parked
        // listener, a blocked ask, on-screen overlays, or being the voice
        // target) — otherwise it lingers as an empty no-message entry the
        // user can't do anything with (ticket #14).
        let overlayOwners = overlayManager.sessionsWithOverlays()
        // Done pushes are panel history, not pill business — a stack of
        // nothing but done pushes offers the picker nothing (ticket #17).
        let live = mcpServer.sessions.ordered().filter { session in
            guard session.engaged else { return false }
            // A LIVE session with any thread history stays reachable even
            // fully consumed (Safet QA: he couldn't answer a heard message
            // without hunting in the panel) — only dead sessions retire.
            return sessionPushes[session.id]?.isEmpty == false
                || inbox.hasWaiter(for: session.id)
                || pendingInteraction?.sessionId == session.id
                || overlayOwners.contains(session.id)
                || session.id == targetSessionId
                // The thread being read aloud stays reachable (ticket #21).
                || session.id == playerContext?.sessionId
        }
            .map { (id: $0.id, label: $0.label) }
        let liveIds = Set(live.map { $0.id })
        let ghosts = sessionPushes
            .filter {
                !liveIds.contains($0.key)
                    && ($0.value.contains { $0.done != true }
                        // A ghost mid-read-aloud keeps its dot (ticket #21).
                        || $0.key == playerContext?.sessionId)
            }
            .sorted { ($0.value.last?.at ?? .distantPast) < ($1.value.last?.at ?? .distantPast) }
            .map { (id: $0.key, label: sessionLabels[$0.key] ?? Self.senderLabel($0.value)) }
        return local + live + ghosts
    }

    /// A ghost has no registry entry anymore — its newest push remembers
    /// who sent it.
    private static func senderLabel(_ queue: [SessionPush]) -> String {
        let title = queue.last?.title ?? "Claude"
        return title.hasSuffix(" asks") ? String(title.dropLast(5)) : title
    }

    // ── Session slots — stable ⌃⌥1–9 numbers (ticket VF-48) ──
    // A session KEEPS its number for as long as it is picker-eligible;
    // numbers never shift while occupied. A number frees only when its
    // session leaves the picker (consumed and finished), and the next
    // queued session takes the lowest free number. Persisted so ghost
    // stacks keep their numbers across restarts.
    static let maxSessionSlots = 9
    private static var slotsURL: URL {
        VoiceFlowPaths.shared.file("slots.json")
    }
    private var sessionSlots: [String: Int] = {
        guard let data = try? Data(contentsOf: AppDelegate.slotsURL),
              let slots = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return slots
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(sessionSlots) {
                try? data.write(to: Self.slotsURL, options: .atomic)
            }
        }
    }

    /// Eligible sessions wearing their sticky numbers, sorted by slot.
    /// Eligible sessions beyond nine hold no number yet — they are the
    /// queue, and enter as numbers free up. Main thread.
    private func slottedSessions() -> [(slot: Int, id: String, label: String)] {
        let eligible = pickerSessions()
        let eligibleIds = Set(eligible.map { $0.id })
        var slots = sessionSlots.filter { eligibleIds.contains($0.key) }
        var used = Set(slots.values)
        for session in eligible where slots[session.id] == nil {
            guard let free = (1...Self.maxSessionSlots).first(where: { !used.contains($0) }) else { continue }
            slots[session.id] = free
            used.insert(free)
        }
        if slots != sessionSlots { sessionSlots = slots }
        return eligible
            .compactMap { session in slots[session.id].map { (slot: $0, id: session.id, label: session.label) } }
            .sorted { $0.slot < $1.slot }
    }

    /// The picker's view of the world: one entry per slotted session
    /// (active lit, pending amber) plus the active entry's name.
    /// Main thread.
    private func pickerEntries() -> (entries: [FloatingIndicator.PickerEntry], activeName: String?) {
        let sessions = slottedSessions()
        let entries = sessions.map { session in
            if isAssistantPickerSession(session.id) {
                return FloatingIndicator.PickerEntry(
                    number: session.slot,
                    active: session.id == targetSessionId,
                    pending: assistantWakeInFlight || agent?.isRunning == true || assistantHasUnseenReply,
                    asking: false)
            }
            return FloatingIndicator.PickerEntry(
                number: session.slot,
                active: session.id == targetSessionId,
                // Amber means "something is waiting on you" — an unseen
                // push, an unanswered ask, or an undelivered inbox message.
                // A fully-read stack stays previewable but not amber.
                pending: inbox.pendingCount(for: session.id) > 0
                    || pendingInteraction?.sessionId == session.id
                    || sessionPushes[session.id]?.contains { !$0.seen } == true,
                // The ask tier pulses until answered (ticket VF-48).
                asking: pendingInteraction?.sessionId == session.id
                    || sessionPushes[session.id]?.contains {
                        $0.isAsk && $0.answer == nil && $0.done != true } == true)
        }
        return (entries, sessions.first { $0.id == targetSessionId }?.label)
    }

    private func showAssistantPreview(
        bottomPicker: (entries: [FloatingIndicator.PickerEntry], activeName: String?)? = nil
    ) {
        guard let id = assistantPickerSessionId else { return }
        let conversation = agent.currentConversation
        let replies = conversation.assistantPreviewReplies
        guard let newest = replies.last else {
            let picker = bottomPicker ?? pickerEntries()
            indicator.showPicker(entries: picker.entries, activeName: picker.activeName)
            return
        }
        let wasUnseen = conversation.hasUnseenAssistantReply
        currentPushSessionId = nil
        indicator.showGrown(
            FloatingIndicator.GrownSpec(
                title: assistantPickerLabel,
                text: newest.text,
                earlier: replies.dropLast().map(\.text),
                hint: wasUnseen ? nil : "heard — dictate or ⌨ to reply",
                routesToAssistant: true,
                consumed: !wasUnseen,
                contentKey: id),
            bottomPicker: bottomPicker)
        agent.markCurrentAssistantRepliesSeen()
        refreshUnreadIndicator()
        refreshPlayerSurface(karaoke: true)
    }

    /// Single entry for changing which Claude session owns the user's
    /// voice + screen: routes hotkeys, swaps that session's overlays in,
    /// and updates the pill (middle-dot number + picker row). Main thread.
    func setTargetSession(_ id: String?, announce: Bool) {
        if id != targetSessionId, targetSessionId != nil {
            previousTargetSessionId = targetSessionId
        }
        targetSessionId = id
        overlayManager.setActiveSession(id)
        refreshSessionIndicator()
        refreshUnreadIndicator()
        if announce {
            let (entries, activeName) = pickerEntries()
            if isAssistantPickerSession(id) {
                showAssistantPreview(bottomPicker: (entries, activeName))
            } else if let id, let queue = sessionPushes[id]?.filter({ $0.done != true }), !queue.isEmpty {
                // The session has something to show — the picker grows
                // straight into its whole stack, picker row at the bottom.
                // NOTHING auto-hides (ticket VF-48): the stack stays up
                // until Esc/✕/click/switch, seen or not — timers kept
                // vanishing content mid-read.
                currentPushSessionId = id
                showPushStack(for: id, bottomPicker: (entries, activeName))
            } else if let id, let tail = sessionPushes[id]?.last {
                // Fully consumed thread: its tail stays visible in the
                // heard tone with the reply affordances LIVE (Safet QA:
                // answering must not require hunting in the panel).
                currentPushSessionId = id
                indicator.showGrown(
                    FloatingIndicator.GrownSpec(
                        title: sessionLabels[id] ?? tail.title,
                        text: tail.text,
                        hint: "heard — dictate or ⌨ to reply",
                        consumed: true,
                        contentKey: id),
                    bottomPicker: (entries, activeName))
            } else {
                indicator.showPicker(entries: entries, activeName: activeName)
            }
        }
    }

    /// Keep the pill's middle-dot session number current.
    func refreshSessionIndicator() {
        indicator.setActiveSessionNumber(
            slottedSessions().first { $0.id == targetSessionId }?.slot)
    }

    /// Queue a push and announce it with a one-line receipt — the full
    /// text NEVER takes the screen on arrival, no matter whose session it
    /// is, and audio never auto-plays. The user reads it by switching onto
    /// the session (⌃⌥1–6 grows its whole stack), re-selects to hear it,
    /// or opens the panel's Agents tab; the ring + amber picker dot persist
    /// until the stack is actually viewed. Main thread.
    func deliverPush(_ push: SessionPush, from sessionId: String?) {
        let sid = sessionId ?? ""
        var queue = sessionPushes[sid] ?? []
        // A stack now exists for this session — pin its current label so
        // the thread's title outlives the session.
        rememberSessionLabel(sessionId)
        // Re-engaging the user supersedes an old "user closed" tombstone:
        // this push restores the session's presence, so its next listen
        // must wait for a reply, not be told to stop.
        if let sessionId { inbox.clearUserClosed(sessionId) }
        // An agent re-sending the same thing (retry loops, "did you hear
        // me?" spam) collapses into one entry instead of filling the stack —
        // but a consumed (done) push is history and stays.
        if let last = queue.last, last.done != true, last.text == push.text, last.isAsk == push.isAsk {
            queue.removeLast()
        }
        queue.append(push)
        // The quick stack holds ≤8 ACTIVE pushes — overflow ages into done
        // history instead of vanishing (ticket #17); the thread history
        // itself is capped separately.
        var active = queue.indices.filter { queue[$0].done != true }
        while active.count > maxQueuedPushes {
            let index = active.removeFirst()
            queue[index].done = true
            queue[index].seen = true
        }
        if queue.count > maxKeptPushes { queue.removeFirst(queue.count - maxKeptPushes) }
        sessionPushes[sid] = queue
        // The permanent record — messages.json keeps every push even
        // after its session expires or the stack is trashed.
        chatPanel.addAgentMessage(time: Self.timestamp(), session: push.title,
                                  text: push.text, isAsk: push.isAsk)
        refreshUnreadIndicator()

        // A push for the stack that's ALREADY on screen refreshes it in
        // place — updating what the user is reading isn't taking the screen.
        if indicator.isGrownVisible, currentPushSessionId == sid {
            // …unless that stack is being READ ALOUD: the karaoke owns the
            // text and a re-render would swallow the push AND mark it seen
            // (interaction audit C1/C8). It stays unseen; the ring says so.
            if playerContext?.sessionId == sid, ttsController.queuedSpeechActive {
                refreshUnreadIndicator()
                return
            }
            showPushStack(for: sid)
            return
        }

        // The receipt: one line, ~4s, only when nothing else owns the
        // surface — never over grown content, never while the user talks.
        guard !surfaceBusy else { return }
        var receipt = push.isAsk ? push.title : "\(push.title) · new message"
        if let slot = slottedSessions().first(where: { $0.id == sid })?.slot {
            receipt += " — ⌃⌥\(slot)"
        }
        indicator.flashMessage(receipt, seconds: 4)
    }

    /// Render a session's queued pushes as one grown surface: older ones
    /// dim above, the newest bright; the hint line (and brighter border)
    /// appear when an ask is anywhere in the stack. Displaying marks the
    /// stack seen (it stays queued for previews until trashed). Main thread.
    private func showPushStack(for sessionId: String,
                               bottomPicker: (entries: [FloatingIndicator.PickerEntry], activeName: String?)? = nil,
                               autoHide: TimeInterval? = nil) {
        // The grown surface shows only the ACTIVE stack — done pushes live
        // in the panel's Agents thread, not here (ticket #17).
        guard let queue = sessionPushes[sessionId]?.filter({ $0.done != true }),
              let newest = queue.last else { return }
        // An answered ask is history, not a question — never re-render ask
        // styling or the answer hint for it.
        let ask = queue.last { $0.isAsk && $0.answer == nil }
        indicator.showGrown(
            FloatingIndicator.GrownSpec(
                title: (ask ?? newest).title,
                text: newest.text,
                earlier: queue.dropLast().map { $0.text },
                hint: ask?.hint,
                isAsk: ask != nil,
                contentKey: sessionId),
            bottomPicker: bottomPicker,
            autoHide: autoHide)
        // Mark the STORED queue seen — `queue` above is the active subset.
        sessionPushes[sessionId] = sessionPushes[sessionId]?.map { push in
            var seen = push
            seen.seen = true
            return seen
        }
        refreshUnreadIndicator()
        // Growing the session that's playing hands the surface to the
        // grown band + karaoke (ticket VF-48).
        refreshPlayerSurface(karaoke: true)
    }

    /// Something the user is looking at or doing that background events
    /// (session connects, renames, receipts) must never stomp. Main thread.
    private var surfaceBusy: Bool {
        indicator.isGrownVisible
            || state == .recording || state == .processing || state == .handsFree
    }

    /// Sessions (other than `excluded`) holding pushes the user hasn't
    /// seen — ghosts included: unread messages outlive their session and
    /// stay reachable via the picker until read or trashed. Main thread.
    private func unseenSessions(excluding excluded: String? = nil) -> Int {
        sessionPushes = sessionPushes.filter { !$0.value.isEmpty }
        var count = sessionPushes.filter { sid, queue in
            sid != excluded && queue.contains { !$0.seen }
        }.count
        if let assistantId = assistantPickerSessionId,
           assistantId != excluded, assistantPickerEligible, assistantHasUnseenReply {
            count += 1
        }
        return count
    }

    /// An ask stays hot until answered — the only thing that pulses
    /// (ticket VF-48). Main thread.
    private var hasUnansweredAsk: Bool {
        pendingInteraction != nil || sessionPushes.contains { _, queue in
            queue.contains { $0.isAsk && $0.answer == nil && $0.done != true }
        }
    }

    /// The pill's small ring around the number dot, two tiers (VF-48):
    /// static while any session holds unseen pushes, pulsing only while a
    /// blocking ask waits for an answer. Main thread.
    func refreshUnreadIndicator() {
        indicator.setUnreadIndicator(unread: unseenSessions() > 0, asking: hasUnansweredAsk)
    }

    /// VF-48 consumption: a consumed, FINISHED session leaves the picker —
    /// its stack retires to panel history and its slot number frees for the
    /// next queued session. Live sessions never retire this way (they are
    /// active workers), and neither does anything unseen, asking, on screen,
    /// or still being read aloud. Main thread.
    private func retireConsumedGhosts() {
        for (sid, queue) in sessionPushes {
            guard mcpServer.sessions.session(sid) == nil,
                  sid != currentPushSessionId,
                  sid != playerContext?.sessionId,
                  queue.contains(where: { $0.done != true }),
                  !queue.contains(where: { !$0.seen }),
                  !queue.contains(where: { $0.isAsk && $0.answer == nil && $0.done != true })
            else { continue }
            markStackDone(sid)
        }
        refreshSessionIndicator()
        refreshUnreadIndicator()
    }

    /// User-initiated selection (⌃⌥N / menu bar). Double-select = a second
    /// press while the first press's stack is already on screen: THAT reads
    /// the messages aloud (Settings toggle). Merely being the default
    /// target doesn't count — the first press must SHOW, never speak.
    /// Main thread.
    private func userSelectSession(_ id: String) {
        // Panel open → ⌃⌥N deep-links into the session's thread there;
        // the pill flow stays untouched when the panel is closed.
        if chatPanel.isVisible {
            setTargetSession(id, announce: false)
            if isAssistantPickerSession(id) {
                agent.markCurrentAssistantRepliesSeen()
                chatPanel.restoreAssistantConversation(agent.currentConversation, open: true)
                refreshUnreadIndicator()
            } else {
                chatPanel.openAgentThread(id)
            }
            return
        }
        if isAssistantPickerSession(id), id == targetSessionId,
           indicator.isGrownAssistantConversationVisible,
           UserSettings.shared.doubleSelectSpeak,
           let text = agent.currentConversation.latestAssistantReply?.text, !text.isEmpty {
            speakTextThroughPlayer(
                text,
                source: .assistantReply(title: assistantPlayerTitle()),
                showSettingsOnMissingKey: false)
            return
        }
        if id == targetSessionId, indicator.isGrownVisible, currentPushSessionId == id,
           UserSettings.shared.doubleSelectSpeak,
           sessionPushes[id]?.isEmpty == false {
            speakSessionUnconsumed(id)
            return
        }
        setTargetSession(id, announce: true)
    }

    /// The user answered what was on screen by voice — the view collapses
    /// and the receipt lands after it. When the answer actually reached a
    /// session, its stack is consumed: done history in the panel's Agents
    /// thread, gone from the pill's quick surfaces (ticket #17). Main thread.
    private func answeredSession(_ id: String?, note: String, clearStack: Bool) {
        if clearStack, let id {
            markStackDone(id)
            refreshUnreadIndicator()
        }
        currentPushSessionId = nil
        replyBubble.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            self.replyBubble.showTransient(note, seconds: 6)
        }
    }

    /// The session ⌃⌥0 bounces back to (ticket VF-48).
    private var previousTargetSessionId: String?

    /// ⌃⌥0: jump to the previously active session; with none available
    /// the press just opens the picker. Main thread.
    private func toggleLastSession() {
        guard let previous = previousTargetSessionId,
              pickerSessions().contains(where: { $0.id == previous }) else {
            let (entries, activeName) = pickerEntries()
            indicator.showPicker(entries: entries, activeName: activeName)
            return
        }
        userSelectSession(previous)
    }

    /// ⌃⌥1–9 — the number is the session's sticky slot, not a list
    /// position. Any select attempt aimed at an empty number opens the
    /// picker showing what's actually available. Main thread.
    private func switchToSession(slot: Int) {
        // Repaint the badge and ring against what actually exists before
        // acting on it — the look itself may have expired live sessions.
        refreshSessionIndicator()
        refreshUnreadIndicator()
        guard let session = slottedSessions().first(where: { $0.slot == slot }) else {
            let (entries, activeName) = pickerEntries()
            indicator.showPicker(entries: entries, activeName: activeName)
            return
        }
        userSelectSession(session.id)
    }

    /// Menu-bar route to the same prompt the post-session bubble offers —
    /// for when that bubble is long dismissed.
    private func copyLatestCapturePrompt() {
        guard let (directory, meta) = CaptureStore.latestBundle() else {
            replyBubble.showTransient("no captures yet", seconds: 4)
            return
        }
        let prompt = CaptureSummary.claudePrompt(
            transcriptPath: directory.appendingPathComponent("transcript.md").path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        replyBubble.showTransient("capture prompt copied", seconds: 4)
    }

    // ── Sending to the agent ────────────────────────────

    /// A grown Assistant response is a compact doorway back into that exact
    /// conversation. MCP/session pushes retain their close-and-keep contract.
    private func handleGrownPillClick() {
        if let sid = currentPushSessionId {
            // Clicking the shown stack opens its full thread in the panel
            // (Safet QA: "it definitely should") — ✕ stays the close.
            setTargetSession(sid, announce: false)
            chatPanel.show(focusInput: false)
            chatPanel.openAgentThread(sid)
            return
        }
        guard agent != nil else { return }
        agent.markCurrentAssistantRepliesSeen()
        chatPanel.restoreAssistantConversation(agent.currentConversation, open: true)
        refreshUnreadIndicator()
        chatPanel.show()
    }

    /// Escape closes whichever Voice Flow surface owns focus and preserves its
    /// existing safety role when the Assistant is controlling the screen.
    private func handleVoiceFlowEscape() {
        if annotationOverlay?.isEditing == true {
            annotationOverlay.endEditing()
            return
        }
        if agent?.activity == .acting {
            agent.interrupt()
            stopSpeechPlayback()
            chatPanel.addNote("Stopped by Escape")
        }
        if chatPanel?.isVisible == true { chatPanel.hide() }
        if indicator?.isGrownVisible == true {
            // Esc de-escalates, never stops audio (ticket VF-48): the
            // collapse's onCollapsed hands the surface to the strip.
            indicator.dismissGrown()
        } else {
            indicator?.collapseNow()
        }
    }

    private func flashAssistantReceipt(_ status: String, isError: Bool = false) {
        guard !surfaceBusy else { return }
        var text = "\(assistantPickerLabel) · \(status)"
        if let id = assistantPickerSessionId,
           let slot = slottedSessions().first(where: { $0.id == id })?.slot {
            text += " — ⌃⌥\(slot)"
        }
        indicator.flashMessage(text, seconds: 4, isError: isError)
    }

    private func assistantReplyArrived() {
        assistantWakeInFlight = processingAssistantWakeTurns
            || !pendingAssistantWakeTurns.isEmpty
        refreshSessionIndicator()
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
        if isAssistantPickerSession(targetSessionId),
           indicator.isGrownAssistantConversationVisible {
            showAssistantPreview(bottomPicker: pickerEntries())
            return
        }
        flashAssistantReceipt("new message")
    }

    private func enqueueAssistantWakeTurn(
        assistant: AssistantDefinition,
        displayText: String,
        agentText: String,
        screenshots: [Data],
        attachmentNote: String?
    ) {
        assistantPickerDismissed = false
        assistantWakeInFlight = true
        pendingAssistantWakeTurns.append(PendingAssistantWakeTurn(
            assistant: assistant,
            displayText: displayText,
            agentText: agentText,
            screenshots: screenshots,
            attachmentNote: attachmentNote))
        refreshSessionIndicator()
        refreshUnreadIndicator()
        processAssistantWakeTurnsIfNeeded()
    }

    private func processAssistantWakeTurnsIfNeeded() {
        guard !processingAssistantWakeTurns else { return }
        processingAssistantWakeTurns = true
        if agent.isRunning { agent.interrupt() }

        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.pendingAssistantWakeTurns.isEmpty {
                while self.agent.isRunning {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let turn = self.pendingAssistantWakeTurns.removeFirst()
                let priorSessionId = self.agent.currentSessionId
                self.agent.activateAssistant(turn.assistant)
                self.replySpeaker.voiceOverride = turn.assistant.voice
                if self.agent.currentSessionId != priorSessionId {
                    self.chatPanel.restoreAssistantConversation(self.agent.currentConversation)
                }
                self.refreshSessionIndicator()
                self.refreshUnreadIndicator()
                if self.targetSessionId == nil
                    || !self.pickerSessions().contains(where: { $0.id == self.targetSessionId }) {
                    self.setTargetSession(self.assistantPickerSessionId, announce: false)
                }
                self.flashAssistantReceipt("working")

                let outcome = await self.assistantContinuityDecision(
                    incoming: turn.displayText, staleRetries: 1)
                vflog("assistant continuity: \(outcome.decision.rawValue) confidence=\(outcome.confidence) fallback=\(outcome.usedFallback) reason=\(outcome.reason)")
                if outcome.decision == .new {
                    let conversation = self.agent.createConversation()
                    self.chatPanel.restoreAssistantConversation(conversation)
                }

                self.assistantTurnUsesReceiptPresentation = self.chatPanel.conversationFocus != .assistant
                self.chatPanel.addUserMessage(turn.displayText, attachmentNote: turn.attachmentNote)
                self.agent.send(text: turn.agentText, screenshots: turn.screenshots)

                // Preserve bursts: the next queued dictation is classified
                // only after this one has updated the current conversation.
                while self.agent.isRunning {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                // AgentSession persists the reply before dispatching its UI
                // completion callback. Wait for that callback before a queued
                // wake changes the global presentation state. An interrupted
                // or empty turn has no callback, so cap this handoff at 0.5 s.
                var callbackChecks = 0
                while self.assistantTurnUsesReceiptPresentation && callbackChecks < 50 {
                    callbackChecks += 1
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                self.assistantTurnUsesReceiptPresentation = false
            }
            self.processingAssistantWakeTurns = false
            self.assistantWakeInFlight = false
            self.refreshSessionIndicator()
            self.refreshUnreadIndicator()
        }
    }

    private func assistantContinuityDecision(
        incoming: String,
        staleRetries: Int
    ) async -> AssistantContinuityOutcome {
        let snapshot = agent.currentConversation
        let outcome = await assistantContinuityClassifier.decide(current: snapshot, incoming: incoming)
        guard agent.currentSessionId != snapshot.id else { return outcome }
        guard staleRetries > 0 else {
            return .fallback("the active conversation changed while continuity was being classified")
        }
        return await assistantContinuityDecision(incoming: incoming, staleRetries: staleRetries - 1)
    }

    private func sendTypedMessage(_ text: String) {
        if let interaction = pendingInteraction {
            chatPanel.addNote("Sent to Claude.")
            fulfillInteraction(interaction, text: text, includeScreenshot: false)
            return
        }
        sendToAgent(text: text, includeFreshScreenshot: sessionActive)
    }

    /// Hand the user's answer to the MCP tool call that's blocked on it.
    /// If that call already timed out, the answer goes to the inbox instead
    /// so Claude still gets it on its next check-in.
    private func fulfillInteraction(_ interaction: PendingInteraction, text: String, includeScreenshot: Bool) {
        Task { @MainActor in
            var attachments: [String] = []
            let display = DisplayTopology.underMouse ?? DisplayTopology.primary
            if includeScreenshot,
               let raw = try? await screenCapture.captureScreen(on: display),
               let shot = CaptureStore.saveShot(raw, on: display) {
                attachments.append(shot.path)
            }
            guard !interaction.resolved else {
                inbox.add(text: text, attachments: attachments, session: interaction.sessionId)
                replyBubble.showTransient("\(sessionName(for: interaction.sessionId)) had stopped waiting — answer queued", seconds: 6)
                return
            }
            interaction.attachments.append(contentsOf: attachments)
            interaction.responseText = text
            interaction.semaphore.signal()
            // The answer stays attached to its ask (↳ in the Agents thread);
            // answering CONSUMES the stack — done history in the panel,
            // gone from the pill's quick surfaces (tickets #17/#14).
            attachAnswer(text, to: interaction.sessionId)
            answeredSession(interaction.sessionId,
                            note: "answer sent to \(sessionName(for: interaction.sessionId))",
                            clearStack: true)
        }
    }

    /// Same interaction contract for evidence already frozen by CaptureRun.
    /// Never takes a later screenshot or consults the current target session.
    private func fulfillInteraction(_ interaction: PendingInteraction, text: String,
                                    attachments: [String]) {
        guard !interaction.resolved else {
            inbox.add(text: text, attachments: attachments, session: interaction.sessionId)
            replyBubble.showTransient("\(sessionName(for: interaction.sessionId)) had stopped waiting — answer queued", seconds: 6)
            return
        }
        interaction.attachments.append(contentsOf: attachments)
        interaction.responseText = text
        interaction.semaphore.signal()
        attachAnswer(text, to: interaction.sessionId)
        answeredSession(interaction.sessionId,
                        note: "answer sent to \(sessionName(for: interaction.sessionId))",
                        clearStack: true)
    }

    /// Record the user's reply on the newest unanswered ask push of the
    /// session, so the panel's thread shows question and answer together.
    private func attachAnswer(_ text: String, to sessionId: String?) {
        guard let sid = sessionId, var queue = sessionPushes[sid] else { return }
        guard let index = queue.lastIndex(where: { $0.isAsk && $0.answer == nil }) else { return }
        queue[index].answer = text
        queue[index].seen = true
        queue[index].spoken = true   // answered = consumed (ticket #16)
        sessionPushes[sid] = queue
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
    }

    private static func messagePrompt(text: String, attachments: [String]) -> String {
        guard !attachments.isEmpty else { return text }
        return text + "\n(Screenshot of what I was looking at: \(attachments.joined(separator: ", ")) — read it.)"
    }

    /// Hand-deliver the queue: every pending message goes to the clipboard
    /// as a paste-ready prompt (and leaves the inbox — pasting IS delivery).
    private func copyQueuedMessages() {
        let messages = inbox.drain(session: nil)
        guard !messages.isEmpty else {
            replyBubble.showTransient("no queued messages")
            return
        }
        var lines = ["Voice messages I recorded for you in Voice Flow:"]
        for message in messages {
            var line = "- \(message.text)"
            if !message.attachments.isEmpty {
                line += " (screenshot of what I was looking at: \(message.attachments.joined(separator: ", ")) — read it)"
            }
            lines.append(line)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        replyBubble.showTransient("copied \(messages.count) message\(messages.count == 1 ? "" : "s")", seconds: 4)
    }

    private func snapAndSend() {
        sendToAgent(text: nil, includeFreshScreenshot: true, forceScreenshot: true)
    }

    private func sendToAgent(text: String?, includeFreshScreenshot: Bool, forceScreenshot: Bool = false) {
        assistantTurnUsesReceiptPresentation = false
        if !chatPanel.isVisible {
            currentPushSessionId = nil   // grown shows agent content now
            replyBubble.showThinking(echo: text)
        }

        Task { @MainActor in
            var screenshots: [Data] = []
            if includeFreshScreenshot || forceScreenshot {
                if let fresh = try? await screenCapture.captureScreen() {
                    screenshots.append(fresh)
                    lastCaptureData = fresh
                }
            }

            self.chatPanel.addUserMessage(text ?? "", attachmentNote: Self.attachmentNote(count: screenshots.count))
            self.agent.send(text: text, screenshots: screenshots)
        }
    }

    /// The agent may still be finishing an earlier turn when the session
    /// bundle is ready — interrupt it and retry briefly rather than lose it.
    private func deliverToAgent(_ text: String, screenshots: [Data], retriesLeft: Int) {
        if agent.isRunning, retriesLeft > 0 {
            agent.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.deliverToAgent(text, screenshots: screenshots, retriesLeft: retriesLeft - 1)
            }
            return
        }
        assistantTurnUsesReceiptPresentation = false
        agent.send(text: text, screenshots: screenshots)
    }

    private static func attachmentNote(count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "📎 1 screenshot"
        default: return "📎 \(count) screenshots"
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Capability-first capture flow
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func visibleConversationFocus() -> ConversationFocus {
        if chatPanel.isVisible { return chatPanel.conversationFocus }
        guard indicator.isGrownVisible else { return .none }
        return GrownConversationFocus.resolve(
            routesToAssistant: indicator.isGrownAssistantConversationVisible,
            sessionId: currentPushSessionId)
    }

    /// Continue-append (ticket #36): record through the normal kept pipeline
    /// with the target entry id frozen into the run. A second Continue click
    /// while the continuation records commits it (like toggle-Dictate).
    private func continueDictation(appendingTo entryId: String) {
        if recorder.isRecording {
            if let id = activeRunId, captureRuns[id]?.appendEntryId != nil {
                stopCapture()
            } else {
                chatPanel.setContinuationActive(entryId: nil)
                replyBubble.showTransient("already recording", seconds: 4)
            }
            return
        }
        beginCapture(capability: .dictate, deliveryPolicy: .historyOnly,
                     handsFree: false, appendToEntryId: entryId)
        if recorder.isRecording, let id = activeRunId,
           captureRuns[id]?.appendEntryId == entryId {
            chatPanel.setContinuationActive(entryId: entryId)
            replyBubble.showTransient("continuing dictation — Dictate key or Stop ends it", seconds: 5)
        } else {
            chatPanel.setContinuationActive(entryId: nil)
        }
    }

    private func beginCapture(capability: CaptureCapability,
                              deliveryPolicy: CaptureDeliveryPolicy,
                              handsFree: Bool,
                              appendToEntryId: String? = nil) {
        // A normal Dictate press while toggle-Dictate is active commits the
        // existing run; the next press starts the contextual one.
        if recorder.isRecording,
           let id = activeRunId, let run = captureRuns[id],
           case .historyOnly = run.route, deliveryPolicy == .contextual {
            stopCapture()
            replyBubble.showTransient(run.appendEntryId != nil
                                        ? "continuation captured — press again to dictate"
                                        : "kept in Inbox — press again to dictate", seconds: 5)
            return
        }
        guard !recorder.isRecording else { return }

        // Snapshot intent before collapsing the pill/panel-adjacent UI.
        let focus = visibleConversationFocus()
        let pasteTarget = deliveryPolicy == .contextual && focus == .none
            ? paster.captureTarget() : nil
        let route = CaptureRouter.resolve(
            policy: deliveryPolicy,
            focus: focus,
            pasteTarget: pasteTarget,
            pendingInteraction: pendingInteraction)
        let id = UUID()
        let snapshot: SnapshotState = capability == .snapshot ? .pending : .notNeeded
        let display = DisplayTopology.underMouse ?? DisplayTopology.primary
        let run = CaptureRun(
            id: id, capability: capability, route: route, startedAt: Date(),
            display: display, snapshot: snapshot, appendEntryId: appendToEntryId)
        captureRuns[id] = run
        activeRunId = id

        indicator.collapseNow()
        stopSpeechPlayback()
        streamingViaAX = false
        hadPartialStream = false

        if capability == .continuous {
            sessionActive = true
            ambientScreenshots.removeAll()
            pendingSessionShots.removeAll()
            lastCaptureData = nil
            captureStore.beginSession(runId: id)
            captureScheduler.interval = TimeInterval(max(1, UserSettings.shared.captureIntervalSeconds))
            captureScheduler.targetDisplay = display
            captureScheduler.start()
            indicator.setSessionActive(true)
            menuBar.setSessionActive(true)
            chatPanel.setSessionActive(true)
            chatPanel.addNote("Continuous capture started — recording voice and screen.")
        }

        playSound("Tink")
        state = handsFree ? .handsFree : .recording
        recorder.start()
        guard recorder.isRecording else {
            captureRuns[id]?.phase = .failed
            activeRunId = nil
            if capability == .continuous {
                sessionActive = false
                captureScheduler.stop()
                _ = captureStore.endSession(transcript: nil)
                indicator.setSessionActive(false)
                menuBar.setSessionActive(false)
                chatPanel.setSessionActive(false)
            }
            state = .idle
            replyBubble.showTransient("microphone unavailable — restart Voice Flow", seconds: 8, isError: true)
            return
        }
        vflog("capture \(id) started capability=\(capability.rawValue) focus=\(focus)")
    }

    private func stopCapture(expectedCapability: CaptureCapability? = nil) {
        guard recorder.isRecording, let id = activeRunId,
              let run = captureRuns[id],
              CaptureStopPolicy.permits(
                active: run.capability, requestedBy: expectedCapability) else { return }
        if run.appendEntryId != nil {
            chatPanel.setContinuationActive(entryId: nil)
        }
        partialTimer?.invalidate()
        partialTimer = nil
        transcriptPanel.hide()

        // Snapshot evidence belongs to the release moment, not the later
        // transcription callback. It joins the run independently by UUID.
        if run.capability == .snapshot {
            Task { @MainActor in
                let raw = try? await screenCapture.captureScreen(on: run.display)
                guard var current = captureRuns[id], current.phase != .delivered else { return }
                if let raw, let shot = CaptureStore.saveShot(raw, on: run.display) {
                    current.snapshot = .captured(path: shot.path, data: raw)
                } else {
                    current.snapshot = .unavailable
                }
                captureRuns[id] = current
                maybeDeliverCapture(id)
            }
        }

        recorder.stop { [weak self] pcmData in
            guard let self, var current = self.captureRuns[id] else { return }
            current.phase = .awaitingTranscription
            self.captureRuns[id] = current
            if self.activeRunId == id { self.activeRunId = nil }
            if case .historyOnly = current.route {
                self.handsFreeHotkeyManager.resetHandsFreeState()
            }

            guard let pcmData else {
                if current.capability == .continuous, current.continuousSummary != nil {
                    current.transcript = ""
                    current.phase = .ready
                    self.captureRuns[id] = current
                    self.maybeDeliverCapture(id)
                } else {
                    current.phase = .failed
                    self.captureRuns[id] = current
                    if self.recorder.lastCaptureBytes == 0 {
                        self.replyBubble.showTransient("no audio from the microphone", seconds: 8, isError: true)
                    } else if self.recorder.lastCaptureWasSilent {
                        self.replyBubble.showTransient("didn't catch any speech")
                    }
                }
                if self.activeRunId == nil { self.state = .idle }
                return
            }

            if self.activeRunId == nil { self.state = .processing }
            let settings = UserSettings.shared
            let provider = settings.dictationProvider
            let openAIAPIKey = provider == .openai ? KeychainStore.shared.loadOpenAIAPIKey() : nil
            if provider == .openai, openAIAPIKey == nil {
                self.handleTranscriptionError(requestId: id.uuidString,
                                              message: "Add your OpenAI key in Settings to transcribe voice.")
                if case .paste = current.route { self.showSettings() }
                return
            }
            self.backend.transcribe(
                pcmData: pcmData,
                sampleRate: 16000,
                provider: provider,
                requestId: id.uuidString,
                skipCleanup: provider != .local || !settings.llmCleanupEnabled,
                openAIAPIKey: openAIAPIKey,
                vocabulary: settings.customVocabulary,
                wakeWord: settings.assistantWakeEnabled ? settings.assistantWakeWord : nil)
        }
    }

    /// A longer configured chord took ownership while a modifier-only capture
    /// prefix was still held. Discard that exact run before the descendant's
    /// onPress executes; never cancel an unrelated active capability.
    private func cancelCaptureForHotkeySupersession(capability: CaptureCapability) {
        guard recorder.isRecording, let id = activeRunId,
              captureRuns[id]?.capability == capability else { return }
        partialTimer?.invalidate()
        partialTimer = nil
        transcriptPanel.hide()
        recorder.cancel()
        if captureRuns[id]?.appendEntryId != nil {
            chatPanel.setContinuationActive(entryId: nil)
        }
        captureRuns[id]?.phase = .failed
        captureRuns.removeValue(forKey: id)
        activeRunId = nil
        streamingViaAX = false
        hadPartialStream = false
        state = .idle
        vflog("capture \(id) cancelled: hotkey superseded by longer chord")
    }

    // ── streaming partial transcription ───────────────

    private func startPartialTranscriptionTimer() {
        partialRequestId = 0
        latestDisplayedPartialId = 0
        partialTimer?.invalidate()
        partialTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.sendPartialTranscription()
        }
    }

    private func sendPartialTranscription() {
        guard recorder.isRecording, let id = activeRunId,
              let (snapshot, hasNewSpeech) = recorder.currentAudioSnapshot(),
              hasNewSpeech else { return }

        partialRequestId += 1
        vflog("partial: sending request \(partialRequestId) (\(snapshot.count) bytes)")
        let settings = UserSettings.shared
        let provider = settings.dictationProvider

        let openAIAPIKey: String?
        if provider == .openai {
            openAIAPIKey = KeychainStore.shared.loadOpenAIAPIKey()
        } else {
            openAIAPIKey = nil
        }

        backend.partialTranscribe(
            pcmData: snapshot,
            sampleRate: 16000,
            provider: provider,
            runId: id.uuidString,
            requestId: partialRequestId,
            openAIAPIKey: openAIAPIKey,
            vocabulary: settings.customVocabulary,
            wakeWord: settings.assistantWakeEnabled ? settings.assistantWakeWord : nil
        )
    }

    private func handlePartialResult(runId: String?, text: String, requestId: Int) {
        vflog("partial result \(requestId): \"\(text)\" (state=\(state.rawValue))")
        guard runId == activeRunId?.uuidString else { return }
        guard requestId > latestDisplayedPartialId else { return }
        latestDisplayedPartialId = requestId
        guard state == .recording || state == .handsFree else { return }
        guard !text.isEmpty else { return }

        if streamingViaAX {
            vflog("partial: streaming \(text.count) chars via AX")
            paster.streamText(text)
            hadPartialStream = true
        } else {
            vflog("partial: showing in panel")
            transcriptPanel.setText(text)
        }
    }

    // ── final result + exactly-once delivery ────────────

    private func correlatedRunId(_ requestId: String?) -> UUID? {
        CaptureCorrelation.resolve(requestId: requestId, runs: captureRuns)
    }

    private func handleTranscriptionResult(requestId: String?, raw: String, cleaned: String) {
        vflog("raw: \(raw)")
        vflog("cleaned: \(cleaned)")
        guard let id = correlatedRunId(requestId), var run = captureRuns[id],
              run.phase != .delivered, run.phase != .failed else {
            vflog("uncorrelated or duplicate transcription result id=\(requestId ?? "nil")")
            return
        }
        let note = (cleaned.isEmpty ? raw : cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        run.transcript = note
        run.phase = .ready
        if run.capability == .continuous, let summary = run.continuousSummary {
            run.continuousSummary = captureStore.updateTranscript(note, in: summary)
        }
        captureRuns[id] = run
        paster.clearStreamTarget()
        hadPartialStream = false
        maybeDeliverCapture(id)
    }

    private func handleTranscriptionError(requestId: String?, message: String) {
        guard let id = correlatedRunId(requestId), var run = captureRuns[id] else {
            chatPanel.addNote(message)
            if !chatPanel.isVisible {
                replyBubble.showTransient(message, seconds: 6, isError: true)
            }
            return
        }
        if run.capability == .continuous, let summary = run.continuousSummary {
            run.transcript = ""
            run.continuousSummary = captureStore.updateTranscript("", in: summary)
            run.phase = .ready
            captureRuns[id] = run
            maybeDeliverCapture(id)
        } else {
            run.phase = .failed
            captureRuns[id] = run
            chatPanel.addNote(message)
            replyBubble.showTransient("couldn't transcribe — capture kept from being misrouted",
                                      seconds: 6, isError: true)
        }
        if activeRunId == nil { state = .idle }
    }

    /// One wake name per loaded assistant (ticket VF-49). The base assistant
    /// keeps answering to the Settings wake word exactly as before; folder
    /// variants answer to their own names, longest match first.
    private func assistantWakeCandidates() -> [AssistantWakeCandidate] {
        let store = AssistantsStore.shared
        let settingsWord = UserSettings.shared.assistantWakeWord
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return store.assistants.map { assistant in
            let keyword = assistant.slug == store.base?.slug && !settingsWord.isEmpty
                ? settingsWord : assistant.name
            return AssistantWakeCandidate(slug: assistant.slug, keyword: keyword)
        }
    }

    private func maybeDeliverCapture(_ id: UUID) {
        guard var run = captureRuns[id], run.phase != .delivered,
              run.phase != .failed, run.isReadyToDeliver else { return }
        let note = run.transcript ?? ""
        let hasFrames = (run.continuousSummary?.frameCount ?? 0) > 0
        guard !note.isEmpty || hasFrames else {
            run.phase = .failed
            captureRuns[id] = run
            if activeRunId == nil { state = .idle }
            return
        }

        // Continue-append (ticket #36): the transcript joins its frozen
        // target entry instead of becoming a new one — no routing, no wake
        // word, no paste. The entry resurfaces as new (fresh timestamp,
        // unseen, top of the list).
        if let appendEntryId = run.appendEntryId {
            chatPanel.appendDictation(entryId: appendEntryId, text: note)
            replyBubble.showTransient("added to your dictation")
            run.phase = .delivered
            captureRuns[id] = run
            playSound("Pop")
            if activeRunId == nil { state = .done }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.state == .done { self.state = .idle }
            }
            pruneFinishedCaptureRuns()
            return
        }

        var attachmentPaths: [String] = []
        var screenshotData: [Data] = []
        if case .captured(let path, let data) = run.snapshot {
            attachmentPaths = [path]
            screenshotData = [data]
        }
        if let summary = run.continuousSummary {
            attachmentPaths = summary.framePaths
            screenshotData = run.continuousScreenshots
        }

        let externalText: String
        if let summary = run.continuousSummary {
            externalText = note.isEmpty ? summary.claudePrompt : "\(note)\n\n\(summary.claudePrompt)"
        } else {
            externalText = Self.messagePrompt(text: note, attachments: attachmentPaths)
        }

        let destination: CaptureDestination
        let seen: Bool?
        let settings = UserSettings.shared
        let wakeMatch = run.capability == .dictate && settings.assistantWakeEnabled
            ? AssistantWakeMatcher.resolve(in: note, candidates: assistantWakeCandidates())
            : nil
        let effectiveRoute: CaptureRoute = wakeMatch == nil ? run.route : .assistant
        switch effectiveRoute {
        case .historyOnly:
            destination = .kept
            seen = false
            replyBubble.showTransient("kept in Inbox")
        case .paste(let target):
            if paster.paste(externalText, to: target) {
                destination = .pasted
                seen = nil
            } else {
                destination = .kept
                seen = false
                replyBubble.showTransient("original app closed — copied and kept in Inbox",
                                          seconds: 7, isError: true)
            }
        case .assistant:
            destination = .assistant
            seen = nil
            let assistantNote = wakeMatch?.prompt ?? note
            let assistantText = run.capability == .continuous
                ? "I recorded a continuous screen capture. Read the ordered screenshots alongside my narration: \(externalText)"
                : assistantNote
            if let wakeMatch,
               let matched = AssistantsStore.shared.assistant(slug: wakeMatch.slug) {
                // A wake turn is classified before choosing its Codex thread
                // and reports like a normal session; it never auto-grows the
                // user's prompt or streamed response (ticket VF-54).
                enqueueAssistantWakeTurn(
                    assistant: matched,
                    displayText: assistantNote,
                    agentText: assistantText,
                    screenshots: screenshotData,
                    attachmentNote: Self.attachmentNote(count: screenshotData.count))
            } else {
                assistantTurnUsesReceiptPresentation = false
                if !chatPanel.isVisible {
                    replyBubble.showThinking(echo: assistantNote.isEmpty ? "Screen capture" : assistantNote)
                }
                chatPanel.addUserMessage(
                    assistantNote,
                    attachmentNote: Self.attachmentNote(count: screenshotData.count))
                deliverToAgent(assistantText, screenshots: screenshotData, retriesLeft: 2)
            }
        case .session(let sessionId, let interaction):
            destination = .session
            seen = nil
            if let interaction {
                fulfillInteraction(interaction, text: note.isEmpty ? externalText : note,
                                   attachments: attachmentPaths)
            } else {
                let live = inbox.hasWaiter(for: sessionId)
                inbox.add(text: externalText, attachments: attachmentPaths, session: sessionId)
                answeredSession(sessionId,
                                note: live ? "sent to \(sessionName(for: sessionId))"
                                           : "queued for \(sessionName(for: sessionId)) — delivered on its next check-in",
                                clearStack: live)
            }
        }

        if run.capability == .snapshot, case .unavailable = run.snapshot {
            replyBubble.showTransient("snapshot unavailable — sent words only",
                                      seconds: 6, isError: true)
        }

        let historyText = note.isEmpty
            ? "Screen capture (\(run.continuousSummary?.frameCount ?? attachmentPaths.count) frames)"
            : note
        chatPanel.addDictation(
            text: historyText, time: Self.timestamp(), destination: destination, seen: seen,
            capability: run.capability, attachments: attachmentPaths,
            captureId: run.continuousSummary?.id)
        run.phase = .delivered
        captureRuns[id] = run
        playSound("Pop")
        if activeRunId == nil { state = .done }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if self.state == .done { self.state = .idle }
        }
        pruneFinishedCaptureRuns()
    }

    private func pruneFinishedCaptureRuns() {
        let finished = captureRuns.values
            .filter { $0.phase == .delivered || $0.phase == .failed }
            .sorted { $0.startedAt > $1.startedAt }
        for stale in finished.dropFirst(40) { captureRuns.removeValue(forKey: stale.id) }
    }

    private func playSound(_ name: String) {
        guard UserSettings.shared.soundsEnabled else { return }
        NSSound(named: name)?.play()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Voice replies
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Silence any in-flight speech (streamed reply or read-aloud).
    private func stopSpeechPlayback() {
        replySpeaker.cancel()
        let phase = ttsController.status.phase
        // A PAUSED queue counts too (interaction audit C6/C12): barge-in
        // ends it cleanly — resume points survive via the settle path, and
        // no stuck paused strip fights the recording visuals.
        if phase == .playing || phase == .generating || ttsController.queuedSpeechActive {
            ttsController.stop()
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Permissions
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func checkAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Screen-recording TCC rows bind to the granting build's code
    /// signature: after a signature change System Settings still shows
    /// Voice Flow "On" while the OS denies the running binary — and
    /// CGPreflightScreenCaptureAccess trusts the stale row. Other apps'
    /// window NAMES are only readable with a live grant, so probe those.
    private func screenCaptureActuallyWorks() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        return windows.contains { window in
            window[kCGWindowOwnerPID as String] as? Int != myPid
                && (window[kCGWindowName as String] as? String)?.isEmpty == false
        }
    }

    /// Drop this app's TCC row so the next request shows a fresh prompt
    /// instead of a System Settings toggle that is already (stale) "On".
    private func resetStaleTCCGrant(service: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.voiceflow.app"]
        try? proc.run()
        proc.waitUntilExit()
        vflog("permissions: tccutil reset \(service) → exit \(proc.terminationStatus)")
    }

    private func relaunchNow() {
        vflog("permissions: relaunching to apply screen recording grant")
        let path = Bundle.main.bundlePath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? proc.run()
        NSApp.terminate(nil)
    }

    /// Screen-recording grants only take effect after a relaunch, and the
    /// running process CACHES its denial — CGPreflight often keeps saying
    /// false here even after the user approves. The poll is best-effort;
    /// the reliable path is the "Restart Voice Flow" button
    /// (screenGrantPendingRestart) shown after a request.
    private func relaunchWhenScreenCaptureGranted() {
        screenGrantPollTimer?.invalidate()
        var polls = 0
        screenGrantPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            polls += 1
            if CGPreflightScreenCaptureAccess(), self?.screenCaptureActuallyWorks() != true {
                timer.invalidate()
                self?.relaunchNow()
            } else if polls > 90 {
                timer.invalidate()
            }
        }
    }

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        vflog("accessibility prompt shown")
    }

    private func requestInitialPermissionsIfNeeded() {
        guard !initialPermissionsRequested else { return }
        initialPermissionsRequested = true
        refreshPermissionWindow()
        if !allPermissionsGranted() {
            showPermissions()
        }
    }

    private func requestMicrophonePermission() {
        showPermissions()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            vflog("microphone permission already granted")
            refreshPermissionWindow()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                vflog("microphone permission \(granted ? "granted" : "denied")")
                DispatchQueue.main.async {
                    self?.refreshPermissionWindow()
                }
            }
        case .denied, .restricted:
            openPrivacySettings(anchor: "Privacy_Microphone")
            refreshPermissionWindow()
        @unknown default:
            refreshPermissionWindow()
        }
    }

    private func requestScreenCapturePermission() {
        showPermissions()
        if CGPreflightScreenCaptureAccess(), screenCaptureActuallyWorks() {
            vflog("screen capture permission already granted")
            screenGrantPendingRestart = false
            refreshPermissionWindow()
            return
        }
        if screenGrantPendingRestart {
            // Second click = the "Restart Voice Flow" button.
            relaunchNow()
            return
        }
        if CGPreflightScreenCaptureAccess() {
            // Stale row: clear it so the fresh prompt and the System
            // Settings entry actually apply to THIS build.
            vflog("screen capture grant is stale — resetting")
            resetStaleTCCGrant(service: "ScreenCapture")
        }
        let granted = CGRequestScreenCaptureAccess()
        vflog(granted ? "screen capture permission granted" : "screen capture permission not yet granted")
        screenGrantPendingRestart = true
        relaunchWhenScreenCaptureGranted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshPermissionWindow()
        }
    }

    private func requestAccessibilityPermission() {
        showPermissions()
        if checkAccessibility() {
            vflog("accessibility already granted")
            refreshPermissionWindow()
            return
        }
        // A stale "On" row in System Settings blocks re-granting (the
        // toggle is already on) — clear it first; a no-op when fresh.
        resetStaleTCCGrant(service: "Accessibility")
        requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshPermissionWindow()
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func microphonePermissionState() -> PermissionViewState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return PermissionViewState(
                statusText: "Granted",
                statusColor: NSColor(r: 120, g: 180, b: 100),
                actionTitle: "Granted",
                actionEnabled: false
            )
        case .notDetermined:
            return PermissionViewState(
                statusText: "Not requested yet",
                statusColor: Theme.text3,
                actionTitle: "Request",
                actionEnabled: true
            )
        case .denied:
            return PermissionViewState(
                statusText: "Denied. Open System Settings and allow microphone access.",
                statusColor: NSColor(r: 220, g: 90, b: 70),
                actionTitle: "Open Settings",
                actionEnabled: true
            )
        case .restricted:
            return PermissionViewState(
                statusText: "Restricted by macOS.",
                statusColor: NSColor(r: 220, g: 90, b: 70),
                actionTitle: "System Managed",
                actionEnabled: false
            )
        @unknown default:
            return PermissionViewState(
                statusText: "Unknown status",
                statusColor: Theme.text3,
                actionTitle: "Refresh",
                actionEnabled: true
            )
        }
    }

    private func screenCapturePermissionState() -> PermissionViewState {
        if CGPreflightScreenCaptureAccess() {
            if screenCaptureActuallyWorks() {
                return PermissionViewState(
                    statusText: "Granted",
                    statusColor: NSColor(r: 120, g: 180, b: 100),
                    actionTitle: "Granted",
                    actionEnabled: false
                )
            }
            if screenGrantPendingRestart {
                return PermissionViewState(
                    statusText: "Approved — restart Voice Flow to apply it (macOS only hands the grant to a fresh launch).",
                    statusColor: NSColor(r: 220, g: 160, b: 70),
                    actionTitle: "Restart Voice Flow",
                    actionEnabled: true
                )
            }
            return PermissionViewState(
                statusText: "Stale: System Settings lists an older build as allowed, but macOS denies this one. Reset clears the stale entry and re-prompts, then restart to apply.",
                statusColor: NSColor(r: 220, g: 160, b: 70),
                actionTitle: "Reset & Re-grant",
                actionEnabled: true
            )
        }
        if screenGrantPendingRestart {
            return PermissionViewState(
                statusText: "After approving in the system dialog or System Settings, restart Voice Flow to apply it.",
                statusColor: NSColor(r: 220, g: 160, b: 70),
                actionTitle: "Restart Voice Flow",
                actionEnabled: true
            )
        }
        return PermissionViewState(
            statusText: "Not granted yet. macOS may open System Settings after you request it.",
            statusColor: Theme.text2,
            actionTitle: "Request",
            actionEnabled: true
        )
    }

    private func accessibilityPermissionState() -> PermissionViewState {
        if checkAccessibility() {
            return PermissionViewState(
                statusText: "Granted",
                statusColor: NSColor(r: 120, g: 180, b: 100),
                actionTitle: "Granted",
                actionEnabled: false
            )
        }
        return PermissionViewState(
            statusText: "Not granted yet. macOS may open System Settings after you request it.",
            statusColor: Theme.text2,
            actionTitle: "Request",
            actionEnabled: true
        )
    }

    private func allPermissionsGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && CGPreflightScreenCaptureAccess()
            && screenCaptureActuallyWorks()
            && checkAccessibility()
    }

    private func refreshPermissionWindow() {
        guard permissionsWindow != nil else { return }
        permissionsWindow.update(
            microphone: microphonePermissionState(),
            screenCapture: screenCapturePermissionState(),
            accessibility: accessibilityPermissionState(),
            allGranted: allPermissionsGranted()
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Windows
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func toggleHistory() {
        chatPanel.show(focusInput: false)
        chatPanel.selectTab(.inbox)
    }

    private func showSettings() {
        showDock()
        chatPanel.hide()
        settingsWindow.prepareForPresentation()
        settingsWindow.showWindow(nil)
        settingsWindow.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPermissions() {
        showDock()
        refreshPermissionWindow()
        permissionsWindow.showWindow(nil)
        permissionsWindow.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func revealSpeechTab() {
        chatPanel.show(focusInput: false)
        chatPanel.openSpeech()
    }

    private func showDock() { NSApp.setActivationPolicy(.regular) }

    private func hideDockIfNoWindows() {
        let settingsVisible = settingsWindow.window?.isVisible == true
        let permissionsVisible = permissionsWindow.window?.isVisible == true
        if !settingsVisible && !permissionsVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  TTS (hotkey + local API)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// The read-aloud hotkey doubles as a stop button while anything is speaking.
    private func speakSelectedTextOrStop() {
        let phase = ttsController.status.phase
        if phase == .playing || phase == .generating {
            stopSpeechPlayback()
            vflog("tts hotkey: stopped speech")
            return
        }

        guard let selectedText = paster.copySelectedText() else {
            NSSound.beep()
            vflog("tts hotkey: no selected text available")
            return
        }

        speakTextThroughPlayer(selectedText, source: .text(title: "Selection"),
                               showSettingsOnMissingKey: true)
    }

#if VOICE_FLOW_QA
    private func qaObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data.isEmpty ? [:] : nil
        }
        return value
    }

    private func handleQAControl(method: String, path: String,
                                 body: Data) -> LocalAPIResponse {
        guard let payload = qaObject(body) else {
            return .error(400, "Request body must be a JSON object.")
        }
        switch (method, path) {
        case ("GET", "/__qa/state"):
            return .ok(qaState())
        case ("GET", "/__qa/events"):
            let after = (payload["after"] as? NSNumber)?.intValue ?? 0
            return .ok(["events": QAEventRecorder.shared.snapshot(after: after)])
        case ("POST", "/__qa/events/reset"):
            QAEventRecorder.shared.reset()
            return .ok(["ok": true])
        case ("GET", "/__qa/capabilities"):
            let candidates = [
                Bundle.main.resourceURL?.appendingPathComponent("QA/capabilities.json"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("tests/capabilities.json"),
            ].compactMap { $0 }
            guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let data = try? Data(contentsOf: url),
                  let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error(503, "QA capability catalog is not bundled.")
            }
            return .ok(catalog)
        case ("POST", "/__qa/conversation/create"):
            var response = LocalAPIResponse.error(409, "Assistant is running.")
            DispatchQueue.main.sync {
                guard !self.agent.isRunning else { return }
                let conversation = self.agent.createConversation(
                    force: payload["force"] as? Bool ?? false)
                self.chatPanel.restoreAssistantConversation(conversation, open: true)
                response = .ok(["conversation_id": conversation.id])
            }
            return response
        case ("POST", "/__qa/conversation/select"):
            guard let id = payload["conversation_id"] as? String else {
                return .error(400, "conversation_id is required.")
            }
            var response = LocalAPIResponse.error(404, "Conversation not found or busy.")
            DispatchQueue.main.sync {
                if let conversation = self.agent.activateConversation(id) {
                    self.chatPanel.restoreAssistantConversation(conversation, open: true)
                    response = .ok(["conversation_id": id])
                }
            }
            return response
        case ("POST", "/__qa/runtime"):
            guard let raw = payload["runtime"] as? String,
                  let runtime = AgentRuntimeKind(rawValue: raw) else {
                return .error(400, "runtime must be codex or opencode.")
            }
            let trust = (payload["trust_profile"] as? String)
                .flatMap(AgentTrustProfile.init(rawValue:)) ?? .workspace
            var response = LocalAPIResponse.error(409, "Assistant is running.")
            DispatchQueue.main.sync {
                self.agent.qaTrustProfile = trust
                if self.agent.setPreferredRuntime(runtime) != nil {
                    self.chatPanel.setAssistantRuntime(runtime, enabled: true)
                    response = .ok(["runtime": runtime.rawValue, "trust_profile": trust.rawValue])
                }
            }
            return response
        case ("POST", "/__qa/runtime/default"):
            guard let raw = payload["runtime"] as? String,
                  let runtime = AgentRuntimeKind(rawValue: raw) else {
                return .error(400, "runtime must be codex or opencode.")
            }
            UserSettings.shared.agentBackend = runtime.rawValue
            UserSettings.shared.save()
            return .ok(["runtime": runtime.rawValue])
        case ("GET", "/__qa/runtime/health"):
            let semaphore = DispatchSemaphore(value: 0)
            var values: [[String: Any]] = []
            Task {
                for runtime in AgentRuntimeKind.allCases {
                    let status: AgentRuntimeStatus
                    switch runtime {
                    case .codex: status = await CodexAgentRuntime().status()
                    case .opencode: status = await OpenCodeAgentRuntime().status()
                    }
                    values.append([
                        "runtime": runtime.rawValue,
                        "health": status.health.rawValue,
                        "version": status.version ?? "",
                        "detail": status.detail ?? "",
                    ])
                }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 5) == .success else {
                return .error(504, "runtime health check timed out.")
            }
            return .ok(["runtimes": values])
        case ("GET", "/__qa/assistant/tail"):
            var response: [String: Any] = [:]
            DispatchQueue.main.sync {
                let conversation = self.agent.currentConversation
                response = [
                    "conversation_id": conversation.id,
                    "message_count": conversation.messages.count,
                    "messages": conversation.messages.suffix(8).map { message in
                        [
                            "role": message.role.rawValue,
                            "text": String(AgentSecretPolicy.redacted(message.text).prefix(4_000)),
                        ]
                    },
                    "running": self.agent.isRunning,
                ]
            }
            return .ok(response)
        case ("POST", "/__qa/provider"):
            guard let base = payload["base_url"] as? String,
                  let url = URL(string: base),
                  url.host == "127.0.0.1" || url.host == "localhost",
                  let model = payload["model"] as? String,
                  !model.isEmpty else {
                return .error(400, "QA provider must be a loopback base_url and non-empty model.")
            }
            UserSettings.shared.agentBaseURL = url.absoluteString
            UserSettings.shared.agentModel = model
            if let budget = (payload["daily_budget_usd"] as? NSNumber)?.doubleValue {
                UserSettings.shared.agentDailyBudgetUSD = max(0, budget)
            }
            UserSettings.shared.save()
            return .ok(["base_url": url.absoluteString, "model": model])
        case ("POST", "/__qa/submit"):
            let text = payload["text"] as? String
            let paths = payload["screenshots"] as? [String] ?? []
            var images: [Data] = []
            for path in paths {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard VoiceFlowPaths.shared.contains(url),
                      let data = try? Data(contentsOf: url), data.count <= 20_000_000 else {
                    return .error(403, "Every screenshot must be a bounded file inside the QA root.")
                }
                images.append(data)
            }
            var response = LocalAPIResponse.error(409, "Assistant is running.")
            DispatchQueue.main.sync {
                guard !self.agent.isRunning else { return }
                self.agent.send(text: text, screenshots: images)
                response = .accepted([
                    "conversation_id": self.agent.currentSessionId,
                    "runtime": self.agent.preferredRuntime.rawValue,
                ])
            }
            return response
        case ("POST", "/__qa/hotkey/post"):
            guard let rawKeyCode = (payload["key_code"] as? NSNumber)?.intValue,
                  (0...127).contains(rawKeyCode),
                  let action = payload["action"] as? String,
                  HotkeyManager.qaPost(keyCode: CGKeyCode(rawKeyCode), action: action) else {
                return .error(400, "key_code 0...127 and action press|release|tap|double_tap are required.")
            }
            return .accepted(["key_code": rawKeyCode, "action": action])
        case ("POST", "/__qa/interrupt"):
            DispatchQueue.main.sync { self.agent.interrupt() }
            return .accepted(["interrupt_requested": true])
        case ("POST", "/__qa/permission"):
            guard let id = payload["id"] as? String,
                  let raw = payload["response"] as? String,
                  let response = AgentPermissionResponse(rawValue: raw) else {
                return .error(400, "id and response (once|reject) are required.")
            }
            Task { await AgentPermissionBroker.shared.resolve(id: id, response: response) }
            return .accepted(["permission_id": id, "response": raw])
        case ("POST", "/__qa/opencode/stop"):
            let profile = (payload["trust_profile"] as? String)
                .flatMap(AgentTrustProfile.init(rawValue:))
            Task {
                if let profile { await OpenCodeSupervisor.shared.stop(profile: profile) }
                else { await OpenCodeSupervisor.shared.stopAll() }
                QAEventRecorder.shared.append("opencode_stopped")
            }
            return .accepted(["stop_requested": true])
        case ("POST", "/__qa/opencode/restart"):
            let profile = (payload["trust_profile"] as? String)
                .flatMap(AgentTrustProfile.init(rawValue:)) ?? .workspace
            Task {
                await OpenCodeSupervisor.shared.stop(profile: profile)
                do {
                    let connection = try await OpenCodeSupervisor.shared.connection(for: profile)
                    QAEventRecorder.shared.append(
                        "opencode_restarted", ["version": connection.version])
                } catch {
                    QAEventRecorder.shared.append(
                        "opencode_restart_failed", ["error": error.localizedDescription])
                }
            }
            return .accepted(["restart_requested": true, "trust_profile": profile.rawValue])
        case ("GET", "/__qa/jobs"):
            return .ok(["jobs": qaJobs()])
        case ("POST", "/__qa/automation/editor"):
            let action = payload["action"] as? String ?? "open"
            if action == "open" {
                let configured = UserSettings.shared.agentBaseURL
                let baseURL = URL(string: configured) ?? URL(string: DefaultAgentBaseURL)!
                let defaultModel = UserSettings.shared.agentModel
                var fallbackIDs: Set<String> = [defaultModel]
                if let store = agentJobStore, let jobs = try? store.jobs(limit: 500) {
                    fallbackIDs.formUnion(jobs.compactMap(\.modelID))
                }
                Task {
                    let models = await OpenRouterModelCatalog.shared.refresh(
                        baseURL: baseURL,
                        apiKey: KeychainStore.shared.loadAgentAPIKey(),
                        fallbackIDs: fallbackIDs)
                    await MainActor.run {
                        let editor = AgentJobEditorView(
                            models: models, preferredRuntime: self.agent.preferredRuntime,
                            defaultModelID: defaultModel)
                        let window = NSPanel(
                            contentRect: NSRect(x: 0, y: 0, width: 500, height: 246),
                            styleMask: [.titled, .closable], backing: .buffered,
                            defer: false)
                        window.title = "New automation"
                        window.contentView = editor
                        window.center()
                        window.orderFrontRegardless()
                        self.activeAgentJobQAWindow = window
                        self.activeAgentJobEditor = editor
                        QAEventRecorder.shared.append("automation_editor_presented")
                    }
                }
                return .accepted(["opening": true])
            }
            if action == "close" {
                DispatchQueue.main.async {
                    if let window = self.activeAgentJobQAWindow {
                        window.close()
                        self.activeAgentJobQAWindow = nil
                        self.activeAgentJobEditor = nil
                    } else if let alert = self.activeAgentJobAlert {
                        NSApp.abortModal()
                        alert.window.orderOut(nil)
                    }
                }
                return .accepted(["closing": true])
            }
            if action == "search", let query = payload["query"] as? String {
                var accepted = false
                DispatchQueue.main.sync {
                    guard let editor = self.activeAgentJobEditor else { return }
                    editor.modelCombo.stringValue = query
                    editor.modelCombo.controlTextDidChange(Notification(
                        name: NSControl.textDidChangeNotification,
                        object: editor.modelCombo))
                    accepted = true
                }
                return accepted ? .ok(["query": query])
                    : .error(409, "Automation editor is not visible.")
            }
            if action == "select_model", let modelID = payload["model_id"] as? String {
                var selected = false
                DispatchQueue.main.sync {
                    selected = self.activeAgentJobEditor?.qaSelectModel(id: modelID) ?? false
                }
                return selected ? .ok(["model_id": modelID])
                    : .error(400, "model_id is not in the current picker catalog.")
            }
            if action == "select_runtime", let runtime = payload["runtime"] as? String {
                var selected = false
                DispatchQueue.main.sync {
                    guard let editor = self.activeAgentJobEditor,
                          let kind = AgentRuntimeKind(rawValue: runtime) else { return }
                    editor.qaSelectRuntime(kind)
                    selected = true
                }
                return selected ? .ok(["runtime": runtime])
                    : .error(400, "runtime must be codex or opencode.")
            }
            if action == "select_trigger", let trigger = payload["trigger"] as? String {
                let labels = [
                    "manual": "Manual", "interval": "Interval",
                    "inbox": "Inbox message", "capture": "Capture completed",
                    "watcher": "Watcher action",
                ]
                var selected = false
                DispatchQueue.main.sync {
                    guard let editor = self.activeAgentJobEditor,
                          let label = labels[trigger] else { return }
                    editor.qaSetVisibleTrigger(label)
                    selected = true
                }
                return selected ? .ok(["trigger": trigger])
                    : .error(400, "trigger is not supported.")
            }
            return .error(
                400,
                "action must be open, search, select_model, select_runtime, select_trigger, or close.")
        case ("POST", "/__qa/automation/editor_snapshot"):
            var response = LocalAPIResponse.error(409, "Automation editor is not visible.")
            DispatchQueue.main.sync {
                guard let editor = self.activeAgentJobEditor else { return }
                do {
                    let shot = try editor.qaSnapshot()
                    response = .ok([
                        "path": shot.path, "width": shot.width, "height": shot.height,
                    ])
                } catch {
                    response = .error(500, error.localizedDescription)
                }
            }
            return response
        case ("POST", "/__qa/settings/assistant"):
            let action = payload["action"] as? String ?? "open"
            var response = LocalAPIResponse.error(400, "Unknown Settings action.")
            DispatchQueue.main.sync {
                switch action {
                case "open":
                    self.settingsWindow.qaShowAssistant()
                    response = .accepted(["opening": true])
                case "close":
                    self.settingsWindow.qaClose()
                    response = .accepted(["closing": true])
                case "select_model":
                    guard let id = payload["model_id"] as? String,
                          self.settingsWindow.qaSelectModel(id: id) else {
                        response = .error(400, "model_id is not in the Settings catalog.")
                        return
                    }
                    response = .ok(["model_id": id])
                default:
                    break
                }
            }
            return response
        case ("POST", "/__qa/settings/snapshot"):
            var response = LocalAPIResponse.error(409, "Assistant Settings is not visible.")
            DispatchQueue.main.sync {
                guard self.settingsWindow.qaAssistantVisible else { return }
                do {
                    let shot = try self.settingsWindow.qaSnapshot()
                    response = .ok([
                        "path": shot.path, "width": shot.width, "height": shot.height,
                    ])
                } catch {
                    response = .error(500, error.localizedDescription)
                }
            }
            return response
        case ("POST", "/__qa/jobs/create"):
            guard let prompt = payload["prompt"] as? String,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let assistant = agent.activeAssistant,
                  let agentJobStore else {
                return .error(400, "prompt, active assistant, and job store are required.")
            }
            let runtime = (payload["runtime"] as? String)
                .flatMap(AgentRuntimeKind.init(rawValue:)) ?? agent.preferredRuntime
            let trigger = (payload["trigger"] as? String)
                .flatMap(AgentJobTriggerKind.init(rawValue:)) ?? .manual
            let interval = (payload["interval_seconds"] as? NSNumber)?.doubleValue
            let now = Date()
            let job = AgentJob(
                assistantSlug: assistant.slug,
                conversationID: (payload["conversation_id"] as? String) ?? agent.currentSessionId,
                runtime: runtime, trigger: trigger,
                modelID: runtime == .opencode ? payload["model_id"] as? String : nil,
                prompt: prompt,
                trustProfile: (payload["trust_profile"] as? String)
                    .flatMap(AgentTrustProfile.init(rawValue:)) ?? .unattended,
                state: trigger == .interval ? .queued : .completed,
                nextRunAt: trigger == .interval ? now.addingTimeInterval(max(1, interval ?? 60)) : nil,
                intervalSeconds: trigger == .interval ? max(1, interval ?? 60) : nil,
                concurrencyKey: payload["concurrency_key"] as? String,
                dailyBudgetUSD: (payload["daily_budget_usd"] as? NSNumber)?.doubleValue ?? 1,
                maxDurationSeconds: (payload["max_duration_seconds"] as? NSNumber)?.doubleValue ?? 900,
                maxAttempts: (payload["max_attempts"] as? NSNumber)?.intValue ?? 3,
                createdAt: now, updatedAt: now)
            do {
                try agentJobStore.put(job)
                return .ok(["job_id": job.id])
            } catch {
                return .error(400, error.localizedDescription)
            }
        case ("POST", "/__qa/jobs/run"):
            guard let id = payload["job_id"] as? String else {
                return .error(400, "job_id is required.")
            }
            runAgentJob(id)
            return .accepted(["job_id": id])
        case ("POST", "/__qa/jobs/cancel"):
            guard let id = payload["job_id"] as? String else {
                return .error(400, "job_id is required.")
            }
            cancelAgentJob(id)
            return .accepted(["job_id": id])
        case ("POST", "/__qa/jobs/trigger"):
            guard let raw = payload["trigger"] as? String,
                  let trigger = AgentJobTriggerKind(rawValue: raw),
                  trigger != .manual && trigger != .interval else {
                return .error(400, "trigger must be inbox, capture, or watcher.")
            }
            let eventID = (payload["event_id"] as? String) ?? UUID().uuidString
            enqueueAgentJobs(trigger: trigger, source: "qa-\(raw)", eventID: eventID)
            return .accepted(["trigger": raw, "event_id": eventID])
        case ("POST", "/__qa/inbox/add"):
            guard let text = payload["text"] as? String, !text.isEmpty else {
                return .error(400, "text is required.")
            }
            inbox.add(text: text, attachments: [], session: nil)
            return .accepted(["queued": true])
        case ("POST", "/__qa/capture/finalize"):
            guard let transcript = payload["transcript"] as? String, !transcript.isEmpty else {
                return .error(400, "transcript is required.")
            }
            var captureID = ""
            DispatchQueue.main.sync {
                self.captureStore.beginSession(runId: UUID())
                captureID = self.captureStore.endSession(
                    transcript: transcript, keepEmpty: true)?.id ?? ""
            }
            guard !captureID.isEmpty else { return .error(500, "capture did not finalize.") }
            return .accepted(["capture_id": captureID])
        case ("POST", "/__qa/capture/deliver"):
            guard let rawCapability = payload["capability"] as? String,
                  let capability = CaptureCapability(rawValue: rawCapability),
                  let routeName = payload["route"] as? String,
                  let transcript = payload["transcript"] as? String,
                  !transcript.isEmpty else {
                return .error(400, "capability, route, and transcript are required.")
            }
            let fixtureData: Data?
            if let fixturePath = payload["fixture_path"] as? String {
                let fixtureURL = URL(fileURLWithPath: fixturePath).standardizedFileURL
                guard VoiceFlowPaths.shared.contains(fixtureURL),
                      let data = try? Data(contentsOf: fixtureURL), data.count <= 20_000_000 else {
                    return .error(403, "fixture_path must be a bounded file in the QA root.")
                }
                fixtureData = data
            } else {
                fixtureData = nil
            }
            var response = LocalAPIResponse.error(400, "unknown capture route.")
            DispatchQueue.main.sync {
                let route: CaptureRoute
                switch routeName {
                case "history": route = .historyOnly
                case "assistant": route = .assistant
                case "closed_paste":
                    route = .paste(PasteTarget(
                        processIdentifier: pid_t.max, name: "Closed QA target"))
                default: return
                }
                let id = UUID()
                var snapshot: SnapshotState = capability == .snapshot ? .unavailable : .notNeeded
                if capability == .snapshot, let data = fixtureData,
                   let shot = CaptureStore.saveShot(data) {
                    snapshot = .captured(path: shot.path, data: data)
                }
                var run = CaptureRun(
                    id: id, capability: capability, route: route, startedAt: Date(),
                    display: DisplayTopology.primary, snapshot: snapshot)
                run.transcript = transcript
                run.phase = .ready
                if capability == .continuous {
                    self.captureStore.beginSession(runId: id)
                    if let data = fixtureData {
                        self.captureStore.addFrame(data)
                        run.continuousScreenshots = [data]
                    }
                    run.continuousSummary = self.captureStore.endSession(
                        transcript: nil, keepEmpty: true)
                }
                self.captureRuns[id] = run
                self.maybeDeliverCapture(id)
                response = .accepted([
                    "run_id": id.uuidString,
                    "capability": capability.rawValue,
                    "route": routeName,
                ])
            }
            return response
        case ("POST", "/__qa/watcher/action"):
            let eventID = (payload["event_id"] as? String) ?? UUID().uuidString
            DispatchQueue.main.sync { self.workflowWatcher.emitQAAction(id: eventID) }
            return .accepted(["event_id": eventID])
        case ("POST", "/__qa/tts/action"):
            guard let action = payload["action"] as? String else {
                return .error(400, "action is required.")
            }
            var accepted = true
            DispatchQueue.main.sync {
                switch action {
                case "pause": self.ttsController.pause()
                case "resume":
                    if self.ttsController.isPaused { self.ttsController.togglePause() }
                case "seek":
                    self.ttsController.seek(to: (payload["position"] as? NSNumber)?.doubleValue ?? 0)
                case "stop": self.ttsController.stop()
                case "voice_replies_on":
                    UserSettings.shared.voiceRepliesEnabled = true
                    UserSettings.shared.save()
                    self.chatPanel.setVoiceReplies(true)
                case "voice_replies_off":
                    UserSettings.shared.voiceRepliesEnabled = false
                    UserSettings.shared.save()
                    self.chatPanel.setVoiceReplies(false)
                case "live_begin": self.replySpeaker.begin()
                case "live_feed":
                    guard let text = payload["text"] as? String, !text.isEmpty else {
                        accepted = false
                        return
                    }
                    self.replySpeaker.append(text)
                case "live_finish": self.replySpeaker.finish()
                default: accepted = false
                }
            }
            return accepted ? .accepted(["action": action]) : .error(400, "unknown TTS action.")
        case ("POST", "/__qa/panel"):
            let tab = payload["tab"] as? String
            DispatchQueue.main.sync {
                if tab == "hide" {
                    self.chatPanel.hide()
                } else {
                    self.chatPanel.show(focusInput: false)
                    if tab == "inbox" { self.chatPanel.selectTab(.inbox) }
                    else if tab == "agents" { self.chatPanel.showAgentsList() }
                }
            }
            return .ok(["shown": tab ?? "current"])
        case ("POST", "/__qa/overlay/user_close"):
            guard let id = payload["id"] as? String,
                  let sanitized = OverlayManager.sanitize(id: id), sanitized == id else {
                return .error(400, "a sanitized overlay id is required.")
            }
            DispatchQueue.main.sync { self.overlayManager.qaClose(id: id) }
            return .accepted(["id": id])
        case ("POST", "/__qa/mcp/select"):
            guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else {
                return .error(400, "session_id is required.")
            }
            var selected = false
            DispatchQueue.main.sync {
                selected = self.pickerSessions().contains { $0.id == sessionID }
                if selected { self.setTargetSession(sessionID, announce: true) }
            }
            return selected ? .ok(["selected": sessionID]) : .error(404, "session not selectable.")
        case ("POST", "/__qa/pill/action"):
            guard let action = payload["action"] as? String else {
                return .error(400, "action is required.")
            }
            var accepted = true
            DispatchQueue.main.sync {
                switch action {
                case "close": self.indicator.dismissGrown()
                case "trash":
                    self.replyBubble.onTrashed?()
                    self.replyBubble.hide()
                case "picker":
                    let picker = self.pickerEntries()
                    self.indicator.showPicker(entries: picker.entries, activeName: picker.activeName)
                case "flash":
                    self.indicator.flashMessage("QA receipt", seconds: 30)
                case "collapse":
                    if self.indicator.isGrownVisible { self.indicator.dismissGrown() }
                    else { self.indicator.collapseNow() }
                case "barge_in": self.stopSpeechPlayback()
                case "escape": self.handleVoiceFlowEscape()
                case "annotate_begin": self.annotationOverlay.beginEditing()
                case "user_select":
                    guard let sessionID = payload["session_id"] as? String,
                          self.pickerSessions().contains(where: { $0.id == sessionID }) else {
                        accepted = false
                        return
                    }
                    self.userSelectSession(sessionID)
                case "speaker":
                    guard self.indicator.isGrownVisible else {
                        accepted = false
                        return
                    }
                    self.indicator.qaTapSpeaker()
                default: accepted = false
                }
            }
            return accepted ? .accepted(["action": action]) : .error(400, "unknown pill action.")
        case ("POST", "/__qa/ui/snapshot"):
            var response = LocalAPIResponse.error(500, "ChatPanel snapshot failed.")
            DispatchQueue.main.sync {
                do {
                    let shot = try self.chatPanel.qaSnapshot()
                    response = .ok([
                        "path": shot.path, "width": shot.width, "height": shot.height,
                    ])
                } catch {
                    response = .error(500, error.localizedDescription)
                }
            }
            return response
        case ("POST", "/__qa/ui/pill_snapshot"):
            var response = LocalAPIResponse.error(500, "Indicator snapshot failed.")
            DispatchQueue.main.sync {
                do {
                    let name = payload["name"] as? String ?? "state"
                    let shot = try self.indicator.qaSnapshot(name: name)
                    response = .ok([
                        "path": shot.path, "width": shot.width, "height": shot.height,
                    ])
                } catch {
                    response = .error(500, error.localizedDescription)
                }
            }
            return response
        case ("POST", "/__qa/app/terminate"):
            QAEventRecorder.shared.append("app_terminate_requested")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.terminate(nil)
            }
            return .accepted(["terminating": true])
        default:
            return .error(404, "Unknown QA action.")
        }
    }

    private func qaJobs() -> [[String: Any]] {
        ((try? agentJobStore?.jobs(limit: 100)) ?? []).map { job in
            var result: [String: Any] = [
                "id": job.id, "conversation_id": job.conversationID,
                "runtime": job.runtime.rawValue, "trigger": job.trigger.rawValue,
                "state": job.state.rawValue, "prompt": String(job.prompt.prefix(8_000)),
                "updated_at": job.updatedAt.timeIntervalSince1970,
            ]
            if let modelID = job.modelID { result["model_id"] = modelID }
            if let next = job.nextRunAt { result["next_run_at"] = next.timeIntervalSince1970 }
            return result
        }
    }

    private func qaState() -> [String: Any] {
        var state: [String: Any] = [
            "ok": true,
            "config_root": VoiceFlowPaths.shared.configRoot.path,
            "isolated": VoiceFlowPaths.shared.isIsolated,
            "synthetic_input_only": HotkeyManager.qaSyntheticInputIsolationEnabled,
            "jobs": qaJobs(),
            "events": QAEventRecorder.shared.snapshot(after: 0),
        ]
        DispatchQueue.main.sync {
            let conversation = self.agent.currentConversation
            state["assistant"] = [
                "conversation_id": conversation.id,
                "runtime": self.agent.preferredRuntime.rawValue,
                "trust_profile": self.agent.qaTrustProfile.rawValue,
                "activity": self.agent.activity.rawValue,
                "running": self.agent.isRunning,
                "messages": conversation.messages.map { message in
                    [
                        "id": message.id.uuidString,
                        "role": message.role.rawValue,
                        "text": String(AgentSecretPolicy.redacted(message.text).prefix(16_000)),
                    ]
                },
            ] as [String: Any]
            state["ui"] = [
                "panel_visible": self.chatPanel.isVisible,
                "conversation_focus": String(describing: self.chatPanel.conversationFocus),
                "agent_session_rows": self.agentSessionRows().count,
                "job_rows": self.agentJobRows().count,
                "controls": self.chatPanel.qaControlState,
            ] as [String: Any]
            state["default_runtime"] = UserSettings.shared.agentBackend
            state["mcp"] = [
                "target_session_id": self.targetSessionId ?? "",
                "sessions": self.mcpServer.sessions.ordered().map { session in
                    [
                        "id": session.id,
                        "number": session.number,
                        "name": session.name ?? "",
                        "engaged": session.engaged,
                        "push_count": self.sessionPushes[session.id]?.count ?? 0,
                        "unread_count": self.sessionPushes[session.id]?.filter { !$0.seen }.count ?? 0,
                    ] as [String: Any]
                },
            ] as [String: Any]
            var pill = self.indicator.qaState
            pill["current_push_session_id"] = self.currentPushSessionId ?? ""
            pill["slots"] = self.slottedSessions().map { session in
                ["number": session.slot, "id": session.id, "label": session.label]
                    as [String: Any]
            }
            pill["pushes"] = self.sessionPushes.map { sessionID, queue in
                [
                    "session_id": sessionID,
                    "count": queue.count,
                    "unread": queue.filter { !$0.seen }.count,
                    "active": queue.filter { $0.done != true }.count,
                ] as [String: Any]
            }
            state["pill"] = pill
            let tts = self.ttsController.status
            state["tts"] = [
                "phase": tts.phase.rawValue,
                "message": tts.message,
                "position": tts.currentTime,
                "duration": tts.duration,
                "has_audio": tts.hasAudio,
                "reply_speaker_active": self.replySpeaker.isActive,
            ] as [String: Any]
            state["annotation_editing"] = self.annotationOverlay.isEditing
            state["automation_editor_visible"] = self.activeAgentJobEditor?.window?.isVisible ?? false
            if let editor = self.activeAgentJobEditor {
                state["automation_editor"] = [
                    "model_accessibility_label": editor.modelCombo.accessibilityLabel() ?? "",
                    "matching_model_ids": editor.qaFilteredModelIDs,
                    "runtime_title": editor.runtimePopUp.titleOfSelectedItem ?? "",
                    "trigger_title": editor.triggerPopUp.titleOfSelectedItem ?? "",
                    "selected_runtime": editor.selectedRuntime.rawValue,
                    "selected_trigger": editor.selectedTrigger.rawValue,
                    "model_enabled": editor.qaModelEnabled,
                    "model_status": editor.qaModelStatus,
                    "model_text": editor.modelCombo.stringValue,
                ] as [String: Any]
            }
            state["settings_assistant_visible"] = self.settingsWindow.qaAssistantVisible
            if self.settingsWindow.qaAssistantVisible {
                state["settings_assistant"] = self.settingsWindow.qaAssistantState
            }
            state["capture"] = [
                "state": self.state.rawValue,
                "recording": self.recorder.isRecording,
                "session_active": self.sessionActive,
                "capability": self.activeRunId.flatMap {
                    self.captureRuns[$0]?.capability.rawValue
                } ?? "",
            ] as [String: Any]
            state["clipboard_text"] = String(
                (NSPasteboard.general.string(forType: .string) ?? "").prefix(16_000))
            state["overlays"] = [
                "active_session": self.overlayManager.qaActiveSession,
                "rendered_ids": self.overlayManager.qaRenderedIDs,
                "file_ids": self.overlayManager.list().map(\.id),
                "signature": self.overlayManager.qaSignature,
            ] as [String: Any]
        }
        return state
    }
#endif

    private func setupLocalAPIServer() {
        localAPIServer = LocalAPIServer()
#if VOICE_FLOW_QA
        do {
            localAPIServer.qaToken = try QAControlSecurity.installToken()
            localAPIServer.onQA = { [weak self] method, path, body in
                self?.handleQAControl(method: method, path: path, body: body)
                    ?? LocalAPIResponse.error(503, "App not ready.")
            }
        } catch {
            vflog("QA control disabled: \(error.localizedDescription)")
        }
#endif
        localAPIServer.onServerMessage = { [weak self] message in
            DispatchQueue.main.async {
                self?.chatPanel.setTTSServerLabel(message)
            }
        }
        localAPIServer.onStatus = { [weak self] in
            guard let self else { return LocalAPIResponse.error(503, "App not ready.") }
            var response = LocalAPIResponse.error(503, "Status unavailable.")
            DispatchQueue.main.sync {
                response = self.makeTTSStatusResponse()
            }
            return response
        }
        localAPIServer.onSet = { [weak self] payload in
            guard let self else { return LocalAPIResponse.error(503, "App not ready.") }
            var response = LocalAPIResponse.error(503, "TTS controls unavailable.")
            DispatchQueue.main.sync {
                response = self.handleTTSSet(payload)
            }
            return response
        }
        localAPIServer.onSpeak = { [weak self] payload in
            guard let self else { return LocalAPIResponse.error(503, "App not ready.") }
            var response = LocalAPIResponse.error(503, "TTS speak unavailable.")
            DispatchQueue.main.sync {
                response = self.handleTTSSpeak(payload)
            }
            return response
        }
        localAPIServer.onSeek = { [weak self] payload in
            guard let self else { return LocalAPIResponse.error(503, "App not ready.") }
            var response = LocalAPIResponse.error(503, "TTS seek unavailable.")
            DispatchQueue.main.sync {
                response = self.handleTTSSeek(payload)
            }
            return response
        }
        localAPIServer.onPanelShow = { [weak self] tab in
            guard let self else { return LocalAPIResponse.error(503, "App not ready.") }
            DispatchQueue.main.sync {
                self.chatPanel.show(focusInput: false)
                switch tab {
                case "inbox": self.chatPanel.selectTab(.inbox)
                case "agents": self.chatPanel.selectTab(.agents)
                case "speech": self.chatPanel.openSpeech()
                default: break
                }
            }
            return LocalAPIResponse.ok(["shown": tab ?? "current"])
        }
        localAPIServer.onStop = { [weak self] in
            guard let self else { return LocalAPIResponse.error(503, "App not ready.") }
            var response = LocalAPIResponse.error(503, "TTS stop unavailable.")
            DispatchQueue.main.sync {
                self.ttsController.stop()
                response = LocalAPIResponse.ok([
                    "ok": true,
                    "status": "stopped",
                ])
            }
            return response
        }

        mcpServer = MCPServer()
        mcpServer.callTool = { [weak self] name, arguments, session in
            guard let self else {
                return MCPServer.ToolResult.fail("Voice Flow is shutting down.")
            }
            return self.handleMCPTool(name, arguments, session)
        }
        // Connecting is NOT engaging: every Claude Code session initializes
        // every registered MCP server, so a fresh connection must neither
        // appear in the picker nor steal the voice target. Presence (and
        // target eligibility) starts with the first user-facing tool call —
        // see the engagement hook in handleMCPTool.
        mcpServer.onSessionConnected = nil
        localAPIServer.onMCP = { [weak self] body, sessionId in
            self?.mcpServer.handle(body: body, sessionId: sessionId) ?? (503, nil, nil)
        }
        localAPIServer.onMCPSessionEnd = { [weak self] sessionId in
            guard let self, let closed = self.mcpServer.sessions.close(sessionId) else { return }
            DispatchQueue.main.async {
                self.lastMCPDisplay.removeValue(forKey: closed.id)
                // An unread stack survives its session as a ghost picker
                // entry; a fully-read one leaves the pill with its session
                // but stays in the panel as done history (ticket #17).
                if self.sessionPushes[closed.id]?.contains(where: { !$0.seen }) != true {
                    self.markStackDone(closed.id)
                }
                self.refreshUnreadIndicator()
                if self.targetSessionId == closed.id {
                    let nextId = self.firstAvailableTarget(excluding: closed.id)
                    self.setTargetSession(nextId, announce: false)
                    if let nextId,
                       let next = self.pickerSessions().first(where: { $0.id == nextId }) {
                        self.replyBubble.showTransient(
                            "\(closed.label) ended — now talking to \(next.label)", seconds: 5)
                        return
                    }
                }
                self.refreshSessionIndicator()
                self.replyBubble.showTransient("\(closed.label) ended", seconds: 5)
            }
        }
        localAPIServer.start()

        // Registry pruning is lazy (no callbacks): sessions idle 2h vanish
        // the next time someone LOOKS, so the number dot and the unread
        // ring could lie for hours (e.g. overnight). A periodic sweep
        // keeps them honest. Stacks are NEVER auto-deleted — read or not,
        // they are the panel's thread history and persist until the user
        // trashes them (reading a ghost used to vaporize it within 60s,
        // taking the speaker and the thread with it — Safet QA). The sweep
        // only drops empty queues and re-targets off dead entries.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sessionPushes = self.sessionPushes.filter { _, queue in
                !queue.isEmpty
            }
            // Consumed, finished sessions leave the picker so their slot
            // numbers free for the queue (ticket VF-48).
            self.retireConsumedGhosts()
            // Overlays whose owning session no longer exists are orphans the
            // user has no affordance to clear — sweep them (ticket #14).
            let known = Set(self.mcpServer.sessions.ordered().map { $0.id })
            // Sticky labels leave with the stacks (and sessions) they name.
            self.sessionLabels = self.sessionLabels.filter {
                self.sessionPushes[$0.key] != nil || known.contains($0.key)
            }
            for owner in self.overlayManager.sessionsWithOverlays() where !known.contains(owner) {
                self.overlayManager.removeAll(forSession: owner)
            }
            if self.targetSessionId != nil,
               !self.pickerSessions().contains(where: { $0.id == self.targetSessionId }) {
                self.setTargetSession(self.firstAvailableTarget(), announce: false)
            }
            self.refreshSessionIndicator()
            self.refreshUnreadIndicator()
        }
        // Ghost stacks restored from disk should light the ring right away.
        refreshSessionIndicator()
        refreshUnreadIndicator()
    }

    private func mergedTTSRequest(_ payload: TTSAPIUpdatePayload) -> TTSRequest {
        var request = chatPanel.currentTTSRequest()
        if let text = payload.text { request.text = text }
        if let voice = payload.voice { request.voice = voice }
        if let speed = payload.speed { request.speed = speed }
        if let instructions = payload.instructions { request.instructions = instructions }
        return request.normalized()
    }

    @discardableResult
    private func handleTTSSpeak(_ request: TTSRequest, reveal: Bool, showSettingsOnMissingKey: Bool) -> String? {
        let normalized = request.normalized()
        chatPanel.applyTTSRequest(normalized)
        if reveal {
            revealSpeechTab()
        }
        // The same text already in the player: the Play button is a pause
        // toggle, matching the old same-request resume behavior.
        if ttsController.queuedSpeechActive, let context = playerContext,
           case .text = context.source,
           context.sentences == [SpeechSentencer.sentences(of: normalized.text)] {
            ttsController.togglePause()
            refreshPlayerSurface()
            return nil
        }
        return speakTextThroughPlayer(normalized.text, source: .text(title: "Speech"),
                                      request: normalized,
                                      showSettingsOnMissingKey: showSettingsOnMissingKey)
    }

    private func handleTTSSet(_ payload: TTSAPIUpdatePayload) -> LocalAPIResponse {
        let request = mergedTTSRequest(payload)
        chatPanel.applyTTSRequest(request)
        if payload.reveal == true {
            revealSpeechTab()
        }

        return LocalAPIResponse.ok([
            "ok": true,
            "status": "updated",
            "voice": request.voice,
            "speed": request.speed,
        ])
    }

    private func handleTTSSpeak(_ payload: TTSAPIUpdatePayload) -> LocalAPIResponse {
        let request = mergedTTSRequest(payload)
        if let error = handleTTSSpeak(request, reveal: payload.reveal == true, showSettingsOnMissingKey: false) {
            return LocalAPIResponse.error(400, error)
        }

        return LocalAPIResponse.accepted([
            "ok": true,
            "status": "speaking",
            "voice": request.voice,
            "speed": request.speed,
        ])
    }

    private func handleTTSSeek(_ payload: TTSAPIUpdatePayload) -> LocalAPIResponse {
        guard let position = payload.position else {
            return LocalAPIResponse.error(400, "A numeric `position` value is required.")
        }
        ttsController.seek(to: position)
        if payload.reveal == true {
            revealSpeechTab()
        }
        return LocalAPIResponse.ok([
            "ok": true,
            "status": "seeked",
            "position": ttsController.status.currentTime,
            "duration": ttsController.status.duration,
        ])
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  MCP tools — Voice Flow as Claude Code's interaction layer
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Runs on a background HTTP thread; anything touching UI hops to main.
    //  a report_to_user question deliberately blocks — its result IS the user's answer.

    /// Tools whose call makes the session user-visible: it gets its picker
    /// dot, its ⌃⌥N slot, and voice-target eligibility. Read-only tools
    /// (screenshots, captures, dictations) and set_session_name do NOT
    /// engage — a session the user never hears from stays invisible.
    private static let engagingMCPTools: Set<String> = [
        "report_to_user", "wait_for_message",
        "show_guide", "update_guide", "show_panel", "annotate_screen",
    ]

    private func handleMCPTool(_ name: String, _ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        if let session, Self.engagingMCPTools.contains(name),
           mcpServer.sessions.markEngaged(session.id) {
            // First engagement: surface the session. It claims the voice
            // target only when nobody engaged holds it — an active session
            // is never stolen from; the receipt's "⌃⌥N" is how the user
            // switches deliberately.
            DispatchQueue.main.sync {
                if self.targetSessionId == nil
                    || !self.pickerSessions().contains(where: { $0.id == self.targetSessionId }) {
                    self.setTargetSession(session.id, announce: false)
                }
                self.refreshSessionIndicator()
            }
        }
        let result = dispatchMCPTool(name, args, session)
        // Queued voice messages piggyback on every tool result so they
        // can't rot in the inbox unnoticed.
        guard !result.isError, let session,
              name != "check_messages", name != "wait_for_message" else { return result }
        let pending = inbox.pendingCount(for: session.id)
        guard pending > 0 else { return result }
        return .ok(result.text
            + "\n\n(\(pending) voice message\(pending == 1 ? "" : "s") from the user queued — call check_messages.)")
    }

    private func dispatchMCPTool(_ name: String, _ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        switch name {
        case "set_session_name": return mcpSetSessionName(args, session)
        case "report_to_user": return mcpReportToUser(args, session)
        case "check_messages": return mcpCheckMessages(session)
        case "wait_for_message": return mcpWaitForMessage(args, session)
        case "get_latest_capture": return mcpLatestCapture()
        case "list_captures": return mcpListCaptures(args)
        case "take_screenshot": return mcpTakeScreenshot(session)
        case "show_guide": return mcpShowGuide(args, session)
        case "update_guide": return mcpUpdateGuide(args, session)
        case "show_panel": return mcpShowPanel(args, session)
        case "annotate_screen": return mcpAnnotateScreen(args, session)
        case "clear_annotations":
            let removed = overlayManager.removeAll(annotationsOnly: true)
            DispatchQueue.main.sync { self.annotationOverlay.clear() }
            return .ok("Cleared \(removed) annotation overlay\(removed == 1 ? "" : "s") and the user's own marks.")
        case "remove_overlay": return mcpRemoveOverlay(args)
        case "list_overlays": return mcpListOverlays()
        case "get_recent_dictations": return mcpRecentDictations(args)
        default:
            return .fail("Unknown tool: \(name)")
        }
    }

    // Embedded OpenCode tools use this private bridge rather than public MCP,
    // so they never engage MCPSessionRegistry or create external picker state.
    private func handleEmbeddedOverlayTool(
        _ args: [String: Any], conversationID: String
    ) async throws -> AgentToolOutput {
        let operation = try AgentToolDispatcher.requiredString("operation", in: args)
        let owner = assistantPickerSessionId ?? "assistant:\(conversationID)"
        let rawID = OverlayManager.sanitize(id: args["id"] as? String) ?? "agent"
        let id = "assistant-\(rawID)"
        switch operation {
        case "list":
            let items = overlayManager.list().compactMap { item -> [String: Any]? in
                guard overlayManager.read(id: item.id)?["session"] as? String == owner else { return nil }
                return ["id": item.id, "type": item.type, "path": item.path, "visible": item.visible]
            }
            return AgentToolOutput(data: ["overlays": items])
        case "remove":
            guard overlayManager.read(id: id)?["session"] as? String == owner else {
                throw AgentToolError.denied("overlay is not owned by this Assistant")
            }
            return AgentToolOutput(data: ["id": id, "removed": overlayManager.remove(id: id)])
        case "update_guide":
            guard var current = overlayManager.read(id: id),
                  current["session"] as? String == owner else {
                throw AgentToolError.denied("guide is not owned by this Assistant")
            }
            let payload = args["payload"] as? [String: Any] ?? [:]
            for (key, value) in payload { current[key] = value }
            current["type"] = "guide"
            current["session"] = owner
            guard let path = overlayManager.write(id: id, dict: current) else {
                throw AgentToolError.unavailable("overlay file could not be written")
            }
            return AgentToolOutput(data: ["id": id, "path": path, "updated": true])
        case "show_guide", "show_panel", "annotate":
            var payload = args["payload"] as? [String: Any] ?? [:]
            payload["type"] = operation == "show_guide" ? "guide"
                : operation == "show_panel" ? "panel" : "annotations"
            payload["session"] = owner
            guard JSONSerialization.isValidJSONObject(payload),
                  let encoded = try? JSONSerialization.data(withJSONObject: payload),
                  encoded.count <= 64 * 1_024 else {
                throw AgentToolError.invalidArguments("overlay payload is invalid or over 64 KiB")
            }
            guard let path = overlayManager.write(id: id, dict: payload) else {
                throw AgentToolError.unavailable("overlay file could not be written")
            }
            return AgentToolOutput(data: ["id": id, "path": path, "owner": owner])
        default:
            throw AgentToolError.invalidArguments("unsupported overlay operation")
        }
    }

    private func handleEmbeddedUserTool(
        _ args: [String: Any], conversationID: String
    ) async throws -> AgentToolOutput {
        let operation = try AgentToolDispatcher.requiredString("operation", in: args)
        let owner = assistantPickerSessionId ?? "assistant:\(conversationID)"
        let summary = (args["summary"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (args["details"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch operation {
        case "report":
            guard !summary.isEmpty else {
                throw AgentToolError.invalidArguments("report needs a non-empty summary")
            }
            let text = details.isEmpty ? summary : "\(summary)\n\n\(details)"
            await MainActor.run {
                self.chatPanel.addNote("\(self.assistantPickerLabel): \(text)")
                if !self.surfaceBusy {
                    self.indicator.flashMessage("\(self.assistantPickerLabel) · update", seconds: 6)
                }
            }
            return AgentToolOutput(data: ["delivered": true, "channel": "assistant"])
        case "check":
            let messages = inbox.drain(session: owner)
            return AgentToolOutput(data: ["messages": messages.map {
                ["time": $0.time, "text": $0.text, "screenshots": $0.attachments] as [String: Any]
            }])
        case "ask", "wait":
            var prompt = (args["question"] as? String ?? summary)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.isEmpty { prompt = "The Assistant is waiting for your reply." }
            let requested = (args["timeout_seconds"] as? NSNumber)?.doubleValue
                ?? (operation == "ask" ? 1_800 : 600)
            let timeout = min(max(requested, 5), 14_400)
            var interaction: PendingInteraction?
            await MainActor.run {
                guard self.pendingInteraction == nil else { return }
                let value = PendingInteraction(prompt: prompt, sessionId: owner)
                self.pendingInteraction = value
                interaction = value
                self.replyBubble.showAsk(prompt: prompt, hint: self.askHint())
                self.chatPanel.addNote("\(self.assistantPickerLabel) asks: \(prompt)")
            }
            guard let interaction else {
                throw AgentToolError.unavailable("another user question is already pending")
            }
            _ = interaction.semaphore.wait(timeout: .now() + timeout)
            return try await MainActor.run {
                interaction.resolved = true
                self.pendingInteraction = nil
                self.replyBubble.hide()
                if let response = interaction.responseText {
                    return AgentToolOutput(data: [
                        "response": response,
                        "screenshots": interaction.attachments,
                    ])
                }
                if interaction.cancelled {
                    throw AgentToolError.unavailable("the user dismissed the question")
                }
                throw AgentToolError.unavailable("no user response arrived before timeout")
            }
        default:
            throw AgentToolError.invalidArguments("unsupported user operation")
        }
    }

    private func mcpJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func mcpSetSessionName(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        guard let session else {
            return .fail("This request carried no session id, so there is nothing to name.")
        }
        var name = (args["name"] as? String ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .fail("set_session_name needs a non-empty `name`.")
        }
        name = String(name.prefix(48))
        guard let renamed = mcpServer.sessions.rename(session.id, to: name) else {
            return .fail("This session is no longer registered.")
        }
        // Naming is silent by design: it must not create the impression of
        // a session the user should look at. The label surfaces whenever
        // the session actually engages.
        DispatchQueue.main.async {
            // A rename must reach existing threads' sticky titles too.
            if self.sessionLabels[renamed.id] != nil || self.sessionPushes[renamed.id] != nil {
                self.rememberSessionLabel(renamed.id)
            }
            self.refreshSessionIndicator()
        }
        return .ok("This session now appears to the user as \"\(renamed.label)\". You stay invisible to them until your first report_to_user / wait_for_message / overlay call.")
    }

    /// The one messaging tool: a receipt-backed report (summary + details),
    /// optionally blocking on a `question`.
    private func mcpReportToUser(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        let trimmed = { (key: String) in
            (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let summary = trimmed("summary")
        let details = trimmed("details")
        let question = trimmed("question")
        guard !summary.isEmpty else {
            return .fail("report_to_user needs a non-empty `summary` (and `details` with the substance — what happened, where, what you need).")
        }
        // The user reads one text: summary, then details, then the question
        // (skipped when it just repeats the summary).
        var parts = [summary]
        if !details.isEmpty { parts.append(details) }
        if !question.isEmpty, question != summary { parts.append(question) }
        let text = parts.joined(separator: "\n\n")

        guard !question.isEmpty else {
            let sessionId = session?.id
            DispatchQueue.main.sync {
                let sender = self.sessionName(for: sessionId)
                self.deliverPush(
                    SessionPush(title: sender, text: text, hint: nil, isAsk: false),
                    from: sessionId)
                if self.chatPanel.isVisible {
                    self.chatPanel.addNote("\(sender): \(text)")
                }
                self.playSound("Glass")
            }
            var reply = "Delivered: the user got a one-line receipt and reads the full report when they switch onto your session (⌃⌥N) or in the panel's Agents tab; audio plays only on their demand."
            if let sessionId {
                reply += """
                 If they might reply, start the reply listener as a background Bash task NOW — whether you keep working or are about to finish:
                ~/.claude/skills/communicate-with-user/scripts/vf listen --attach \(sessionId) --timeout 7200
                The moment they talk to your session it completes with their words and you are re-invoked. Without it, a reply sits queued until you happen to call another voice-flow tool — and can never reach you once you stop. Always start it fresh: it automatically replaces any earlier listener for this session (the old task ends itself with a superseded notice — ignore it).
                """
            }
            return .ok(reply)
        }

        var timeout = (args["timeout_seconds"] as? NSNumber)?.doubleValue ?? 1800
        timeout = min(max(timeout, 10), 14400)

        var interaction: PendingInteraction?
        DispatchQueue.main.sync {
            guard self.pendingInteraction == nil else { return }
            let created = PendingInteraction(prompt: text, sessionId: session?.id)
            self.pendingInteraction = created
            interaction = created
            let asker = self.sessionName(for: created.sessionId)
            // The ask lives ONLY in its session's thread (attached composer
            // is the signal) — never cross-posted into the assistant chat.
            self.deliverPush(
                SessionPush(title: "\(asker) asks", text: text,
                            hint: self.askHint(), isAsk: true),
                from: session?.id)
            if self.chatPanel.isVisible { self.chatPanel.refreshAgents() }
            self.playSound("Glass")
        }
        guard let interaction else {
            let busyWith = DispatchQueue.main.sync { self.pendingInteraction.map { self.sessionName(for: $0.sessionId) } }
            return .fail("\(busyWith ?? "Another session") is already blocking on a question — only one can wait at a time. Send your report without `question` now and collect the answer later via check_messages / wait_for_message.")
        }

        _ = interaction.semaphore.wait(timeout: .now() + timeout)

        var result = MCPServer.ToolResult.fail("Internal error resolving the interaction.")
        DispatchQueue.main.sync {
            interaction.resolved = true
            self.pendingInteraction = nil
            // The ask is settled either way. An ANSWERED ask stays with its
            // ↳ answer; an unanswered one (timeout / dismissed) DEGRADES to
            // a plain readable message instead of being deleted — threads
            // accumulate as history until the user completes them (Safet:
            // "nothing wrong with them, I want the history persistent").
            if let sid = interaction.sessionId {
                self.sessionPushes[sid] = self.sessionPushes[sid]?.map { push in
                    guard push.isAsk, push.answer == nil else { return push }
                    return SessionPush(at: push.at, title: push.title, text: push.text,
                                       hint: nil, isAsk: false, seen: push.seen,
                                       answer: nil, spoken: push.spoken, done: push.done)
                }
                self.refreshUnreadIndicator()
                self.chatPanel.refreshAgents()
            }
            if interaction.sessionId == nil || self.currentPushSessionId == interaction.sessionId {
                self.replyBubble.hide()
            }
            if let text = interaction.responseText {
                var payload: [String: Any] = ["response": text]
                if !interaction.attachments.isEmpty {
                    payload["screenshots"] = interaction.attachments
                    payload["note"] = "Screenshot file paths, in order — read them to see what the user showed you."
                }
                result = .ok(self.mcpJSON(payload))
            } else if interaction.cancelled {
                result = .fail("The user dismissed the prompt without answering. Don't immediately re-ask; continue as best you can or try another approach.")
            } else {
                self.replyBubble.showTransient("\(self.sessionName(for: interaction.sessionId)) stopped waiting", seconds: 6)
                result = .fail("The user didn't respond within \(Int(timeout))s. The prompt was removed from their screen.")
            }
        }
        return result
    }

    /// How a session is shown to the user: its self-chosen name when it has
    /// one, plain "Claude" when it's the only (unnamed) session, "Claude #N"
    /// otherwise. Looked up live so a later set_session_name call sticks.
    private func sessionName(for id: String?) -> String {
        guard let session = mcpServer.sessions.session(id) else { return "Claude" }
        if session.name != nil { return session.label }
        // "#N" only disambiguates against sessions the user can SEE —
        // engaged ones and ghosts, not idle connections.
        return pickerSessions().count > 1 ? session.label : "Claude"
    }

    func askHint() -> String {
        let settings = UserSettings.shared
        return "Hold \(settings.hotkey.label) to answer · \(settings.snapshotHotkey.label) +screen · \(settings.continuousCaptureHotkey.label) continuous"
    }

    private func mcpLatestCapture() -> MCPServer.ToolResult {
        guard let (directory, meta) = CaptureStore.latestBundle() else {
            return .fail("No captures yet. The user records one with the continuous-capture hotkey — or asks for one with report_to_user (question).")
        }
        var payload: [String: Any] = [
            "id": meta.id,
            "directory": directory.path,
            "recorded_at": meta.startedAt,
            "duration_seconds": Int(meta.durationSeconds),
            "transcript": meta.transcript,
            "frames": meta.frames.map { directory.appendingPathComponent($0.file).path },
            "note": "Frames are ordered by time — read them alongside the transcript.",
        ]
        var recording = false
        DispatchQueue.main.sync { recording = self.captureStore.isCapturing }
        if recording {
            payload["warning"] = "A new session is being recorded right now; this is the latest COMPLETED capture."
        }
        return .ok(mcpJSON(payload))
    }

    private func mcpListCaptures(_ args: [String: Any]) -> MCPServer.ToolResult {
        let limit = min(max((args["limit"] as? NSNumber)?.intValue ?? 10, 1), 40)
        let bundles = CaptureStore.listBundles(limit: limit)
        guard !bundles.isEmpty else {
            return .ok("No captures recorded yet. The user records one with the continuous-capture hotkey, or you can request a demonstration via report_to_user (question).")
        }
        let items: [[String: Any]] = bundles.map { directory, meta in
            [
                "id": meta.id,
                "directory": directory.path,
                "recorded_at": meta.startedAt,
                "duration_seconds": Int(meta.durationSeconds),
                "frame_count": meta.frames.count,
                "transcript_preview": String(meta.transcript.prefix(160)),
            ]
        }
        return .ok(mcpJSON([
            "captures": items,
            "note": "Newest first. Each directory has transcript.md and a frames/ folder.",
        ]))
    }

    private func mcpTakeScreenshot(_ session: MCPSession?) -> MCPServer.ToolResult {
#if VOICE_FLOW_QA
        if let fixturePath = ProcessInfo.processInfo.environment["VOICE_FLOW_QA_SCREENSHOT_FIXTURE"],
           let raw = try? Data(contentsOf: URL(fileURLWithPath: fixturePath)),
           let shot = CaptureStore.saveShot(raw, on: DisplayTopology.primary) {
            let display = DisplayTopology.primary
            if let session, let display { lastMCPDisplay[session.id] = display.id }
            let cursor = display?.screenshotPoint(forGlobalPoint: NSEvent.mouseLocation) ?? .zero
            return .ok(mcpJSON([
                "path": shot.path,
                "width": shot.width,
                "height": shot.height,
                "display_id": Int(display?.id ?? 0),
                "cursor": [Int(cursor.x.rounded()), Int(cursor.y.rounded())],
                "note": "QA fixture captured through the same bounded screenshot store.",
            ]))
        }
#endif
        let semaphore = DispatchSemaphore(value: 0)
        var outcome = MCPServer.ToolResult.fail("Screenshot failed — screen recording permission may be missing.")
        Task { @MainActor in
            defer { semaphore.signal() }
            guard let display = DisplayTopology.underMouse ?? DisplayTopology.primary,
                  let raw = try? await self.screenCapture.captureScreen(on: display),
                  let shot = CaptureStore.saveShot(raw, on: display) else { return }
            if let session {
                self.lastMCPDisplay[session.id] = display.id
            }
            // Cursor position in the same pixel space as the saved image —
            // "circle the thing I'm pointing at" needs no extra round-trip.
            let cursor = display.screenshotPoint(forGlobalPoint: NSEvent.mouseLocation)
            outcome = .ok(self.mcpJSON([
                "path": shot.path,
                "width": shot.width,
                "height": shot.height,
                "display_id": Int(display.id),
                "cursor": [Int(cursor.x.rounded()), Int(cursor.y.rounded())],
                "note": "Read this file to see the screen. Overlay/annotation coordinates are pixels in this \(shot.width)x\(shot.height) image; `cursor` is where the user's pointer is right now.",
            ]))
        }
        _ = semaphore.wait(timeout: .now() + 15)
        return outcome
    }

    // ── Inbox tools ─────────────────────────────────────

    private func inboxPayload(_ messages: [InboxMessage]) -> String {
        mcpJSON([
            "messages": messages.map { message -> [String: Any] in
                var entry: [String: Any] = ["time": message.time, "text": message.text]
                if !message.attachments.isEmpty {
                    entry["screenshots"] = message.attachments
                }
                return entry
            },
            "note": "Oldest first. Screenshot paths show what the user was looking at — read them.",
        ])
    }

    private func mcpCheckMessages(_ session: MCPSession?) -> MCPServer.ToolResult {
        let messages = inbox.drain(session: session?.id)
        guard !messages.isEmpty else {
            return .ok("No messages from the user.")
        }
        return .ok(inboxPayload(messages))
    }

    private func mcpWaitForMessage(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        var timeout = (args["timeout_seconds"] as? NSNumber)?.doubleValue ?? 600
        timeout = min(max(timeout, 5), 3600)
        let (messages, superseded) = inbox.wait(timeout: timeout, session: session?.id)
        if superseded {
            return .ok("A newer listener took over this session. Nothing to do: say nothing, end your turn, do not restart this task.")
        }
        guard !messages.isEmpty else {
            return .ok("No message arrived within \(Int(timeout))s. That's normal — call wait_for_message again to keep listening, or move on.")
        }
        return .ok(inboxPayload(messages))
    }

    // ── Overlay tools (file-backed; see swift/Overlay.swift) ──

    private static func overlayStepDicts(_ raw: Any?) -> [[String: Any]]? {
        if let strings = raw as? [String], !strings.isEmpty {
            return strings.map { ["text": $0] }
        }
        guard let array = raw as? [[String: Any]] else { return nil }
        let steps = array.compactMap { dict -> [String: Any]? in
            guard let text = dict["text"] as? String,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var step: [String: Any] = ["text": text]
            if let detail = dict["detail"] as? String, !detail.isEmpty {
                step["detail"] = detail
            }
            return step
        }
        return steps.isEmpty ? nil : steps
    }

    private func overlayWrittenResult(_ kind: String, id: String, path: String?, session: MCPSession?, extra: String = "") -> MCPServer.ToolResult {
        guard let path else {
            return .fail("Couldn't write the \(kind) overlay file.")
        }
        let visibility = notifyIfBackgroundOverlay(kind, session: session)
            ? "It is NOT on screen yet — the user is working with another session and was notified; they'll see it when they switch to you. "
            : "It is on the user's screen. "
        return .ok("\(kind.capitalized) \"\(id)\" written. \(visibility)\(extra)Its live file is \(path) — edit it directly (or via the tools) and the screen updates within ~0.5s; delete it (or remove_overlay) to dismiss. Schema: \(OverlayManager.schemaPath)")
    }

    /// A non-active session pushed something on screen — tell the user
    /// instead of drawing over what they're doing. Returns true when the
    /// element is hidden until they switch. Any thread.
    private func notifyIfBackgroundOverlay(_ kind: String, session: MCPSession?) -> Bool {
        guard let session else { return false }
        var hidden = false
        DispatchQueue.main.sync {
            hidden = session.id != self.targetSessionId
            // The note waits its turn like any receipt — never over grown
            // content or the user's recording.
            if hidden, !self.surfaceBusy {
                let index = self.pickerSessions().firstIndex { $0.id == session.id }
                let hint = index.map { " (⌃⌥\($0 + 1))" } ?? ""
                self.replyBubble.showTransient(
                    "\(self.sessionName(for: session.id)) placed a \(kind) — switch to it\(hint) to view.",
                    seconds: 8)
            }
        }
        return hidden
    }

    private func mcpShowGuide(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        guard let steps = Self.overlayStepDicts(args["steps"]) else {
            return .fail("show_guide needs a non-empty `steps` array of {text, detail?} objects.")
        }
        let id = OverlayManager.sanitize(id: args["id"] as? String) ?? "guide"
        var doc: [String: Any] = [
            "type": "guide",
            "title": args["title"] as? String ?? "Guide",
            "steps": steps,
            "active_step": max(1, (args["active_step"] as? NSNumber)?.intValue ?? 1),
            "position": args["position"] as? String ?? "center-right",
        ]
        if let note = args["note"] as? String, !note.isEmpty {
            doc["note"] = note
        }
        if let session {
            doc["session"] = session.id
        }
        let path = overlayManager.write(id: id, dict: doc)
        return overlayWrittenResult("guide", id: id, path: path, session: session,
                                    extra: "\(steps.count) steps. Advance with update_guide as the user progresses. ")
    }

    private func mcpUpdateGuide(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        let id = OverlayManager.sanitize(id: args["id"] as? String) ?? "guide"
        guard var doc = overlayManager.read(id: id), doc["type"] as? String == "guide" else {
            return .fail("No guide overlay \"\(id)\" exists — call show_guide first.")
        }
        if let active = (args["active_step"] as? NSNumber)?.intValue {
            doc["active_step"] = max(1, active)
        }
        if let note = args["note"] as? String {
            if note.isEmpty { doc.removeValue(forKey: "note") } else { doc["note"] = note }
        }
        if let title = args["title"] as? String, !title.isEmpty {
            doc["title"] = title
        }
        if let steps = Self.overlayStepDicts(args["steps"]) {
            doc["steps"] = steps
        }
        if let position = args["position"] as? String, !position.isEmpty {
            doc["position"] = position
        }
        guard overlayManager.write(id: id, dict: doc) != nil else {
            return .fail("Couldn't write the guide overlay file.")
        }
        return .ok("Guide \"\(id)\" updated.")
    }

    private func mcpShowPanel(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        guard let rawBlocks = args["blocks"] as? [[String: Any]], !rawBlocks.isEmpty else {
            return .fail("show_panel needs a non-empty `blocks` array.")
        }
        let validKinds: Set<String> = ["heading", "text", "code", "bullets"]
        let blocks = rawBlocks.filter { validKinds.contains($0["kind"] as? String ?? "") }
        guard !blocks.isEmpty else {
            return .fail("No valid blocks — each needs kind heading|text|code|bullets plus text (or items for bullets).")
        }
        let id = OverlayManager.sanitize(id: args["id"] as? String) ?? "panel"
        var doc: [String: Any] = [
            "type": "panel",
            "blocks": blocks,
            "position": args["position"] as? String ?? "center-right",
        ]
        if let title = args["title"] as? String, !title.isEmpty {
            doc["title"] = title
        }
        if let note = args["note"] as? String, !note.isEmpty {
            doc["note"] = note
        }
        if let width = (args["width"] as? NSNumber)?.doubleValue {
            doc["width"] = min(max(width, 240), 620)
        }
        if let session {
            doc["session"] = session.id
        }
        let path = overlayManager.write(id: id, dict: doc)
        return overlayWrittenResult("panel", id: id, path: path, session: session)
    }

    private func mcpAnnotateScreen(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        guard let actions = args["actions"] as? [[String: Any]], !actions.isEmpty else {
            return .fail("annotate_screen needs a non-empty `actions` array.")
        }
        var valid: [[String: Any]] = []
        var problems: [String] = []
        for (index, action) in actions.enumerated() {
            if OverlayShape.parse(action) != nil {
                valid.append(action)
            } else {
                problems.append("actions[\(index)] (\(action["type"] as? String ?? "?")) is malformed — see the annotate_screen schema")
            }
        }
        guard !valid.isEmpty else {
            return .fail("No valid actions. " + problems.joined(separator: "; "))
        }

        let id = OverlayManager.sanitize(id: args["id"] as? String) ?? "annotations"
        let clearFirst = args["clear_first"] as? Bool ?? false
        var items = valid
        if !clearFirst,
           let existing = overlayManager.read(id: id),
           existing["type"] as? String == "annotations",
           let previous = existing["items"] as? [[String: Any]] {
            items = previous + valid
        }
        var annotationsDoc: [String: Any] = ["type": "annotations", "items": items]
        if let existing = overlayManager.read(id: id),
           let displayId = existing["display_id"] as? NSNumber,
           !clearFirst {
            annotationsDoc["display_id"] = displayId
        } else if let session, let displayId = lastMCPDisplay[session.id] {
            annotationsDoc["display_id"] = Int(displayId)
        } else if let display = DisplayTopology.primary {
            annotationsDoc["display_id"] = Int(display.id)
        }
        if let session {
            annotationsDoc["session"] = session.id
        }
        let path = overlayManager.write(id: id, dict: annotationsDoc)
        guard let path else {
            return .fail("Couldn't write the annotations overlay file.")
        }
        let hidden = notifyIfBackgroundOverlay("drawing", session: session)
        var text = hidden
            ? "Drew \(valid.count) shape\(valid.count == 1 ? "" : "s") (\(items.count) total in overlay \"\(id)\") — NOT visible yet: the user is on another session and was notified; they'll see them when they switch to you. Live file: \(path)"
            : "Drew \(valid.count) shape\(valid.count == 1 ? "" : "s") on the user's screen (\(items.count) total in overlay \"\(id)\"). They stay visible — and appear in screenshots — until cleared. Live file: \(path)"
        if !problems.isEmpty {
            text += " Skipped: " + problems.joined(separator: "; ")
        }
        return .ok(text)
    }

    private func mcpRemoveOverlay(_ args: [String: Any]) -> MCPServer.ToolResult {
        guard let rawId = args["id"] as? String, !rawId.isEmpty else {
            return .fail("remove_overlay needs an `id` (or \"all\").")
        }
        if rawId == "all" {
            let removed = overlayManager.removeAll(annotationsOnly: false)
            return .ok("Removed \(removed) overlay\(removed == 1 ? "" : "s") from the user's screen.")
        }
        guard let id = OverlayManager.sanitize(id: rawId) else {
            return .fail("Invalid overlay id.")
        }
        guard overlayManager.remove(id: id) else {
            return .fail("No overlay \"\(id)\" exists. list_overlays shows what's on screen.")
        }
        return .ok("Overlay \"\(id)\" removed.")
    }

    private func mcpListOverlays() -> MCPServer.ToolResult {
        let overlays = overlayManager.list()
        guard !overlays.isEmpty else {
            return .ok("No overlays on screen. Create one with show_guide / show_panel / annotate_screen, or write a JSON file into \(OverlayManager.dir.path) (schema: \(OverlayManager.schemaPath)).")
        }
        return .ok(mcpJSON([
            "overlays": overlays.map { overlay -> [String: Any] in
                ["id": overlay.id, "type": overlay.type, "path": overlay.path, "visible": overlay.visible]
            },
            "note": "Edit any file directly and the screen re-renders within ~0.5s. Schema: \(OverlayManager.schemaPath)",
        ]))
    }

    private func mcpRecentDictations(_ args: [String: Any]) -> MCPServer.ToolResult {
        let limit = min(max((args["limit"] as? NSNumber)?.intValue ?? 10, 1), 50)
        let entries = DictationsView.recentEntries(limit: limit)
        guard !entries.isEmpty else {
            return .ok("No dictations recorded yet.")
        }
        return .ok(mcpJSON([
            "dictations": entries.map { ["time": $0.time, "text": $0.text] },
            "note": "Newest first; times are HH:mm:ss, local, from today's app session or earlier.",
        ]))
    }

    private func makeTTSStatusResponse() -> LocalAPIResponse {
        let request = chatPanel.currentTTSRequest()
        let status = ttsController.status
        return LocalAPIResponse.ok([
            "ok": true,
            "phase": status.phase.rawValue,
            "message": status.message,
            "position": status.currentTime,
            "duration": status.duration,
            "has_audio": status.hasAudio,
            "is_cached": status.isCached,
            "text": request.text,
            "voice": request.voice,
            "speed": request.speed,
            "instructions": request.instructions,
            "has_openai_api_key": KeychainStore.shared.hasOpenAIAPIKey,
            "api_base_url": localAPIServer.baseURL,
            "endpoints": [
                "GET /api/tts/status",
                "POST /api/tts/set",
                "POST /api/tts/speak",
                "POST /api/tts/seek",
                "POST /api/tts/stop",
            ],
        ])
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Agents tab data source — the panel's window onto the same per-session
//  push stacks the pill shows. Numbering ≡ the picker (⌃⌥1–6); ghosts and
//  unread state come along unchanged.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension AppDelegate: AgentsDataSource {
    private static let pushTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    func agentJobRows() -> [AgentJobRow] {
        let jobs = (try? agentJobStore?.jobs(limit: 100)) ?? []
        return jobs.map { job in
            let firstLine = job.prompt
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
            var preview = "\(job.state.rawValue) · \(job.runtime.label) · \(job.trigger.rawValue)"
            if let modelID = job.modelID { preview += " · \(modelID)" }
            if let next = job.nextRunAt, job.state == .queued {
                preview += " · " + Self.pushTimeFormatter.string(from: next)
            }
            let assistantName = AssistantsStore.shared.assistant(slug: job.assistantSlug)?.name
                ?? job.assistantSlug
            return AgentJobRow(
                id: job.id, name: title.isEmpty ? "automation" : title,
                preview: preview,
                time: Self.pushTimeFormatter.string(from: job.updatedAt),
                updatedAt: job.updatedAt, assistantName: assistantName,
                state: job.state, runtime: job.runtime,
                trigger: job.trigger, modelID: job.modelID, prompt: job.prompt)
        }
    }

    func agentAssistantRows() -> [AgentAssistantRow] {
        let definitions = AssistantsStore.shared.assistants
        let jobs = (try? agentJobStore?.jobs(limit: 500)) ?? []
        let conversations = agent?.conversations ?? []
        let baseSlug = AssistantsStore.shared.base?.slug
        return definitions.map { assistant in
            let ownedJobs = jobs.filter { $0.assistantSlug == assistant.slug }
            let ownedConversations = conversations.filter {
                $0.assistantSlug == assistant.slug
                    || ($0.assistantSlug == nil && assistant.slug == baseSlug)
            }
            let latestConversation = ownedConversations.map(\.updatedAt).max()
            let latestJob = ownedJobs.map(\.updatedAt).max()
            let updatedAt = [latestConversation, latestJob].compactMap { $0 }.max()
            return AgentAssistantRow(
                slug: assistant.slug, name: assistant.name,
                description: assistant.description,
                isDefault: assistant.slug == baseSlug,
                conversationCount: ownedConversations.filter {
                    !$0.messages.isEmpty || $0.codexThreadId != nil || $0.turnState != .idle
                }.count,
                automationCount: ownedJobs.count,
                skillCount: assistant.selectedSkills.count,
                attentionCount: ownedJobs.filter {
                    $0.state == .blocked || $0.state == .failed
                }.count + ownedConversations.filter(\.hasUnseenAssistantReply).count,
                running: ownedJobs.contains { $0.state == .running }
                    || ownedConversations.contains { $0.turnState == .running },
                updatedAt: updatedAt)
        }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            if lhs.attentionCount != rhs.attentionCount { return lhs.attentionCount > rhs.attentionCount }
            if lhs.running != rhs.running { return lhs.running }
            if lhs.updatedAt != rhs.updatedAt { return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast) }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func runAgentJob(_ jobId: String) {
        guard let agentJobStore else { return }
        do {
            try agentJobStore.runNow(jobID: jobId)
            Task { [weak self] in await self?.agentSupervisor?.wake() }
            chatPanel.refreshAgents()
        } catch {
            replyBubble.showTransient("could not run automation", seconds: 5)
        }
    }

    func cancelAgentJob(_ jobId: String) {
        Task { [weak self] in await self?.agentSupervisor?.cancel(jobID: jobId) }
        chatPanel.refreshAgents()
    }

    func setAgentJob(_ jobId: String, enabled: Bool) {
        guard let agentJobStore else { return }
        do {
            try agentJobStore.setEnabled(jobID: jobId, enabled: enabled)
            if enabled { Task { [weak self] in await self?.agentSupervisor?.wake() } }
            chatPanel.refreshAgents()
        } catch {
            replyBubble.showTransient("could not update automation", seconds: 5)
        }
    }

    func agentSessionRows() -> [AgentSessionRow] {
        let activeAssistantConversationId = agent?.currentSessionId
        let assistantNumber = assistantPickerSessionId.flatMap { id in
            slottedSessions().first { $0.id == id }?.slot
        }
        let assistantRows: [AgentSessionRow] = (agent?.conversations ?? [])
            .filter { !$0.messages.isEmpty || $0.codexThreadId != nil || $0.turnState != .idle }
            .map { conversation in
            let isActive = conversation.id == activeAssistantConversationId && assistantPickerEligible
            var preview = conversation.preview
            if preview.count > 120 { preview = String(preview.prefix(120)) + "…" }
            return AgentSessionRow(
                id: conversation.id,
                kind: .assistant,
                number: isActive ? assistantNumber : nil,
                name: conversation.title,
                preview: preview,
                time: Self.pushTimeFormatter.string(from: conversation.updatedAt),
                updatedAt: conversation.updatedAt,
                owner: conversation.assistantNameSnapshot
                    ?? conversation.assistantSlug
                    ?? DefaultAssistantWakeWord,
                unread: conversation.hasUnseenAssistantReply,
                pendingAsk: false,
                live: conversation.turnState == .running,
                archived: conversation.completedAt != nil,
                completed: conversation.completedAt != nil,
                ghost: false)
        }
        // Numbers stay ≡ the pill picker (⌃⌥N identity); the LIST order is
        // latest activity first, per the mock. No-push sessions trail in
        // picker order.
        let picker = pickerSessions().filter { !isAssistantPickerSession($0.id) }
        let pickerIds = Set(picker.map { $0.id })
        // Consumed threads (every push done) have left the pill but stay
        // browsable here until ✓-completed — numberless: they hold no
        // ⌃⌥ slot anymore (ticket #17).
        let history = sessionPushes
            .filter { !pickerIds.contains($0.key) && !$0.value.isEmpty }
            .sorted { ($0.value.last?.at ?? .distantPast) > ($1.value.last?.at ?? .distantPast) }
            .map { (id: $0.key,
                    label: mcpServer.sessions.session($0.key)?.label
                        ?? sessionLabels[$0.key] ?? Self.senderLabel($0.value)) }
        let slotted = slottedSessions().filter { !isAssistantPickerSession($0.id) }
        let slottedIds = Set(slotted.map { $0.id })
        // Eligible but unnumbered = the queue waiting for a freed slot
        // (ticket VF-48: nine sticky numbers, overflow waits).
        let queued = picker.filter { !slottedIds.contains($0.id) }
        let entries: [(id: String, label: String, number: Int?)] =
            slotted.map { ($0.id, $0.label, $0.slot) }
            + queued.map { ($0.id, $0.label, nil) }
            + history.map { ($0.id, $0.label, nil) }
        let rows = entries.map { session -> (row: AgentSessionRow, at: Date?) in
            let queue = sessionPushes[session.id] ?? []
            let newest = queue.last
            var preview = newest.map { $0.text.replacingOccurrences(of: "\n", with: " ") } ?? ""
            if hasPendingAsk(for: session.id),
               let ask = queue.last(where: { $0.isAsk && $0.answer == nil }) {
                preview = "asks: " + ask.text.replacingOccurrences(of: "\n", with: " ")
            }
            // In-progress listening state rides the preview as words, not
            // decorations (ticket VF-48, panel remark #4).
            let activePushes = queue.filter { $0.done != true }
            if let progressIdx = activePushes.lastIndex(where: { $0.resumeSentence != nil }) {
                preview = "paused · \(progressIdx + 1)/\(activePushes.count) — " + preview
            }
            if preview.count > 120 { preview = String(preview.prefix(120)) + "…" }
            let row = AgentSessionRow(
                id: session.id,
                kind: .mcp,
                number: session.number,
                name: session.label,
                preview: preview,
                time: newest.map { Self.pushTimeFormatter.string(from: $0.at) } ?? "",
                updatedAt: newest?.at ?? .distantPast,
                owner: session.label,
                unread: queue.contains { !$0.seen },
                pendingAsk: hasPendingAsk(for: session.id),
                live: false,
                archived: session.number == nil && !pickerIds.contains(session.id),
                // A numberless, no-longer-eligible row IS a consumed thread —
                // "completed"; a numberless ELIGIBLE row is just queued for
                // a slot (ticket VF-48).
                completed: session.number == nil && !pickerIds.contains(session.id),
                ghost: session.number != nil && mcpServer.sessions.session(session.id) == nil)
            return (row, newest?.at)
        }
        let mcpRows = rows.sorted {
            switch ($0.at, $1.at) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return ($0.row.number ?? .max) < ($1.row.number ?? .max)
            }
        }.map { $0.row }
        return assistantRows + mcpRows
    }

    func agentThread(for sessionId: String) -> [SessionPush] {
        sessionPushes[sessionId] ?? []
    }

    func markThreadSeen(_ sessionId: String) {
        guard let queue = sessionPushes[sessionId] else { return }
        sessionPushes[sessionId] = queue.map { push in
            var seen = push
            seen.seen = true
            return seen
        }
        refreshUnreadIndicator()
        chatPanel.refreshTabBadges()
    }

    func hasPendingAsk(for sessionId: String) -> Bool {
        guard let interaction = pendingInteraction else { return false }
        return interaction.sessionId == sessionId && !interaction.resolved
    }

    /// Typed in the panel's thread composer: resolves the session's blocked
    /// ask if one waits, otherwise queues in its inbox (delivered live to a
    /// listener, or on the session's next check-in).
    func sendMessage(toSession sessionId: String, text: String) {
        if let interaction = pendingInteraction, interaction.sessionId == sessionId, !interaction.resolved {
            fulfillInteraction(interaction, text: text, includeScreenshot: false)
            return
        }
        let live = inbox.hasWaiter(for: sessionId)
        inbox.add(text: text, attachments: [], session: sessionId)
        // The sent message must be VISIBLE in the thread, not swallowed:
        // it attaches (↳) under the newest push — the message it answers.
        if var queue = sessionPushes[sessionId], let idx = queue.indices.last {
            if queue[idx].answer == nil {
                queue[idx].answer = text
            } else {
                queue[idx].answer! += "\n↳ " + text
            }
            queue[idx].seen = true
            queue[idx].spoken = true   // replied-to = consumed (ticket #16)
            sessionPushes[sessionId] = queue
            // Replying consumes the stack: done history in the panel, out
            // of the pill's quick surfaces (ticket #14).
            markStackDone(sessionId)
            refreshUnreadIndicator()
        }
        replyBubble.showTransient(live ? "sent to \(sessionName(for: sessionId))"
                                       : "queued for \(sessionName(for: sessionId)) — delivered on its next check-in",
                                  seconds: 5)
    }

    /// The thread header's 🔊 — same read-aloud as re-selecting the session.
    func speakThread(_ sessionId: String) {
        speakSessionUnconsumed(sessionId)
    }

    /// The thread header's ✓ — the user is done with this thread: stack,
    /// session, and its overlays all go (a live session re-adopts on its
    /// next call, so this is always safe).
    func completeThread(_ sessionId: String) {
        if let interaction = pendingInteraction, interaction.sessionId == sessionId {
            interaction.cancelled = true
            interaction.semaphore.signal()
        }
        sessionPushes.removeValue(forKey: sessionId)
        inbox.cancelWait(for: sessionId)
        overlayManager.removeAll(forSession: sessionId)
        _ = mcpServer.sessions.close(sessionId)
        if targetSessionId == sessionId {
            setTargetSession(firstAvailableTarget(excluding: sessionId), announce: false)
        }
        refreshSessionIndicator()
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
        replyBubble.showTransient("thread completed", seconds: 4)
    }

    /// Read-aloud honors the consumption cursor (ticket #16): only pushes
    /// neither spoken before nor answered are read. Fully caught up? A
    /// press is an explicit request to REPLAY the stack. Playback is a
    /// SENTENCE QUEUE (ticket VF-48): skips are exact, an interrupted push
    /// keeps a resume point, and the cursor advances with the voice —
    /// a push is spoken only once the voice moved past it. Consumption to
    /// done history still lands only when playback ends (ticket #21).
    func speakSessionUnconsumed(_ sessionId: String, allowReplay: Bool = true) {
        guard let queue = sessionPushes[sessionId], !queue.isEmpty else {
            replyBubble.showTransient("nothing to read for this session", seconds: 4)
            return
        }
        let fresh = queue.indices.filter { queue[$0].spoken != true && queue[$0].answer == nil }
        let replay = fresh.isEmpty
        if replay, !allowReplay {
            // Never flashMessage here — it would stomp the grown view the
            // user is looking at (interaction audit C4/C13); showTransient
            // yields to grown content on its own.
            replyBubble.showTransient("all heard — 🔊 replays", seconds: 3)
            return
        }
        let indices = replay ? Array(queue.indices) : fresh
        let sentences = indices.map { SpeechSentencer.sentences(of: queue[$0].text) }
        let map = PlaybackQueueMap(counts: sentences.map { $0.count })
        guard map.totalChunks > 0 else {
            replyBubble.showTransient("nothing to read for this session", seconds: 4)
            return
        }
        // An interrupted first push resumes where it stopped; a replay
        // starts from the top.
        var startChunk = 0
        if !replay, let resume = queue[indices[0]].resumeSentence,
           resume > 0, resume < map.counts[0] {
            startChunk = resume
        }
        let request = chatPanel.currentTTSRequest().normalized()
        // Whatever batch was still settling settles now — only what was
        // actually heard retires (finalize filters on spoken).
        if playerContext != nil { finalizeSpeechConsumption() }
        do {
            try ttsController.beginQueuedSpeech(
                sentences: sentences.flatMap { $0 },
                voice: request.voice, speed: request.speed,
                instructions: request.instructions, startAt: startChunk)
        } catch TTSError.missingAPIKey {
            replyBubble.showTransient("add an OpenAI API key for speech — opening Settings", seconds: 5)
            showSettings()
            return
        } catch {
            replyBubble.showTransient("couldn't start speech — check the TTS settings", seconds: 5)
            return
        }
        playerContext = PlayerContext(
            source: .sessionStack(id: sessionId, indices: indices),
            sentences: sentences)
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
        refreshPlayerSurface(karaoke: true)
    }

    /// Every read-aloud that isn't a session stack lands here (VF-48
    /// unification): sentence-split the text and run it through the same
    /// queued player, so replies, selections, the Speech drawer and the
    /// HTTP API all get the band/waveform/karaoke/transport sessions have.
    @discardableResult
    private func speakTextThroughPlayer(_ text: String, source: PlayerContext.Source,
                                        request baseRequest: TTSRequest? = nil,
                                        showSettingsOnMissingKey: Bool) -> String? {
        let sentences = SpeechSentencer.sentences(of: text)
        guard !sentences.isEmpty else { return "Nothing to read." }
        var request = baseRequest ?? chatPanel.currentTTSRequest()
        request.text = text
        let normalized = request.normalized()
        chatPanel.applyTTSRequest(normalized)
        if playerContext != nil { finalizeSpeechConsumption() }
        do {
            try ttsController.beginQueuedSpeech(
                sentences: sentences, voice: normalized.voice, speed: normalized.speed,
                instructions: normalized.instructions)
        } catch {
            let message = error.localizedDescription
            chatPanel.setTTSStatus(TTSStatusSnapshot(
                phase: .error, message: message,
                currentTime: 0, duration: 0, hasAudio: false, isCached: false))
            if showSettingsOnMissingKey, let ttsError = error as? TTSError,
               case .missingAPIKey = ttsError {
                replyBubble.showTransient("add an OpenAI API key for speech — opening Settings", seconds: 5)
                showSettings()
            }
            return message
        }
        playerContext = PlayerContext(source: source, sentences: [sentences])
        refreshPlayerSurface(karaoke: true)
        return nil
    }

    /// The assistant's replies play under its own name.
    private func assistantPlayerTitle() -> String {
        agent.activeAssistant?.name ?? "Assistant"
    }

    /// Live sources (a streaming reply) grow their queue after the context
    /// is created — mirror the engine's queue into the context. Sentences
    /// only ever append, so a count check is enough.
    private func syncPlayerSentences(_ context: PlayerContext) {
        guard context.sessionId == nil else { return }
        let live = ttsController.queuedSentences
        guard !live.isEmpty, context.sentences.first?.count != live.count else { return }
        context.sentences = [live]
    }

    /// The player band's current state, or nil when no sentence queue is
    /// alive. One shape for every source (VF-48 unification). Main thread.
    private func playerStateSnapshot(compactTitle: Bool) -> FloatingIndicator.PlayerState? {
        guard let context = playerContext,
              ttsController.queuedSpeechActive,
              let chunk = ttsController.queuedChunkIndex else { return nil }
        syncPlayerSentences(context)
        let map = context.map
        let position = map.position(ofChunk: chunk)
        let title: String
        switch context.source {
        case .sessionStack(let id, _):
            let progress = "\(position.item + 1)/\(map.itemCount)"
            let label = sessionLabels[id]
                ?? pickerSessions().first { $0.id == id }?.label
                ?? "session"
            title = compactTitle ? progress : "\(label) · \(progress)"
        case .assistantReply(let name):
            title = name
        case .text(let name):
            title = name
        }
        return FloatingIndicator.PlayerState(
            title: title,
            playing: !ttsController.isPaused,
            envelope: ttsController.audioEnvelope(buckets: 18),
            // The bar reads over the WHOLE queue, same scale the scrubber
            // seeks in — one mental model (Safet QA).
            fraction: (Double(chunk) + 0.5) / Double(max(1, map.totalChunks)),
            speed: ttsController.queuedSpeed ?? UserSettings.shared.ttsSpeed)
    }

    /// One playback surface at a time (ticket VF-48): the grown stack
    /// carries the band while it shows the playing session; otherwise the
    /// one-line strip carries it. Karaoke re-renders only on sentence
    /// boundaries, not on every status tick. Main thread.
    func refreshPlayerSurface(karaoke: Bool = false) {
        // Which grown surface (if any) owns the playing content?
        let onGrownSurface: Bool
        switch playerContext?.source {
        case .sessionStack(let id, _):
            onGrownSurface = indicator.isGrownVisible && currentPushSessionId == id
        case .assistantReply:
            onGrownSurface = indicator.isGrownAssistantConversationVisible
        case .text, .none:
            onGrownSurface = false
        }
        guard let state = playerStateSnapshot(compactTitle: onGrownSurface) else {
            indicator.setGrownPlayer(nil)
            indicator.hidePlayerStrip()
            return
        }
        if onGrownSurface {
            // Karaoke first (it relayouts and restores the dots), the band
            // second (it claims the bottom band back). A still-streaming
            // reply keeps its delta renderer — karaoke starts once the
            // full text landed, so the two never fight for the text view.
            if karaoke, let context = playerContext, !context.streaming,
               let chunk = ttsController.queuedChunkIndex {
                let position = context.map.position(ofChunk: chunk)
                indicator.renderGrownKaraoke(items: context.sentences,
                                             currentItem: position.item,
                                             currentSentence: position.sentence)
            }
            indicator.setGrownPlayer(state)
        } else if indicator.isGrownVisible {
            // Some OTHER view holds the pill while audio plays: the band
            // still renders on it — full title, transport, waveform, no
            // karaoke — so playback is never invisible and uncontrollable
            // (interaction audit C2/C9).
            indicator.setGrownPlayer(state)
        } else {
            indicator.setGrownPlayer(nil)
            indicator.showPlayerStrip(state)
        }
    }

    /// The waveform is the scrubber over the WHOLE queue (Safet QA:
    /// clicking the end must land at the end): a click/drag maps its
    /// fraction onto the full sentence run. Seek unit stays the sentence.
    private func playerSeek(messageFraction: Double) {
        guard let context = playerContext else { return }
        syncPlayerSentences(context)
        let total = context.map.totalChunks
        guard total > 0 else { return }
        let target = max(0, min(total - 1, Int(messageFraction * Double(total))))
        ttsController.skipQueuedSpeech(to: target)
    }

    private func playerAdjustSpeed(_ delta: Double) {
        let current = ttsController.queuedSpeed ?? UserSettings.shared.ttsSpeed
        ttsController.setQueuedSpeed(current + delta)
        // Generation runs ahead of playback, so already-fetched sentences
        // would keep the old pace (Safet QA: clicks seemed dead until a
        // skip). Regenerate from the playhead — the change is heard NOW.
        if !ttsController.isPaused, let chunk = ttsController.queuedChunkIndex {
            ttsController.skipQueuedSpeech(to: chunk)
        }
        refreshPlayerSurface()
    }

    // ── The transport key (ticket VF-48) ────────────────
    // Press-count grammar users already know from their earbuds: 1 press =
    // play/pause, 2 = skip forward a sentence, 3 = skip back, hold = stop.
    private func transportPressBegan() {
        indicator.collapseNow()
        transportHoldFired = false
        transportHoldTimer?.invalidate()
        transportHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, self.ttsController.queuedSpeechActive else { return }
            self.transportHoldFired = true
            self.transportPressCount = 0
            self.transportResolveTimer?.invalidate()
            self.playerStop()
        }
    }

    private func transportPressEnded() {
        transportHoldTimer?.invalidate()
        transportHoldTimer = nil
        guard !transportHoldFired else { return }
        transportPressCount += 1
        transportResolveTimer?.invalidate()
        transportResolveTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) { [weak self] _ in
            self?.resolveTransportPresses()
        }
    }

    private func resolveTransportPresses() {
        let count = transportPressCount
        transportPressCount = 0
        guard count > 0 else { return }
        vflog("transport: \(count) press(es), queue active=\(ttsController.queuedSpeechActive)")
        guard ttsController.queuedSpeechActive else {
            // No player alive: a press reads the shown stack or the shown
            // reply, else it keeps the legacy read-selection/stop meaning.
            // A fully-heard stack does NOT replay from here (Safet QA: a
            // press right after a finish restarted the whole thing) — the
            // 🔊 icon and the panel remain the explicit replay paths.
            if indicator.isGrownVisible, let sid = currentPushSessionId {
                speakSessionUnconsumed(sid, allowReplay: false)
            } else if indicator.isGrownAssistantConversationVisible,
                      let reply = lastAssistantReply, !reply.isEmpty {
                speakTextThroughPlayer(reply,
                                       source: .assistantReply(title: assistantPlayerTitle()),
                                       showSettingsOnMissingKey: false)
            } else {
                speakSelectedTextOrStop()
            }
            return
        }
        switch count {
        case 1:
            ttsController.togglePause()
            refreshPlayerSurface()
        case 2:
            playerSkipSentence(1)
        default:
            playerSkipSentence(-1)
        }
    }

    private func playerSkipSentence(_ delta: Int) {
        guard let context = playerContext,
              let chunk = ttsController.queuedChunkIndex else { return }
        syncPlayerSentences(context)
        let target = max(0, min(context.map.totalChunks - 1, chunk + delta))
        vflog("transport: skip \(delta > 0 ? "+" : "")\(delta) — sentence \(chunk) → \(target) of \(context.map.totalChunks)")
        guard target != chunk else { return }
        ttsController.skipQueuedSpeech(to: target)
    }

    /// Hold = stop, the only stop there is: what was heard settles, the
    /// interrupted push keeps its resume point, the strip goes away — and
    /// nothing else happens.
    private func playerStop() {
        ttsController.stop()
        indicator.hidePlayerStrip()
        indicator.setGrownPlayer(nil)
        refreshPlayerSurface()
    }

    /// The consumption cursor moves with the voice (ticket VF-48): pushes
    /// fully behind the playhead are spoken (a soft tick marks each
    /// boundary); the one under it keeps a resume point so stopping never
    /// loses the place. Main thread.
    private func handlePlayerChunkChange(_ chunk: Int) {
        guard let context = playerContext else { return }
        guard let sid = context.sessionId, let indices = context.sessionIndices,
              var queue = sessionPushes[sid] else {
            // Sources without consumption (reply, selection, drawer) just
            // advance the karaoke and the band.
            refreshPlayerSurface(karaoke: true)
            return
        }
        let position = context.map.position(ofChunk: chunk)
        for (ordinal, index) in indices.enumerated() where queue.indices.contains(index) {
            if ordinal < position.item {
                if queue[index].spoken != true {
                    queue[index].spoken = true
                    if let tick = NSSound(named: "Tink") {
                        tick.volume = 0.2
                        tick.play()
                    }
                }
                queue[index].resumeSentence = nil
            } else if ordinal == position.item {
                queue[index].resumeSentence = position.sentence > 0 ? position.sentence : nil
            }
        }
        sessionPushes[sid] = queue
        chatPanel.refreshAgents()
        refreshPlayerSurface(karaoke: true)
    }

    /// Natural end of the whole stack: everything is heard, the end tone
    /// sounds — and deliberately NOTHING else happens (Safet's call: the
    /// end of a stack is where the user decides what's next). Main thread.
    private func handlePlayerQueueFinished() {
        if let context = playerContext, let sid = context.sessionId,
           let indices = context.sessionIndices, var queue = sessionPushes[sid] {
            for index in indices where queue.indices.contains(index) {
                queue[index].spoken = true
                queue[index].resumeSentence = nil
            }
            sessionPushes[sid] = queue
            NSSound(named: "Purr")?.play()
        }
        // Non-session sources end silently — a heard reply or selection
        // needs no receipt. Consumption to done history follows via
        // settleSpeechConsumption on the .ready status this produces.
    }

    /// Fed every TTS status change: once the speech begun by
    /// speakSessionUnconsumed leaves generating/playing — natural finish,
    /// stop, barge-in, or error — its pushes become done history and the
    /// thread leaves the pill's quick surfaces. Main thread.
    func settleSpeechConsumption(_ phase: TTSPlaybackPhase) {
        guard let context = playerContext else { return }
        switch phase {
        case .generating, .playing:
            context.playbackSeen = true
        case .idle, .ready, .error:
            // Ignore transitions from before our request actually started.
            guard context.playbackSeen else { return }
            // A paused player is not finished (ticket VF-48): the sentence
            // queue is still active, just silent — nothing settles yet.
            if ttsController.queuedSpeechActive { return }
            finalizeSpeechConsumption()
        }
    }

    private func finalizeSpeechConsumption() {
        guard let context = playerContext else { return }
        playerContext = nil
        // The compact karaoke window opens back up once listening ends —
        // the full text returns, everything marked heard (dimmed).
        let ownedGrown: Bool
        switch context.source {
        case .sessionStack(let id, _):
            ownedGrown = indicator.isGrownVisible && currentPushSessionId == id
        case .assistantReply:
            ownedGrown = indicator.isGrownAssistantConversationVisible
        case .text:
            ownedGrown = false
        }
        if ownedGrown, !context.streaming {
            indicator.renderGrownKaraoke(items: context.sentences,
                                         currentItem: -1, currentSentence: 0)
        }
        // Only session stacks have consumption to settle.
        guard let sid = context.sessionId, let indices = context.sessionIndices,
              var queue = sessionPushes[sid] else { return }
        for index in indices where queue.indices.contains(index) {
            // Only what was actually HEARD retires (ticket VF-48): an
            // interrupted push keeps its resume point and stays active,
            // and a still-unanswered ask stays hot regardless.
            guard queue[index].spoken == true,
                  !(queue[index].isAsk && queue[index].answer == nil) else { continue }
            queue[index].done = true
            queue[index].seen = true
        }
        sessionPushes[sid] = queue
        refreshSessionIndicator()
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
    }
}
