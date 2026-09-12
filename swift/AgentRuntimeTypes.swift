import Foundation
import CoreFoundation
import CryptoKit

enum AgentRuntimeKind: String, Codable, CaseIterable {
    case codex
    case opencode
    case claude

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .claude: return "Claude Code"
        }
    }

    /// The CLI runtimes draw on a subscription the CLI itself holds; only
    /// OpenCode needs a provider key in Voice Flow's Keychain.
    var usesSubscriptionCLI: Bool { self != .opencode }

    /// The `agent_backend` setting is a string for historical reasons.
    static func fromBackendSetting(_ value: String) -> AgentRuntimeKind {
        AgentRuntimeKind(rawValue: value) ?? .codex
    }
}

enum RuntimeBindingState: String, Codable {
    case clean
    case dirty
}

struct RuntimeBinding: Codable, Equatable {
    /// Old external transcripts contain persona/skills as user messages.
    /// Rebuild once from canonical history when crossing this boundary.
    static let currentInstructionVersion = 1
    var externalSessionID: String?
    var syncedThroughMessageID: UUID?
    var generation: Int
    var state: RuntimeBindingState
    var runtimeVersion: String?
    var lastUsedAt: Date?
    var instructionVersion: Int?
    var instructionFingerprint: String?
    var contextUsage: AgentContextUsage?

    init(externalSessionID: String? = nil,
         syncedThroughMessageID: UUID? = nil,
         generation: Int = 0,
         state: RuntimeBindingState = .dirty,
         runtimeVersion: String? = nil,
         lastUsedAt: Date? = nil,
         instructionVersion: Int? = RuntimeBinding.currentInstructionVersion,
         instructionFingerprint: String? = nil,
         contextUsage: AgentContextUsage? = nil) {
        self.externalSessionID = externalSessionID
        self.syncedThroughMessageID = syncedThroughMessageID
        self.generation = generation
        self.state = state
        self.runtimeVersion = runtimeVersion
        self.lastUsedAt = lastUsedAt
        self.instructionVersion = instructionVersion
        self.instructionFingerprint = instructionFingerprint
        self.contextUsage = contextUsage
    }

    func canResume(through messageID: UUID?) -> Bool {
        state == .clean
            && instructionVersion == Self.currentInstructionVersion
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
    var contextUsage: AgentContextUsage? = nil
}

/// The last model request's footprint, including cached input. Billing totals
/// accumulated across tool calls/turns are deliberately not context usage.
struct AgentContextUsage: Codable, Equatable {
    let inputTokens: Int
    let outputTokens: Int?
    let contextWindow: Int?

    init?(inputTokens: Int, outputTokens: Int? = nil, contextWindow: Int? = nil) {
        guard inputTokens > 0, (outputTokens ?? 0) >= 0,
              !inputTokens.addingReportingOverflow(outputTokens ?? 0).overflow else { return nil }
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.contextWindow = contextWindow.flatMap { $0 > 0 ? $0 : nil }
    }

    var tokens: Int { inputTokens.addingReportingOverflow(outputTokens ?? 0).partialValue }
    var isValid: Bool {
        inputTokens > 0 && (outputTokens ?? 0) >= 0 && tokens >= inputTokens && (contextWindow ?? 1) > 0
    }
    var fractionUsed: Double? {
        guard isValid, let contextWindow, contextWindow > 0 else { return nil }
        return Double(tokens) / Double(contextWindow)
    }

    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value >= 0, value < Double(Int.max), value.rounded(.down) == value else { return nil }
        return number.intValue
    }

    static func codex(_ last: [String: Any], window: Any?, camelCase: Bool) -> AgentContextUsage? {
        // Codex inputTokens already includes cachedInputTokens; never add it twice.
        guard let input = count(last[camelCase ? "inputTokens" : "input_tokens"]),
              let output = count(last[camelCase ? "outputTokens" : "output_tokens"]) else { return nil }
        return AgentContextUsage(inputTokens: input, outputTokens: output, contextWindow: count(window))
    }

    static func claude(_ usage: [String: Any]) -> AgentContextUsage? {
        // Claude's per-step output count is a placeholder, so report only
        // the measured input footprint instead of substituting a turn total.
        guard let measured = inclusive(input: usage["input_tokens"], output: 0,
            cached: usage["cache_read_input_tokens"], written: usage["cache_creation_input_tokens"]) else { return nil }
        return AgentContextUsage(inputTokens: measured.inputTokens)
    }

    static func openCode(_ tokens: [String: Any]) -> AgentContextUsage? {
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        guard let output = count(tokens["output"]),
              let reasoning = tokens["reasoning"] == nil ? 0 : count(tokens["reasoning"]) else { return nil }
        let generated = output.addingReportingOverflow(reasoning)
        guard !generated.overflow else { return nil }
        return inclusive(input: tokens["input"], output: generated.partialValue,
                         cached: cache["read"], written: cache["write"])
    }

    private static func inclusive(input: Any?, output: Any?, cached: Any?, written: Any?) -> AgentContextUsage? {
        guard let input = count(input), let output = count(output),
              let cached = cached == nil ? 0 : count(cached),
              let written = written == nil ? 0 : count(written) else { return nil }
        let first = input.addingReportingOverflow(cached)
        let total = first.partialValue.addingReportingOverflow(written)
        guard !first.overflow, !total.overflow else { return nil }
        return AgentContextUsage(inputTokens: total.partialValue, outputTokens: output)
    }
}

/// Shared by the Assistant and the two one-shot Codex system agents.
/// Arguments are passed directly to Process; only the TOML value is encoded.
enum AgentInstructionEncoding {
    static func fingerprint(_ instructions: String) -> String {
        SHA256.hash(data: Data(instructions.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func tomlString(_ value: String) -> String {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: encoded += "\\\""
            case 0x5C: encoded += "\\\\"
            case 0..<0x20, 0x7F:
                encoded += String(format: "\\u%04X", scalar.value)
            default: encoded.unicodeScalars.append(scalar)
            }
        }
        return encoded + "\""
    }
}
