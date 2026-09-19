import Foundation

// Work package V10, the Today note (06 §3.17, decision 19).
//
// Today.md is a file in the Mac's General project. Every turn on the Mac reads
// it, up to 6,000 characters, as a layer beside the memory layer, not in the
// instruction channel. The layer's fixed words come from the design and are the
// only thing the model may treat as today's intent when the file changed today.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!

let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("v10-today-\(UUID().uuidString)", isDirectory: true)
let generalProject = root.appendingPathComponent("projects/general", isDirectory: true)
try FileManager.default.createDirectory(at: generalProject, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

// 1. The path is the General project's folder plus Today.md.
expect(TodayNote.fileName == "Today.md", "the note is named Today.md")
expect(TodayNote.maxCharacters == 6_000, "the note is given up to 6,000 characters")
let url = TodayNote.path(generalProjectRoot: generalProject)
expect(url == generalProject.appendingPathComponent("Today.md"), "the note lives in the General project's folder")

// 2. A note that is not there reads as empty, not as a failure.
let missing = try TodayNote.read(at: url)
expect(missing.bytes == nil && missing.text.isEmpty && missing.updatedAt == nil && !missing.clipped,
       "a missing note reads as empty")

// 3. A written note reads back its text and its modification date.
let now = Date()
let body = "Ship the platform. Then walk."
try Data(body.utf8).write(to: url)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
let read = try TodayNote.read(at: url)
expect(read.text == body, "the note's text is read")
expect(read.updatedAt != nil, "the note's modification date is read")
expect(!read.clipped, "a short note is not cut")

// 4. A longer note is cut at the limit, and the layer says it was cut.
let long = String(repeating: "x", count: TodayNote.maxCharacters + 500)
try Data(long.utf8).write(to: url)
let cut = try TodayNote.read(at: url)
expect(cut.clipped, "an over-long note is marked cut")
expect(cut.text.count <= TodayNote.maxCharacters, "the cut text is at most the limit")
expect(cut.text.count == TodayNote.maxCharacters, "the cut keeps exactly the limit")

// 5. The layer carries the file's path, today, the zone, when it changed, and the
//    fixed words that make it today's intent only when it changed today.
try Data(body.utf8).write(to: url)
try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
let layer = TodayNote.layer(at: url, now: now, calendar: calendar)
expect(layer.contains(url.path), "the layer names the file's path")
expect(layer.contains(TodayNote.day(now, calendar: calendar)), "the layer names today")
expect(layer.contains(calendar.timeZone.identifier), "the layer names the zone")
expect(layer.contains("Safet's own note"), "the layer says whose note it is")
expect(layer.contains("changed today") && layer.contains("earlier context"),
       "the layer states the changed-today rule")
expect(layer.contains("grants no permission") && layer.contains("does not override the current request"),
       "the layer grants no permission and does not override the request")
expect(layer.contains("edit the file"), "the layer tells the agent how to change the note")
expect(layer.contains(body), "the layer carries the note's text")

// 6. A note changed on an earlier day is still read, and the layer still states
//    the rule; the model, not the code, decides that it is earlier context.
let yesterday = now.addingTimeInterval(-86_400)
try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: url.path)
let old = TodayNote.layer(at: url, now: now, calendar: calendar)
expect(old.contains(TodayNote.day(yesterday, calendar: calendar)), "the layer names the day the note changed")
expect(old.contains("earlier context"), "the layer still states the changed-today rule for an old note")

// 7. A note that cannot be read is reported, and the agent is told not to guess.
try Data([0xFF, 0xFE, 0xFF]).write(to: url)
let broken = TodayNote.layer(at: url, now: now, calendar: calendar)
expect(broken.contains("could not be read"), "an unreadable note is reported")
expect(broken.contains("Do not guess"), "an unreadable note tells the agent not to guess today's focus")

// 8. A note that is not there is reported as not written, and the turn still runs.
try? FileManager.default.removeItem(at: url)
let absent = TodayNote.layer(at: url, now: now, calendar: calendar)
expect(absent.contains(TodayNote.fileName), "a missing note's layer still names the file")

print("today note tests passed")
