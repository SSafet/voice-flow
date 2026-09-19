import Cocoa

// The user's marks on disk at version 3 (07 §3.7): each stored mark gains its
// order number, a version 2 file loads with the order taken from its position,
// and the stored mark converts to the contract's Mark. The same file still
// keeps the rich canvas shape (text style, typography) it had at version 2,
// because a `Mark` cannot carry those.

// The two helpers `Annotation.swift` expects from the app's UI layer.
func vflog(_ message: String) { print(message) }
extension NSColor {
    convenience init(r: Int, g: Int, b: Int) {
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("s3-annotations-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let store = AnnotationStore(url: root.appendingPathComponent("annotations.json"))

// A version 2 file, written the way the old format really wrote it.
let version2 = """
{"version":2,"items":[
 {"text":{"_0":"old note","_1":[10,20],"_2":{"red":1,"green":0,"blue":0,"alpha":1},"_3":16,"_4":300}},
 {"shape":{"_0":"rect","_1":[100,100],"_2":[300,250],"_3":{"red":0,"green":0.5,"blue":1,"alpha":1},"_4":4}}
]}
"""
try Data(version2.utf8).write(to: store.url)

let upgraded = try store.loadOrdered()
expect(upgraded.count == 2, "the version 2 file loads two marks, not \(upgraded.count)")
expect(upgraded.map(\.n) == [1, 2], "a version 2 mark's order is its position: \(upgraded.map(\.n))")
let legacy = try store.load()
expect(legacy.count == 2, "the existing reader still sees both marks in order")

let marks = try store.loadMarks()
expect(marks.count == 2, "loadMarks returns both marks")
expect(marks.map(\.n) == [1, 2], "loadMarks carries the order: \(marks.map(\.n))")
expect(marks[0].kind == .text && marks[0].note == "old note", "the note survives the conversion: \(marks[0])")
expect(marks[0].origin == [10, 20], "the text mark keeps its origin: \(String(describing: marks[0].origin))")
expect(marks[1].kind == .rect && marks[1].box == [100, 100, 200, 150],
       "the rectangle keeps its box: \(marks[1].box)")
expect(marks[1].color == .blue, "the rectangle keeps its colour name: \(marks[1].color)")

// Saving writes version 3, and every stored mark carries its order number.
try store.saveOrdered(try store.loadOrdered())
let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
guard let raw else { fail("the saved file is JSON") }
expect(raw["version"] as? Int == 3, "the saved file is version 3, not \(String(describing: raw["version"]))")
guard let stored = raw["marks"] as? [[String: Any]] else { fail("version 3 stores marks") }
expect(stored.count == 2, "both marks are stored")
expect(stored.compactMap { $0["n"] as? Int } == [1, 2], "each stored mark carries its order number")

// The order is the mark's own `n`, not its position: a jumbled file comes back
// in order, and writing it again is stable.
let jumbled = """
{"version":3,"marks":[
 {"n":5,"item":{"text":{"_0":"five","_1":[0,0],"_2":{"red":0,"green":0,"blue":0,"alpha":1},"_3":12,"_4":200}}},
 {"n":2,"item":{"text":{"_0":"two","_1":[0,0],"_2":{"red":0,"green":0,"blue":0,"alpha":1},"_3":12,"_4":200}}}
]}
"""
try Data(jumbled.utf8).write(to: store.url)
let reordered = try store.loadOrdered()
expect(reordered.map(\.n) == [2, 5], "stored marks come back in their own order: \(reordered.map(\.n))")
try store.saveOrdered(reordered)
let firstPass = try Data(contentsOf: store.url)
try store.saveOrdered(try store.loadOrdered())
let secondPass = try Data(contentsOf: store.url)
expect(secondPass == firstPass, "saving what was loaded changes nothing")

// Every canvas shape converts to the contract's Mark.
func itemMark(_ item: AnnotationItem, _ n: Int) -> TPMark { MarkConversion.mark(from: item, n: n) }
let stroke = itemMark(.stroke(points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
                             color: AnnotationColors[0], width: 5), 1)
expect(stroke.kind == .pen && stroke.points == [[1, 2], [3, 4]] && stroke.stroke == 5,
       "a stroke is a pen mark: \(stroke.kind)")
let highlight = itemMark(.highlight(points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
                                    color: AnnotationColors[1], width: 14), 2)
expect(highlight.kind == .highlight && highlight.color == .amber,
       "a highlight keeps its kind and colour: \(highlight.kind) \(highlight.color)")
for (shape, expected) in [(AnnotationShapeKind.line, TPMarkKind.line), (.arrow, .arrow),
                          (.rect, .rect), (.ellipse, .ellipse)] {
    let mark = itemMark(.shape(kind: shape, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 60),
                               color: AnnotationColors[3], width: 4), 3)
    expect(mark.kind == expected, "\(shape) converts to \(expected), not \(mark.kind)")
    expect(mark.from == [10, 10] && mark.to == [50, 60], "\(shape) keeps from and to")
}
let badge = itemMark(.number(value: 7, center: CGPoint(x: 40, y: 50), color: AnnotationColors[4], diameter: 30), 4)
expect(badge.kind == .badge && badge.center == [40, 50] && badge.label == 7,
       "a number stamp is a badge with its label: \(badge.kind)")
let note = itemMark(.text(string: "why?", origin: CGPoint(x: 5, y: 6), color: AnnotationColors[5],
                          fontSize: 16, width: 240, style: .halo), 5)
expect(note.kind == .text && note.note == "why?" && note.origin == [5, 6],
       "a typed note is a text mark: \(note.kind)")

// The six contract colour names map to the six canvas colours and back.
let names = ["red", "amber", "green", "blue", "magenta", "white"]
for (index, name) in names.enumerated() {
    expect(MarkConversion.colorName(AnnotationColors[index]) == name,
           "canvas colour \(index) is \(name), not \(MarkConversion.colorName(AnnotationColors[index]))")
    let rgb = MarkConversion.color(named: name).usingColorSpace(.sRGB)!
    let wanted = AnnotationColors[index].usingColorSpace(.sRGB)!
    expect(abs(rgb.redComponent - wanted.redComponent) < 0.001
           && abs(rgb.greenComponent - wanted.greenComponent) < 0.001
           && abs(rgb.blueComponent - wanted.blueComponent) < 0.001,
           "\(name) maps back to the canvas colour")
}
expect(names.contains(MarkConversion.colorName(NSColor(srgbRed: 0.123, green: 0.456, blue: 0.789, alpha: 1))),
       "a colour is mapped to one of the six contract names, never an invented one")

print("annotations v3: order preserved, version 3 written, five canvas shapes convert")
