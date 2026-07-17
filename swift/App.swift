import Cocoa
import AVFoundation
import CoreGraphics

// ── App State ───────────────────────────────────────────
enum AppState: String {
    case idle, loading, recording, processing, done, handsFree
}

// What the microphone is currently recording for.
enum RecordingPurpose {
    case dictation   // paste into the focused app
    case brainDump   // record into Voice Flow only — kept in the Inbox, never pasted
    case talk        // voice note → agent, no screenshot
    case snapTalk    // voice note → agent + one fresh screenshot
    case session     // continuous session audio, bundled at session end
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
    var sessionHotkeyManager: HotkeyManager!
    var talkHotkeyManager: HotkeyManager!
    var snapTalkHotkeyManager: HotkeyManager!
    var annotateHotkeyManager: HotkeyManager!
    var recorder: AudioRecorder!
    var backend: BackendBridge!
    var paster: Paster!
    var ttsController: TTSController!
    var localAPIServer: LocalAPIServer!
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
    }
    /// Persisted to pushes.json — unread stacks must survive app restarts,
    /// not just session deaths. A session re-adopting its old id reclaims
    /// its queue; the rest show as ghost picker entries.
    var sessionPushes: [String: [SessionPush]] = [:] {
        didSet { Self.savePushes(sessionPushes) }
    }
    private let maxQueuedPushes = 8

    private static let pushesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voice-flow/pushes.json")

    private static func savePushes(_ pushes: [String: [SessionPush]]) {
        if let data = try? JSONEncoder().encode(pushes) {
            try? data.write(to: pushesURL, options: .atomic)
        }
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
                                  hint: nil, isAsk: false, seen: push.seen)
                    : push
            }
        }
    }
    /// Which session's push is currently displayed (trash targets it).
    var currentPushSessionId: String?

    // Agent session
    var screenCapture: ScreenCapture!
    var captureScheduler: CaptureScheduler!
    var workflowWatcher: WorkflowWatcher!
    var agent: AgentSession!
    private var sessionActive = false
    private var lastCaptureData: Data?
    private let diffThreshold: Double = 0.01
    private var ambientScreenshots: [Data] = []
    private let maxAmbientScreenshots = 7
    // Frames collected during a session, waiting for the end-of-session send.
    private var pendingSessionShots: [Data] = []
    private var escapeMonitor: Any?

    private var recordingPurpose: RecordingPurpose = .dictation
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
                indicator?.setState(state, recordingFor: recordingPurpose)
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
            // Same list, order, and numbering as the picker and ⌃⌥1–6 —
            // two orderings of the same sessions would be a routing trap.
            return self.pickerSessions().enumerated().map { index, entry in
                let age = self.mcpServer.sessions.session(entry.id)
                    .map { "active \(Self.relativeAge($0.lastSeen))" } ?? "ended — unread"
                return (entry.id,
                        "\(index + 1) · \(entry.label) — \(age)",
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
            _ = self.mcpServer.sessions.close(id)   // nil for a ghost — fine
            self.sessionPushes.removeValue(forKey: id)
            // Its stack may be the thing on screen right now.
            if self.currentPushSessionId == id {
                self.currentPushSessionId = nil
                self.replyBubble.hide()
            }
            if self.targetSessionId == id {
                self.setTargetSession(self.mcpServer.sessions.list().first { $0.engaged }?.id, announce: false)
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
                    Task { @MainActor in
                        if let shot = try? await self.screenCapture.captureScreen() {
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
            let waiting = self.unseenSessions(excluding: closed)
            guard waiting > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard !self.indicator.isGrownVisible else { return }
                self.indicator.flashMessage(
                    "\(waiting) session\(waiting == 1 ? "" : "s") waiting — ⌃⌥1–6", seconds: 4)
            }
        }
        // Trash means "I'm done with this one": it cancels a waiting ask,
        // clears the whole push stack, AND disconnects the session — its
        // picker dot goes too (a live session quietly re-adopts on its
        // next tool call, so this is always safe).
        replyBubble.onTrashed = { [weak self] in
            guard let self else { return }
            // Cancel only an ask that belongs to the trashed stack — a
            // DIFFERENT session's pending ask must survive this click.
            if let interaction = self.pendingInteraction,
               interaction.sessionId == self.currentPushSessionId {
                interaction.cancelled = true
                interaction.semaphore.signal()
            }
            if let id = self.currentPushSessionId {
                self.sessionPushes.removeValue(forKey: id)
                if let closed = self.mcpServer.sessions.close(id) {
                    if self.targetSessionId == id {
                        self.setTargetSession(self.mcpServer.sessions.list().first { $0.engaged }?.id, announce: false)
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
            guard let self, !text.isEmpty else { return }
            var request = self.chatPanel.currentTTSRequest()
            request.text = text
            _ = self.handleTTSSpeak(request.normalized(), reveal: false, showSettingsOnMissingKey: false)
        }


        overlayManager = OverlayManager()
        overlayManager.start()

        chatPanel = ChatPanel()
        chatPanel.onShown = { [weak self] in self?.replyBubble.hide() }
        chatPanel.agentsDataSource = self
        chatPanel.onSendText = { [weak self] text in self?.sendTypedMessage(text) }
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
            self?.agent.reset()
            self?.chatPanel.clearConversation()
            self?.chatPanel.setActivity(.idle)
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
        settingsWindow.onSessionHotkeyChanged = { [weak self] spec in
            self?.sessionHotkeyManager.updateSpec(spec)
        }
        settingsWindow.onTalkHotkeyChanged = { [weak self] spec in
            self?.talkHotkeyManager.updateSpec(spec)
        }
        settingsWindow.onSnapTalkHotkeyChanged = { [weak self] spec in
            self?.snapTalkHotkeyManager.updateSpec(spec)
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
        recorder = AudioRecorder()
        paster = Paster()
        captureStore = CaptureStore()
        inbox = MessageInbox()
        ttsController = TTSController()
        ttsController.onStatusChanged = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.indicator.setTTSStatus(snapshot)
                self?.chatPanel.setTTSStatus(snapshot)
            }
        }
        replySpeaker = AgentReplySpeaker(tts: ttsController)

        backend = BackendBridge()
        backend.onReady = { [weak self] in
            self?.state = .idle
            vflog("backend ready — dictation available")
        }
        backend.onResult = { [weak self] raw, cleaned in
            self?.handleResult(raw: raw, cleaned: cleaned)
        }
        backend.onPartialResult = { [weak self] text, requestId in
            self?.handlePartialResult(text: text, requestId: requestId)
        }
        backend.onError = { [weak self] msg in
            vflog("backend error: \(msg)")
            guard let self else { return }
            let purpose = self.recordingPurpose
            self.recordingPurpose = .dictation
            self.state = .idle
            switch purpose {
            case .talk, .snapTalk, .brainDump:
                self.chatPanel.addNote("Couldn't transcribe that — try again.")
                if !self.chatPanel.isVisible {
                    self.replyBubble.showTransient("couldn't transcribe — try again", seconds: 5, isError: true)
                }
            case .session:
                self.chatPanel.addNote("Couldn't transcribe the session audio — keeping the screenshots on their own.")
                self.finishSession(transcript: nil)
            case .dictation:
                break
            }
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
        agent.onActivityChanged = { [weak self] activity in
            guard let self else { return }
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
            self.chatPanel.beginAssistantMessage()
            if !self.chatPanel.isVisible {
                // The grown surface now shows a reply, not a push stack —
                // trash/double-select must not hit a stale session.
                self.currentPushSessionId = nil
                self.replyBubble.beginStreaming()
            }
            if UserSettings.shared.voiceRepliesEnabled {
                self.replySpeaker.begin()
            }
        }
        agent.onAssistantDelta = { [weak self] delta in
            self?.chatPanel.appendAssistantDelta(delta)
            self?.replyBubble.appendDelta(delta)
            self?.replySpeaker.append(delta)
        }
        agent.onAssistantDone = { [weak self] text in
            guard let self else { return }
            self.chatPanel.finishAssistantMessage(text)
            self.replyBubble.finishStreaming(text)
            self.replySpeaker.finish()
        }
        agent.onToolActivity = { [weak self] detail in
            self?.chatPanel.setToolDetail(detail)
            self?.replyBubble.setStatus(detail)
        }
        agent.onError = { [weak self] message in
            guard let self else { return }
            self.chatPanel.addNote(message)
            self.replySpeaker.finish()
            if !self.chatPanel.isVisible {
                self.replyBubble.showNote(message)
            }
        }

        // Escape is the panic button while the agent is acting.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.agent.activity == .acting else { return }
            self.agent.interrupt()
            self.stopSpeechPlayback()
            self.chatPanel.addNote("Stopped by Escape")
        }
    }

    private func setupHotkeys() {
        hotkeyManager = HotkeyManager(spec: UserSettings.shared.hotkey)
        hotkeyManager.onPress = { [weak self] in self?.startRecording() }
        hotkeyManager.onRelease = { [weak self] in self?.stopRecording() }
        hotkeyManager.allowsHandsFreeDoublePress = false

        // Double-tap = brain dump: talk into Voice Flow's Inbox from anywhere,
        // no paste target involved (ticket #2).
        handsFreeHotkeyManager = HotkeyManager(spec: UserSettings.shared.handsFreeHotkey)
        handsFreeHotkeyManager.allowsHandsFreeDoublePress = true
        handsFreeHotkeyManager.onHandsFree = { [weak self] active in
            guard let self else { return }
            if active {
                self.startBrainDumpRecording()
            } else {
                self.stopRecording()
            }
        }

        ttsHotkeyManager = HotkeyManager(spec: UserSettings.shared.ttsHotkey)
        ttsHotkeyManager.onPress = { [weak self] in
            self?.indicator.collapseNow()
            self?.speakSelectedTextOrStop()
        }

        sessionHotkeyManager = HotkeyManager(spec: UserSettings.shared.sessionHotkey)
        sessionHotkeyManager.onPress = { [weak self] in
            self?.indicator.collapseNow()   // any other hotkey closes the picker
            self?.toggleSession()
        }

        talkHotkeyManager = HotkeyManager(spec: UserSettings.shared.talkHotkey)
        talkHotkeyManager.onPress = { [weak self] in self?.startTalkRecording(purpose: .talk) }
        talkHotkeyManager.onRelease = { [weak self] in self?.stopTalkRecording() }

        snapTalkHotkeyManager = HotkeyManager(spec: UserSettings.shared.snapTalkHotkey)
        snapTalkHotkeyManager.onPress = { [weak self] in self?.startTalkRecording(purpose: .snapTalk) }
        snapTalkHotkeyManager.onRelease = { [weak self] in self?.stopTalkRecording() }

        annotateHotkeyManager = HotkeyManager(spec: UserSettings.shared.annotateHotkey)
        annotateHotkeyManager.onPress = { [weak self] in
            self?.indicator.collapseNow()
            self?.annotationOverlay.toggleEditing()
        }

        // ⌃⌥1–6: jump straight to a Claude session (order = connect order,
        // mirrored by the session strip's chip numbers).
        let numberKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22]   // 1…6
        sessionSwitchHotkeyManagers = numberKeyCodes.enumerated().map { index, keyCode in
            let manager = HotkeyManager(spec: HotkeySpec(
                keyCode: keyCode,
                modifiers: [.maskControl, .maskAlternate],
                label: "⌃⌥\(index + 1)"))
            manager.onPress = { [weak self] in self?.switchToSession(at: index) }
            return manager
        }
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
        sessionHotkeyManager.start()
        talkHotkeyManager.start()
        snapTalkHotkeyManager.start()
        annotateHotkeyManager.start()
        sessionSwitchHotkeyManagers.forEach { $0.start() }
    }

    @objc private func showPermissionsMenuAction() { showPermissions() }
    @objc private func showSettingsMenuAction() { showSettings() }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Session — the one mode
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
        guard !sessionActive else { return }
        if UserSettings.shared.sessionSendToAgent, !KeychainStore.shared.hasAgentAPIKey {
            chatPanel.show(focusInput: false)
            chatPanel.addNote("Add your OpenRouter key in Settings, or turn off sending sessions to the assistant.")
            showSettings()
            return
        }
        guard !recorder.isRecording else {
            chatPanel.addNote("Finish the current recording, then start a session.")
            return
        }
        stopSpeechPlayback()
        sessionActive = true
        ambientScreenshots.removeAll()
        pendingSessionShots.removeAll()
        lastCaptureData = nil
        captureStore.beginSession()
        captureScheduler.interval = TimeInterval(max(1, UserSettings.shared.captureIntervalSeconds))
        captureScheduler.start()

        // The whole session is one long voice note — transcribed and bundled
        // with the collected screenshots when the session ends.
        recordingPurpose = .session
        recorder.start()
        if !recorder.isRecording {
            recordingPurpose = .dictation
            replyBubble.showTransient("microphone unavailable — screenshots only", seconds: 8, isError: true)
        }

        indicator.setSessionActive(true)
        menuBar.setSessionActive(true)
        chatPanel.setSessionActive(true)
        chatPanel.addNote(pendingInteraction != nil
            ? "Recording a demonstration for Claude — stop the session to send it."
            : "Session started — capturing your voice and screen. Stop to save the capture.")
        playSound("Tink")
        vflog("session started")
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
        vflog("session ended")

        Task { @MainActor in
            // Final frame: how the screen looks the moment the session ends.
            if let fresh = try? await screenCapture.captureScreen() {
                pendingSessionShots.append(fresh)
                captureStore.addFrame(fresh)
            }
            if recorder.isRecording, recordingPurpose == .session {
                stopRecording()   // → transcribe → handleResult(.session) → finishSession
            } else {
                recordingPurpose = .dictation
                finishSession(transcript: nil)
            }
        }
    }

    /// Ambient screenshots build quiet context while a session runs —
    /// deduped so an unchanged screen doesn't pile up frames.
    private func handleAmbientCapture(_ imageData: Data) {
        if let previous = lastCaptureData {
            let diff = ImageUtils.difference(previous, imageData)
            if diff < diffThreshold { return }
        }
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

    /// A session just produced its transcript (or failed to) — turn
    /// everything collected into a capture bundle and route it: to the
    /// waiting MCP interaction if Claude asked, to the in-app agent when
    /// that legacy path is enabled, otherwise offer it to the user for
    /// Claude Code.
    private func finishSession(transcript: String?) {
        let summary = captureStore.endSession(transcript: transcript)

        // Claude is literally waiting on this demonstration.
        if let interaction = pendingInteraction, let summary {
            pendingSessionShots.removeAll()
            interaction.attachments = summary.framePaths
            interaction.responseText = summary.transcript.isEmpty
                ? "(no narration — the screenshots are the demonstration)"
                : summary.transcript
            interaction.semaphore.signal()
            replyBubble.showTransient("Demonstration sent to \(sessionName(for: interaction.sessionId)) — \(summary.frameCount) frames.", seconds: 5)
            return
        }

        if UserSettings.shared.sessionSendToAgent {
            sendSessionBundle(transcript: transcript)
            if let summary, chatPanel.isVisible {
                chatPanel.addNote("Capture also saved to \(summary.directory.path)")
            }
            return
        }

        pendingSessionShots.removeAll()
        guard let summary else {
            chatPanel.addNote("Session ended — nothing captured.")
            if !chatPanel.isVisible {
                replyBubble.showTransient("session ended — nothing captured", seconds: 5)
            }
            return
        }

        let frames = "\(summary.frameCount) frame\(summary.frameCount == 1 ? "" : "s")"
        let stats = "\(frames) · \(Int(summary.durationSeconds))s"
        // Hand the capture to the active session automatically: instantly
        // if it's listening, otherwise queued + surfaced by the piggyback
        // nudge on its next Voice Flow call. The menu bar keeps the manual
        // copy-prompt fallback for unconnected sessions.
        if let target = mcpServer.sessions.session(targetSessionId) {
            let live = inbox.hasWaiter(for: target.id)
            inbox.add(
                text: "I recorded a Voice Flow capture (\(stats)). Fetch it with get_latest_capture, or read \(summary.transcriptPath) and the frames it lists in order.",
                attachments: [],
                session: target.id)
            replyBubble.showTransient("capture saved — \(sessionName(for: target.id)) \(live ? "got it" : "is told next check-in")", seconds: 6)
        } else {
            replyBubble.showTransient("capture saved — no session; menu bar has the prompt", seconds: 8)
        }
        if chatPanel.isVisible {
            chatPanel.addNote("Capture saved to \(summary.directory.path)")
        }
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
        // Only ENGAGED sessions are user-visible — a connected-but-silent
        // session (every Claude Code session initializes every MCP server)
        // has nothing for the user to switch to.
        let live = mcpServer.sessions.ordered().filter { $0.engaged }
            .map { (id: $0.id, label: $0.label) }
        let liveIds = Set(live.map { $0.id })
        let ghosts = sessionPushes
            .filter { !liveIds.contains($0.key) && !$0.value.isEmpty }
            .sorted { ($0.value.last?.at ?? .distantPast) < ($1.value.last?.at ?? .distantPast) }
            .map { (id: $0.key, label: Self.senderLabel($0.value)) }
        return live + ghosts
    }

    /// A ghost has no registry entry anymore — its newest push remembers
    /// who sent it.
    private static func senderLabel(_ queue: [SessionPush]) -> String {
        let title = queue.last?.title ?? "Claude"
        return title.hasSuffix(" asks") ? String(title.dropLast(5)) : title
    }

    /// The picker's view of the world: one entry per live-or-ghost session
    /// (active lit, pending amber) plus the active entry's name.
    /// Main thread.
    private func pickerEntries() -> (entries: [FloatingIndicator.PickerEntry], activeName: String?) {
        let sessions = pickerSessions()
        let entries = sessions.enumerated().map { index, session in
            FloatingIndicator.PickerEntry(
                number: index + 1,
                active: session.id == targetSessionId,
                // Amber means "something is waiting on you" — an unseen
                // push, an unanswered ask, or an undelivered inbox message.
                // A fully-read stack stays previewable but not amber.
                pending: inbox.pendingCount(for: session.id) > 0
                    || pendingInteraction?.sessionId == session.id
                    || sessionPushes[session.id]?.contains { !$0.seen } == true)
        }
        return (entries, sessions.first { $0.id == targetSessionId }?.label)
    }

    /// Single entry for changing which Claude session owns the user's
    /// voice + screen: routes hotkeys, swaps that session's overlays in,
    /// and updates the pill (middle-dot number + picker row). Main thread.
    func setTargetSession(_ id: String?, announce: Bool) {
        targetSessionId = id
        overlayManager.setActiveSession(id)
        refreshSessionIndicator()
        refreshUnreadIndicator()
        if announce {
            let (entries, activeName) = pickerEntries()
            if let id, let queue = sessionPushes[id], !queue.isEmpty {
                // The session has something to show — the picker grows
                // straight into its whole stack, picker row at the bottom.
                // Unseen content stays up until ✕ (this IS the reading
                // path); an already-seen stack is just a 5s re-preview.
                currentPushSessionId = id
                let hasUnseen = queue.contains { !$0.seen }
                showPushStack(for: id, bottomPicker: (entries, activeName),
                              autoHide: hasUnseen ? nil : 5.0)
            } else {
                indicator.showPicker(entries: entries, activeName: activeName)
            }
        }
    }

    /// Keep the pill's middle-dot session number current.
    func refreshSessionIndicator() {
        indicator.setActiveSessionNumber(
            pickerSessions().firstIndex { $0.id == targetSessionId }.map { $0 + 1 })
    }

    /// Queue a push and announce it with a one-line receipt — the full
    /// text NEVER takes the screen on arrival, no matter whose session it
    /// is, and audio never auto-plays. The user reads it by switching onto
    /// the session (⌃⌥1–6 grows its whole stack), re-selects to hear it,
    /// or opens the Messages tab; the ring + amber picker dot persist
    /// until the stack is actually viewed. Main thread.
    func deliverPush(_ push: SessionPush, from sessionId: String?) {
        let sid = sessionId ?? ""
        var queue = sessionPushes[sid] ?? []
        // An agent re-sending the same thing (retry loops, "did you hear
        // me?" spam) collapses into one entry instead of filling the stack.
        if let last = queue.last, last.text == push.text, last.isAsk == push.isAsk {
            queue.removeLast()
        }
        queue.append(push)
        if queue.count > maxQueuedPushes { queue.removeFirst(queue.count - maxQueuedPushes) }
        sessionPushes[sid] = queue
        // The permanent record — the Messages tab keeps every push even
        // after its session expires or the stack is trashed.
        chatPanel.addAgentMessage(time: Self.timestamp(), session: push.title,
                                  text: push.text, isAsk: push.isAsk)
        refreshUnreadIndicator()

        // A push for the stack that's ALREADY on screen refreshes it in
        // place — updating what the user is reading isn't taking the screen.
        if indicator.isGrownVisible, currentPushSessionId == sid {
            showPushStack(for: sid)
            return
        }

        // The receipt: one line, ~4s, only when nothing else owns the
        // surface — never over grown content, never while the user talks.
        guard !surfaceBusy else { return }
        var receipt = push.isAsk ? push.title : "\(push.title) · new message"
        if let index = pickerSessions().firstIndex(where: { $0.id == sid }) {
            receipt += " — ⌃⌥\(index + 1)"
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
        guard let queue = sessionPushes[sessionId], let newest = queue.last else { return }
        let ask = queue.last { $0.isAsk }
        indicator.showGrown(
            FloatingIndicator.GrownSpec(
                title: (ask ?? newest).title,
                text: newest.text,
                earlier: queue.dropLast().map { $0.text },
                hint: ask?.hint,
                isAsk: ask != nil),
            bottomPicker: bottomPicker,
            autoHide: autoHide)
        sessionPushes[sessionId] = queue.map { push in
            var seen = push
            seen.seen = true
            return seen
        }
        refreshUnreadIndicator()
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
        return sessionPushes.filter { sid, queue in
            sid != excluded && queue.contains { !$0.seen }
        }.count
    }

    /// The pill's small pulsing ring around the number dot: on while ANY
    /// session holds pushes the user hasn't viewed yet (viewing = growing
    /// its stack by switching onto it). Main thread.
    func refreshUnreadIndicator() {
        indicator.setUnreadIndicator(unseenSessions() > 0)
    }

    /// User-initiated selection (⌃⌥N / menu bar). Double-select = a second
    /// press while the first press's stack is already on screen: THAT reads
    /// the messages aloud (Settings toggle). Merely being the default
    /// target doesn't count — the first press must SHOW, never speak.
    /// Main thread.
    private func userSelectSession(_ id: String) {
        if id == targetSessionId, indicator.isGrownVisible, currentPushSessionId == id,
           UserSettings.shared.doubleSelectSpeak,
           let queue = sessionPushes[id], !queue.isEmpty {
            var request = chatPanel.currentTTSRequest()
            request.text = queue.map(\.text).joined(separator: "\n\n")
            _ = handleTTSSpeak(request.normalized(), reveal: false, showSettingsOnMissingKey: false)
            return
        }
        setTargetSession(id, announce: true)
    }

    /// The user answered what was on screen by voice — the view collapses
    /// and the receipt lands after it. When the answer actually reached a
    /// session, its stack is also done with (the Messages tab keeps the
    /// history). Main thread.
    private func answeredSession(_ id: String?, note: String, clearStack: Bool) {
        if clearStack, let id {
            sessionPushes.removeValue(forKey: id)
            refreshUnreadIndicator()
        }
        currentPushSessionId = nil
        replyBubble.hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            self.replyBubble.showTransient(note, seconds: 6)
        }
    }

    /// ⌃⌥1–6. Any select attempt — valid or aimed at a missing number —
    /// opens the picker showing what's actually available. Main thread.
    private func switchToSession(at index: Int) {
        // Repaint the badge and ring against what actually exists before
        // acting on it — the look itself may have expired live sessions.
        refreshSessionIndicator()
        refreshUnreadIndicator()
        let sessions = pickerSessions()
        guard index < sessions.count else {
            let (entries, activeName) = pickerEntries()
            indicator.showPicker(entries: entries, activeName: activeName)
            return
        }
        userSelectSession(sessions[index].id)
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
            if includeScreenshot,
               let raw = try? await screenCapture.captureScreen(),
               let shot = CaptureStore.saveShot(raw) {
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
            // the stack survives as read history — trash still deletes it.
            attachAnswer(text, to: interaction.sessionId)
            answeredSession(interaction.sessionId,
                            note: "answer sent to \(sessionName(for: interaction.sessionId))",
                            clearStack: false)
        }
    }

    /// Record the user's reply on the newest unanswered ask push of the
    /// session, so the panel's thread shows question and answer together.
    private func attachAnswer(_ text: String, to sessionId: String?) {
        guard let sid = sessionId, var queue = sessionPushes[sid] else { return }
        guard let index = queue.lastIndex(where: { $0.isAsk && $0.answer == nil }) else { return }
        queue[index].answer = text
        queue[index].seen = true
        sessionPushes[sid] = queue
        chatPanel.refreshAgents()
    }

    /// No question pending — a talk message goes to the target Claude
    /// session: instantly when it's listening (parked in wait_for_message),
    /// otherwise QUEUED in its inbox — a running session is nudged on its
    /// next tool call, a finished one is woken by its background listener.
    /// Only with no target session at all does the message fall back to the
    /// clipboard + dictation history.
    private func deliverTalkMessage(text: String, includeScreenshot: Bool) {
        Task { @MainActor in
            var attachments: [String] = []
            if includeScreenshot,
               let raw = try? await screenCapture.captureScreen(),
               let shot = CaptureStore.saveShot(raw) {
                attachments.append(shot.path)
            }
            let target = mcpServer.sessions.session(targetSessionId)
            if let target {
                let live = inbox.hasWaiter(for: target.id)
                inbox.add(text: text, attachments: attachments, session: target.id)
                answeredSession(target.id,
                                note: live ? "sent to \(sessionName(for: target.id))"
                                           : "queued for \(sessionName(for: target.id)) — delivered on its next check-in",
                                clearStack: live)
                return
            }
            // A session parked in wait_for_message takes it even when no
            // target is registered — clients from before session ids exist
            // send no id, yet a live listener is unambiguous.
            if inbox.hasWaiter(for: nil) {
                inbox.add(text: text, attachments: attachments, session: nil)
                answeredSession(nil, note: "sent to Claude", clearStack: false)
                return
            }
            let prompt = Self.messagePrompt(text: text, attachments: attachments)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            chatPanel.addDictation(text: prompt, time: Self.timestamp(),
                                   destination: .kept, seen: false)
            // The stack stays (nothing was delivered), but the screen must
            // still visibly react to having been spoken to.
            answeredSession(nil, note: "no session — copied + saved in History", clearStack: false)
        }
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

    /// Everything gathered between session start and stop, sent as one turn.
    private func sendSessionBundle(transcript: String?) {
        var shots = pendingSessionShots
        pendingSessionShots.removeAll()
        let maxShots = 8   // matches the agent's image-history budget
        if shots.count > maxShots {
            shots = Array(shots.suffix(maxShots))
        }

        let trimmed = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty || !shots.isEmpty else {
            chatPanel.addNote("Session ended — nothing captured.")
            return
        }

        let preamble = "I just finished a screen session. The screenshots show what I was doing, in order — annotations I drew are part of the message."
        let agentText = trimmed.isEmpty
            ? preamble
            : "\(preamble) My spoken notes while working: \(trimmed)"

        if !chatPanel.isVisible {
            replyBubble.showThinking(echo: trimmed.isEmpty ? "Session recap" : trimmed)
        }
        chatPanel.addUserMessage(trimmed, attachmentNote: Self.attachmentNote(count: shots.count))
        deliverToAgent(agentText, screenshots: shots, retriesLeft: 2)
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
        agent.send(text: text, screenshots: screenshots)
    }

    private static func attachmentNote(count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "📎 1 screenshot"
        default: return "📎 \(count) screenshots"
        }
    }

    // ── Talk to the agent (hold-to-record) ─────────────

    private func startTalkRecording(purpose: RecordingPurpose) {
        indicator.collapseNow()   // any other hotkey closes the picker
        guard !recorder.isRecording else { return }
        stopSpeechPlayback()   // barge-in: don't record the agent's own voice
        recordingPurpose = purpose
        streamingViaAX = false
        hadPartialStream = false
        playSound("Tink")
        state = .recording
        recorder.start()
        guard recorder.isRecording else {
            state = .idle
            recordingPurpose = .dictation
            replyBubble.showTransient("microphone unavailable — restart Voice Flow", seconds: 8, isError: true)
            return
        }
        vflog("talk-to-agent recording started (\(purpose))")
    }

    private func stopTalkRecording() {
        guard recordingPurpose == .talk || recordingPurpose == .snapTalk else { return }
        stopRecording()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Dictation flow
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func startRecording() {
        indicator.collapseNow()   // any other hotkey closes the picker
        guard !recorder.isRecording else { return }
        stopSpeechPlayback()
        recordingPurpose = .dictation
        paster.capturePasteTarget()
        streamingViaAX = false
        hadPartialStream = false
        playSound("Tink")
        state = .recording
        recorder.start()
        if !recorder.isRecording {
            state = .idle
            replyBubble.showTransient("microphone unavailable — restart Voice Flow", seconds: 8, isError: true)
        }
    }

    /// Continuous recording that lands in the Inbox as a kept brain dump —
    /// no paste target is captured, so the frontmost app never matters.
    private func startBrainDumpRecording() {
        indicator.collapseNow()
        guard !recorder.isRecording else { return }
        stopSpeechPlayback()
        recordingPurpose = .brainDump
        streamingViaAX = false
        hadPartialStream = false
        playSound("Tink")
        state = .handsFree
        recorder.start()
        if !recorder.isRecording {
            state = .idle
            recordingPurpose = .dictation
            replyBubble.showTransient("microphone unavailable — restart Voice Flow", seconds: 8, isError: true)
        }
    }

    private func stopRecording() {
        guard recorder.isRecording else { return }
        partialTimer?.invalidate()
        partialTimer = nil
        transcriptPanel.hide()
        recorder.stop { [weak self] pcmData in
            guard let self else { return }
            if let pcmData {
                self.state = .processing
                let settings = UserSettings.shared
                let provider = settings.dictationProvider
                let skipCleanup = provider != .local || !settings.llmCleanupEnabled
                vflog("final dictation provider=\(provider.rawValue)")

                let openAIAPIKey: String?
                if provider == .openai {
                    openAIAPIKey = KeychainStore.shared.loadOpenAIAPIKey()
                    if openAIAPIKey == nil {
                        vflog("OpenAI dictation selected, but no API key is saved")
                        self.state = .idle
                        let purpose = self.recordingPurpose
                        self.recordingPurpose = .dictation
                        switch purpose {
                        case .dictation:
                            self.showSettings()
                        case .talk, .snapTalk, .brainDump:
                            self.chatPanel.addNote("Add your OpenAI key in Settings to transcribe voice notes.")
                        case .session:
                            self.chatPanel.addNote("No OpenAI key — keeping the session screenshots without a transcript.")
                            self.finishSession(transcript: nil)
                        }
                        return
                    }
                } else {
                    openAIAPIKey = nil
                }

                self.backend.transcribe(
                    pcmData: pcmData,
                    sampleRate: 16000,
                    provider: provider,
                    skipCleanup: skipCleanup,
                    openAIAPIKey: openAIAPIKey,
                    vocabulary: settings.customVocabulary
                )
            } else {
                let purpose = self.recordingPurpose
                self.recordingPurpose = .dictation
                self.state = .idle
                if self.recorder.lastCaptureBytes == 0 {
                    self.replyBubble.showTransient("no audio from the microphone", seconds: 8, isError: true)
                } else if self.recorder.lastCaptureWasSilent {
                    self.replyBubble.showTransient("didn't catch any speech")
                }
                if purpose == .session {
                    self.finishSession(transcript: nil)
                }
            }
        }
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
        guard recorder.isRecording,
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
            requestId: partialRequestId,
            openAIAPIKey: openAIAPIKey,
            vocabulary: settings.customVocabulary
        )
    }

    private func handlePartialResult(text: String, requestId: Int) {
        vflog("partial result \(requestId): \"\(text)\" (state=\(state.rawValue))")
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

    // ── final result ────────────────────────────────────

    private func handleResult(raw: String, cleaned: String) {
        vflog("raw: \(raw)")
        vflog("cleaned: \(cleaned)")

        // Voice destined for the agent — never pasted anywhere.
        if recordingPurpose != .dictation {
            let purpose = recordingPurpose
            recordingPurpose = .dictation
            paster.clearStreamTarget()
            hadPartialStream = false
            state = .idle
            let note = (cleaned.isEmpty ? raw : cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            switch purpose {
            case .talk:
                guard !note.isEmpty else { return }
                playSound("Pop")
                if let interaction = pendingInteraction {
                    fulfillInteraction(interaction, text: note, includeScreenshot: false)
                } else if UserSettings.shared.talkSendToAgent {
                    sendToAgent(text: note, includeFreshScreenshot: false)
                } else {
                    deliverTalkMessage(text: note, includeScreenshot: false)
                }
            case .snapTalk:
                guard !note.isEmpty else { return }
                playSound("Pop")
                if let interaction = pendingInteraction {
                    fulfillInteraction(interaction, text: note, includeScreenshot: true)
                } else if UserSettings.shared.talkSendToAgent {
                    sendToAgent(text: note, includeFreshScreenshot: true, forceScreenshot: true)
                } else {
                    deliverTalkMessage(text: note, includeScreenshot: true)
                }
            case .session:
                playSound("Pop")
                finishSession(transcript: note)
            case .brainDump:
                guard !note.isEmpty else {
                    replyBubble.showTransient("didn't catch any speech")
                    return
                }
                playSound("Pop")
                let timestamp = Self.timestamp()
                DispatchQueue.main.async {
                    self.chatPanel.addDictation(text: note, time: timestamp,
                                                destination: .kept, seen: false)
                    self.replyBubble.showTransient("kept in Inbox")
                }
            case .dictation:
                break
            }
            return
        }

        if cleaned.isEmpty {
            if hadPartialStream {
                paster.streamText("")
            }
            paster.clearStreamTarget()
            hadPartialStream = false
            state = .idle
            return
        }

        if hadPartialStream {
            // Partial text is in the field via AX — do final update with cleaned text
            vflog("final AX update with cleaned text")
            paster.streamText(cleaned)
            paster.clearStreamTarget()
            hadPartialStream = false
        } else {
            // No streaming (short recording or AX unsupported) — paste normally
            paster.clearStreamTarget()
            vflog("pasting text...")
            paster.paste(cleaned)
        }
        playSound("Pop")
        let timestamp = Self.timestamp()
        DispatchQueue.main.async {
            self.chatPanel.addDictation(text: cleaned, time: timestamp)
        }
        state = .done
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if self.state == .done { self.state = .idle }
        }
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
        if phase == .playing || phase == .generating {
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

        var request = chatPanel.currentTTSRequest()
        request.text = selectedText
        let normalized = request.normalized()
        chatPanel.applyTTSRequest(normalized)
        _ = handleTTSSpeak(normalized, reveal: false, showSettingsOnMissingKey: true)
    }

    private func setupLocalAPIServer() {
        localAPIServer = LocalAPIServer()
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
                // An unread stack survives its session as a ghost picker
                // entry; only read residue leaves with it.
                if self.sessionPushes[closed.id]?.contains(where: { !$0.seen }) != true {
                    self.sessionPushes.removeValue(forKey: closed.id)
                }
                self.refreshUnreadIndicator()
                if self.targetSessionId == closed.id {
                    self.setTargetSession(self.mcpServer.sessions.list().first { $0.engaged }?.id, announce: false)
                    if let next = self.mcpServer.sessions.session(self.targetSessionId) {
                        self.replyBubble.showTransient("\(closed.label) ended — now talking to \(next.label)", seconds: 5)
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
        // keeps them honest. It NEVER touches unread stacks — those stay
        // as readable ghost entries; it only clears read residue of dead
        // sessions and re-targets off an entry that no longer exists.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let live = Set(self.mcpServer.sessions.ordered().map { $0.id })
            self.sessionPushes = self.sessionPushes.filter { sid, queue in
                !queue.isEmpty && (live.contains(sid) || queue.contains { !$0.seen })
            }
            if self.targetSessionId != nil,
               !self.pickerSessions().contains(where: { $0.id == self.targetSessionId }) {
                self.setTargetSession(self.mcpServer.sessions.list().first { $0.engaged }?.id, announce: false)
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

        do {
            try ttsController.speak(request: normalized)
            return nil
        } catch {
            let message = error.localizedDescription
            let currentStatus = ttsController.status
            chatPanel.setTTSStatus(TTSStatusSnapshot(
                phase: .error,
                message: message,
                currentTime: currentStatus.currentTime,
                duration: currentStatus.duration,
                hasAudio: currentStatus.hasAudio,
                isCached: currentStatus.isCached
            ))
            if showSettingsOnMissingKey,
               let ttsError = error as? TTSError,
               case .missingAPIKey = ttsError {
                showSettings()
            }
            return message
        }
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
                if self.mcpServer.sessions.session(self.targetSessionId)?.engaged != true {
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
        case "take_screenshot": return mcpTakeScreenshot()
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
            var reply = "Delivered: the user got a one-line receipt and reads the full report when they switch onto your session (⌃⌥N) or in their Messages tab; audio plays only on their demand."
            if let sessionId {
                reply += """
                 If they might reply, start the reply listener as a background Bash task NOW — whether you keep working or are about to finish:
                ~/.claude/skills/communicate-with-user/scripts/vf listen --attach \(sessionId) --timeout 7200
                The moment they talk to your session it completes with their words and you are re-invoked. Without it, a reply sits queued until you happen to call another voice-flow tool — and can never reach you once you stop.
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
            self.deliverPush(
                SessionPush(title: "\(asker) asks", text: text,
                            hint: self.askHint(), isAsk: true),
                from: session?.id)
            if self.chatPanel.isVisible {
                self.chatPanel.addNote("\(asker) asks: \(text)")
            }
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
            // The ask is settled either way — drop IT from the stack (any
            // queued notifies survive as pending) and give the screen back,
            // unless another session's content took it in the meantime.
            if let sid = interaction.sessionId {
                self.sessionPushes[sid]?.removeAll { $0.isAsk }
                if self.sessionPushes[sid]?.isEmpty == true {
                    self.sessionPushes.removeValue(forKey: sid)
                }
                self.refreshUnreadIndicator()
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
        return "Hold \(settings.talkHotkey.label) to answer · \(settings.snapTalkHotkey.label) +screen · \(settings.sessionHotkey.label) demo"
    }

    private func mcpLatestCapture() -> MCPServer.ToolResult {
        guard let (directory, meta) = CaptureStore.latestBundle() else {
            return .fail("No captures yet. The user records one with the session hotkey — or ask for one with report_to_user (question).")
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
            return .ok("No captures recorded yet. The user records one with the session hotkey, or you can request a demonstration via report_to_user (question).")
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

    private func mcpTakeScreenshot() -> MCPServer.ToolResult {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome = MCPServer.ToolResult.fail("Screenshot failed — screen recording permission may be missing.")
        Task { @MainActor in
            defer { semaphore.signal() }
            guard let raw = try? await self.screenCapture.captureScreen(),
                  let shot = CaptureStore.saveShot(raw) else { return }
            // Cursor position in the same pixel space as the saved image —
            // "circle the thing I'm pointing at" needs no extra round-trip.
            let location = CGEvent(source: nil)?.location ?? .zero
            let scale = CaptureStore.annotationPointScale()
            outcome = .ok(self.mcpJSON([
                "path": shot.path,
                "width": shot.width,
                "height": shot.height,
                "cursor": [Int(location.x / scale), Int(location.y / scale)],
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
        let messages = inbox.wait(timeout: timeout, session: session?.id)
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

    func agentSessionRows() -> [AgentSessionRow] {
        pickerSessions().enumerated().map { index, session in
            let queue = sessionPushes[session.id] ?? []
            let newest = queue.last
            var preview = newest.map { $0.text.replacingOccurrences(of: "\n", with: " ") } ?? ""
            if hasPendingAsk(for: session.id),
               let ask = queue.last(where: { $0.isAsk && $0.answer == nil }) {
                preview = "asks: " + ask.text.replacingOccurrences(of: "\n", with: " ")
            }
            return AgentSessionRow(
                id: session.id,
                number: index + 1,
                name: session.label,
                preview: preview,
                time: newest.map { Self.pushTimeFormatter.string(from: $0.at) } ?? "",
                unread: queue.contains { !$0.seen },
                ghost: mcpServer.sessions.session(session.id) == nil)
        }
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
        replyBubble.showTransient(live ? "sent to \(sessionName(for: sessionId))"
                                       : "queued for \(sessionName(for: sessionId)) — delivered on its next check-in",
                                  seconds: 5)
    }

    /// The thread header's 🔊 — same read-aloud as re-selecting the session.
    func speakThread(_ sessionId: String) {
        guard let queue = sessionPushes[sessionId], !queue.isEmpty else { return }
        var request = chatPanel.currentTTSRequest()
        request.text = queue.map(\.text).joined(separator: "\n\n")
        _ = handleTTSSpeak(request.normalized(), reveal: false, showSettingsOnMissingKey: false)
    }
}
