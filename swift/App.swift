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
    let sessionLabel: String?   // "Claude #2" for display
    let semaphore = DispatchSemaphore(value: 0)
    var responseText: String?
    var attachments: [String] = []   // absolute screenshot/frame paths
    var cancelled = false
    /// Set (on main) once the blocked tool call has returned — a late
    /// answer must go to the inbox instead of this dead interaction.
    var resolved = false

    init(prompt: String, sessionId: String?, sessionLabel: String?) {
        self.prompt = prompt
        self.sessionId = sessionId
        self.sessionLabel = sessionLabel
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
    /// Set while an MCP ask_user call is waiting for the human. Main thread only.
    var pendingInteraction: PendingInteraction?
    /// Which Claude Code session the talk hotkeys feed (newest connection
    /// by default; switchable via the menu bar). Main thread only.
    var targetSessionId: String?

    // Agent session
    var screenCapture: ScreenCapture!
    var captureScheduler: CaptureScheduler!
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
        menuBar.onCopyCapturePrompt = { [weak self] in self?.copyLatestCapturePrompt() }
        menuBar.claudeSessionsProvider = { [weak self] in
            guard let self else { return [] }
            return self.mcpServer.sessions.list().map { session in
                (session.id,
                 "\(session.label) — active \(Self.relativeAge(session.lastSeen))",
                 session.id == self.targetSessionId)
            }
        }
        menuBar.onSelectClaudeSession = { [weak self] id in
            guard let self else { return }
            self.targetSessionId = id
            if let session = self.mcpServer.sessions.session(id) {
                self.replyBubble.showNote("Talk hotkeys now go to \(session.label).")
            }
        }
        menuBar.onToggleAnnotate = { [weak self] in self?.annotationOverlay.toggleEditing() }
        menuBar.onShowChat = { [weak self] in self?.chatPanel.show() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        indicator = FloatingIndicator()
        indicator.onClick = { [weak self] in self?.chatPanel.toggle() }
        indicator.onShowHistory = { [weak self] in self?.toggleHistory() }
        indicator.onToggleSession = { [weak self] in self?.toggleSession() }
        indicator.onToggleAnnotate = { [weak self] in self?.annotationOverlay.toggleEditing() }
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

        replyBubble = ReplyBubble()
        replyBubble.onClosed = { [weak self] in
            // ✕ on a pending Claude question = "not answering this one".
            guard let self, let interaction = self.pendingInteraction else { return }
            interaction.cancelled = true
            interaction.semaphore.signal()
        }

        overlayManager = OverlayManager()
        overlayManager.start()

        chatPanel = ChatPanel()
        chatPanel.onShown = { [weak self] in self?.replyBubble.hide() }
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
            case .talk, .snapTalk:
                self.chatPanel.addNote("Couldn't transcribe that — try again.")
                if !self.chatPanel.isVisible {
                    self.replyBubble.showNote("Couldn't transcribe that — try again.")
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

        handsFreeHotkeyManager = HotkeyManager(spec: UserSettings.shared.handsFreeHotkey)
        handsFreeHotkeyManager.allowsHandsFreeDoublePress = true
        handsFreeHotkeyManager.onHandsFree = { [weak self] active in
            guard let self else { return }
            if active {
                self.startRecording()
                self.state = .handsFree
            } else {
                self.stopRecording()
            }
        }

        ttsHotkeyManager = HotkeyManager(spec: UserSettings.shared.ttsHotkey)
        ttsHotkeyManager.onPress = { [weak self] in self?.speakSelectedTextOrStop() }

        sessionHotkeyManager = HotkeyManager(spec: UserSettings.shared.sessionHotkey)
        sessionHotkeyManager.onPress = { [weak self] in self?.toggleSession() }

        talkHotkeyManager = HotkeyManager(spec: UserSettings.shared.talkHotkey)
        talkHotkeyManager.onPress = { [weak self] in self?.startTalkRecording(purpose: .talk) }
        talkHotkeyManager.onRelease = { [weak self] in self?.stopTalkRecording() }

        snapTalkHotkeyManager = HotkeyManager(spec: UserSettings.shared.snapTalkHotkey)
        snapTalkHotkeyManager.onPress = { [weak self] in self?.startTalkRecording(purpose: .snapTalk) }
        snapTalkHotkeyManager.onRelease = { [weak self] in self?.stopTalkRecording() }

        annotateHotkeyManager = HotkeyManager(spec: UserSettings.shared.annotateHotkey)
        annotateHotkeyManager.onPress = { [weak self] in self?.annotationOverlay.toggleEditing() }
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
    }

    @objc private func showPermissionsMenuAction() { showPermissions() }
    @objc private func showSettingsMenuAction() { showSettings() }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Session — the one mode
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func toggleSession() {
        if sessionActive { endSession() } else { startSession() }
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
            replyBubble.showNote("Couldn't start the microphone — the session will capture screenshots only.")
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
            replyBubble.showNote("Demonstration sent to Claude — \(summary.frameCount) frames.")
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
                replyBubble.showNote("Session ended — nothing captured.")
            }
            return
        }

        let frames = "\(summary.frameCount) frame\(summary.frameCount == 1 ? "" : "s")"
        let text = "Capture saved — \(frames) · \(Int(summary.durationSeconds))s.\nTell Claude Code to get your latest capture, or copy a ready-made prompt."
        let prompt = summary.claudePrompt
        replyBubble.showNote(text, actionTitle: "Copy prompt for Claude", action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
        })
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

    /// Menu-bar route to the same prompt the post-session bubble offers —
    /// for when that bubble is long dismissed.
    private func copyLatestCapturePrompt() {
        guard let (directory, meta) = CaptureStore.latestBundle() else {
            replyBubble.showNote("No captures yet — record one with the session hotkey (\(UserSettings.shared.sessionHotkey.label)).")
            return
        }
        let prompt = CaptureSummary.claudePrompt(
            transcriptPath: directory.appendingPathComponent("transcript.md").path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        replyBubble.showNote("Prompt for capture \(meta.id) copied — paste it into Claude Code.")
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
                replyBubble.showNote("Claude had stopped waiting — your answer is queued for its next check-in.")
                return
            }
            interaction.attachments.append(contentsOf: attachments)
            interaction.responseText = text
            interaction.semaphore.signal()
            replyBubble.showNote("Answer sent to Claude.")
        }
    }

    /// No question pending — queue a talk-hotkey message in the target
    /// Claude session's inbox (delivered instantly when it's parked in
    /// wait_for_message).
    private func queueInboxMessage(text: String, includeScreenshot: Bool) {
        Task { @MainActor in
            var attachments: [String] = []
            if includeScreenshot,
               let raw = try? await screenCapture.captureScreen(),
               let shot = CaptureStore.saveShot(raw) {
                attachments.append(shot.path)
            }
            // A vanished target (session gone, none left) degrades to an
            // unscoped message any session may pick up.
            let target = mcpServer.sessions.session(targetSessionId)
            let name = (mcpServer.sessions.count > 1 ? target?.label : nil) ?? "Claude"
            let delivered = inbox.hasWaiter(for: target?.id)
            inbox.add(text: text, attachments: attachments, session: target?.id)
            replyBubble.showNote(delivered
                ? "Sent to \(name)."
                : "Queued for \(name) — delivered when it next checks in.")
        }
    }

    private func snapAndSend() {
        sendToAgent(text: nil, includeFreshScreenshot: true, forceScreenshot: true)
    }

    private func sendToAgent(text: String?, includeFreshScreenshot: Bool, forceScreenshot: Bool = false) {
        if !chatPanel.isVisible {
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
            replyBubble.showNote("Couldn't start the microphone — check it's connected, or restart Voice Flow.")
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
            replyBubble.showNote("Couldn't start the microphone — check it's connected, or restart Voice Flow.")
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
                        case .talk, .snapTalk:
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
                    self.replyBubble.showNote("The microphone delivered no audio — it may have changed or be in use. Restart Voice Flow if this keeps happening.")
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
                    queueInboxMessage(text: note, includeScreenshot: false)
                }
            case .snapTalk:
                guard !note.isEmpty else { return }
                playSound("Pop")
                if let interaction = pendingInteraction {
                    fulfillInteraction(interaction, text: note, includeScreenshot: true)
                } else if UserSettings.shared.talkSendToAgent {
                    sendToAgent(text: note, includeFreshScreenshot: true, forceScreenshot: true)
                } else {
                    queueInboxMessage(text: note, includeScreenshot: true)
                }
            case .session:
                playSound("Pop")
                finishSession(transcript: note)
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
        if CGPreflightScreenCaptureAccess() {
            vflog("screen capture permission already granted")
            refreshPermissionWindow()
            return
        }
        let granted = CGRequestScreenCaptureAccess()
        vflog(granted ? "screen capture permission granted" : "screen capture permission not yet granted")
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
        chatPanel.selectTab(.dictations)
    }

    private func showSettings() {
        showDock()
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
        chatPanel.selectTab(.speech)
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
        mcpServer.onSessionConnected = { [weak self] session in
            DispatchQueue.main.async {
                guard let self else { return }
                self.targetSessionId = session.id
                self.replyBubble.showNote(self.mcpServer.sessions.count > 1
                    ? "\(session.label) connected — your talk hotkeys now go to it (switch in the menu bar)."
                    : "Claude Code connected to Voice Flow.")
            }
        }
        localAPIServer.onMCP = { [weak self] body, sessionId in
            self?.mcpServer.handle(body: body, sessionId: sessionId) ?? (503, nil, nil)
        }
        localAPIServer.onMCPSessionEnd = { [weak self] sessionId in
            guard let self, let closed = self.mcpServer.sessions.close(sessionId) else { return }
            DispatchQueue.main.async {
                if self.targetSessionId == closed.id {
                    self.targetSessionId = self.mcpServer.sessions.list().first?.id
                    if let next = self.mcpServer.sessions.session(self.targetSessionId) {
                        self.replyBubble.showNote("\(closed.label) disconnected — talk hotkeys go to \(next.label) now.")
                        return
                    }
                }
                self.replyBubble.showNote("\(closed.label) disconnected.")
            }
        }
        localAPIServer.start()
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
    //  ask_user deliberately blocks — its result IS the user's answer.

    private func handleMCPTool(_ name: String, _ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        switch name {
        case "ask_user": return mcpAskUser(args, session)
        case "notify_user": return mcpNotifyUser(args, session)
        case "check_messages": return mcpCheckMessages(session)
        case "wait_for_message": return mcpWaitForMessage(args, session)
        case "get_latest_capture": return mcpLatestCapture()
        case "list_captures": return mcpListCaptures(args)
        case "take_screenshot": return mcpTakeScreenshot()
        case "show_guide": return mcpShowGuide(args)
        case "update_guide": return mcpUpdateGuide(args)
        case "show_panel": return mcpShowPanel(args)
        case "annotate_screen": return mcpAnnotateScreen(args)
        case "clear_annotations":
            let removed = overlayManager.removeAll(annotationsOnly: true)
            DispatchQueue.main.sync { self.annotationOverlay.clear() }
            return .ok("Cleared \(removed) annotation overlay\(removed == 1 ? "" : "s") and the user's own marks.")
        case "remove_overlay": return mcpRemoveOverlay(args)
        case "list_overlays": return mcpListOverlays()
        case "speak": return mcpSpeak(args)
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

    private func mcpAskUser(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        let prompt = (args["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return .fail("ask_user needs a non-empty `prompt`.")
        }
        let speakAloud = args["speak_aloud"] as? Bool ?? false
        var timeout = (args["timeout_seconds"] as? NSNumber)?.doubleValue ?? 900
        timeout = min(max(timeout, 10), 3600)

        var interaction: PendingInteraction?
        DispatchQueue.main.sync {
            guard self.pendingInteraction == nil else { return }
            let created = PendingInteraction(prompt: prompt, sessionId: session?.id,
                                             sessionLabel: session?.label)
            self.pendingInteraction = created
            interaction = created
            self.presentAsk(prompt: prompt, speakAloud: speakAloud, from: self.askerName(created))
        }
        guard let interaction else {
            return .fail("Another ask_user request is already waiting for the user — wait for it to resolve.")
        }

        _ = interaction.semaphore.wait(timeout: .now() + timeout)

        var result = MCPServer.ToolResult.fail("Internal error resolving the interaction.")
        DispatchQueue.main.sync {
            interaction.resolved = true
            self.pendingInteraction = nil
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
                self.replyBubble.showNote("Claude stopped waiting for an answer.")
                result = .fail("The user didn't respond within \(Int(timeout))s. The prompt was removed from their screen.")
            }
        }
        return result
    }

    /// "Claude #2" when several sessions are connected, plain "Claude"
    /// when there's only one. Main thread.
    private func askerName(_ interaction: PendingInteraction) -> String {
        guard mcpServer.sessions.count > 1, let label = interaction.sessionLabel else {
            return "Claude"
        }
        return label
    }

    /// Main thread. Put Claude's question where the user will see it.
    private func presentAsk(prompt: String, speakAloud: Bool, from asker: String) {
        let settings = UserSettings.shared
        let hint = "Hold \(settings.talkHotkey.label) to answer · \(settings.snapTalkHotkey.label) +screen · \(settings.sessionHotkey.label) demo"
        replyBubble.showAsk(prompt: "\(asker) asks: \(prompt)", hint: hint)
        if chatPanel.isVisible {
            chatPanel.addNote("\(asker) asks: \(prompt)")
        }
        playSound("Glass")
        if speakAloud {
            var request = chatPanel.currentTTSRequest()
            request.text = prompt
            _ = handleTTSSpeak(request.normalized(), reveal: false, showSettingsOnMissingKey: false)
        }
    }

    private func mcpLatestCapture() -> MCPServer.ToolResult {
        guard let (directory, meta) = CaptureStore.latestBundle() else {
            return .fail("No captures yet. The user records one with the session hotkey — or use ask_user to request a demonstration.")
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
            return .ok("No captures recorded yet. The user records one with the session hotkey, or you can request a demonstration via ask_user.")
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

    private func mcpNotifyUser(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .fail("notify_user needs non-empty `text`.")
        }
        let speakAloud = args["speak_aloud"] as? Bool ?? false
        DispatchQueue.main.sync {
            let settings = UserSettings.shared
            let sender = (self.mcpServer.sessions.count > 1 ? session?.label : nil) ?? "Claude"
            self.replyBubble.showNote(
                "\(sender): \(text)",
                actionTitle: nil, action: nil
            )
            self.replyBubble.setStatus("Reply anytime: hold \(settings.talkHotkey.label) · \(settings.snapTalkHotkey.label) +screen")
            if self.chatPanel.isVisible {
                self.chatPanel.addNote("Claude: \(text)")
            }
            self.playSound("Glass")
            if speakAloud {
                var request = self.chatPanel.currentTTSRequest()
                request.text = text
                _ = self.handleTTSSpeak(request.normalized(), reveal: false, showSettingsOnMissingKey: false)
            }
        }
        return .ok("Shown to the user. Any reply lands in the inbox — fetch it with check_messages or wait_for_message.")
    }

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

    private func overlayWrittenResult(_ kind: String, id: String, path: String?, extra: String = "") -> MCPServer.ToolResult {
        guard let path else {
            return .fail("Couldn't write the \(kind) overlay file.")
        }
        return .ok("\(kind.capitalized) \"\(id)\" is on the user's screen. \(extra)Its live file is \(path) — edit it directly (or via the tools) and the screen updates within ~0.5s; delete it (or remove_overlay) to dismiss. Schema: \(OverlayManager.schemaPath)")
    }

    private func mcpShowGuide(_ args: [String: Any]) -> MCPServer.ToolResult {
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
        let path = overlayManager.write(id: id, dict: doc)
        return overlayWrittenResult("guide", id: id, path: path,
                                    extra: "\(steps.count) steps. Advance with update_guide as the user progresses. ")
    }

    private func mcpUpdateGuide(_ args: [String: Any]) -> MCPServer.ToolResult {
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

    private func mcpShowPanel(_ args: [String: Any]) -> MCPServer.ToolResult {
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
        let path = overlayManager.write(id: id, dict: doc)
        return overlayWrittenResult("panel", id: id, path: path)
    }

    private func mcpAnnotateScreen(_ args: [String: Any]) -> MCPServer.ToolResult {
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
        let path = overlayManager.write(id: id, dict: ["type": "annotations", "items": items])
        guard let path else {
            return .fail("Couldn't write the annotations overlay file.")
        }
        var text = "Drew \(valid.count) shape\(valid.count == 1 ? "" : "s") on the user's screen (\(items.count) total in overlay \"\(id)\"). They stay visible — and appear in screenshots — until cleared. Live file: \(path)"
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

    private func mcpSpeak(_ args: [String: Any]) -> MCPServer.ToolResult {
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .fail("speak needs non-empty `text`.")
        }
        var failure: String?
        DispatchQueue.main.sync {
            var request = self.chatPanel.currentTTSRequest()
            request.text = text
            failure = self.handleTTSSpeak(request.normalized(), reveal: false, showSettingsOnMissingKey: false)
        }
        if let failure {
            return .fail("Couldn't speak: \(failure)")
        }
        return .ok("Speaking to the user now.")
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
