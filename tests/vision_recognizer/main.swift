import Foundation
import ImageIO

// VisionTextRecognizer (07 §3.5). Apple's Vision reads text on the device,
// returns the lines with their boxes — which is what "the text under each mark"
// is computed from — and names the languages it was given, where the absence of
// Bulgarian is the known limit Safet is told about.

private var failures: [String] = []
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do { if try !condition() { failures.append(message) } }
    catch { failures.append("\(message) — the check itself threw \(error)") }
}
private func finish(_ label: String) -> Never {
    if failures.isEmpty { print("\(label): ok"); exit(0) }
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    fputs("\(label): \(failures.count) failure(s)\n", stderr)
    exit(1)
}

let fixture = URL(fileURLWithPath: "tests/vision_recognizer/fixture-text.png")
guard let data = try? Data(contentsOf: fixture) else {
    fputs("FAIL: the fixture picture is missing: \(fixture.path)\n", stderr)
    exit(1)
}
guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("FAIL: the fixture picture could not be read\n", stderr)
    exit(1)
}
let width = image.width
let height = image.height

let recognizer = VisionTextRecognizer()
let recognised: RecognizedText
do {
    recognised = try recognizer.recognize(data)
} catch {
    fputs("FAIL: Vision threw \(error)\n", stderr)
    exit(1)
}

expect(recognised.text.contains("Pantrella"), "Vision did not read 'Pantrella' from the fixture: \(recognised.text)")
expect(recognised.text.contains("Disney"), "Vision did not read 'Disney' from the fixture: \(recognised.text)")
expect(recognised.lines.count >= 2, "Vision did not return the two lines with their boxes")
expect(recognised.lines.allSatisfy { !$0.text.isEmpty }, "a recognised line carries no text")
for line in recognised.lines {
    expect(line.box.count == 4, "a line's box is not four numbers: \(line.box)")
    expect(line.box[0] >= 0 && line.box[1] >= 0 && line.box[2] > 0 && line.box[3] > 0,
           "a line's box is not inside the picture: \(line.box)")
    expect(line.box[0] + line.box[2] <= width && line.box[1] + line.box[3] <= height,
           "a line's box runs past the picture: \(line.box) in \(width)x\(height)")
}

// The languages are the ones of 07 §3.5: English, Russian and Ukrainian; the
// absence of Bulgarian is the limit the Captures status shows.
expect(recognizer.languages.contains("en-US"), "English is not among the recognition languages")
expect(recognizer.languages.contains("ru-RU"), "Russian is not among the recognition languages")
expect(recognizer.languages.contains("uk-UA"), "Ukrainian is not among the recognition languages")
expect(!recognizer.languages.contains("bg-BG"), "Bulgarian was claimed as supported when it is not")

// The box helper computes what a mark covers: the whole picture holds both lines.
expect(recognised.text(in: [0, 0, width, height]).contains("Disney"),
       "the text inside a box over the whole picture does not hold the picture's text")

finish("vision recognizer")
