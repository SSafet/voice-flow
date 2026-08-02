import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Workflow Watcher — the desktop source, and the scheduler that runs it
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  `WorkflowWatcher` is now a thin owner of a SourceScheduler (see
//  WatcherBus.swift). Everything it used to do itself lives in DesktopSource,
//  which is one source among however many get registered later.
//
//  ~/.config/voice-flow/watcher/2026-07-28/
//      activity.jsonl        one line per 5 s tick — state of the screen
//      actions.jsonl         one line per coalesced action — what was done
//      frame-HH-mm-ss.jpg    screenshots, saved when the screen actually moved
//      cam-HH-mm-ss.jpg      optional body-camera frames

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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Desktop source
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Screen, apps, input and attention share one cadence, one subject and one
//  cost, so they are one source rather than four. What this source knows
//  about — its thresholds, when a frame is worth keeping, how input becomes
//  actions, how a password is kept out — is all decided here. What happens to
//  the data afterwards is decided by the consumer, once, for every source.

final class DesktopSource: WatcherSource {

    let name = "desktop"
    var interval: TimeInterval { TimeInterval(max(2, UserSettings.shared.watcherIntervalSeconds)) }
    var isEnabled: Bool { UserSettings.shared.workflowWatcherEnabled }

    private let screenCapture: ScreenCapture
    private let coalescer = InputCoalescer()
    private let camera = CameraGrabber()

    private var idleCutoff: TimeInterval {
        TimeInterval(max(30, UserSettings.shared.watcherIdlePauseSeconds))
    }
    /// How many changed blocks (of ~150) make a frame worth keeping. Lower
    /// keeps more: this is the knob for "I would rather have the picture".
    private var diffBlocks: Int { max(1, UserSettings.shared.watcherDiffBlocks) }
    /// Never go longer than this without a frame while a hard-to-read app is
    /// in front, however still the pixels look.
    private var denseSeconds: TimeInterval {
        TimeInterval(max(0, UserSettings.shared.watcherDenseSeconds))
    }

    // Two baselines, because two different questions are being asked. The
    // saved plane answers "does the picture we already have still represent
    // this screen?" — it must only advance when a frame is written, or slow
    // drift would accumulate forever without ever tripping the gate. The tick
    // plane answers "what moved in the last five seconds?", which is what the
    // changed rectangle on each line is describing.
    private var savedPlanes: [CGDirectDisplayID: LumaPlane] = [:]
    private var tickPlanes: [CGDirectDisplayID: LumaPlane] = [:]
    private var lastFrameAt: Date?
    private var latestCamJpeg: Data?
    private var lastSavedCamJpeg: Data?
    private let camDiffThreshold: Double = 0.03

    /// Bumped whenever the state a landing capture would write into stops
    /// being the state it was started against — on stop, on each new tick, and
    /// on the day roll. A capture that lands after its generation has passed is
    /// dropped rather than written: a frame stamped with landing time but
    /// showing 25-second-old pixels is worse than no frame, and it would also
    /// rewind the diff baselines the next tick is judged against.
    private var generation: UInt64 = 0
    private var counters: [CGEventType: UInt32] = [:]
    private var pauseReason: String?
    private var pausedSince: Date?
    private var framesToday = 0
    private var actionsToday = 0
    private var permissionCheck: Timer?

    private static let countedEvents: [(CGEventType, String)] = [
        (.keyDown, "keys"), (.leftMouseDown, "clicks"), (.rightMouseDown, "rclicks"),
        (.scrollWheel, "scroll"), (.leftMouseDragged, "drag"), (.flagsChanged, "mods"),
    ]

    init(screenCapture: ScreenCapture) {
        self.screenCapture = screenCapture
    }

    // ── lifecycle ──────────────────────────────────────────────────────

    func start(bus: DayBus) {
        bus.onDayRoll { [weak self] in
            self?.generation &+= 1
            self?.savedPlanes.removeAll()
            self?.tickPlanes.removeAll()
            self?.lastFrameAt = nil
            self?.framesToday = 0
            self?.actionsToday = 0
        }
        coalescer.onAction = { [weak bus, weak self] action in
            guard let bus else { return }
            var fields = action.fields
            fields["kind"] = action.kind
            bus.append(fields, to: "actions", at: action.at)
            self?.actionsToday += 1
        }
        primeCounters()
        applySettings()
        bus.append(["kind": "watcher_start", "interval_s": Int(interval),
                    "actions": UserSettings.shared.watcherActionsEnabled], to: "activity")
    }

    /// Everything the scheduler cannot see for itself. The scheduler only
    /// reconciles `isEnabled` and `interval`; the camera and the action stream
    /// are this source's own knobs, so without this hook turning either off
    /// would do nothing until the app restarted — which for the action stream
    /// means a privacy switch that does not switch anything off.
    func applySettings() {
        syncCamera()
        syncActions()
    }

    private func syncActions() {
        let wanted = UserSettings.shared.watcherActionsEnabled
        if wanted, !coalescer.isRunning {
            coalescer.start()
            // Accessibility can be revoked mid-session and the monitor keeps
            // handing back a live token, so ask the system rather than trust it.
            permissionCheck?.invalidate()
            permissionCheck = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.coalescer.recheckPermission()
            }
        } else if !wanted, coalescer.isRunning {
            coalescer.stop()
            permissionCheck?.invalidate()
            permissionCheck = nil
        }
    }

    func stop() {
        generation &+= 1
        coalescer.stop()
        permissionCheck?.invalidate()
        permissionCheck = nil
        camera.stop()
        latestCamJpeg = nil
        lastSavedCamJpeg = nil
        savedPlanes.removeAll()
        tickPlanes.removeAll()
        lastFrameAt = nil
    }

    func status() -> [String: Any] {
        var s: [String: Any] = [
            "frames_today": framesToday,
            "actions_today": actionsToday,
            "actions_running": coalescer.isRunning,
            "diff_blocks": diffBlocks,
        ]
        if let health = coalescer.health { s["actions_health"] = health }
        if let reason = pauseReason { s["paused"] = reason }
        return s
    }

    // ── the tick ───────────────────────────────────────────────────────

    func tick(bus: DayBus, done: @escaping (String?) -> Void) {
        switch WatcherPolicy.tickDecision(
            screenLocked: Self.screenIsLocked(),
            secondsSinceLastInput: Self.secondsSinceLastInput(), idleCutoff: idleCutoff) {
        case .pause(let reason):
            return pause(reason, bus: bus, done: done)
        case .capture:
            break
        }
        resume(bus: bus)
        generation &+= 1
        let gen = generation

        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.localizedName ?? "?"
        let bundle = front?.bundleIdentifier ?? ""
        let window = Self.frontmostWindow(pid: front?.processIdentifier)
        let display = DisplayTopology.underMouse ?? DisplayTopology.primary
        let deltas = drainCounters()
        let secure = IsSecureEventInputEnabled()

        if camera.runningDeviceId != nil {
            camera.requestFrame { [weak self] jpeg in
                guard let self, self.generation == gen else { return }
                self.latestCamJpeg = jpeg
            }
        }

        Task.detached { [weak self] in
            guard let self else { return await MainActor.run { done(nil) } }
            let url = Self.browserURL(app: app)
            let focus = Self.focusedElement()
            let image = try? await self.screenCapture.captureImage(on: display,
                                                                   excludeOwnWindows: true)
            let plane = image.flatMap { LumaPlane.make(from: $0) }
            await MainActor.run {
                // Stopped, rolled to a new day, or overtaken by the stall
                // watchdog while this was in flight — drop it.
                guard self.generation == gen else { return done(nil) }
                self.record(image: image, plane: plane, display: display,
                            app: app, bundle: bundle, window: window, url: url,
                            focus: focus, secure: secure, deltas: deltas, bus: bus)
                done(image == nil ? "capture failed" : nil)
            }
        }
    }

    // ── writing the line ───────────────────────────────────────────────

    private func record(image: CGImage?, plane: LumaPlane?, display: DisplayContext?,
                        app: String, bundle: String, window: (title: String?, bounds: [String: Int]?),
                        url: String?, focus: (role: String, chars: Int?)?, secure: Bool,
                        deltas: [String: Int], bus: DayBus) {
        let now = Date()
        var line: [String: Any] = ["app": app]
        if let title = window.title, !title.isEmpty { line["title"] = title }
        if let url, !url.isEmpty { line["url"] = url }
        if let bounds = window.bounds { line["win"] = bounds }
        if secure { line["secure"] = true }
        if let focus {
            line["focus"] = focus.role
            if let chars = focus.chars { line["focus_chars"] = chars }
        }
        if !deltas.isEmpty { line["input"] = deltas }

        if let image, let display {
            line["display"] = Int(display.id)
            // The geometry of the frame AS STORED, not as captured — that is
            // the file a consumer actually opens. Capture is at the display's
            // own size; the stored JPEG is downscaled to a 1568 px long edge.
            let long = CGFloat(max(image.width, image.height))
            let shrink = long > 0 ? min(1.0, 1568.0 / long) : 1.0
            line["geom"] = ["w": Int((CGFloat(image.width) * shrink).rounded()),
                            "h": Int((CGFloat(image.height) * shrink).rounded())]

            // What moved since the last tick — the rectangle is stored, never
            // applied. A crop is irreversible and these frames get cited by
            // name weeks later, so the consumer crops at read time instead.
            if let plane, let previous = tickPlanes[display.id], previous.width == plane.width {
                let moved = ScreenDiff.compare(previous, plane)
                line["chg_blocks"] = moved.changedBlocks
                line["chg_pct"] = Int((moved.fraction * 100).rounded())
                if let box = moved.box {
                    line["chg"] = [box.x, box.y, box.w, box.h]
                    line["chg_of"] = [plane.width, plane.height]
                }
            }
            if let plane { tickPlanes[display.id] = plane }

            // Whether the frame we already hold is still a fair picture.
            var changedBlocks: Int?
            if let plane, let saved = savedPlanes[display.id], saved.width == plane.width {
                changedBlocks = ScreenDiff.compare(saved, plane).changedBlocks
            }
            let naturallyChanged = changedBlocks.map { $0 >= diffBlocks } ?? true
            let save = WatcherPolicy.shouldSaveScreen(
                previousChangedBlocks: changedBlocks, threshold: diffBlocks,
                denseApp: isDense(bundle: bundle),
                secondsSinceLastFrame: lastFrameAt.map { now.timeIntervalSince($0) },
                denseFloor: denseSeconds)
            if save && !naturallyChanged { line["forced"] = true }

            if save {
                if let plane { savedPlanes[display.id] = plane }
                lastFrameAt = now
                framesToday += 1
                line["frame"] = bus.artifact(prefix: "frame", ext: "jpg", at: now) {
                    ImageUtils.jpeg(from: image, maxDimension: 1568, quality: 0.5)
                }
            }
            // Displays that went away should not pin their planes in memory.
            let live = Set(DisplayTopology.displays.map(\.id))
            savedPlanes = savedPlanes.filter { live.contains($0.key) }
            tickPlanes = tickPlanes.filter { live.contains($0.key) }
        }

        if let cam = latestCamJpeg {
            let difference = lastSavedCamJpeg.map { ImageUtils.difference($0, cam) }
            if WatcherPolicy.shouldSaveCamera(
                previousDifference: difference, threshold: camDiffThreshold) {
                lastSavedCamJpeg = cam
                line["cam"] = bus.artifact(prefix: "cam", ext: "jpg", at: now) {
                    ImageUtils.compress(cam, maxDimension: 960, quality: 0.5)
                }
            }
        }

        bus.append(line, to: "activity", at: now)
    }

    // ── guards ─────────────────────────────────────────────────────────

    /// A skipped tick used to be an unexplained hole in the log — idle, a
    /// locked screen and a crashed watcher were indistinguishable after the
    /// fact. Now the edges are recorded, once each, not once per tick.
    private func pause(_ reason: String, bus: DayBus, done: @escaping (String?) -> Void) {
        if pauseReason != reason {
            pauseReason = reason
            pausedSince = Date()
            bus.append(["kind": "pause", "reason": reason], to: "activity")
        }
        done(nil)
    }

    private func resume(bus: DayBus) {
        guard let reason = pauseReason else { return }
        let seconds = pausedSince.map { Int(Date().timeIntervalSince($0)) } ?? 0
        pauseReason = nil
        pausedSince = nil
        bus.append(["kind": "resume", "after": reason, "seconds": seconds], to: "activity")
    }

    private func isDense(bundle: String) -> Bool {
        guard !bundle.isEmpty else { return false }
        return UserSettings.shared.watcherDenseApps.contains(bundle)
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

    // ── counters ───────────────────────────────────────────────────────
    //  Volume of input per tick, read from the counters macOS already keeps.
    //  These need no permission at all, so the shape of a tick survives even
    //  if the action stream goes dark — reading a reply, writing a prompt and
    //  scrolling a feed stay distinguishable either way.

    private func primeCounters() {
        for (type, _) in Self.countedEvents {
            counters[type] = UInt32(CGEventSource.counterForEventType(.combinedSessionState, eventType: type))
        }
    }

    private func drainCounters() -> [String: Int] {
        var out: [String: Int] = [:]
        for (type, key) in Self.countedEvents {
            let now = UInt32(CGEventSource.counterForEventType(.combinedSessionState, eventType: type))
            let previous = counters[type] ?? now
            counters[type] = now
            let delta = now &- previous
            if delta > 0 { out[key] = Int(delta) }
        }
        return out
    }

    // ── environment probes ─────────────────────────────────────────────

    /// Title and bounds of the frontmost app's front window, from one pass of
    /// the window list (the bounds come free with the title).
    private static func frontmostWindow(pid: pid_t?) -> (title: String?, bounds: [String: Int]?) {
        guard let pid else { return (nil, nil) }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return (nil, nil) }
        // An app's first layer-0 window is often an untitled helper (Electron
        // shells in particular), so keep looking for a titled one and only fall
        // back to the first geometry we saw.
        var fallback: (title: String?, bounds: [String: Int]?)?
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? Int == Int(pid),
                  window[kCGWindowLayer as String] as? Int == 0 else { continue }
            let name = window[kCGWindowName as String] as? String
            var bounds: [String: Int]?
            if let raw = window[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) {
                bounds = ["x": Int(rect.minX), "y": Int(rect.minY),
                          "w": Int(rect.width), "h": Int(rect.height)]
            }
            if name?.isEmpty == false { return (name, bounds) }
            if fallback == nil, bounds != nil { fallback = (nil, bounds) }
        }
        return fallback ?? (nil, nil)
    }

    /// What has keyboard focus, as a shape only — the role and how much text
    /// is in it, never the text. Inside a window whose title never changes,
    /// a rising character count is composing and a non-text role with scroll
    /// activity is reading.
    ///
    /// The messaging timeout is set on the focused element only. Setting it on
    /// the system-wide element is documented to apply to the whole process,
    /// which would shorten every other accessibility call the app makes —
    /// including dictation's text-field streaming.
    private static func focusedElement() -> (role: String, chars: Int?)? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return nil }
        var countRef: CFTypeRef?
        var chars: Int?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success {
            chars = countRef as? Int
        }
        return (role, chars)
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
        // SIGTERM is ignorable; escalate so a wedged osascript cannot hold the
        // tick open until the scheduler's stall guard has to step in.
        let killer = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
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
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Facade — what the rest of the app talks to
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class WorkflowWatcher {

    static var baseDir: URL { DayBus.baseDir }

    private let scheduler = SourceScheduler()
    private var statusTimer: Timer?
    var onEvent: ((String, [String: Any], Date) -> Void)? {
        didSet { scheduler.bus.onAppend = onEvent }
    }

    var isRunning: Bool { scheduler.isRunning }

    init(screenCapture: ScreenCapture) {
        scheduler.register(DesktopSource(screenCapture: screenCapture))
    }

    func start() {
        guard !scheduler.isRunning else { return }
        scheduler.start()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.scheduler.writeStatus()
        }
    }

    func stop() {
        guard scheduler.isRunning else { return }
        scheduler.bus.append(["kind": "watcher_stop"], to: "activity")
        statusTimer?.invalidate()
        statusTimer = nil
        scheduler.stop()
    }

    func applySettings() { scheduler.applySettings() }

    func statusLine() -> String { scheduler.statusLine() }

#if VOICE_FLOW_QA
    /// Exercise the same watcher-bus callback used by coalesced desktop
    /// actions without collecting the user's real screen archive.
    func emitQAAction(id: String) {
        scheduler.bus.append(
            ["kind": "qa_action", "id": String(id.prefix(160))],
            to: "actions", at: Date())
    }
#endif
}
