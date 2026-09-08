import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--prompt" {
    print(DailyFocus.prompt(from: URL(fileURLWithPath: CommandLine.arguments[2])))
    exit(0)
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-daily-focus-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let url = root.appendingPathComponent("FOCUS-NOW.md")
let now = ISO8601DateFormatter().date(from: "2026-09-08T09:00:00Z")!
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Europe/Sofia")!
let missing = try DailyFocus.read(from: url)
expect(missing.bytes == nil && !missing.isCurrent(at: now), "missing context must not be active")
try DailyFocus.replace("Focus X", expected: missing, at: now, to: url)
let first = try DailyFocus.read(from: url)
expect(first.text == "Focus X" && first.isCurrent(at: now, calendar: calendar), "saved context must be active today")
expect(String(data: first.bytes!, encoding: .utf8)!.hasPrefix("Updated: 2026-09-08T09:00:00Z\n"), "first line must carry ISO timestamp")
let unchanged = DailyFocus.prompt(from: url, at: now.addingTimeInterval(60), calendar: calendar)
expect(DailyFocus.prompt(from: url, at: now, calendar: calendar) == unchanged, "unchanged daily context must not force runtime reseeding every second")
let threeDaysLater = now.addingTimeInterval(3 * 86400)
expect(!first.isCurrent(at: threeDaysLater, calendar: calendar), "three-day-old focus must be historical")
let stalePrompt = DailyFocus.prompt(from: url, at: threeDaysLater, calendar: calendar)
expect(stalePrompt.contains("historical only") && stalePrompt.contains("REPLACE") && stalePrompt.contains("Do not blend stale focus"), "stale prompt must require replacement")
try DailyFocus.replace("Focus Y", expected: first, at: threeDaysLater, to: url)
let next = try DailyFocus.read(from: url)
expect(next.text == "Focus Y" && !next.text.contains("Focus X"), "replacement must not blend old focus")
expect(next.isCurrent(at: threeDaysLater, calendar: calendar), "replacement must be active on the new day")
do { try DailyFocus.replace("Stale editor", expected: first, at: threeDaysLater, to: url); fatalError("conflict must fail") }
catch {}
expect((try? DailyFocus.read(from: url).text) == "Focus Y", "conflict must preserve current content")
expect(!next.isCurrent(at: now, calendar: calendar), "future date must not become today's intent")
let beforeMidnight = ISO8601DateFormatter().date(from: "2026-09-08T20:59:59Z")!
try DailyFocus.replace("Late focus", expected: next, at: beforeMidnight, to: url)
let late = try DailyFocus.read(from: url)
expect(late.isCurrent(at: beforeMidnight, calendar: calendar), "local-day context should apply before midnight")
expect(!late.isCurrent(at: beforeMidnight.addingTimeInterval(2), calendar: calendar), "local midnight must expire context")
try Data("Undated old focus".utf8).write(to: url)
let undated = try DailyFocus.read(from: url)
expect(undated.text == "Undated old focus" && !undated.isCurrent(at: now), "undated text must remain historical")
try Data("Updated: nonsense\n\nBroken date focus".utf8).write(to: url)
expect((try? DailyFocus.read(from: url).updatedAt) == nil, "malformed timestamps must not be active")
let invalid = try DailyFocus.read(from: url)
try DailyFocus.replace("", expected: invalid, at: now, to: url)
expect((try? DailyFocus.read(from: url).status(at: now)) == "No active daily context", "blank save clears active context")
let empty = try DailyFocus.read(from: url)
do { try DailyFocus.replace(String(repeating: "x", count: 6001), expected: empty, at: now, to: url); fatalError("oversize must fail") } catch {}
print("daily focus: fresh/stale/future/undated, midnight expiry, replacement, conflict protection, bounds and stable instruction fingerprint passed")
