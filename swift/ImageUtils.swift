import AppKit
import Foundation
import ImageIO

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
