import ScreenCaptureKit
import AppKit
import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Image Utilities
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum ImageUtils {
    /// Downscale so the long edge is at most `maxDimension` PIXELS, then JPEG.
    ///
    /// This used to size the target from `NSImage.size`, which is in points,
    /// and render through `lockFocus`, whose backing store is allocated at the
    /// deepest attached screen's scale factor. On a Retina Mac both halves of
    /// that compounded: asking for 1568 wrote a 3136 px file, ~3.6x the bytes
    /// for pixels the vision path immediately throws away. Everything now goes
    /// through one explicit CGContext at an exact pixel size.
    static func compress(_ data: Data, maxDimension: CGFloat = 1568, quality: CGFloat = 0.7) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return jpeg(from: image, maxDimension: maxDimension, quality: quality)
    }

    /// The same downscale-and-encode straight off a CGImage — no intermediate
    /// TIFF, which is the expensive part of the old path.
    static func jpeg(from image: CGImage, maxDimension: CGFloat = 1568, quality: CGFloat = 0.7) -> Data? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, maxDimension / max(w, h))
        let outW = max(1, Int((w * scale).rounded()))
        let outH = max(1, Int((h * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let scaled = ctx.makeImage() else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Resize to an exact pixel size (JPEG). Used for agent screenshots so
    /// tool coordinates map 1:1 onto a known image geometry.
    static func resizeExact(_ data: Data, width: Int, height: Int, quality: CGFloat = 0.7) -> Data? {
        guard width > 0, height > 0, let image = NSImage(data: data) else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func difference(_ a: Data, _ b: Data) -> Double {
        let size = 32
        guard let thumbA = thumbnail(a, size: size),
              let thumbB = thumbnail(b, size: size) else { return 1.0 }

        let bytesPerPixel = 4
        let totalPixels = size * size
        let totalBytes = totalPixels * bytesPerPixel

        guard thumbA.count >= totalBytes, thumbB.count >= totalBytes else { return 1.0 }

        var totalDiff: Int = 0
        for i in 0..<totalPixels {
            let offset = i * bytesPerPixel
            let rDiff = abs(Int(thumbA[offset]) - Int(thumbB[offset]))
            let gDiff = abs(Int(thumbA[offset + 1]) - Int(thumbB[offset + 1]))
            let bDiff = abs(Int(thumbA[offset + 2]) - Int(thumbB[offset + 2]))
            totalDiff += rDiff + gDiff + bDiff
        }

        return Double(totalDiff) / Double(255 * 3 * totalPixels)
    }

    private static func thumbnail(_ data: Data, size: Int) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let thumbSize = NSSize(width: size, height: size)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        image.draw(in: NSRect(origin: .zero, size: thumbSize),
                   from: .zero,
                   operation: .copy,
                   fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let pixelData = ctx.data else { return nil }
        return Data(bytes: pixelData, count: size * size * 4)
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
