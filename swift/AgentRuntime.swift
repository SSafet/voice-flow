import Foundation

struct AgentRuntimeCapabilities: Equatable {
    let images: Bool
    let nativeTools: Bool
    let skills: Bool
    let externalMCP: Bool
    let permissions: Bool
}

struct AgentModelSelection: Codable, Equatable {
    let provider: String
    let model: String
    /// How hard the model should think, when the model exposes the knob.
    /// Provider-specific and deliberately a free string — OpenCode calls this
    /// a model *variant* ("minimal"/"low"/"high"/"max" depending on provider),
    /// codex takes the same idea as `model_reasoning_effort`. Nil means the
    /// provider default, so an unset config behaves exactly as before.
    let reasoningEffort: String?

    init(provider: String, model: String, reasoningEffort: String? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = AgentReasoningEffort.normalized(reasoningEffort)
    }

    /// Codex picks its model from the user's own codex settings — Voice Flow
    /// only ever overrides how hard it thinks. Nil when there is nothing to
    /// override, so that path keeps sending no model config at all.
    static func codex(reasoningEffort: String?) -> AgentModelSelection? {
        guard let effort = AgentReasoningEffort.normalized(reasoningEffort) else { return nil }
        return AgentModelSelection(provider: "codex", model: "", reasoningEffort: effort)
    }
}

struct AgentTurnRequest {
    let turnID: UUID
    let conversationID: String
    let assistant: AssistantDefinition?
    let priorMessages: [AssistantHistoryMessage]
    let prompt: String
    let screenshots: [Data]
    let workingDirectory: URL
    let extraWritableRoots: [String]
    let trustProfile: AgentTrustProfile
    let model: AgentModelSelection?
    var sourceContext: String = ""
    var sourceAccessMode: AgentSourceAccessMode = .standard

    func replacingPrompt(_ value: String) -> AgentTurnRequest {
        AgentTurnRequest(
            turnID: turnID, conversationID: conversationID,
            assistant: assistant, priorMessages: priorMessages,
            prompt: value, screenshots: screenshots,
            workingDirectory: workingDirectory,
            extraWritableRoots: extraWritableRoots,
            trustProfile: trustProfile, model: model,
            sourceContext: sourceContext, sourceAccessMode: sourceAccessMode)
    }
}

struct AgentPermissionRequest: Equatable {
    let id: String
    let title: String
    let detail: String
}

enum AgentRuntimeEvent {
    case started(externalSessionID: String)
    case activity(String)
    case textDelta(partID: String, delta: String)
    case permission(AgentPermissionRequest)
    case usage(AgentUsage)
    case completed(text: String)
    case failed(AgentRuntimeFailure)
    case interrupted
}

struct AgentRuntimeFailure: LocalizedError, Equatable {
    let code: String
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }
}

enum AgentRuntimeHealth: String, Equatable {
    case starting
    case healthy
    case degraded
    case crashed
    case versionMismatch
    case stopped
}

struct AgentRuntimeStatus: Equatable {
    let health: AgentRuntimeHealth
    let version: String?
    let detail: String?
}

struct AgentTurnResult {
    let externalSessionID: String?
    let runtimeVersion: String?
    let text: String
    let usage: AgentUsage?
}

protocol AgentRuntime: AnyObject {
    var kind: AgentRuntimeKind { get }
    var capabilities: AgentRuntimeCapabilities { get }
    func status() async -> AgentRuntimeStatus
    func run(_ request: AgentTurnRequest,
             binding: RuntimeBinding?,
             emit: @escaping (AgentRuntimeEvent) -> Void) async throws -> AgentTurnResult
    func cancel(turnID: UUID) async
}
