import ScreenCaptureKit
import AppKit
import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Image Utilities
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum ImageUtils {
    static func compress(_ data: Data, maxDimension: CGFloat = 1568, quality: CGFloat = 0.7) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        let scale: CGFloat
        if max(size.width, size.height) > maxDimension {
            scale = maxDimension / max(size.width, size.height)
        } else {
            scale = 1.0
        }
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize))
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }

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

    func captureScreen() async throws -> Data {
        do {
            return try await captureWithSCKit()
        } catch let error as NSError where error.code == -3801 {
            NSLog("[VF] SCKit denied, falling back to screencapture CLI")
            return try await captureWithCLI()
        }
    }

    private func captureWithSCKit() async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width = Int(display.width) * Int(scale) / 2
        config.height = Int(display.height) * Int(scale) / 2
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        guard let data = cgImageToData(image) else {
            throw CaptureError.conversionFailed
        }
        return data
    }

    private func captureWithCLI() async throws -> Data {
        let tmpPath = NSTemporaryDirectory() + "vf-capture-\(UUID().uuidString).png"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", tmpPath]

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
            let data = try await screenCapture.captureScreen()
            NSLog("[VF] CaptureScheduler captured %d bytes", data.count)
            onCapture?(data)
        } catch {
            NSLog("[VF] CaptureScheduler capture error: %@", "\(error)")
        }
    }
}
