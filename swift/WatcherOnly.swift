import Cocoa
import CoreGraphics
import Darwin

/// Local desktop recorder entry point. It never creates AppDelegate or saves settings.
enum WatcherOnly {
    static func run() -> Int32 {
        let managed = CommandLine.arguments.contains("--controller-managed")
        func emit(_ fields: [String: Any]) {
            guard managed, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        func failed(_ message: String, code: Int32) -> Int32 {
            emit(["op": "recorder_status", "state": "failed",
                  "last_error": message, "last_frame_at": NSNull()])
            FileHandle.standardError.write(Data("watcher-only: \(message).\n".utf8))
            return code
        }
        let screenPermission = CGPreflightScreenCaptureAccess()
        if CommandLine.arguments.contains("--check-permissions") {
            if managed {
                emit(["op": "recorder_status", "state": screenPermission ? "starting" : "failed",
                      "last_error": screenPermission ? NSNull() : "screen recording permission unavailable" as Any,
                      "last_frame_at": NSNull()])
            } else { print("screen_recording=\(screenPermission)") }
            return screenPermission ? 0 : 77
        }
        guard screenPermission else {
            return failed("screen recording permission unavailable; no capture started", code: 77)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.voiceflow.app" && $0.processIdentifier != ownPID
        }) else {
            return failed("another Voice Flow app is running", code: 73)
        }
        let lockPath = VoiceFlowPaths.shared.file("watcher-only.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        guard lockFD >= 0 else {
            return failed("cannot open recorder lock", code: 73)
        }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            return failed("another recorder is running", code: 73)
        }
        let settings = UserSettings.shared
        settings.load()
        settings.workflowWatcherEnabled = true
        settings.watcherActionsEnabled = false
        settings.watcherCameraId = ""

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let watcher = WorkflowWatcher(
            screenCapture: ScreenCapture(), retentionEnabled: false,
            browserURLCollectionEnabled: false, requiresScreenPermissionPreflight: true)
        var stopping = false
        func stop() {
            guard !stopping else { return }
            stopping = true
            watcher.stop()
            if !watcher.flush() {
                FileHandle.standardError.write(Data("watcher-only: archive drain timed out.\n".utf8))
            }
            FileHandle.standardError.write(Data("watcher-only: stopped.\n".utf8))
            exit(0)
        }
        let signals: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { stop() }
            source.resume()
            return source
        }
        if managed { WatcherParentLifetime.watch(fd: STDIN_FILENO, onEOF: stop) }
        watcher.start()
        FileHandle.standardError.write(Data(
            "watcher-only: desktop recording started; camera, actions, browser automation and pruning disabled.\n".utf8))
        emit(watcher.recorderHealth())
        let heartbeat = managed ? Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            emit(watcher.recorderHealth())
        } : nil
        withExtendedLifetime(signals) { app.run() }
        heartbeat?.invalidate()
        watcher.stop()
        watcher.flush()
        return 0
    }
}
