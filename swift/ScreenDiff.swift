import CoreGraphics
import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Screen diffing — block-localized, not one global number
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  The watcher used to hold the previous frame as an uncompressed TIFF and
//  re-decode BOTH frames every tick just to produce one "how different"
//  scalar. That cost ~5.5 ms on the main thread, retained ~7.7 MB, and told
//  us only *how much* changed — never *where*.
//
//  Instead each capture is rasterized once into a small 8-bit grayscale
//  plane (~596 KB retained) and compared block by block. That is cheaper
//  than the old scalar AND yields the changed region, which is what lets a
//  reviewer tell "typing in a small composer" from "the whole window
//  switched" without opening the image.

struct LumaPlane {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    /// Rasterize a capture into a gray plane whose long edge is `targetWidth`.
    /// Aspect ratio is preserved — a square rescale would compress the
    /// horizontal axis ~2.4x on a wide display and misplace every block.
    static func make(from image: CGImage, targetWidth: Int = 960) -> LumaPlane? {
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1.0, Double(targetWidth) / Double(srcW))
        let w = max(1, Int((Double(srcW) * scale).rounded()))
        let h = max(1, Int((Double(srcH) * scale).rounded()))

        // Gamma-encoded gray, NOT linear. Drawing an sRGB screenshot into a
        // linear-gray context decodes gamma and crushes the dark range: an
        // sRGB 30→50 change — the band every dark theme's selections, hovers
        // and panel swaps live in — arrives as a delta of 5, under every
        // threshold below. On a dark-mode desktop that makes the diff blind.
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }

        let rowBytes = ctx.bytesPerRow
        var pixels = [UInt8](repeating: 0, count: w * h)
        let src = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let from = y * rowBytes
            let to = y * w
            for x in 0..<w { pixels[to + x] = src[from + x] }
        }
        return LumaPlane(width: w, height: h, pixels: pixels)
    }
}

struct ScreenDiff {
    /// Blocks whose content moved, out of `totalBlocks`.
    let changedBlocks: Int
    let totalBlocks: Int
    /// Bounding box of the changed blocks, in plane coordinates
    /// (top-left origin), or nil when nothing moved.
    let box: (x: Int, y: Int, w: Int, h: Int)?

    var fraction: Double {
        totalBlocks > 0 ? Double(changedBlocks) / Double(totalBlocks) : 0
    }

    /// A block counts as changed when its mean absolute luma delta clears
    /// `blockThreshold`, or when enough individual pixels move by more than
    /// `pixelDelta` — the second test catches a small high-contrast edit
    /// (a caret, a short line of text) that the mean would average away.
    ///
    /// The top slice of the plane is ignored: the menu-bar clock ticks every
    /// minute and would otherwise mark the screen as changed forever. It is a
    /// fraction, not a pixel count — a constant copied from a 1x source render
    /// would remove no block row at our geometry.
    /// Defaults calibrated against synthetic cases spanning what actually has
    /// to be caught and what must not be. Caught: a dark-theme sidebar
    /// selection (sRGB 30→50), a hover state (24→38), a light-mode row
    /// selection (235→215), a message appearing. Rejected: a blinking text
    /// caret and the menu-bar clock ticking over. `pixelCount` is what
    /// separates them — a caret is too few pixels to clear it however bright
    /// it is, while a selection band is thousands.
    static func compare(_ a: LumaPlane, _ b: LumaPlane,
                        blockSize: Int = 64,
                        blockThreshold: Int = 6,
                        pixelDelta: Int = 10,
                        pixelCount: Int = 100,
                        ignoreTopFraction: Double = 0.02) -> ScreenDiff {
        // Geometry changed (display swap, resolution change): nothing is
        // comparable, so report everything changed. It must fail toward
        // SAVING — a sentinel below the save threshold would leave the stale
        // wrong-sized plane in place and latch capture off for that display
        // for the rest of the day, silently.
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0 else {
            let n = max(1, ((b.width + blockSize - 1) / blockSize) * ((b.height + blockSize - 1) / blockSize))
            return ScreenDiff(changedBlocks: n, totalBlocks: n, box: (0, 0, b.width, b.height))
        }
        let w = a.width, h = a.height
        let skipRows = Int((Double(h) * ignoreTopFraction).rounded())
        let cols = (w + blockSize - 1) / blockSize
        let rows = (h + blockSize - 1) / blockSize

        var changed = 0
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0

        for by in 0..<rows {
            let y0 = by * blockSize
            let y1 = min(y0 + blockSize, h)
            if y1 <= skipRows { continue }
            let yStart = max(y0, skipRows)
            for bx in 0..<cols {
                let x0 = bx * blockSize
                let x1 = min(x0 + blockSize, w)
                var sum = 0
                var hits = 0
                for y in yStart..<y1 {
                    let row = y * w
                    for x in x0..<x1 {
                        let d = abs(Int(a.pixels[row + x]) - Int(b.pixels[row + x]))
                        sum += d
                        if d > pixelDelta { hits += 1 }
                    }
                }
                let area = (y1 - yStart) * (x1 - x0)
                guard area > 0 else { continue }
                let mean = sum / area
                if mean > blockThreshold || hits >= pixelCount {
                    changed += 1
                    minX = min(minX, x0); minY = min(minY, yStart)
                    maxX = max(maxX, x1); maxY = max(maxY, y1)
                }
            }
        }

        let total = cols * rows
        guard changed > 0 else { return ScreenDiff(changedBlocks: 0, totalBlocks: total, box: nil) }
        return ScreenDiff(changedBlocks: changed, totalBlocks: total,
                          box: (minX, minY, maxX - minX, maxY - minY))
    }
}
