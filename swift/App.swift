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
    var dataSourceStore: DataSourceStore!
    var sourceCollector: SourceCollector!
    var sourcesView: SourcesView!
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
    var nextQueue: NextQueue!
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
    var playerContext: PlayerContext?
    /// The assistant's last finished reply — the transport's "re-read"
    /// target while its conversation is the grown surface.
    var lastAssistantReply: String?
    // Transport-key press counting (ticket VF-48).
    var transportPressCount = 0
    var transportResolveTimer: Timer?
    var transportHoldTimer: Timer?
    var transportHoldFired = false
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
    func markStackDone(_ sessionId: String) {
        guard let queue = sessionPushes[sessionId] else { return }
        sessionPushes[sessionId] = queue.map { push in
            var done = push
            done.done = true
            done.seen = true
            // VF-53: consumed by any means is consumed for the voice too —
            // otherwise a later read-aloud replays retired history from the top.
            done.spoken = true
            return done
        }
        chatPanel.refreshAgents()
    }

    /// Archive state is independent from the session registry. Reopening a
    /// retained external thread makes only its newest retained item active;
    /// history stays intact and no connection is fabricated.
    func reopenStack(_ sessionId: String) {
        guard var queue = sessionPushes[sessionId], let last = queue.indices.last else { return }
        queue[last].done = false
        sessionPushes[sessionId] = queue
        chatPanel.refreshAgents()
    }

    // Agent session
    var screenCapture: ScreenCapture!
    var captureScheduler: CaptureScheduler!
    var workflowWatcher: WorkflowWatcher!
    private var openCodeUpdateTimer: Timer?
    var agent: AgentSession!
    var agentJobStore: AgentJobStore?
    var assistantWorkspaceCoordinator: AssistantWorkspaceCoordinator!
    var agentSupervisor: AgentSupervisor?
