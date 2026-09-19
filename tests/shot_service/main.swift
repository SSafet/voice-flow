import Cocoa
import CoreGraphics

// ShotService — the one way a screenshot comes to exist (07 §3.8). It captures
// the display without Voice Flow's own windows, projects the user's marks for
// that display, composes the marked picture and writes it beside the clean one
// (only one file when there are no marks), so the two pictures line up exactly.
// Display capture only; a bundle frame and an agent's `screen_capture` use the
// same function, so every shot carries its context and its marks.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("s3-shots-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let primary = DisplayContext(
    id: 1, frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
    backingScaleFactor: 1, captureIndex: 1)
let laptop = DisplayContext(
    id: 2, frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
    visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1055),
    backingScaleFactor: 2, captureIndex: 2)
let displays = [primary, laptop]
let shotDisplays = [ShotDisplay(uuid: "A", display: primary), ShotDisplay(uuid: "B", display: laptop)]
let virtualFrame = DisplayTopology.virtualFrame(for: displays.map(\.frame))

func whiteImage(_ width: Int, _ height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

final class StubCapture: ScreenCapturing {
    let image: CGImage
    init(image: CGImage) { self.image = image }
    func captureImage(on display: DisplayContext, excludeOwnWindows: Bool) async throws -> CGImage { image }
}

func context(_ app: String, display: TPContextDisplay, index: Int) -> TPContext {
    TPContext(app: app, bundleID: nil, display: display, pointer: [100, 200], contextPrivate: false,
              url: nil, windowBox: nil, windowTitle: "\(app) window")
}
let primaryDisplay = TPContextDisplay(heightPt: 900, index: 1, scale: 1, uuid: "A", widthPt: 1440)
let laptopDisplay = TPContextDisplay(heightPt: 1080, index: 2, scale: 2, uuid: "B", widthPt: 1920)

func pixelSize(_ path: String) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (image.width, image.height)
}
func topLeftColour(_ path: String, _ x: Int, _ y: Int) -> NSColor? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
}

let pen = TPMark(box: [720, 400, 20, 20], center: nil, color: .red, from: nil, kind: .pen, label: nil,
                 n: 1, note: nil, origin: nil, points: [[720, 400], [760, 440]], stroke: 4, to: nil,
                 underText: nil)
let laptopPen = TPMark(box: [2400, 400, 20, 20], center: nil, color: .blue, from: nil, kind: .pen,
                       label: nil, n: 2, note: nil, origin: nil, points: [[2400, 400], [2440, 440]],
                       stroke: 4, to: nil, underText: nil)

// A shot with marks: two files, the marked one carries the mark and the clean
// one is the untouched capture at the named size.
var stamped: [String] = []
var tick = 0.0
let service = ShotService(
    capture: StubCapture(image: whiteImage(2880, 1800)),
    paths: ShotPaths(directory: root),
    clock: { tick += 1; return Date(timeIntervalSince1970: 1_760_000_000 + tick) })
service.onShot = { stamped.append($0.shot.id) }

let withMarks = try await service.take(
    display: primary, context: context("Chrome", display: primaryDisplay, index: 1),
    marks: [pen, laptopPen], virtualFrame: virtualFrame,
    bundleID: nil)

expect(withMarks.shot.id.hasPrefix("shot:"), "the shot's item id is a shot: id: \(withMarks.shot.id)")
expect(withMarks.shot.width == 2880 && withMarks.shot.height == 1800,
       "the shot reports the picture's pixel size: \(withMarks.shot.width)x\(withMarks.shot.height)")
expect(withMarks.shot.path == withMarks.markedPath, "the shot points at the marked picture")
expect(FileManager.default.fileExists(atPath: withMarks.markedPath), "the marked picture is written")
guard let cleanPath = withMarks.cleanPath else { fail("a shot with marks writes the clean picture too") }
expect(FileManager.default.fileExists(atPath: cleanPath), "the clean picture is written")
expect(withMarks.shot.marks.count == 1, "only the mark on this display travels: \(withMarks.shot.marks.count)")
expect(withMarks.shot.marks[0].points == [[1440, 440], [1520, 520]],
       "the mark is projected to the picture's pixels: \(String(describing: withMarks.shot.marks[0].points))")
expect(withMarks.shot.context.app == "Chrome", "the shot carries its context")
expect(withMarks.shot.path!.hasSuffix("shot-\(withMarks.shot.id.dropFirst("shot:".count)).jpg"),
       "the file name and the id agree: \(withMarks.shot.path!)")
