import Cocoa
import AVFoundation

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
    var hotkeyManager: HotkeyManager!
    var recorder: AudioRecorder!
    var backend: BackendBridge!
    var paster: Paster!

    // Foundry capture
    var screenCapture: ScreenCapture!
    var captureScheduler: CaptureScheduler!
    var captureHotkeyManager: HotkeyManager!
    var foundryClient: FoundryClient!
    var conversationManager: ConversationManager!
    private var isCapturing = false
    private var lastCaptureData: Data?
    private let diffThreshold: Double = 0.01

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

        settingsWindow = SettingsWindowController()
        settingsWindow.onHotkeyChanged = { [weak self] key in
            self?.hotkeyManager.updateKey(key)
        }
        settingsWindow.onCaptureHotkeyChanged = { [weak self] key in
            self?.captureHotkeyManager.updateKey(key)
        }
        settingsWindow.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.captureScheduler.interval = TimeInterval(UserSettings.shared.captureIntervalSeconds)
        }
        settingsWindow.onWindowClosed = { [weak self] in self?.hideDockIfNoWindows() }

        // ── Menus (Cmd+Q, Cmd+W) ─────────────────────
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Voice Flow")
        appMenu.addItem(withTitle: "Quit Voice Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu

        // ── core ────────────────────────────────────────
        recorder = AudioRecorder()
        paster = Paster()

        backend = BackendBridge()
        backend.onLoaded = { [weak self] in
            self?.state = .idle
            vflog("models loaded — ready")
        }
        backend.onResult = { [weak self] raw, cleaned in
            self?.handleResult(raw: raw, cleaned: cleaned)
        }
        backend.onError = { msg in vflog("backend error: \(msg)") }
        backend.onStatus = { msg in vflog(msg) }

        // ── screen capture ──────────────────────────────
        screenCapture = ScreenCapture()
        captureScheduler = CaptureScheduler(
            screenCapture: screenCapture,
            interval: TimeInterval(UserSettings.shared.captureIntervalSeconds)
        )
        captureScheduler.onCapture = { [weak self] imageData in
            self?.handleScreenCapture(imageData)
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
        hotkeyManager = HotkeyManager(keyName: UserSettings.shared.hotkey)
        hotkeyManager.onPress = { [weak self] in self?.startRecording() }
        hotkeyManager.onRelease = { [weak self] in self?.stopRecording() }
        hotkeyManager.onHandsFree = { [weak self] active in
            if active { self?.state = .handsFree }
        }

        captureHotkeyManager = HotkeyManager(keyName: UserSettings.shared.captureHotkey)
        captureHotkeyManager.onPress = { [weak self] in self?.toggleCapture() }

        startHotkeyWithAccessibilityCheck()

        // ── launch backend ──────────────────────────────
        state = .loading
        backend.start()
        vflog("app started")
    }

    private func startHotkeyWithAccessibilityCheck() {
        if checkAccessibility() {
            hotkeyManager.start()
            captureHotkeyManager.start()
            return
        }
        requestAccessibility()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.checkAccessibility() {
                timer.invalidate()
                self.hotkeyManager.start()
                self.captureHotkeyManager.start()
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

    // ── recording flow ──────────────────────────────────
    private func startRecording() {
        playSound("Tink")
        state = .recording
        recorder.start()
    }

    private func stopRecording() {
        guard recorder.isRecording else { return }
        recorder.stop { [weak self] pcmData in
            guard let self, let pcmData else {
                self?.state = .idle
                return
            }
            self.state = .processing
            let skipCleanup = !UserSettings.shared.llmCleanupEnabled
            self.backend.transcribe(pcmData: pcmData, sampleRate: 16000, skipCleanup: skipCleanup)
        }
    }

    private func handleResult(raw: String, cleaned: String) {
        if cleaned.isEmpty { state = .idle; return }
        vflog("raw: \(raw)")
        vflog("cleaned: \(cleaned)")
        paster.paste(cleaned)
        playSound("Pop")

        let ts = Self.timestamp()
        DispatchQueue.main.async {
            self.historyWindow.addEntry(text: cleaned, time: ts)
        }

        // Send voice to Foundry when capturing
        if isCapturing && foundryClient.connectionState == .subscribed {
            conversationManager.addUserMessage(cleaned)
            foundryClient.sendMessage(cleaned)
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
        captureScheduler.start()
        foundryClient.connect()
        indicator.setCapturing(true)
        menuBar.setCapturing(true)
        historyWindow.setCapturing(true)
        vflog("capture started")
    }

    private func stopCapture() {
        isCapturing = false
        captureScheduler.stop()
        foundryClient.disconnect()
        lastCaptureData = nil
        indicator.setCapturing(false)
        menuBar.setCapturing(false)
        historyWindow.setCapturing(false)
        vflog("capture stopped")
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

        if foundryClient.connectionState == .subscribed {
            conversationManager.addCaptureMarker()
            foundryClient.sendScreenCapture(imageData, prompt: "Here is a screenshot of what I'm currently doing. Analyze what you see and remember the context.")
            vflog("screen capture sent to Foundry")
        } else {
            vflog("screen capture skipped — Foundry not connected (\(foundryClient.connectionState.rawValue))")
        }
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

    private func showDock() { NSApp.setActivationPolicy(.regular) }

    private func hideDockIfNoWindows() {
        let historyVisible = historyWindow.window?.isVisible == true
        let settingsVisible = settingsWindow.window?.isVisible == true
        if !historyVisible && !settingsVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
