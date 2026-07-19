import Cocoa

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
let png = bitmap.representation(using: .png, properties: [:])!
let imageURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("vf-clipboard-\(UUID().uuidString).png")
try png.write(to: imageURL)
defer { try? FileManager.default.removeItem(at: imageURL) }

let rich = CaptureClipboard.makeContent(
    text: "Look <here> & compare", attachmentPaths: [imageURL.path])
expect(rich.imageCount == 1, "valid attachment must be decoded")
expect(rich.plainText.contains(imageURL.path), "plain fallback must retain the local path")
expect(rich.html != nil, "valid attachment must produce HTML")
expect(rich.rtfd != nil, "valid attachment must produce RTFD")
let html = String(data: rich.html!, encoding: .utf8)!
expect(html.contains("data:image/png;base64,"), "HTML must embed the image bytes")
expect(html.contains("Look &lt;here&gt; &amp; compare"), "HTML must escape narration")
let pasteboard = NSPasteboard.withUniqueName()
CaptureClipboard.copy(
    text: "Look <here> & compare", attachmentPaths: [imageURL.path], to: pasteboard)
expect(pasteboard.pasteboardItems?.count == 1, "rich capture must be one pasteboard item")
let types = Set(pasteboard.pasteboardItems?.first?.types ?? [])
expect(types.contains(.string) && types.contains(.html) && types.contains(.rtfd),
       "one item must advertise plain, HTML, and RTFD representations")

let missingPath = "/tmp/voice-flow-file-that-does-not-exist.jpg"
let fallback = CaptureClipboard.makeContent(
    text: "Still useful", attachmentPaths: [missingPath])
expect(fallback.imageCount == 0, "missing attachment must not become a rich image")
expect(fallback.html == nil && fallback.rtfd == nil, "missing attachment must omit rich formats")
expect(fallback.plainText.contains(missingPath), "missing attachment path must survive in plain text")

let textOnly = CaptureClipboard.makeContent(text: "Just words", attachmentPaths: [])
expect(textOnly.plainText == "Just words", "text-only history must preserve exact copy behavior")

print("capture clipboard tests passed")
