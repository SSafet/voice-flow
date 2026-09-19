import Cocoa
import CoreGraphics

// The two helpers `Annotation.swift` expects from the app's UI layer.
func vflog(_ message: String) { print(message) }
extension NSColor {
    convenience init(r: Int, g: Int, b: Int) {
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

// MarkRenderer — the one drawing code for the eight mark kinds (07 §3.7),
// extracted from the user's annotation canvas. It draws a list of marks into a
// drawing context at a given scale, with (0, 0) at the top-left, which is the
// coordinate space every mark lives in. It is used to compose a marked picture,
// to draw an agent's shape layer, and by the canvas itself, so all three agree.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

let width = 400, height = 300

func makeContext() -> CGContext {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context
}

/// `NSBitmapImageRep.colorAt` uses (0, 0) at the top-left, the same corner
/// every mark uses, so a test can ask about the same pixel a mark names.
func colour(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
}
func isWhite(_ colour: NSColor) -> Bool {
    colour.redComponent > 0.9 && colour.greenComponent > 0.9 && colour.blueComponent > 0.9
}
func nonWhite(_ image: CGImage, x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
    var count = 0
    for x in stride(from: x0, to: x1, by: 3) {
        for y in stride(from: y0, to: y1, by: 3) {
            if !isWhite(colour(image, x, y)) { count += 1 }
        }
    }
    return count
}
func rendered(_ marks: [TPMark]) -> CGImage {
    let context = makeContext()
    MarkRenderer.render(marks, into: context, scale: 1)
    return context.makeImage()!
}

func mark(_ kind: TPMarkKind, box: [Int], color: TPMarkColor = .red, stroke: Int = 6,
          from: [Int]? = nil, to: [Int]? = nil, points: [[Int]]? = nil,
          center: [Int]? = nil, label: Int? = nil, origin: [Int]? = nil, note: String? = nil) -> TPMark {
    TPMark(box: box, center: center, color: color, from: from, kind: kind, label: label, n: 1,
           note: note, origin: origin, points: points, stroke: stroke, to: to, underText: nil)
}

// No marks at all paints nothing: this is what makes a shot with no marks have
// only one file, and it proves the probes below can tell white from drawn.
let blank = rendered([])
for x in stride(from: 0, to: width, by: 17) {
    for y in stride(from: 0, to: height, by: 17) {
        expect(isWhite(colour(blank, x, y)), "an empty mark list draws nothing at (\(x), \(y))")
    }
}

// Every kind draws inside its own box and nowhere near an empty corner.
let cases: [(String, TPMark, (Int, Int, Int, Int))] = [
    ("pen", mark(.pen, box: [40, 40, 120, 80], points: [[40, 40], [80, 80], [160, 120]]), (30, 30, 170, 130)),
    ("highlight", mark(.highlight, box: [40, 40, 120, 80], color: .amber, stroke: 18,
                       points: [[40, 60], [160, 60]]), (30, 50, 170, 80)),
    ("line", mark(.line, box: [40, 40, 120, 80], from: [40, 120], to: [160, 40]), (30, 30, 170, 130)),
    ("arrow", mark(.arrow, box: [40, 40, 120, 80], from: [40, 120], to: [160, 40]), (30, 30, 170, 130)),
    ("rect", mark(.rect, box: [40, 40, 120, 80], color: .green), (30, 30, 170, 130)),
    ("ellipse", mark(.ellipse, box: [40, 40, 120, 80], color: .blue), (30, 30, 170, 130)),
    ("badge", mark(.badge, box: [180, 40, 36, 36], center: [198, 58], label: 2), (170, 30, 230, 90)),
    ("text", mark(.text, box: [40, 180, 220, 40], color: .magenta, stroke: 18,
                  origin: [40, 180], note: "why does 2 fail?"), (30, 170, 270, 230)),
]
for (name, example, region) in cases {
    let image = rendered([example])
    let inside = nonWhite(image, x0: region.0, y0: region.1, x1: region.2, y1: region.3)
    expect(inside > 4, "\(name) draws inside its box: \(inside) samples")
    expect(nonWhite(image, x0: 330, y0: 250, x1: 399, y1: 299) == 0,
           "\(name) draws nothing in an empty corner")
}

// The badge is filled with its colour, which is how an agent's numbered mark is
// read off the picture.
let badge = rendered([mark(.badge, box: [180, 40, 40, 40], color: .red, center: [200, 60], label: 1)])
let badgePixel = colour(badge, 200, 60)
expect(badgePixel.redComponent > 0.5 && badgePixel.greenComponent < 0.4,
       "the badge centre is the badge's colour: \(badgePixel)")

// Scale is the only difference between drawing on a picture and drawing on the
// screen: at scale 2 the same mark reaches twice as far, so a point the small
// mark never touches is covered by the large one.
let small = rendered([mark(.rect, box: [40, 40, 40, 40])])
let context = makeContext()
MarkRenderer.render([mark(.rect, box: [40, 40, 40, 40])], into: context, scale: 2)
let large = context.makeImage()!
expect(!isWhite(colour(small, 60, 60)), "scale 1 draws the box at its own pixels")
expect(isWhite(colour(small, 120, 120)), "scale 1 does not reach the scale 2 corner")
expect(!isWhite(colour(large, 120, 120)), "scale 2 draws the box at twice the origin and size")
expect(!isWhite(colour(large, 100, 100)), "scale 2 fills where the small box cannot reach")

// Composing onto a picture returns a picture of the same size: marks on a
// clean base, and nothing added when there are no marks. This is what makes the
// marked and clean files line up exactly (07 §3.8).
let baseContext = makeContext()
let base = baseContext.makeImage()!
guard let composed = MarkRenderer.compose(base: base, marks: [mark(.rect, box: [40, 40, 120, 80])], scale: 1) else {
    fail("compose returns an image")
}
expect(composed.width == base.width && composed.height == base.height,
       "compose keeps the picture's size: \(composed.width)x\(composed.height)")
expect(nonWhite(composed, x0: 30, y0: 30, x1: 170, y1: 130) > 4, "the composed mark is on the picture")
guard let clean = MarkRenderer.compose(base: base, marks: [], scale: 1) else {
    fail("compose with no marks returns an image")
}
for x in stride(from: 0, to: width, by: 17) {
    for y in stride(from: 0, to: height, by: 17) {
        expect(isWhite(colour(clean, x, y)), "composing no marks changes nothing at (\(x), \(y))")
    }
}

// The canvas's own shapes keep their text style: a plated note paints a dark
// plate where a halo note does not. This is the canvas user of the same
// renderer, and it is not allowed to drift.
func itemRendered(_ item: AnnotationItem) -> CGImage {
    let context = makeContext()
    MarkRenderer.render([item], into: context, scale: 1)
    return context.makeImage()!
}
let halo = itemRendered(.text(string: "note", origin: CGPoint(x: 40, y: 40), color: AnnotationColors[5],
                              fontSize: 16, width: 240, style: .halo))
let plate = itemRendered(.text(string: "note", origin: CGPoint(x: 40, y: 40), color: AnnotationColors[5],
                               fontSize: 16, width: 240, style: .plate))
func darkCount(_ image: CGImage) -> Int {
    var count = 0
    for x in stride(from: 40, to: 280, by: 2) {
        for y in stride(from: 40, to: 120, by: 2) {
            let colour = colour(image, x, y)
            if colour.redComponent < 0.5 && colour.greenComponent < 0.5 && colour.blueComponent < 0.5 { count += 1 }
        }
    }
    return count
}
expect(darkCount(plate) > darkCount(halo) + 5,
       "a plated note paints a darker area than a halo note: \(darkCount(plate)) vs \(darkCount(halo))")

print("mark renderer: eight kinds, scale, compose, and the canvas text styles")
