import Cocoa
import AVFoundation
import CoreGraphics

// ── App State ───────────────────────────────────────────
enum AppState: String {
    case idle, loading, recording, processing, done, handsFree
}

// ── App Delegate ────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarManager!
    var indicator: FloatingIndicator!
    var chatPanel: ChatPanel!
    var annotationOverlay: AnnotationOverlay!
    var historyWindow: HistoryWindowController!
    var settingsWindow: SettingsWindowController!
    var permissionsWindow: PermissionsWindowController!
    var hotkeyManager: HotkeyManager!
    var handsFreeHotkeyManager: HotkeyManager!
    var ttsHotkeyManager: HotkeyManager!
    var sessionHotkeyManager: HotkeyManager!
    var talkHotkeyManager: HotkeyManager!
    var annotateHotkeyManager: HotkeyManager!
    var recorder: AudioRecorder!
    var backend: BackendBridge!
    var paster: Paster!
    var ttsController: TTSController!
    var localAPIServer: LocalAPIServer!

    // Agent session
    var screenCapture: ScreenCapture!
    var captureScheduler: CaptureScheduler!
    var agent: AgentSession!
    private var sessionActive = false
    private var lastCaptureData: Data?
    private let diffThreshold: Double = 0.01
    private var ambientScreenshots: [Data] = []
    private let maxAmbientScreenshots = 2
    private var escapeMonitor: Any?

    // Tracks whether the current recording is a voice note for the agent
    // (buffer + send) vs regular dictation (paste into the focused app).
    private var recordingForAgent = false
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
                indicator?.setState(state)
                historyWindow?.setState(state)
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
            self?.chatPanel.setAnnotating(editing)
        }

        chatPanel = ChatPanel()
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
        chatPanel.onStop = { [weak self] in self?.agent.interrupt() }
        chatPanel.onClear = { [weak self] in
            self?.agent.reset()
            self?.chatPanel.clearConversation()
            self?.chatPanel.setActivity(.idle)
        }
        chatPanel.onOpenSettings = { [weak self] in self?.showSettings() }
        chatPanel.setVoiceReplies(UserSettings.shared.voiceRepliesEnabled)

        transcriptPanel = FloatingTranscriptPanel()

        historyWindow = HistoryWindowController()
        historyWindow.onSettings = { [weak self] in self?.showSettings() }
        historyWindow.onWindowClosed = { [weak self] in self?.hideDockIfNoWindows() }
        historyWindow.onTTSSpeak = { [weak self] request in
            self?.handleTTSSpeak(request, reveal: false, showSettingsOnMissingKey: true)
        }
        historyWindow.onTTSSeek = { [weak self] position in
            self?.ttsController.seek(to: position)
        }
        historyWindow.onTTSStop = { [weak self] in
            self?.ttsController.stop()
        }

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
                self?.historyWindow.setTTSStatus(snapshot)
            }
        }

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
            if self.recordingForAgent {
                self.recordingForAgent = false
                self.state = .idle
                self.chatPanel.addNote("Couldn't transcribe that — try again.")
            } else {
                self.state = .idle
            }
        }
        backend.onStatus = { msg in vflog(msg) }

        let initialTTSRequest = TTSRequest(
            text: "",
            voice: UserSettings.shared.ttsVoice,
            speed: UserSettings.shared.ttsSpeed,
            instructions: UserSettings.shared.ttsInstructions
        )
        historyWindow.applyTTSRequest(initialTTSRequest)
        historyWindow.setTTSStatus(ttsController.status)

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
            self?.indicator.setAgentActivity(activity)
            self?.chatPanel.setActivity(activity)
        }
        agent.onAssistantStart = { [weak self] in
            self?.chatPanel.beginAssistantMessage()
        }
        agent.onAssistantDelta = { [weak self] delta in
            self?.chatPanel.appendAssistantDelta(delta)
        }
        agent.onAssistantDone = { [weak self] text in
            guard let self else { return }
            self.chatPanel.finishAssistantMessage(text)
            if UserSettings.shared.voiceRepliesEnabled {
                self.speakAgentReply(text)
            }
        }
        agent.onToolActivity = { [weak self] detail in
            self?.chatPanel.setToolDetail(detail)
        }
        agent.onError = { [weak self] message in
            self?.chatPanel.addNote(message)
            if self?.chatPanel.isVisible == false {
                self?.chatPanel.show(focusInput: false)
            }
        }

        // Escape is the panic button while the agent is acting.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.agent.activity == .acting else { return }
            self.agent.interrupt()
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
        ttsHotkeyManager.onPress = { [weak self] in self?.speakSelectedText() }

        sessionHotkeyManager = HotkeyManager(spec: UserSettings.shared.sessionHotkey)
        sessionHotkeyManager.onPress = { [weak self] in self?.toggleSession() }

        talkHotkeyManager = HotkeyManager(spec: UserSettings.shared.talkHotkey)
        talkHotkeyManager.onPress = { [weak self] in self?.startTalkRecording() }
        talkHotkeyManager.onRelease = { [weak self] in self?.stopTalkRecording() }

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
        sessionActive = true
        ambientScreenshots.removeAll()
        lastCaptureData = nil
        captureScheduler.interval = TimeInterval(max(1, UserSettings.shared.captureIntervalSeconds))
        captureScheduler.start()

        indicator.setSessionActive(true)
        menuBar.setSessionActive(true)
        chatPanel.setSessionActive(true)
        if !chatPanel.isVisible {
            chatPanel.show(focusInput: false)
        }
        chatPanel.addNote("Session started — I can see your screen when you talk, type, or snap.")
        playSound("Tink")
        vflog("session started")
    }

    private func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        captureScheduler.stop()
        ambientScreenshots.removeAll()
        lastCaptureData = nil
        if agent.isRunning {
            agent.interrupt()
        }

        indicator.setSessionActive(false)
        indicator.setAgentActivity(.idle)
        menuBar.setSessionActive(false)
        chatPanel.setSessionActive(false)
        chatPanel.setActivity(.idle)
        chatPanel.addNote("Session ended")
        playSound("Pop")
        vflog("session ended")
    }

    /// Ambient screenshots build quiet context while a session runs —
    /// deduped so an unchanged screen doesn't pile up frames.
    private func handleAmbientCapture(_ imageData: Data) {
        if let previous = lastCaptureData {
            let diff = ImageUtils.difference(previous, imageData)
            if diff < diffThreshold { return }
        }
        lastCaptureData = imageData
        indicator.flashCapturePulse()
        ambientScreenshots.append(imageData)
        if ambientScreenshots.count > maxAmbientScreenshots {
            ambientScreenshots.removeFirst(ambientScreenshots.count - maxAmbientScreenshots)
        }
    }

    // ── Sending to the agent ────────────────────────────

    private func sendTypedMessage(_ text: String) {
        if sessionActive {
            sendToAgent(text: text, includeFreshScreenshot: true)
        } else {
            sendToAgent(text: text, includeFreshScreenshot: false)
        }
    }

    private func snapAndSend() {
        sendToAgent(text: nil, includeFreshScreenshot: true, forceScreenshot: true)
    }

    private func sendToAgent(text: String?, includeFreshScreenshot: Bool, forceScreenshot: Bool = false) {
        if !chatPanel.isVisible {
            chatPanel.show(focusInput: false)
        }

        Task { @MainActor in
            var screenshots: [Data] = []
            if sessionActive {
                screenshots.append(contentsOf: ambientScreenshots)
                ambientScreenshots.removeAll()
            }
            if includeFreshScreenshot || forceScreenshot {
                if let fresh = try? await screenCapture.captureScreen() {
                    screenshots.append(fresh)
                    lastCaptureData = fresh
                }
            }

            let note: String?
            if screenshots.isEmpty {
                note = nil
            } else if screenshots.count == 1 {
                note = "📎 1 screenshot"
            } else {
                note = "📎 \(screenshots.count) screenshots"
            }
            self.chatPanel.addUserMessage(text ?? "", attachmentNote: note)
            self.agent.send(text: text, screenshots: screenshots)
        }
    }

    // ── Talk to the agent (hold-to-record) ─────────────

    private func startTalkRecording() {
        guard !recorder.isRecording else { return }
        recordingForAgent = true
        streamingViaAX = false
        hadPartialStream = false
        playSound("Tink")
        state = .recording
        recorder.start()
        vflog("talk-to-agent recording started")
    }

    private func stopTalkRecording() {
        guard recordingForAgent else { return }
        stopRecording()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Dictation flow
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func startRecording() {
        guard !recorder.isRecording else { return }
        recordingForAgent = false
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
                        if self.recordingForAgent {
                            self.recordingForAgent = false
                            self.chatPanel.addNote("Add your OpenAI key in Settings to transcribe voice notes.")
                        } else {
                            self.showSettings()
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
            } else if self.recordingForAgent {
                self.recordingForAgent = false
                self.state = .idle
            } else {
                self.state = .idle
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

        // Voice note for the agent — never pasted anywhere.
        if recordingForAgent {
            recordingForAgent = false
            paster.clearStreamTarget()
            hadPartialStream = false
            state = .idle
            let note = cleaned.isEmpty ? raw : cleaned
            guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            playSound("Pop")
            sendToAgent(text: note, includeFreshScreenshot: true)
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
            self.historyWindow.addEntry(text: cleaned, time: timestamp)
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

    private func speakAgentReply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, KeychainStore.shared.hasOpenAIAPIKey else { return }
        let settings = UserSettings.shared
        let request = TTSRequest(
            text: trimmed,
            voice: settings.ttsVoice,
            speed: settings.ttsSpeed,
            instructions: settings.ttsInstructions
        )
        try? ttsController.speak(request: request.normalized())
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
        if historyWindow.window?.isVisible == true {
            historyWindow.window?.orderOut(nil)
            hideDockIfNoWindows()
        } else {
            showDock()
            historyWindow.showWindow(nil)
            historyWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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

    private func showHistoryTab(_ tab: HistoryTab) {
        showDock()
        historyWindow.showWindow(nil)
        historyWindow.window?.makeKeyAndOrderFront(nil)
        historyWindow.selectTab(tab)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showDock() { NSApp.setActivationPolicy(.regular) }

    private func hideDockIfNoWindows() {
        let historyVisible = historyWindow.window?.isVisible == true
        let settingsVisible = settingsWindow.window?.isVisible == true
        let permissionsVisible = permissionsWindow.window?.isVisible == true
        if !historyVisible && !settingsVisible && !permissionsVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  TTS (hotkey + local API)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func speakSelectedText() {
        guard let selectedText = paster.copySelectedText() else {
            NSSound.beep()
            vflog("tts hotkey: no selected text available")
            return
        }

        var request = historyWindow.currentTTSRequest()
        request.text = selectedText
        let normalized = request.normalized()
        historyWindow.applyTTSRequest(normalized)
        _ = handleTTSSpeak(normalized, reveal: false, showSettingsOnMissingKey: true)
    }

    private func setupLocalAPIServer() {
        localAPIServer = LocalAPIServer()
        localAPIServer.onServerMessage = { [weak self] message in
            DispatchQueue.main.async {
                self?.historyWindow.setTTSServerLabel(message)
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
        var request = historyWindow.currentTTSRequest()
        if let text = payload.text { request.text = text }
        if let voice = payload.voice { request.voice = voice }
        if let speed = payload.speed { request.speed = speed }
        if let instructions = payload.instructions { request.instructions = instructions }
        return request.normalized()
    }

    @discardableResult
    private func handleTTSSpeak(_ request: TTSRequest, reveal: Bool, showSettingsOnMissingKey: Bool) -> String? {
        let normalized = request.normalized()
        historyWindow.applyTTSRequest(normalized)
        if reveal {
            showHistoryTab(.tts)
        }

        do {
            try ttsController.speak(request: normalized)
            return nil
        } catch {
            let message = error.localizedDescription
            let currentStatus = ttsController.status
            historyWindow.setTTSStatus(TTSStatusSnapshot(
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
        historyWindow.applyTTSRequest(request)
        if payload.reveal == true {
            showHistoryTab(.tts)
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
            showHistoryTab(.tts)
        }
        return LocalAPIResponse.ok([
            "ok": true,
            "status": "seeked",
            "position": ttsController.status.currentTime,
            "duration": ttsController.status.duration,
        ])
    }

    private func makeTTSStatusResponse() -> LocalAPIResponse {
        let request = historyWindow.currentTTSRequest()
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