expect(withMarks.cleanPath!.hasSuffix(".clean.jpg"), "the clean picture is the .clean variant: \(cleanPath)")
expect(pixelSize(cleanPath)?.width == 2880 && pixelSize(cleanPath)?.height == 1800,
       "the clean picture is the named size")
expect(pixelSize(withMarks.markedPath)?.width == 2880 && pixelSize(withMarks.markedPath)?.height == 1800,
       "the marked picture is the named size")
let markedBytes = try Data(contentsOf: URL(fileURLWithPath: withMarks.markedPath))
let cleanBytes = try Data(contentsOf: URL(fileURLWithPath: cleanPath))
expect(markedBytes != cleanBytes, "the marked picture differs from the clean one")
if let dark = topLeftColour(withMarks.markedPath, 1450, 450) {
    expect(dark.redComponent < 0.95, "the mark is visible on the marked picture: \(dark)")
} else { fail("the marked picture decodes") }
if let base = topLeftColour(cleanPath, 1450, 450) {
    expect(base.redComponent > 0.95 && base.greenComponent > 0.95 && base.blueComponent > 0.95,
           "the clean picture has no mark: \(base)")
} else { fail("the clean picture decodes") }
expect(stamped == [withMarks.shot.id], "the live hook fires once with the finished shot")

// No marks: one file only, and no clean variant to leave behind.
let cleanOnly = try await service.take(
    display: laptop, context: context("Safari", display: laptopDisplay, index: 2),
    marks: [], virtualFrame: virtualFrame, bundleID: nil)
expect(cleanOnly.cleanPath == nil, "a shot with no marks has no clean variant")
expect(cleanOnly.shot.marks.isEmpty, "a shot with no marks carries no marks")
expect(FileManager.default.fileExists(atPath: cleanOnly.markedPath), "the only picture is written")
let stem = String(cleanOnly.markedPath.split(separator: "/").last!.dropFirst("shot-".count).dropLast(".jpg".count))
expect(!FileManager.default.fileExists(atPath: ShotPaths(directory: root).cleanURL(for: stem).path),
       "a shot with no marks writes no clean file")
expect(stamped.count == 2, "the live hook fires for every shot")

// Which displays a capture takes: marks decide when there are any; otherwise
// the input does (07 §3.8).
let pointerShot = try await service.takeForCapture(
    TPScreenCaptureInput(display: nil), displays: shotDisplays, marks: [], virtualFrame: virtualFrame,
    pointer: primary, context: { display in
        display.id == primary.id
            ? context("primary", display: primaryDisplay, index: 1)
            : context("laptop", display: laptopDisplay, index: 2)
    })
expect(pointerShot.count == 1 && pointerShot[0].shot.context.app == "primary",
       "with no marks and no display input, the display under the pointer is captured")
let allShots = try await service.takeForCapture(
    TPScreenCaptureInput(display: "all"), displays: shotDisplays, marks: [], virtualFrame: virtualFrame,
    pointer: primary, context: { display in
        context(display.id == primary.id ? "primary" : "laptop",
                display: display.id == primary.id ? primaryDisplay : laptopDisplay,
                index: display.id == primary.id ? 1 : 2)
    })
expect(allShots.count == 2, "`all` captures every attached display: \(allShots.count)")
expect(Set(allShots.map(\.shot.context.app)) == ["primary", "laptop"],
       "each shot asks for the context of its own display")
let namedShot = try await service.takeForCapture(
    TPScreenCaptureInput(display: "B"), displays: shotDisplays, marks: [], virtualFrame: virtualFrame,
    pointer: primary, context: { display in
        display.id == laptop.id
            ? context("laptop", display: laptopDisplay, index: 2)
            : context("primary", display: primaryDisplay, index: 1)
    })
expect(namedShot.count == 1 && namedShot[0].shot.context.app == "laptop",
       "a display uuid captures that display: \(namedShot.map(\.shot.context.app))")
let markedShots = try await service.takeForCapture(
    TPScreenCaptureInput(display: nil), displays: shotDisplays, marks: [laptopPen],
    virtualFrame: virtualFrame, pointer: primary,
    context: { display in
        display.id == laptop.id
            ? context("laptop", display: laptopDisplay, index: 2)
            : context("primary", display: primaryDisplay, index: 1)
    })
expect(markedShots.count == 1 && markedShots[0].shot.context.app == "laptop",
       "marks decide the display, not the pointer: \(markedShots.map(\.shot.context.app))")
expect(markedShots[0].cleanPath != nil, "the marked display's shot has a clean variant")

print("shot service: marked and clean files, one file without marks, display choice, live hook")
