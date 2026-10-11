import Cocoa
import CoreGraphics
import Darwin

/// Local desktop recorder entry point. It never creates AppDelegate or saves settings.
enum WatcherOnly {
    static func run() -> Int32 {
        let screenPermission = CGPreflightScreenCaptureAccess()
        if CommandLine.arguments.contains("--check-permissions") {
            print("screen_recording=\(screenPermission)")
            return screenPermission ? 0 : 77
        }
        guard screenPermission else {
            FileHandle.standardError.write(Data(
                "watcher-only: Screen Recording permission is unavailable; no capture started.\n".utf8))
            return 77
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.voiceflow.app" && $0.processIdentifier != ownPID
        }) else {
            FileHandle.standardError.write(Data("watcher-only: another Voice Flow app is running.\n".utf8))
            return 73
        }
        let lockPath = VoiceFlowPaths.shared.file("watcher-only.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        guard lockFD >= 0 else {
            FileHandle.standardError.write(Data("watcher-only: cannot open recorder lock.\n".utf8))
            return 73
        }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            FileHandle.standardError.write(Data("watcher-only: another recorder is running.\n".utf8))
            return 73
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
        let signals: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                guard !stopping else { return }
                stopping = true
                watcher.stop()
                watcher.flush()
                FileHandle.standardError.write(Data("watcher-only: stopped.\n".utf8))
                exit(0)
            }
            source.resume()
            return source
        }
        watcher.start()
        FileHandle.standardError.write(Data(
            "watcher-only: desktop recording started; camera, actions, browser automation and pruning disabled.\n".utf8))
        withExtendedLifetime(signals) { app.run() }
        watcher.stop()
        watcher.flush()
        return 0
    }
}
