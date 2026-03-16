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
        // Hide dock icon (LSUIElement backup)
        NSApp.setActivationPolicy(.accessory)

        // ── settings ────────────────────────────────────
        UserSettings.shared.load()

        // ── UI ──────────────────────────────────────────
        menuBar = MenuBarManager()
        menuBar.onShowHistory = { [weak self] in self?.toggleHistory() }
        menuBar.onShowSettings = { [weak self] in self?.showSettings() }
        menuBar.onQuit = { NSApp.terminate(nil) }

        indicator = FloatingIndicator()
        indicator.onClick = { [weak self] in self?.toggleHistory() }
        indicator.onShowHistory = { [weak self] in self?.toggleHistory() }
        indicator.onQuit = { NSApp.terminate(nil) }
        indicator.show()

        historyWindow = HistoryWindowController()
        historyWindow.onSettings = { [weak self] in self?.showSettings() }
        historyWindow.onWindowClosed = { [weak self] in self?.hideDockIfNoWindows() }
        settingsWindow = SettingsWindowController()
        settingsWindow.onHotkeyChanged = { [weak self] key in
            self?.hotkeyManager.updateKey(key)
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
        backend.onError = { msg in
            vflog("backend error: \(msg)")
        }
        backend.onStatus = { msg in
            vflog(msg)
        }

        // ── hotkey ──────────────────────────────────────
        hotkeyManager = HotkeyManager(keyName: UserSettings.shared.hotkey)
        hotkeyManager.onPress = { [weak self] in self?.startRecording() }
        hotkeyManager.onRelease = { [weak self] in self?.stopRecording() }
        hotkeyManager.onHandsFree = { [weak self] active in
            if active { self?.state = .handsFree }
        }

        // ── accessibility + hotkey start ─────────────────
        startHotkeyWithAccessibilityCheck()

        // ── launch backend ──────────────────────────────
        state = .loading
        backend.start()

        vflog("app started")
    }

    private func startHotkeyWithAccessibilityCheck() {
        if checkAccessibility() {
            hotkeyManager.start()
            return
        }
        // Prompt for accessibility
        requestAccessibility()
        // Poll until granted (user is in System Settings)
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.checkAccessibility() {
                timer.invalidate()
                self.hotkeyManager.start()
                vflog("accessibility granted — hotkey active")
            }
        }
    }

    // ── accessibility ───────────────────────────────────
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
        recorder.stop { [weak self] wavPath in
            guard let self, let wavPath else {
                self?.state = .idle
                return
            }
            self.state = .processing
            self.backend.transcribe(audioPath: wavPath)
        }
    }

    private func handleResult(raw: String, cleaned: String) {
        if cleaned.isEmpty {
            state = .idle
            return
        }
        vflog("raw: \(raw)")
        vflog("cleaned: \(cleaned)")
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

    private func playSound(_ name: String) {
        guard UserSettings.shared.soundsEnabled else { return }
        NSSound(named: name)?.play()
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
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

    private func showDock() {
        NSApp.setActivationPolicy(.regular)
    }

    private func hideDockIfNoWindows() {
        let historyVisible = historyWindow.window?.isVisible == true
        let settingsVisible = settingsWindow.window?.isVisible == true
        if !historyVisible && !settingsVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

