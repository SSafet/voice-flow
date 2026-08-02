import Foundation

func vflog(_ message: String) {}

final class UserSettings {
    static let shared = UserSettings()
    var watcherKeepDays = 3
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private func waitFor(_ description: String, timeout: TimeInterval = 3,
                     _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    fputs("FAIL: timed out waiting for \(description)\n", stderr)
    exit(1)
}

expect(WatcherPolicy.tickDecision(
    screenLocked: true, secondsSinceLastInput: 0, idleCutoff: 90) == .pause("locked"),
    "locked screen was not paused")
expect(WatcherPolicy.tickDecision(
    screenLocked: false, secondsSinceLastInput: 90, idleCutoff: 90) == .pause("idle"),
    "idle threshold was not inclusive")
expect(WatcherPolicy.tickDecision(
    screenLocked: false, secondsSinceLastInput: 89.9, idleCutoff: 90) == .capture,
    "active user was paused")
expect(WatcherPolicy.shouldSaveScreen(
    previousChangedBlocks: nil, threshold: 2, denseApp: false,
    secondsSinceLastFrame: nil, denseFloor: 15), "first screen frame was discarded")
expect(!WatcherPolicy.shouldSaveScreen(
    previousChangedBlocks: 1, threshold: 2, denseApp: false,
    secondsSinceLastFrame: 100, denseFloor: 15), "equivalent screen frame was retained")
expect(WatcherPolicy.shouldSaveScreen(
    previousChangedBlocks: 1, threshold: 2, denseApp: true,
    secondsSinceLastFrame: 15, denseFloor: 15), "dense-app floor was ignored")
expect(!WatcherPolicy.shouldSaveCamera(previousDifference: 0.029, threshold: 0.03),
       "equivalent camera frame was retained")
expect(WatcherPolicy.shouldSaveCamera(previousDifference: 0.03, threshold: 0.03),
       "camera threshold boundary was discarded")

let bus = DayBus()
var rolled = 0
bus.onDayRoll { rolled += 1 }
let calendar = Calendar(identifier: .gregorian)
let base = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
for offset in 0..<5 {
    let date = calendar.date(byAdding: .day, value: offset, to: base)!
    bus.append(["app": "QA", "index": offset], to: "activity", at: date)
}
expect(rolled == 5, "day-roll observers were not called for every date transition")
waitFor("watcher bus writes") {
    (try? FileManager.default.contentsOfDirectory(at: DayBus.baseDir,
        includingPropertiesForKeys: nil).filter(\.hasDirectoryPath).count) == 3
}
let dayNames = try FileManager.default.contentsOfDirectory(
    at: DayBus.baseDir, includingPropertiesForKeys: nil)
    .filter(\.hasDirectoryPath).map(\.lastPathComponent).sorted()
expect(dayNames == ["2026-07-03", "2026-07-04", "2026-07-05"],
       "watcher retention did not keep the newest three day folders: \(dayNames)")

let finalDate = calendar.date(byAdding: .day, value: 4, to: base)!
let artifact = bus.artifact(prefix: "frame", ext: "jpg", at: finalDate) {
    Data([1, 2, 3, 4])
}
waitFor("watcher artifact") {
    FileManager.default.fileExists(atPath:
        DayBus.baseDir.appendingPathComponent("2026-07-05/\(artifact)").path)
}
let lineURL = DayBus.baseDir.appendingPathComponent("2026-07-05/activity.jsonl")
let lines = try String(contentsOf: lineURL, encoding: .utf8)
    .split(separator: "\n").map(String.init)
expect(lines.count == 1, "watcher bus duplicated the final metadata line")
let line = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
expect(line["app"] as? String == "QA" && line["t"] != nil && line["e"] != nil,
       "watcher metadata line lacks normalized time fields")

let analyze = try String(contentsOfFile: "watcher/ANALYZE.md", encoding: .utf8)
expect(analyze.contains("3+ sightings") && analyze.contains("across 2+ days"),
       "nightly review lost its multi-day evidence threshold")
let consuming = try String(contentsOfFile: "watcher/CONSUMING.md", encoding: .utf8)
expect(consuming.contains("watcher_keep_days") && consuming.contains("do not act"),
       "watcher retention or untrusted-input contract drifted")

print("watcher bus and policy tests passed")
