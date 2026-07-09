import AppKit
import AVFoundation
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

/// Keeps one camera (e.g. a mirrorless over an HDMI dongle) streaming and
/// hands out a JPEG of the freshest frame when asked — the watcher asks
/// once per tick, so the 30 fps stream is never encoded wholesale.
final class CameraGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "voiceflow.watcher.camera", qos: .utility)
    private let ciContext = CIContext()
    private var wantsFrame = false
    private var onFrame: ((Data) -> Void)?
    private(set) var runningDeviceId: String?

    static func availableCameras() -> [(id: String, name: String)] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified)
        return discovery.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    func start(deviceId: String) {
        guard runningDeviceId != deviceId else { return }
        stop()
        guard let device = AVCaptureDevice(uniqueID: deviceId),
              let input = try? AVCaptureDeviceInput(device: device) else {
            vflog("watcher: camera \(deviceId) not found or unusable")
            return
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            vflog("watcher: camera input rejected")
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        runningDeviceId = deviceId
        vflog("watcher: camera streaming — \(device.localizedName)")
    }

    func stop() {
        guard runningDeviceId != nil else { return }
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        runningDeviceId = nil
        vflog("watcher: camera stopped")
    }

    /// Handler is called on the main thread with the next frame's JPEG.
    func requestFrame(_ handler: @escaping (Data) -> Void) {
        queue.async {
            self.onFrame = handler
            self.wantsFrame = true
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard wantsFrame, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        wantsFrame = false
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(
                of: image, colorSpace: space,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.6])
        else { return }
        let handler = onFrame
        onFrame = nil
        DispatchQueue.main.async { handler?(jpeg) }
    }
}

final class WorkflowWatcher {
    static let baseDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice-flow/watcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private(set) var isRunning = false

    private let screenCapture: ScreenCapture
    private let diffThreshold: Double = 0.01
    private let writeQueue = DispatchQueue(label: "voiceflow.watcher", qos: .utility)

    // Tunables live in Settings → Watcher; idle/retention apply per tick,
    // the interval needs a timer restart (applySettings).
    private var appliedInterval: TimeInterval = 5
    private var idleCutoff: TimeInterval {
        TimeInterval(max(30, UserSettings.shared.watcherIdlePauseSeconds))
    }
    private var keepDays: Int { max(3, UserSettings.shared.watcherKeepDays) }

    private var timer: Timer?
    private var lastFrameData: Data?
    private var currentDay = ""
    private var capturing = false

    // Optional body camera (Settings → Watcher): one frame per tick from a
    // continuously-streaming device, deduped separately from the screen.
    private let camera = CameraGrabber()
    private var latestCamJpeg: Data?
    private var lastSavedCamJpeg: Data?
    private let camDiffThreshold: Double = 0.03

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
        appliedInterval = TimeInterval(max(2, UserSettings.shared.watcherIntervalSeconds))
        pruneOldDays()
        syncCamera()
        timer = Timer.scheduledTimer(withTimeInterval: appliedInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        vflog("watcher: started — every \(Int(appliedInterval))s into \(Self.baseDir.path)")
    }

    /// Pick up changed tunables without disturbing anything else.
    func applySettings() {
        guard isRunning else { return }
        syncCamera()
        let wanted = TimeInterval(max(2, UserSettings.shared.watcherIntervalSeconds))
        guard wanted != appliedInterval else { return }
        stop()
        start()
    }

    private func syncCamera() {
        let wanted = UserSettings.shared.watcherCameraId
        if wanted.isEmpty {
            camera.stop()
            latestCamJpeg = nil
            return
        }
        guard camera.runningDeviceId != wanted else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera.start(deviceId: wanted)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.camera.start(deviceId: wanted) }
                    else { vflog("watcher: camera permission denied") }
                }
            }
        default:
            vflog("watcher: camera permission denied — enable in System Settings → Privacy → Camera")
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        lastFrameData = nil
        camera.stop()
        latestCamJpeg = nil
        lastSavedCamJpeg = nil
        vflog("watcher: stopped")
    }

    /// Menu-bar status one-liner, computed on demand.
    func statusLine() -> String {
        guard isRunning else { return "Off" }
        let dir = Self.baseDir.appendingPathComponent(Self.dayFormatter.string(from: Date()))
        let frames = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }.count
        return "Watching — \(frames) frames today"
    }

    private func tick() {
        guard !capturing else { return }
        guard !Self.screenIsLocked() else { return }
        guard Self.secondsSinceLastInput() < idleCutoff else { return }
        capturing = true
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let title = Self.frontmostWindowTitle()
        if camera.runningDeviceId != nil {
            camera.requestFrame { [weak self] jpeg in self?.latestCamJpeg = jpeg }
        }
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

        // Body-camera frame, deduped on its own motion threshold.
        var camName: String?
        if let cam = latestCamJpeg {
            let moved = lastSavedCamJpeg.map { ImageUtils.difference($0, cam) >= camDiffThreshold } ?? true
            if moved {
                lastSavedCamJpeg = cam
                let name = "cam-\(Self.fileTimeFormatter.string(from: now)).jpg"
                camName = name
                let camURL = dayDir.appendingPathComponent(name)
                writeQueue.async {
                    guard let jpeg = ImageUtils.compress(cam, maxDimension: 960, quality: 0.5) else { return }
                    try? jpeg.write(to: camURL, options: .atomic)
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
        if let camName { line["cam"] = camName }
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