#if VOICE_FLOW_QA
    weak var activeAgentJobAlert: NSAlert?
    weak var activeAgentJobEditor: AgentJobEditorView?
    var activeAgentJobQAWindow: NSWindow?
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
    var assistantTurnUsesReceiptPresentation = false
    var sessionActive = false
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
    var activeRunId: UUID?
    var captureRuns: [UUID: CaptureRun] = [:]
    /// Last screenshot display per MCP session. Annotation coordinates from
    /// that session stay coupled to the image the agent actually inspected.
    var lastMCPDisplay: [String: CGDirectDisplayID] = [:]
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

    var state: AppState = .loading {
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

        // VF-60: a previous session that died without applicationWillTerminate
        // (crash, force-quit, rebuild-under-a-running-app) leaves its runtime
        // orphaned on launchd, still serving. Sweep before we start our own.
        Task { await OpenCodeSupervisor.shared.reapOrphanedRuntimes() }

        // VF-44: recordings whose transcription never delivered survive as
        // WAVs — say so once per launch instead of losing them silently.
        let pendingAudio = PendingAudioStore.pendingFiles()
        if !pendingAudio.isEmpty {
            vflog("pending-audio: \(pendingAudio.count) unprocessed recording(s) from earlier runs")
            agent.note("\(pendingAudio.count) unprocessed recording(s) kept in \(PendingAudioStore.directory().path)")
        }
        scheduleOpenCodeUpdates()
        vflog("app started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        sourceCollector?.stop()
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
            await backgroundSupervisor?.shutdown()
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
        menuBar.onShowQueue = { [weak self] in self?.showNextQueueNow() }
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
        indicator.onShowQueue = { [weak self] in self?.showNextQueueNow() }
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
        chatPanel.onSelectAssistantRuntime = { [weak self] runtime, conversationID in
            guard let self else { return }
            // The picker belongs to the thread on screen, which need not be
            // the agent's current conversation — make it current first.
            guard self.agent.activateConversation(conversationID) != nil,
                  let conversation = self.agent.setPreferredRuntime(runtime) else {
                self.chatPanel.refreshAgents()
                self.replyBubble.showTransient("wait for the Assistant to finish first", seconds: 4)
                return
            }
            self.chatPanel.restoreAssistantConversation(conversation, open: true)
            self.replyBubble.showTransient("Assistant will use \(runtime.label)", seconds: 3)
        }
        chatPanel.onEscape = { [weak self] in self?.handleVoiceFlowEscape() }
        chatPanel.onContinueDictation = { [weak self] entryId in
            self?.continueDictation(appendingTo: entryId)
        }
        chatPanel.onSelectReasoningEffort = { effort in
            // The same knob as Settings → Assistant → Reasoning effort.
            UserSettings.shared.agentReasoningEffort =
                AgentReasoningEffort.normalized(effort) ?? AgentReasoningEffort.unset
            UserSettings.shared.save()
        }
        chatPanel.onSnap = { [weak self] conversationID in
            guard let self else { return }
            guard self.agent.activateConversation(conversationID) != nil else {
                self.replyBubble.showTransient("wait for the Assistant to finish first", seconds: 4)
                return
            }
            self.snapAndSend()
        }
        chatPanel.onToggleSession = { [weak self] in self?.toggleSession() }
        chatPanel.onToggleAnnotate = { [weak self] in self?.annotationOverlay.toggleEditing() }
        chatPanel.onToggleVoiceReplies = { on in
            UserSettings.shared.voiceRepliesEnabled = on
            UserSettings.shared.save()
        }
        chatPanel.onToggleControl = { on in
            // Same switch as Settings → Assistant → Computer use; the agent
            // reads the setting live (AgentSession.allowControl).
            UserSettings.shared.assistantComputerUse = on
            UserSettings.shared.save()
        }
        chatPanel.onStop = { [weak self] conversationID in
            guard let self, self.agent.currentSessionId == conversationID else { return }
            self.agent.interrupt()
            self.stopSpeechPlayback()
        }
        chatPanel.onClear = { [weak self] in
            guard let self else { return }
            let conversation = self.agent.reset()
            self.chatPanel.restoreAssistantConversation(conversation, open: true)
            self.chatPanel.setActivity(.idle, conversationID: conversation.id)
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
        configureSourceWorkspace()
        settingsWindow.onSettingsChanged = { [weak self] in
            self?.syncWorkflowWatcher()
            self?.nextQueue?.applySettings()
            self?.chatPanel?.setControlAllowed(UserSettings.shared.assistantComputerUse)
        }
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
        // The sandbox reads the granted roots and dial the same just-in-time
        // way the model gateway reads credentials, so a settings change applies
        // to the next runtime start without restarting the app (VF-59).
        AgentSandboxSettings.shared.configure {
            let settings = UserSettings.shared
            return AgentSandboxSnapshot(
                workspaceRoots: settings.agentWorkspaceRoots,
                dial: settings.agentCapabilityDial,
                egressAllowedHosts: settings.agentEgressAllowedHosts,
                egressBlockedHosts: settings.agentEgressBlockedHosts)
        }
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
                provider: "openrouter", model: UserSettings.shared.agentModel,
                reasoningEffort: UserSettings.shared.agentReasoningEffort)
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
                try? self.sendMessage(
                    toThread: AgentsThreadID(source: .mcp, value: sid), text: text)
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
            guard let self else { return }
            let settings = UserSettings.shared
            for e in entries {
                // VF-55: a kept phone note addressed to an assistant by wake
                // name triggers her here, exactly like a Mac dictation would
                // — same matcher (boundary rules, Cyrillic fallback, variant
                // routing), same serialized continuity-classified turn queue.
                // handleSync's dedupe against stored history means an
                // unchanged note never reaches this closure twice.
                if let match = PhoneNoteRouting.match(
                       kind: e.destination, text: e.text,
                       wakeEnabled: settings.assistantWakeEnabled,
                       candidates: self.assistantWakeCandidates()),
                   let assistant = AssistantsStore.shared.assistant(slug: match.slug) {
                    self.chatPanel.upsertDictation(
                        id: e.id, text: e.text, time: e.time, timestamp: e.timestamp,
                        destination: .assistant, seen: nil)
                    self.enqueueAssistantWakeTurn(
                        assistant: assistant,
                        displayText: match.prompt,
                        agentText: match.prompt,
                        screenshots: [],
                        attachmentNote: nil)
                    continue
                }
                self.chatPanel.upsertDictation(
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
        nextQueue = NextQueue(isBusy: { [weak self] in self?.surfaceBusy ?? false })
        nextQueue.applySettings()
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
        assistantWorkspaceCoordinator = AssistantWorkspaceCoordinator(
            agent: agent,
            jobStore: { [weak self] in self?.agentJobStore })
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
            self.chatPanel.refreshAgents()
        }
        agent.onActivityChanged = { [weak self] activity in
            guard let self else { return }
#if VOICE_FLOW_QA
            QAEventRecorder.shared.append("agent_activity", ["activity": activity.rawValue])
#endif
            self.indicator.setAgentActivity(activity)
            self.chatPanel.setActivity(activity, conversationID: self.agent.currentSessionId)
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
            self.chatPanel.beginAssistantThreadStream(
                conversationID: self.agent.currentSessionId)
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
            self.chatPanel.appendAssistantThreadDelta(
                delta, conversationID: self.agent.currentSessionId)
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
            self.chatPanel.finishAssistantThreadStream(
                conversationID: self.agent.currentSessionId)
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
            if let self {
                self.chatPanel.setToolDetail(detail, conversationID: self.agent.currentSessionId)
            }
            self?.replyBubble.setStatus(detail)
        }
        agent.onError = { [weak self] message in
            guard let self else { return }
#if VOICE_FLOW_QA
            QAEventRecorder.shared.append("agent_error", ["message": message])
#endif
            self.chatPanel.addNote(message)
            self.chatPanel.finishAssistantThreadStream(
                conversationID: self.agent.currentSessionId)
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
            // Nothing else re-fetches on its own: without this a long-running
            // app served whatever snapshot the last Settings visit left behind.
            refreshAgentModelCatalogIfStale()
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

    func enqueueAgentJobs(trigger: AgentJobTriggerKind,
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
            defaultModelID: defaultModel,
            defaultReasoningEffort: UserSettings.shared.agentReasoningEffort)
        editor.configureSources(
            choices: agentDataSourceOptions().map { AgentSourceChoice(id: $0.id, label: $0.title) },
            selectedIDs: assistant.selectedSourceIDs, mode: assistant.sourceAccessMode)
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
        if selectedRuntime == .opencode || editor.selectedSourceAccessMode == .reviewCopies, selectedModel == nil {
            replyBubble.showTransient("Choose an OpenRouter model or type its exact provider/model ID", seconds: 7)
            return
        }
        let selectedTrigger = editor.selectedTrigger
        let minutes = min(max(editor.intervalField.doubleValue, 1), 43_200)
        let dailyTime = editor.selectedDailyTimeMinutes
        if selectedTrigger == .daily, dailyTime == nil {
            replyBubble.showTransient("Daily time must look like 08:00", seconds: 7)
            return
        }
        let dailyBudget = min(max(editor.budgetField.doubleValue, 0), 10_000)
        let now = Date()
        let nextRun = AgentJob.nextScheduledRun(
            trigger: selectedTrigger,
            intervalSeconds: minutes * 60,
            dailyTimeMinutes: dailyTime, after: now)
        let jobID = UUID().uuidString
        let conversation = agent.createAutomationConversation(
            jobID: jobID, assistant: assistant)
        let job = AgentJob(
            id: jobID,
            assistantSlug: assistant.slug,
            conversationID: conversation.id,
            runtime: selectedRuntime, trigger: selectedTrigger,
            modelID: selectedModel,
            reasoningEffort: editor.selectedReasoningEffort,
            prompt: task, trustProfile: .unattended,
            state: nextRun == nil ? .completed : .queued,
            nextRunAt: nextRun,
            intervalSeconds: selectedTrigger == .interval ? minutes * 60 : nil,
            dailyTimeMinutes: selectedTrigger == .daily ? dailyTime : nil,
            dailyBudgetUSD: dailyBudget,
            maxDurationSeconds: 900, maxAttempts: 3,
            createdAt: now, updatedAt: now,
            selectedSourceIDs: editor.selectedSourceIDs,
            sourceAccessMode: editor.selectedSourceAccessMode)
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
        agent.note("Permission requested · \(prompt.title)")
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

    /// App-side OpenCode updates. The runtime is never allowed to update
    /// itself (see OpenCodeUpdater), so this is the only path a newer version
    /// arrives by: check on a delay after launch, then daily, and stage it.
    /// The supervisor rolls onto a staged runtime when turns have drained.
    private func scheduleOpenCodeUpdates() {
        checkForOpenCodeUpdate()
        openCodeUpdateTimer = Timer.scheduledTimer(
            withTimeInterval: OpenCodeUpdater.checkInterval, repeats: true) { [weak self] _ in
                self?.checkForOpenCodeUpdate()
            }
    }

    private func checkForOpenCodeUpdate() {
        guard UserSettings.shared.openCodeAutoUpdate else { return }
        Task.detached(priority: .background) {
            let current = OpenCodeUpdater.stagedVersion()
                ?? OpenCodeSupervisor.vendoredVersion()
                ?? "0.0.0"
            do {
                if let staged = try await OpenCodeUpdater.shared
                    .updateIfAvailable(currentVersion: current) {
                    vflog("opencode update staged: \(staged.version) (was \(current))")
                }
            } catch OpenCodeUpdaterError.notNewer {
                // The common case; not worth a log line every day.
            } catch {
                vflog("opencode update check failed: \(error.localizedDescription)")
            }
        }
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

    /// Menu bar / pill context menu: surface the next queue on demand.
    private func showNextQueueNow() {
        if UserSettings.shared.queueEnabled {
            nextQueue?.showNow()
        } else {
            replyBubble.showTransient("The next queue is off — enable it in Settings → Assistant.", seconds: 6)
        }
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

    var assistantPickerSessionId: String? {
        guard let assistant = agent?.activeAssistant else { return nil }
        return LocalAssistantSessionAdapter.id(for: assistant.slug)
    }

    func isAssistantPickerSession(_ id: String?) -> Bool {
        guard let id, let assistantId = assistantPickerSessionId else { return false }
        return id == assistantId
    }

    var assistantPickerLabel: String {
        agent?.activeAssistant?.name ?? DefaultAssistantWakeWord
    }

    var assistantPickerEligible: Bool {
        guard agent != nil, assistantPickerSessionId != nil, !assistantPickerDismissed else { return false }
        let conversation = agent.currentConversation
        return assistantWakeInFlight || agent.isRunning
            || !conversation.messages.isEmpty || conversation.codexThreadId != nil
    }

    private var assistantHasUnseenReply: Bool {
        agent?.currentConversation.hasUnseenAssistantReply == true
    }

    func firstAvailableTarget(excluding excluded: String? = nil) -> String? {
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
    func pickerSessions() -> [(id: String, label: String)] {
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
    static func senderLabel(_ queue: [SessionPush]) -> String {
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
    var sessionSlots: [String: Int] = {
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
    func slottedSessions() -> [(slot: Int, id: String, label: String)] {
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
    func pickerEntries() -> (entries: [FloatingIndicator.PickerEntry], activeName: String?) {
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
    var surfaceBusy: Bool {
        indicator.isGrownVisible
            || state == .recording || state == .processing || state == .handsFree
    }

    /// Sessions (other than `excluded`) holding pushes the user hasn't
    /// seen — ghosts included: unread messages outlive their session and
    /// stay reachable via the picker until read or trashed. Main thread.
    private func unseenSessions(excluding excluded: String? = nil) -> Int {
        // Read-only: assigning sessionPushes here rewrote pushes.json on every
        // one of the ~35 unread-indicator refreshes. Empty queues are dropped
        // by the 60 s sweep; skipping them is enough for the count.
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
    /// Done history is bounded like every other store (captures 40, pushes
    /// per session 40): the newest `maxKeptConsumedSessions` fully-consumed,
    /// disconnected stacks stay browsable under Threads → Done; older ones go,
    /// and the label sweep drops their names. Anything unread, pending, being
    /// read, or still connected is never touched — this only trims history
    /// the user has already dealt with, which had grown to 150+ sessions.
    private let maxKeptConsumedSessions = 40
    private func pruneConsumedHistory() {
        let openInPanel = chatPanel.openAgentThreadId
        let consumed = sessionPushes.filter { sid, queue in
            mcpServer.sessions.session(sid) == nil
                && sid != currentPushSessionId
                && sid != playerContext?.sessionId
                && sid != openInPanel
                && !queue.isEmpty
                && queue.allSatisfy { $0.done == true }
        }
        guard consumed.count > maxKeptConsumedSessions else { return }
        let stale = consumed
            .sorted { ($0.value.last?.at ?? .distantPast) > ($1.value.last?.at ?? .distantPast) }
            .dropFirst(maxKeptConsumedSessions)
            .map { $0.key }
        var kept = sessionPushes
        for sid in stale { kept.removeValue(forKey: sid) }
        sessionPushes = kept
        vflog("sessions: pruned \(stale.count) consumed stacks beyond the newest \(maxKeptConsumedSessions)")
    }

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
    func userSelectSession(_ id: String) {
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
    func handleVoiceFlowEscape() {
        if annotationOverlay?.isEditing == true {
            annotationOverlay.endEditing()
            return
        }
        if agent?.activity == .acting {
            agent.interrupt()
            stopSpeechPlayback()
            chatPanel.addNote("Stopped by Escape")
        }
        if chatPanel?.handleMissionControlEscape() == true { return }
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

    private func sendTypedMessage(_ text: String, images: [String] = []) {
        if let interaction = pendingInteraction {
            chatPanel.addNote("Sent to Claude.")
            fulfillInteraction(interaction, text: text, includeScreenshot: false,
                               extraAttachments: images)
            return
        }
        sendToAgent(text: text, includeFreshScreenshot: sessionActive,
                    extraImagePaths: images)
    }

    /// Hand the user's answer to the MCP tool call that's blocked on it.
    /// If that call already timed out, the answer goes to the inbox instead
    /// so Claude still gets it on its next check-in.
    func fulfillInteraction(_ interaction: PendingInteraction, text: String,
                                    includeScreenshot: Bool,
                                    archiveAfterAnswer: Bool = true,
                                    extraAttachments: [String] = []) {
        Task { @MainActor in
            var attachments: [String] = extraAttachments
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
                            clearStack: archiveAfterAnswer)
        }
    }

    /// Same interaction contract for evidence already frozen by CaptureRun.
    /// Never takes a later screenshot or consults the current target session.
    func fulfillInteraction(_ interaction: PendingInteraction, text: String,
                                    attachments: [String],
                                    archiveAfterAnswer: Bool = true) {
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
                        clearStack: archiveAfterAnswer)
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

    func sendToAgent(text: String?, includeFreshScreenshot: Bool,
                             forceScreenshot: Bool = false,
                             extraImagePaths: [String] = []) {
        assistantTurnUsesReceiptPresentation = false
        if !chatPanel.isVisible {
            currentPushSessionId = nil   // grown shows agent content now
            replyBubble.showThinking(echo: text)
        }

        Task { @MainActor in
            // Images the user pasted into the composer ride the same channel
            // as a snapshot — the model sees them, not a path it has to open.
            var screenshots: [Data] = extraImagePaths.compactMap {
                FileManager.default.contents(atPath: $0)
            }
            if includeFreshScreenshot || forceScreenshot {
                if let fresh = try? await screenCapture.captureScreen() {
                    screenshots.append(fresh)
                    lastCaptureData = fresh
                }
            }

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

    private static func attachmentNote(count: Int, noun: String = "screenshot") -> String? {
        switch count {
        case 0: return nil
        case 1: return "📎 1 \(noun)"
        default: return "📎 \(count) \(noun)s"
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
        // existing run; the next press starts the contextual one. isBusy (not
        // isRecording) so a press landing inside the stop's drain window is a
        // harmless notice instead of a start that destroys the draining audio
        // (VF-44).
        if recorder.isBusy,
           let id = activeRunId, let run = captureRuns[id],
           case .historyOnly = run.route, deliveryPolicy == .contextual {
            stopCapture()
            replyBubble.showTransient(run.appendEntryId != nil
                                        ? "continuation captured — press again to dictate"
                                        : "kept in Inbox — press again to dictate", seconds: 5)
            return
        }
        guard !recorder.isBusy else { return }

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
            // VF-44: keep the raw audio recoverable until the transcript is
            // delivered — a transcription failure, crash, or quit mid-
            // processing must not lose recorded speech.
            PendingAudioStore.save(pcm: pcmData, runId: id, sampleRate: 16000)
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
            agent.note("\(message) Raw audio kept in \(PendingAudioStore.directory().path)")
            let audioURL = PendingAudioStore.directory().appendingPathComponent("\(id.uuidString).wav")
            let recoveryMessage = FileManager.default.fileExists(atPath: audioURL.path)
                ? "couldn't transcribe — recording saved for recovery"
                : "couldn't transcribe — \(message)"
            replyBubble.showTransient(recoveryMessage,
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

    func maybeDeliverCapture(_ id: UUID) {
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
            PendingAudioStore.remove(runId: id)
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
        PendingAudioStore.remove(runId: id)
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

    func playSound(_ name: String) {
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
    func stopSpeechPlayback() {
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
#if VOICE_FLOW_QA
        // A synthetic-input QA copy runs beside the real app and never needs
        // Accessibility; its permissions window would only land on the user.
        if HotkeyManager.qaSyntheticInputIsolationEnabled { return }
#endif
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

    func showSettings() {
        showDock()
        settingsWindow.prepareForPresentation()
        chatPanel.show(focusInput: false)
        chatPanel.showWorkspaceDestination(.settings)
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
    func speakSelectedTextOrStop() {
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
            // Assigning sessionPushes rewrites pushes.json (hundreds of KB);
            // only do it when the sweep actually drops something.
            let nonEmpty = self.sessionPushes.filter { _, queue in !queue.isEmpty }
            if nonEmpty.count != self.sessionPushes.count { self.sessionPushes = nonEmpty }
            // Consumed, finished sessions leave the picker so their slot
            // numbers free for the queue (ticket VF-48).
            self.retireConsumedGhosts()
            self.pruneConsumedHistory()
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

}
