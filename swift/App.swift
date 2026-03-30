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
    var historyWindow: HistoryWindowController!
    var settingsWindow: SettingsWindowController!
    var permissionsWindow: PermissionsWindowController!
    var hotkeyManager: HotkeyManager!
    var handsFreeHotkeyManager: HotkeyManager!
    var ttsHotkeyManager: HotkeyManager!
    var recorder: AudioRecorder!
    var backend: BackendBridge!
    var paster: Paster!
    var ttsController: TTSController!
    var localAPIServer: LocalAPIServer!

    // Foundry capture
    var screenCapture: ScreenCapture!
    var captureScheduler: CaptureScheduler!
    var captureHotkeyManager: HotkeyManager!
    var captureNoteHotkeyManager: HotkeyManager!
    var foundryClient: FoundryClient!
    var conversationManager: ConversationManager!
    private var isCapturing = false
    private var isScreenCaptureActive = false
    private var lastCaptureData: Data?
    private let diffThreshold: Double = 0.01

    // Buffered captures — sent to agent only when activity stops
    private var pendingScreenshots: [Data] = []
    private var pendingDictations: [String] = []

    // Tracks whether the current recording is a capture note (buffer) vs regular dictation (paste)
    private var recordingIsCaptureNote = false
    private var initialPermissionsRequested = false

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

        // ── UI ──────────────────────────────────────────
        menuBar = MenuBarManager()
        menuBar.onShowHistory = { [weak self] in self?.toggleHistory() }
        menuBar.onShowPermissions = { [weak self] in self?.showPermissions() }
        menuBar.onShowSettings = { [weak self] in self?.showSettings() }
        menuBar.onToggleCapture = { [weak self] in self?.toggleCapture() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        indicator = FloatingIndicator()
        indicator.onClick = { [weak self] in self?.toggleHistory() }
        indicator.onShowHistory = { [weak self] in self?.toggleHistory() }
        indicator.onToggleCapture = { [weak self] in self?.toggleCapture() }
        indicator.onQuit = { NSApp.terminate(nil) }
        indicator.show()

        historyWindow = HistoryWindowController()
        historyWindow.onSettings = { [weak self] in self?.showSettings() }
        historyWindow.onToggleCapture = { [weak self] in self?.toggleCapture() }
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
        settingsWindow.onCaptureHotkeyChanged = { [weak self] spec in
            self?.captureHotkeyManager.updateSpec(spec)
        }
        settingsWindow.onCaptureNoteHotkeyChanged = { [weak self] spec in
            self?.captureNoteHotkeyManager.updateSpec(spec)
        }
        settingsWindow.onSettingsChanged = { [weak self] foundrySettingsChanged in
            guard let self else { return }
            self.captureScheduler.interval = TimeInterval(UserSettings.shared.captureIntervalSeconds)
            if foundrySettingsChanged {
                self.resetFoundryConnectionForSettingsChange()
            }
        }
        settingsWindow.onWindowClosed = { [weak self] in self?.hideDockIfNoWindows() }

        permissionsWindow = PermissionsWindowController()
        permissionsWindow.onRequestMicrophone = { [weak self] in self?.requestMicrophonePermission() }
        permissionsWindow.onRequestScreenCapture = { [weak self] in self?.requestScreenCapturePermission() }
        permissionsWindow.onRequestAccessibility = { [weak self] in self?.requestAccessibilityPermission() }
        permissionsWindow.onRefresh = { [weak self] in self?.refreshPermissionWindow() }
        permissionsWindow.onWindowClosed = { [weak self] in self?.hideDockIfNoWindows() }

        // ── Menus (Cmd+Q, Cmd+W) ─────────────────────
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

        // ── core ────────────────────────────────────────
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
        backend.onError = { [weak self] msg in
            vflog("backend error: \(msg)")
            guard let self else { return }
            if self.recordingIsCaptureNote {
                self.finishCaptureNote(text: nil)
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

        // ── screen capture ──────────────────────────────
        screenCapture = ScreenCapture()
        captureScheduler = CaptureScheduler(
            screenCapture: screenCapture,
            interval: TimeInterval(UserSettings.shared.captureIntervalSeconds)
        )
        captureScheduler.onCapture = { [weak self] imageData in
            DispatchQueue.main.async {
                guard let self, self.isScreenCaptureActive else { return }
                self.indicator.flashCapturePulse()
                self.handleScreenCapture(imageData)
            }
        }

        // ── foundry gateway ─────────────────────────────
        foundryClient = FoundryClient()
        conversationManager = ConversationManager()

        foundryClient.onMessage = { [weak self] msg in
            self?.conversationManager.handleFoundryMessage(msg)
        }
        foundryClient.onStreamDelta = { [weak self] streamId, content in
            self?.conversationManager.handleStreamDelta(streamId, content)
        }
        foundryClient.onStreamEnd = { [weak self] streamId in
            self?.conversationManager.handleStreamEnd(streamId)
        }
        foundryClient.onConnectionStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.historyWindow.setFoundryState(state)
            }
        }
        foundryClient.onSessionReset = { [weak self] in
            self?.conversationManager.clear()
        }
        foundryClient.onError = { [weak self] msg in
            vflog("foundry error: \(msg)")
            self?.conversationManager.addError(msg)
        }

        conversationManager.onMessagesChanged = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.historyWindow.updateConversation(self.conversationManager.displayMessages)
            }
        }

        // ── hotkeys ───────────────────────────────────
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

        captureHotkeyManager = HotkeyManager(spec: UserSettings.shared.captureHotkey)
        captureHotkeyManager.onPress = { [weak self] in self?.toggleCapture() }

        captureNoteHotkeyManager = HotkeyManager(spec: UserSettings.shared.captureNoteHotkey)
        captureNoteHotkeyManager.onPress = { [weak self] in self?.startCaptureNoteRecording() }
        captureNoteHotkeyManager.onRelease = { [weak self] in self?.stopCaptureNoteRecording() }

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
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionWindow()
    }

    private func resetFoundryConnectionForSettingsChange() {
        foundryClient.disconnect()
        conversationManager.clear()
        vflog("foundry settings changed — cleared active gateway session and will reconnect on next send")
    }

    @objc private func showPermissionsMenuAction() {
        showPermissions()
    }

    @objc private func showSettingsMenuAction() {
        showSettings()
    }

    private func startHotkeyWithAccessibilityCheck() {
        if checkAccessibility() {
            hotkeyManager.start()
            handsFreeHotkeyManager.start()
            ttsHotkeyManager.start()
            captureHotkeyManager.start()
            captureNoteHotkeyManager.start()
            return
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.checkAccessibility() {
                timer.invalidate()
                self.hotkeyManager.start()
                self.handsFreeHotkeyManager.start()
                self.ttsHotkeyManager.start()
                self.captureHotkeyManager.start()
                self.captureNoteHotkeyManager.start()
                vflog("accessibility granted — hotkeys active")
            }
        }
    }

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

    // ── recording flow ──────────────────────────────────
    private func startRecording() {
        guard !recorder.isRecording else { return }
        recordingIsCaptureNote = false
        paster.capturePasteTarget()
        playSound("Tink")
        state = .recording
        recorder.start()
    }

    private func startCaptureNoteRecording() {
        guard !recorder.isRecording else { return }
        recordingIsCaptureNote = true
        isScreenCaptureActive = true
        pendingScreenshots.removeAll()
        pendingDictations.removeAll()
        lastCaptureData = nil
        conversationManager.clear()

        // Start screenshot capture (takes one immediately + periodic)
        indicator.setCapturing(true)
        captureScheduler.start()

        playSound("Tink")
        state = .recording
        recorder.start()
        vflog("capture note started — recording + screenshots")
    }

    private func stopCaptureNoteRecording() {
        // Stop screenshots
        isScreenCaptureActive = false
        indicator.setCapturing(false)
        captureScheduler.stop()

        // Stop audio → triggers transcription → handleResult
        stopRecording()
    }

    private func stopRecording() {
        guard recorder.isRecording else { return }
        recorder.stop { [weak self] pcmData in
            guard let self else { return }
            if let pcmData {
                self.state = .processing
                let settings = UserSettings.shared
                let provider = settings.dictationProvider
                let skipCleanup = provider != .local || !settings.llmCleanupEnabled

                let openAIAPIKey: String?
                if provider == .openai {
                    openAIAPIKey = KeychainStore.shared.loadOpenAIAPIKey()
                    if openAIAPIKey == nil {
                        vflog("OpenAI dictation selected, but no API key is saved")
                        self.state = .idle
                        if self.recordingIsCaptureNote {
                            self.finishCaptureNote(text: nil)
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
            } else if self.recordingIsCaptureNote {
                // No audio but we have screenshots — send them anyway
                self.finishCaptureNote(text: nil)
            } else {
                self.state = .idle
            }
        }
    }

    private func handleResult(raw: String, cleaned: String) {
        if cleaned.isEmpty && !recordingIsCaptureNote { state = .idle; return }
        vflog("raw: \(raw)")
        vflog("cleaned: \(cleaned)")
        vflog("isCaptureNote=\(recordingIsCaptureNote)")

        if recordingIsCaptureNote {
            finishCaptureNote(text: cleaned.isEmpty ? nil : cleaned)
        } else {
            // Regular dictation — paste into active app
            vflog("pasting text...")
            paster.paste(cleaned)
            playSound("Pop")
            let ts = Self.timestamp()
            DispatchQueue.main.async {
                self.historyWindow.addEntry(text: cleaned, time: ts)
            }
            state = .done
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if self.state == .done { self.state = .idle }
            }
        }
    }

    private func finishCaptureNote(text: String?) {
        let screenshots = pendingScreenshots
        pendingScreenshots.removeAll()
        pendingDictations.removeAll()
        lastCaptureData = nil

        if screenshots.isEmpty && text == nil {
            vflog("capture note empty — nothing to send")
            state = .idle
            return
        }

        var dictations: [String] = []
        if let text { dictations.append(text) }

        vflog("capture note done — \(screenshots.count) screenshots + \(dictations.count) notes, connecting to send")
        playSound("Pop")
        conversationManager.markAllPendingSending()
        connectAndFlush(screenshots: screenshots, dictations: dictations)

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
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // ── capture ─────────────────────────────────────────
    func toggleCapture() {
        if isCapturing { stopCapture() } else { startCapture() }
    }

    private func startCapture() {
        isCapturing = true
        isScreenCaptureActive = true
        pendingScreenshots.removeAll()
        pendingDictations.removeAll()
        conversationManager.clear()
        indicator.setCapturing(true)
        menuBar.setCapturing(true)
        historyWindow.setCapturing(true)
        captureScheduler.start()
        vflog("capture started — buffering until stop (no Foundry connection yet)")
    }

    private func stopCapture() {
        isCapturing = false
        isScreenCaptureActive = false
        lastCaptureData = nil
        indicator.setCapturing(false)
        menuBar.setCapturing(false)
        historyWindow.setCapturing(false)
        captureScheduler.stop()

        let screenshots = pendingScreenshots
        let dictations = pendingDictations
        pendingScreenshots.removeAll()
        pendingDictations.removeAll()

        if screenshots.isEmpty && dictations.isEmpty {
            vflog("capture stopped — nothing to send")
            return
        }

        vflog("capture stopped — connecting to flush \(screenshots.count) screenshots + \(dictations.count) dictations")
        conversationManager.markAllPendingSending()
        connectAndFlush(screenshots: screenshots, dictations: dictations)
    }

    private func connectAndFlush(screenshots: [Data], dictations: [String]) {
        // If already subscribed, flush immediately
        if foundryClient.connectionState == .subscribed {
            flushPendingCaptures(screenshots: screenshots, dictations: dictations)
            return
        }

        // Temporarily override connection handler to flush once subscribed
        let originalHandler = foundryClient.onConnectionStateChanged
        var flushed = false
        foundryClient.onConnectionStateChanged = { [weak self] state in
            guard let self else { return }
            // Always forward to original handler (UI updates)
            originalHandler?(state)

            guard !flushed else { return }
            if state == .subscribed {
                flushed = true
                DispatchQueue.main.async {
                    // Restore original handler
                    self.foundryClient.onConnectionStateChanged = originalHandler
                    self.flushPendingCaptures(screenshots: screenshots, dictations: dictations)
                }
            } else if state == .disconnected {
                flushed = true
                DispatchQueue.main.async {
                    self.foundryClient.onConnectionStateChanged = originalHandler
                    self.conversationManager.addError("Failed to connect — captures saved locally but not sent")
                    vflog("flush failed — could not connect to Foundry")
                }
            }
        }
        foundryClient.connect()
    }

    private func flushPendingCaptures(screenshots: [Data], dictations: [String]) {
        Task {
            // Upload all screenshots
            var attachments: [FoundryAttachment] = []
            for (i, imageData) in screenshots.enumerated() {
                do {
                    let attachment = try await foundryClient.uploadImage(imageData)
                    attachments.append(attachment)
                    vflog("uploaded screenshot \(i + 1)/\(screenshots.count)")
                } catch {
                    vflog("failed to upload screenshot \(i + 1): \(error)")
                }
            }

            // Build combined prompt
            var parts: [String] = []

            if !dictations.isEmpty {
                parts.append("Here are my voice notes during this activity:")
                for (i, text) in dictations.enumerated() {
                    parts.append("\(i + 1). \(text)")
                }
            }

            if !attachments.isEmpty {
                parts.append("\(attachments.count) screenshot(s) of what I was doing are attached.")
            }

            parts.append("Please analyze everything together and provide your response.")

            let prompt = parts.joined(separator: "\n")

            DispatchQueue.main.async {
                self.conversationManager.replacePendingWithSent(prompt)
                self.foundryClient.sendMessage(prompt, attachments: attachments)
                vflog("flush complete — sent combined message with \(attachments.count) attachments")
            }
        }
    }

    private func handleScreenCapture(_ imageData: Data) {
        if let previous = lastCaptureData {
            let diff = ImageUtils.difference(previous, imageData)
            if diff < diffThreshold {
                vflog("screen unchanged — skipping (diff=\(String(format: "%.4f", diff)))")
                return
            }
        }
        lastCaptureData = imageData

        // Buffer screenshot locally — will be sent when activity stops
        pendingScreenshots.append(imageData)
        conversationManager.addCaptureMarker(isPending: true)
        vflog("screen capture buffered (\(pendingScreenshots.count) total)")
    }

    // ── window toggles ──────────────────────────────────
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

    private func showDock() { NSApp.setActivationPolicy(.regular) }

    private func hideDockIfNoWindows() {
        let historyVisible = historyWindow.window?.isVisible == true
        let settingsVisible = settingsWindow.window?.isVisible == true
        let permissionsVisible = permissionsWindow.window?.isVisible == true
        if !historyVisible && !settingsVisible && !permissionsVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
