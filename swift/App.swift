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
                self.chatPanel.addNote("Couldn't transcribe the session audio — sending the screenshots on their own.")
                self.sendSessionBundle(transcript: nil)
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
        guard KeychainStore.shared.hasAgentAPIKey else {
            chatPanel.show(focusInput: false)
            chatPanel.addNote("Add your OpenRouter key in Settings to start a session.")
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
        captureScheduler.interval = TimeInterval(max(1, UserSettings.shared.captureIntervalSeconds))
        captureScheduler.start()

        // The whole session is one long voice note — transcribed and sent
        // together with the collected screenshots when the session ends.
        recordingPurpose = .session
        recorder.start()

        indicator.setSessionActive(true)
        menuBar.setSessionActive(true)
        chatPanel.setSessionActive(true)
        chatPanel.addNote("Session started — I'm listening and watching. Stop the session to send everything to the agent.")
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
            }
            if recorder.isRecording, recordingPurpose == .session {
                stopRecording()   // → transcribe → handleResult(.session) → sendSessionBundle
            } else {
                recordingPurpose = .dictation
                sendSessionBundle(transcript: nil)
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
        ambientScreenshots.append(imageData)
        if ambientScreenshots.count > maxAmbientScreenshots {
            ambientScreenshots.removeFirst(ambientScreenshots.count - maxAmbientScreenshots)
        }
    }

    // ── Sending to the agent ────────────────────────────

    private func sendTypedMessage(_ text: String) {
        sendToAgent(text: text, includeFreshScreenshot: sessionActive)
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
                            self.chatPanel.addNote("No OpenAI key — sending the session screenshots without a transcript.")
                            self.sendSessionBundle(transcript: nil)
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
                if purpose == .session {
                    self.sendSessionBundle(transcript: nil)
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
                sendToAgent(text: note, includeFreshScreenshot: false)
            case .snapTalk:
                guard !note.isEmpty else { return }
                playSound("Pop")
                sendToAgent(text: note, includeFreshScreenshot: true, forceScreenshot: true)
            case .session:
                playSound("Pop")
                sendSessionBundle(transcript: note)
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
