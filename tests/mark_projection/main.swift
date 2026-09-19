import Cocoa
import CoreGraphics

// MarkProjector — the one conversion between the user's canvas (desktop points,
// top-left origin, one canvas across all displays) and the pixels of a
// display's picture (07 §3.7). The scale is the display's width in points
// divided by the picture's width in pixels. The same functions are used in
// both directions, so an agent's arrow lands where the user's mark was.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

// Two displays of different scale, exactly the case the design names.
let primary = DisplayContext(
    id: 1,
    frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
    backingScaleFactor: 1,
    captureIndex: 1)
let laptop = DisplayContext(
    id: 2,
    frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
    visibleFrame: NSRect(x: 1440, y: 0, width: 1920, height: 1055),
    backingScaleFactor: 2,
    captureIndex: 2)
let displays = [primary, laptop]
let virtualFrame = DisplayTopology.virtualFrame(for: displays.map(\.frame))
expect(virtualFrame == NSRect(x: 0, y: 0, width: 3360, height: 1080),
       "the canvas covers both displays: \(virtualFrame)")

// The primary is 1440 pt wide with a 2880 px picture (scale 0.5); the laptop is
// 1920 pt wide with a 1920 px picture (scale 1.0).
let primaryPicture = 2880
let laptopPicture = 1920

// A point in the primary's picture space subtracts the display origin and
// divides by its scale; the laptop's divides by 1.
let onPrimary = MarkProjector.toPicture(
    CGPoint(x: 720, y: 400), on: primary, virtualFrame: virtualFrame, pictureWidth: primaryPicture)
expect(onPrimary.x == 1440 && onPrimary.y == 440,
       "the primary point becomes picture pixels: \(onPrimary)")
let onLaptop = MarkProjector.toPicture(
    CGPoint(x: 2400, y: 400), on: laptop, virtualFrame: virtualFrame, pictureWidth: laptopPicture)
expect(onLaptop.x == 960 && onLaptop.y == 400,
       "the laptop point becomes picture pixels: \(onLaptop)")

// Drawing an agent's mark is the same conversion in reverse, and it is exact.
for point in [CGPoint(x: 720, y: 400), CGPoint(x: 0, y: 0), CGPoint(x: 1439.5, y: 899.5)] {
    let there = MarkProjector.toPicture(point, on: primary, virtualFrame: virtualFrame, pictureWidth: primaryPicture)
    let back = MarkProjector.toCanvas(there, on: primary, virtualFrame: virtualFrame, pictureWidth: primaryPicture)
    expect(abs(back.x - point.x) < 0.0001 && abs(back.y - point.y) < 0.0001,
           "a primary point round-trips: \(point) -> \(there) -> \(back)")
}

// A mark belongs to the display that contains the centre of its box.
let primaryBox = [720, 400, 20, 20]
let laptopBox = [2400, 400, 20, 20]
expect(MarkProjector.display(containingBox: primaryBox, displays: displays, virtualFrame: virtualFrame)?.id == primary.id,
       "a box on the primary is assigned to the primary")
expect(MarkProjector.display(containingBox: laptopBox, displays: displays, virtualFrame: virtualFrame)?.id == laptop.id,
       "a box on the laptop is assigned to the laptop")
expect(MarkProjector.display(containingBox: [4000, 400, 10, 10], displays: displays, virtualFrame: virtualFrame) == nil,
       "a box over no display has no owner")

// Whole marks convert: geometry scales, the stroke scales, the words do not.
let pen = TPMark(
    box: primaryBox, center: nil, color: .red, from: nil, kind: .pen, label: nil, n: 3,
    note: "a note", origin: nil, points: [[720, 400], [730, 410]], stroke: 4, to: nil, underText: "under")
let projected = MarkProjector.project(pen, on: primary, virtualFrame: virtualFrame, pictureWidth: primaryPicture)
expect(projected.box == [1440, 440, 40, 40], "the box scales: \(projected.box)")
expect(projected.points == [[1440, 440], [1460, 460]], "every point scales: \(projected.points!)")
expect(projected.stroke == 8, "the stroke scales to picture pixels: \(projected.stroke)")
expect(projected.n == 3 && projected.kind == .pen && projected.note == "a note" && projected.underText == "under",
       "order, kind, note and underText travel unchanged")
let unprojected = MarkProjector.unproject(projected, on: primary, virtualFrame: virtualFrame, pictureWidth: primaryPicture)
expect(unprojected.points == pen.points && unprojected.stroke == pen.stroke,
       "unproject is the inverse for geometry: \(unprojected.points!)")

// The user's marks are split by display; a mark over no display is dropped and
// counted, so ShotService never invents a display for it.
let laptopPen = TPMark(
    box: laptopBox, center: nil, color: .blue, from: nil, kind: .pen, label: nil, n: 4,
    note: nil, origin: nil, points: [[2400, 400], [2410, 410]], stroke: 4, to: nil, underText: nil)
let stray = TPMark(
    box: [4000, 400, 10, 10], center: nil, color: .green, from: nil, kind: .rect, label: nil, n: 5,
    note: nil, origin: nil, points: nil, stroke: 4, to: nil, underText: nil)
let grouped = MarkProjector.projectAll(
    [pen, laptopPen, stray], displays: displays, virtualFrame: virtualFrame,
    pictureWidth: { $0.id == primary.id ? primaryPicture : laptopPicture })
expect(grouped.byDisplay[primary.id]?.count == 1, "the primary has one mark")
expect(grouped.byDisplay[laptop.id]?.count == 1, "the laptop has one mark")
expect(grouped.dropped == 1, "the mark over no display is dropped: \(grouped.dropped)")
expect(grouped.byDisplay[primary.id]?.first?.points == [[1440, 440], [1460, 460]],
       "the primary's mark carries primary pixels")
expect(grouped.byDisplay[laptop.id]?.first?.points == [[960, 400], [970, 410]],
       "the laptop's mark carries laptop pixels")

print("mark projector: two displays, both directions, \(grouped.dropped) stray mark dropped")
