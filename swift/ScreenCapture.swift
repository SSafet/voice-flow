import ScreenCaptureKit
import AppKit
import Foundation

/// One deterministic predicate owns continuous-capture frame deduplication.
/// Keeping it outside AppDelegate makes the exact threshold independently
/// testable while preserving the current capture routing and storage flow.
enum CaptureFrameDeduplicator {
    static func shouldKeep(previous: Data?, candidate: Data,
                           threshold: Double = 0.01) -> Bool {
        guard let previous else { return true }
        return ImageUtils.difference(previous, candidate) >= threshold
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Screen Capture (SCKit + CLI fallback)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class ScreenCapture {

    func captureScreen(on target: DisplayContext? = nil) async throws -> Data {
        let image = try await captureImage(on: target)
        guard let data = cgImageToData(image) else { throw CaptureError.conversionFailed }
        return data
    }

    /// Prefer this over `captureScreen` when the caller is going to resize,
    /// diff, or encode anyway — it skips a full uncompressed TIFF round trip.
    ///
    /// `excludeOwnWindows` is opt-in and belongs to the ambient watcher alone.
    /// Every other caller NEEDS Voice Flow's own windows in frame: the agent
    /// screenshot path photographs the annotation canvas, the guide overlays
    /// and the shapes drawn by `annotate_screen`, all of which are in-process
    /// panels. Excluding them globally would silently return blank annotations.
    func captureImage(on target: DisplayContext? = nil,
                      excludeOwnWindows: Bool = false) async throws -> CGImage {
        let display = target ?? DisplayTopology.primary
        do {
            return try await captureWithSCKit(on: display, excludeOwnWindows: excludeOwnWindows)
        } catch let error as NSError where error.code == -3801 {
            NSLog("[VF] SCKit denied, falling back to screencapture CLI")
            let data = try await captureWithCLI(on: display)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CaptureError.conversionFailed
            }
            return image
        }
    }

    private func captureWithSCKit(on target: DisplayContext?,
                                  excludeOwnWindows: Bool = false) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = target.flatMap({ wanted in
            content.displays.first(where: { $0.displayID == wanted.id })
        }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        // Keep Voice Flow out of its own frames — for the ambient watcher only.
        // Without it the watcher photographs the panel and reply bubbles, and
        // the nightly review reads its own earlier output back as observed
        // activity. Never do this for the agent paths, whose whole subject is
        // often an in-process overlay.
        var excluded: [SCWindow] = []
        if excludeOwnWindows {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            excluded = content.windows.filter { $0.owningApplication?.processID == ownPID }
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()

        // Capture at the display's own geometry. This was `* scale / 2`, which
        // on a 1x external display halved the resolution outright.
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    private func captureWithCLI(on target: DisplayContext?) async throws -> Data {
        let tmpPath = NSTemporaryDirectory() + "vf-capture-\(UUID().uuidString).png"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        var arguments = ["-x"]
        if let target {
            arguments += ["-D", String(target.captureIndex)]
        }
        arguments.append(tmpPath)
        process.arguments = arguments

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CaptureError.cliFailed(process.terminationStatus)
        }

        let url = URL(fileURLWithPath: tmpPath)
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)

        guard !data.isEmpty else {
            throw CaptureError.conversionFailed
        }

        NSLog("[VF] CLI capture: %d bytes", data.count)
        return data
    }

    private func cgImageToData(_ cgImage: CGImage) -> Data? {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return nsImage.tiffRepresentation
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case windowNotFound
    case conversionFailed
    case cliFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found"
        case .windowNotFound: return "Window not found"
        case .conversionFailed: return "Image conversion failed"
        case .cliFailed(let code): return "screencapture failed (exit \(code))"
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Capture Scheduler (timer-based)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class CaptureScheduler {
    var interval: TimeInterval {
        didSet {
            if isRunning {
                stop()
                start()
            }
        }
    }

    var onCapture: ((Data) -> Void)?
    /// Frozen by the owning continuous CaptureRun before `start()`.
    var targetDisplay: DisplayContext?

    private let screenCapture: ScreenCapture
    private var timer: Timer?
    private var isRunning = false

    init(screenCapture: ScreenCapture, interval: TimeInterval = 30.0) {
        self.screenCapture = screenCapture
        self.interval = interval
    }

    func start() {
        guard !isRunning else {
            NSLog("[VF] CaptureScheduler.start() skipped — already running")
            return
        }
        isRunning = true
        NSLog("[VF] CaptureScheduler started — interval: %.0fs", interval)

        // Capture immediately on start
        Task {
            await capture()
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.capture()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        NSLog("[VF] CaptureScheduler stopped")
    }

    private func capture() async {
        do {
            let data = try await screenCapture.captureScreen(on: targetDisplay)
            NSLog("[VF] CaptureScheduler captured %d bytes", data.count)
            onCapture?(data)
        } catch {
            NSLog("[VF] CaptureScheduler capture error: %@", "\(error)")
        }
    }
}
