import AppKit
import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Workflow Watcher — ambient screen log for the daily review
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  While enabled, one tick every 5 s: an activity line (frontmost app +
//  window title) always, a screenshot only when the screen actually
//  changed. Ticks stop once the user has been idle for two minutes.
//  Everything lands in a per-day folder that a scheduled Claude Code run
//  analyzes against the observations ledger (see watcher/ANALYZE.md):
//
//  ~/.config/voice-flow/watcher/2026-07-09/
//      activity.jsonl            one line per tick
//      frame-HH-mm-ss.jpg        deduped screenshots

final class WorkflowWatcher {
    static let baseDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice-flow/watcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private(set) var isRunning = false

    private let screenCapture: ScreenCapture
    private let interval: TimeInterval = 5
    private let idleCutoff: TimeInterval = 90
    private let diffThreshold: Double = 0.01
    private let keepDays = 7
    private let writeQueue = DispatchQueue(label: "voiceflow.watcher", qos: .utility)

    private var timer: Timer?
    private var lastFrameData: Data?
    private var currentDay = ""
    private var capturing = false

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let fileTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH-mm-ss"
        return f
    }()
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(screenCapture: ScreenCapture) {
        self.screenCapture = screenCapture
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pruneOldDays()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        vflog("watcher: started — every \(Int(interval))s into \(Self.baseDir.path)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        lastFrameData = nil
        vflog("watcher: stopped")
    }

    private func tick() {
        guard !capturing else { return }
        guard !Self.screenIsLocked() else { return }
        guard Self.secondsSinceLastInput() < idleCutoff else { return }
        capturing = true
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let title = Self.frontmostWindowTitle()
        Task.detached { [weak self] in
            let url = Self.browserURL(app: app)
            let raw = try? await self?.screenCapture.captureScreen()
            DispatchQueue.main.async {
                guard let self else { return }
                self.record(raw: raw, app: app, title: title, url: url)
                self.capturing = false
            }
        }
    }

    /// Main thread: dedup + day rolling are serialized here; JPEG encode
    /// and file appends go to the write queue.
    private func record(raw: Data?, app: String, title: String?, url: String?) {
        let now = Date()
        let day = Self.dayFormatter.string(from: now)
        if day != currentDay {
            currentDay = day
            lastFrameData = nil
            pruneOldDays()
        }
        let dayDir = Self.baseDir.appendingPathComponent(day)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        var frameName: String?
        if let raw {
            let changed = lastFrameData.map { ImageUtils.difference($0, raw) >= diffThreshold } ?? true
            if changed {
                lastFrameData = raw
                let name = "frame-\(Self.fileTimeFormatter.string(from: now)).jpg"
                frameName = name
                let frameURL = dayDir.appendingPathComponent(name)
                writeQueue.async {
                    // 1568px = the long edge AI vision actually uses; bigger
                    // is wasted disk and tokens.
                    guard let jpeg = ImageUtils.compress(raw, maxDimension: 1568, quality: 0.5) else { return }
                    try? jpeg.write(to: frameURL, options: .atomic)
                }
            }
        }

        var line: [String: Any] = [
            "t": Self.clockFormatter.string(from: now),
            "e": Int(now.timeIntervalSince1970),
            "app": app,
        ]
        if let title, !title.isEmpty { line["title"] = title }
        if let url, !url.isEmpty { line["url"] = url }
        if let frameName { line["frame"] = frameName }
        guard let json = try? JSONSerialization.data(withJSONObject: line) else { return }
        let logURL = dayDir.appendingPathComponent("activity.jsonl")
        writeQueue.async {
            let entry = json + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entry)
            } else {
                try? entry.write(to: logURL)
            }
        }
    }

    /// Title of the frontmost app's front window (needs the screen
    /// recording permission the app already holds for capture).
    private static func frontmostWindowTitle() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = Int(front.processIdentifier)
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? Int == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let name = window[kCGWindowName as String] as? String,
                  !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    /// Front-tab URL when a known browser is frontmost. One AppleScript per
    /// browser, referenced only when that browser is active — AppleScript
    /// resolves app dictionaries at compile time, so a single script naming
    /// an uninstalled browser would fail outright. First use prompts the
    /// user to allow Voice Flow to control the browser (Automation TCC).
    private static func browserURL(app: String) -> String? {
        let script: String
        switch app {
        case "Google Chrome", "Brave Browser", "Arc", "Microsoft Edge", "Vivaldi":
            script = "tell application \"\(app)\" to get URL of active tab of front window"
        case "Safari":
            script = "tell application \"Safari\" to get URL of front document"
        default:
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: killer)
        proc.waitUntilExit()
        killer.cancel()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    private static func screenIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return dict["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    private func pruneOldDays() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.baseDir, includingPropertiesForKeys: nil) else { return }
        let dayDirs = entries
            .filter { $0.hasDirectoryPath && $0.lastPathComponent.first?.isNumber == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in dayDirs.dropFirst(keepDays) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
