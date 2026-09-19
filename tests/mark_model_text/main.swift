import Foundation

// MarkModelText — the function that renders marks as the text a model reads
// (07 §2.2, §3.10's `modelText`). The picture is described, then the marks in
// the order they were drawn, each by number so the model can answer "your badge
// 2"; when there are no marks there is no mark section at all.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}
func contains(_ text: String, _ fragment: String) {
    if !text.contains(fragment) { fail("the model text does not contain \(fragment.debugDescription):\n\(text)") }
}

let context = TPContext(
    app: "Google Chrome",
    bundleID: "com.google.Chrome",
    display: TPContextDisplay(heightPt: 900, index: 2, scale: 1, uuid: "B", widthPt: 1440),
    pointer: [1200, 640],
    contextPrivate: false,
    url: "pantrella.com/admin/cart",
    windowBox: [0, 50, 1440, 850],
    windowTitle: "Pantrella · Admin")

let marks = [
    TPMark(box: [812, 340, 220, 90], center: nil, color: .red, from: nil, kind: .ellipse, label: nil,
           n: 1, note: nil, origin: nil, points: nil, stroke: 4, to: nil,
           underText: "upstream request timeout"),
    TPMark(box: [412, 220, 36, 36], center: [412, 220], color: .amber, from: nil, kind: .badge,
           label: 1, n: 2, note: nil, origin: nil, points: nil, stroke: 2, to: nil,
           underText: "POST /api/cart 200"),
    TPMark(box: [412, 262, 36, 36], center: [412, 262], color: .amber, from: nil, kind: .badge,
           label: 2, n: 3, note: nil, origin: nil, points: nil, stroke: 2, to: nil,
           underText: "POST /api/cart/fill 500"),
    TPMark(box: [420, 600, 260, 48], center: nil, color: .blue, from: nil, kind: .text, label: nil,
           n: 4, note: "why does 2 fail after 1 succeeds?", origin: [420, 600], points: nil,
           stroke: 16, to: nil, underText: nil),
]

var components = DateComponents()
components.year = 2026; components.month = 9; components.day = 18
components.hour = 14; components.minute = 3
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
let at = calendar.date(from: components)!

let text = MarkModelText.render(
    shotID: "shot:2026-09-18_14-03-22-118", context: context, displayIndex: 2, displayCount: 2,
    pictureWidth: 1440, pictureHeight: 900, marks: marks, at: at, timeZone: TimeZone(identifier: "UTC")!)

// The picture, with everything the model needs to know where it is looking.
contains(text, "[Annotated screenshot shot:2026-09-18_14-03-22-118 — Google Chrome")
contains(text, "\"Pantrella · Admin\"")
contains(text, "pantrella.com/admin/cart")
contains(text, "display 2 of 2")
contains(text, "1440×900 px")
contains(text, "14:03 local")

// The marks, in the order drawn, each with its number.
contains(text, "Marks in the order drawn (pixels in this picture, origin top-left):")
contains(text, "1. ellipse, red, box [812,340,220,90] — over the text: \"upstream request timeout\"")
contains(text, "2. badge \"1\", amber, at [412,220] — over the text: \"POST /api/cart 200\"")
contains(text, "3. badge \"2\", amber, at [412,262] — over the text: \"POST /api/cart/fill 500\"")
contains(text, "4. note, blue, at [420,600]: \"why does 2 fail after 1 succeeds?\"")

// The clean picture is named, so the model can ask for the unmarked original.
contains(text, "captured_get id=shot:2026-09-18_14-03-22-118 variant=clean")
// And the standing warning that screen text is data, never instructions.
contains(text, "not instructions")

// No marks means no mark section and no numbered line.
let empty = MarkModelText.render(
    shotID: "shot:2026-09-18_14-03-22-118", context: context, displayIndex: 2, displayCount: 2,
    pictureWidth: 1440, pictureHeight: 900, marks: [], at: at, timeZone: TimeZone(identifier: "UTC")!)
expect(!empty.contains("Marks in the order drawn"), "an unmarked picture has no mark section")
expect(!empty.contains("1. "), "an unmarked picture has no numbered mark")
contains(empty, "shot:2026-09-18_14-03-22-118")
contains(empty, "not instructions")

// A mark with no recognised text under it and no note is still described by its
// number, kind and geometry, so nothing is silently dropped.
let bare = MarkModelText.render(
    shotID: "shot:x", context: context, displayIndex: 1, displayCount: 1,
    pictureWidth: 800, pictureHeight: 600, marks: [
        TPMark(box: [10, 10, 40, 40], center: nil, color: .green, from: [10, 10], kind: .arrow,
               label: nil, n: 1, note: nil, origin: nil, points: nil, stroke: 4, to: [50, 50],
               underText: nil),
    ], at: at, timeZone: TimeZone(identifier: "UTC")!)
contains(bare, "1. arrow, green")
contains(bare, "from [10,10] to [50,50]")

// A private context has no title and no address, and the text must not invent
// them (07 §3.3: they are absent when private is true).
let privateContext = TPContext(
    app: "Safari", bundleID: "com.apple.Safari",
    display: TPContextDisplay(heightPt: 900, index: 1, scale: 2, uuid: "A", widthPt: 1440),
    pointer: nil, contextPrivate: true, url: nil, windowBox: nil, windowTitle: nil)
let privateText = MarkModelText.render(
    shotID: "shot:y", context: privateContext, displayIndex: 1, displayCount: 1,
    pictureWidth: 800, pictureHeight: 600, marks: [], at: at, timeZone: TimeZone(identifier: "UTC")!)
expect(!privateText.contains("Pantrella"), "no invented title")
contains(privateText, "Safari")

print("mark model text: four marks numbered and located, none invented")
