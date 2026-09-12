import Foundation

// Isolated server fixture: production HTTP/probe/upsert code, temporary stores.
struct VoiceFlowPaths {
    static let shared = VoiceFlowPaths()
    let configRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SYNC_TEST_ROOT"]!)
}
struct Entry {
    var id: String?
    var text: String
    var time: String
    var timestamp: String?
    var destination: Destination?
}
enum Destination: String { case pasted, kept }
enum DictationsView {
    static var entries: [Entry] = []
    static func recentEntries(limit: Int) -> [Entry] { Array(entries.prefix(limit)) }
}
final class UserSettings {
    static let shared = UserSettings()
    var customVocabulary: [String] = []
    var agentModel = "test"
    var llmCleanupEnabled = false
}
final class KeychainStore {
    static let shared = KeychainStore()
    func loadOpenAIAPIKey() -> String? { nil }
    func loadAgentAPIKey() -> String? { nil }
}
func vflog(_ message: String) {}
let server = SyncServer()
server.onDictations = { entries in
    Thread.sleep(forTimeInterval: 0.05) // Force the old async-response race.
    for e in entries {
        DictationsView.entries.removeAll { $0.id == e.id }
        DictationsView.entries.insert(Entry(id: e.id, text: e.text, time: e.time,
            timestamp: e.timestamp, destination: Destination(rawValue: e.destination)), at: 0)
    }
}
server.start()
RunLoop.main.run()
