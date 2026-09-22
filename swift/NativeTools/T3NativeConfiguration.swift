import Foundation
import CryptoKit

/// Native-owned settings snapshot, returned only on the private MCP connection.
struct T3NativeSettings: Codable, Hashable, Sendable {
    let runCommands: Bool
    let reachNetwork: Bool
    let assistantComputerUse: Bool
    let workspaceRoots: [String]
    let egressAllow: [String]
    let egressBlock: [String]
    let dailyBudgetUSD: Double
    let model: String
    let reasoningEffort: String

    func validate() throws {
        guard dailyBudgetUSD.isFinite, (0...10_000).contains(dailyBudgetUSD),
              !model.isEmpty, model.utf8.count <= 256, !model.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              reasoningEffort.utf8.count <= 64,
              [model, reasoningEffort].allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              [workspaceRoots, egressAllow, egressBlock].allSatisfy({ $0.count <= 256 && $0.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } }) else {
            throw T3NativeToolFailure(code: "native_settings_invalid")
        }
    }
    var policyRevision: String { get throws { try Self.digest(self) } }
    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
struct T3NativeConfiguration: Codable, Hashable, Sendable {
    struct Decisions: Codable, Hashable, Sendable {
        let contextRead: T3NativeToolDecision
        let editWorkspace: T3NativeToolDecision
        let shell: T3NativeToolDecision
    }
    let decisions: Decisions
    let version: Int
    let revision: String
    let binding: T3NativeToolBinding
    let policyRevision: String
    let settings: T3NativeSettings
    init(binding: T3NativeToolBinding, settings: T3NativeSettings, decisions: Decisions) throws {
        try settings.validate()
        struct Content: Encodable { let version = 1; let binding: T3NativeToolBinding; let policyRevision: String; let settings: T3NativeSettings; let decisions: Decisions }
        struct Policy: Encodable { let settings: T3NativeSettings; let decisions: Decisions }
        let policy = try T3NativeSettings.digest(Policy(settings: settings, decisions: decisions))
        self.decisions = decisions
        version = 1; self.binding = binding; self.settings = settings; policyRevision = policy
        revision = try T3NativeSettings.digest(Content(binding: binding, policyRevision: policy, settings: settings, decisions: decisions))
    }
}
