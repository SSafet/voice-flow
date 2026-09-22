import AppKit
import Foundation
import GRDB

func vflog(_ message: String) { fputs(message + "\n", stderr) }
final class UserSettings {
    static let shared = UserSettings()
    var watcherKeepDays = 30
    var watcherDenseApps: Set<String> = []
}
final class PendingInteraction { var sessionId: String? }
struct CaptureSummary {}
let root = VoiceFlowPaths.shared.configRoot
precondition(VoiceFlowPaths.shared.isIsolated)
let service = try CapturedService(root: root)
try service.catchUpNow()
for count in try service.index.countsByKindAndImageState() {
    print("\(count.kind.rawValue)\t\(count.imageState.rawValue)\t\(count.count)")
}
let progress = service.progress
print("watcher days: \(progress.daysDone)/\(progress.daysTotal); \(progress.state.rawValue)")
try service.index.read { db in
    for row in try Row.fetchAll(db, sql: "SELECT id, origin_device FROM item WHERE kind = 'dictation' AND origin_device IS NOT NULL ORDER BY id") {
        print("remote dictation: \(row["id"] as String)\t\(row["origin_device"] as String)")
    }
}
