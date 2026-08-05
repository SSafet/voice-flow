import Foundation

enum AgentRuntimeKind: String, Codable, CaseIterable {
    case codex
    case opencode

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
}

enum RuntimeBindingState: String, Codable {
    case clean
    case dirty
}

struct RuntimeBinding: Codable, Equatable {
    var externalSessionID: String?
    var syncedThroughMessageID: UUID?
    var generation: Int
    var state: RuntimeBindingState
    var runtimeVersion: String?
    var lastUsedAt: Date?

    init(externalSessionID: String? = nil,
         syncedThroughMessageID: UUID? = nil,
         generation: Int = 0,
         state: RuntimeBindingState = .dirty,
         runtimeVersion: String? = nil,
         lastUsedAt: Date? = nil) {
        self.externalSessionID = externalSessionID
        self.syncedThroughMessageID = syncedThroughMessageID
        self.generation = generation
        self.state = state
        self.runtimeVersion = runtimeVersion
        self.lastUsedAt = lastUsedAt
    }

    func canResume(through messageID: UUID?) -> Bool {
        state == .clean
            && externalSessionID != nil
            && syncedThroughMessageID == messageID
    }
}

/// The effort ladder both backends understand — OpenCode passes the raw
/// string on as the model *variant*, codex as `model_reasoning_effort` — with
/// "" meaning *the provider decides*, which is what every model did before
/// this setting existed. The levels are read from the shipping binaries:
/// OpenCode 1.17.11 stores per-model variant sets whose richest is
/// minimal…max, and codex carries the same ladder plus a codex-only `ultra`,
/// which is left out because no OpenCode variant set contains it. A model
/// without a given level falls back to its own default.
enum AgentReasoningEffort {
    static let unset = ""
    static let choices: [(value: String, label: String)] = [
        (unset, "Provider default"),
        ("minimal", "Minimal"),
        ("low", "Low"),
        ("medium", "Medium"),
        ("high", "High"),
        ("xhigh", "Extra high"),
        ("max", "Max"),
    ]

    static func label(for value: String?) -> String {
        let normalized = normalized(value) ?? unset
        return choices.first { $0.value == normalized }?.label ?? normalized
    }

    /// Empty, blank, or unknown values mean "provider default" rather than a
    /// string the runtime would forward and the provider would reject.
    static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        return choices.contains { $0.value == lowered } ? lowered : nil
    }
}

enum AgentTrustProfile: String, Codable, CaseIterable {
    case observe
    case workspace
    case unattended
}

enum AgentPermissionResponse: String, Codable, Equatable {
    case once
    case reject
}

enum AgentExecutionOwnershipIssue: Equatable {
    case missingAssistant
    case conversationOwnerMismatch

    static func resolve(jobAssistantSlug: String,
                        conversationAssistantSlug: String?,
                        assistantAvailable: Bool) -> AgentExecutionOwnershipIssue? {
        guard assistantAvailable else { return .missingAssistant }
        guard conversationAssistantSlug == jobAssistantSlug else {
            return .conversationOwnerMismatch
        }
        return nil
    }
}

/// Provider-neutral accounting returned by foreground turns and durable jobs.
/// This lives with the shared runtime value types so the loopback model
/// gateway can report usage without importing the higher-level runtime loop.
struct AgentUsage: Equatable {
    let inputTokens: Int?
    let outputTokens: Int?
    let costUSD: Decimal?
}
