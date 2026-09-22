import Foundation

/// A native source publishes only after its bytes are committed. The root
/// keeps isolated/test stores from refreshing the daily app's derived index.
enum CapturedSourceEvents {
    static let committed = Notification.Name("voiceflow.captured.source-committed")

    static func didCommit(root: URL = VoiceFlowPaths.shared.configRoot) {
        NotificationCenter.default.post(name: committed, object: root.standardizedFileURL)
    }
}
