import Foundation

final class AgentRuntimeJobExecutor: AgentJobExecuting {
    private let history: AssistantHistoryStore
    private let codex: CodexAgentRuntime
    private let openCode: OpenCodeAgentRuntime
    private let environmentProvider: (String) -> AgentToolEnvironment
    private let lock = NSLock()
    private var active: [String: (AgentRuntimeKind, UUID)] = [:]

    init(history: AssistantHistoryStore = .shared,
         codex: CodexAgentRuntime = CodexAgentRuntime(),
         openCode: OpenCodeAgentRuntime = OpenCodeAgentRuntime(),
         environmentProvider: @escaping (String) -> AgentToolEnvironment = { _ in
             AgentToolEnvironment()
         }) {
        self.history = history
        self.codex = codex
        self.openCode = openCode
        self.environmentProvider = environmentProvider
    }

    func execute(job: AgentJob, run: AgentRun,
                 progress: @escaping (String) -> Void) async throws -> AgentJobExecutionResult {
        guard let conversation = history.conversation(job.conversationID) else {
            throw AgentSupervisorError.missingConversation
        }
        let assistant = AssistantsStore.shared.assistant(slug: job.assistantSlug)
        switch AgentExecutionOwnershipIssue.resolve(
            jobAssistantSlug: job.assistantSlug,
            conversationAssistantSlug: conversation.assistantSlug,
            assistantAvailable: assistant != nil) {
        case .missingAssistant:
            throw AgentRuntimeFailure(
                code: "missing_assistant",
                message: "The automation's Assistant is unavailable.",
                retryable: false)
        case .conversationOwnerMismatch:
            throw AgentRuntimeFailure(
                code: "assistant_owner_mismatch",
                message: "The automation conversation belongs to a different Assistant.",
                retryable: false)
        case nil:
            break
        }
        guard let assistant else { preconditionFailure("ownership preflight lost Assistant") }
        let sourceContext = try AgentSourceContext.freeze(sourceIDs: job.selectedSourceIDs)
        let copiesOnly = job.sourceAccessMode == .reviewCopies
        defer {
            if copiesOnly { history.invalidateRuntimeBindingsAfterSourceReview(sessionId: job.conversationID) }
        }
        guard let preparation = history.beginRuntimeTurn(
            sessionId: job.conversationID, runtime: job.runtime, text: job.prompt) else {
            if history.conversation(job.conversationID) != nil {
                throw AgentRuntimeFailure(
                    code: "conversation_busy",
                    message: "The conversation is already running.",
                    retryable: true)
            }
            throw AgentSupervisorError.missingConversation
        }
        let layers = AgentPromptComposer.layers(
            assistant: assistant, priorMessages: preparation.priorMessages,
            task: job.prompt,
            includeHandoff: copiesOnly || preparation.requiresFreshSession,
            includeSkillBodies: !copiesOnly && job.runtime == .codex,
            sourceContext: sourceContext)
        let request = AgentTurnRequest(
            turnID: run.turnID, conversationID: job.conversationID,
            assistant: assistant, priorMessages: preparation.priorMessages,
            prompt: AgentPromptComposer.compose(
                layers, includeIdentity: copiesOnly || preparation.requiresFreshSession),
            screenshots: [],
            workingDirectory: assistant.directory,
            extraWritableRoots: [], trustProfile: job.trustProfile,
            model: copiesOnly || job.runtime == .opencode
                ? AgentModelSelection(
                    provider: "openrouter",
                    model: job.modelID ?? AgentJobRuntimeConfiguration.shared.model().model,
                    reasoningEffort: job.reasoningEffort)
                : AgentModelSelection.codex(reasoningEffort: job.reasoningEffort),
            sourceContext: sourceContext, sourceAccessMode: job.sourceAccessMode)
        let binding = preparation.resumeExternalSessionID.map {
            RuntimeBinding(
                externalSessionID: $0,
                syncedThroughMessageID: preparation.priorContextMessageID,
                state: .clean)
        }
        if !copiesOnly {
            AgentToolSessionRegistry.shared.prepare(
                turnID: run.turnID, environment: environmentProvider(job.conversationID))
        }
        lock.withLock { active[run.id] = (job.runtime, run.turnID) }
        defer { lock.withLock { active.removeValue(forKey: run.id) } }
        let runtime: any AgentRuntime = job.runtime == .codex ? codex : openCode
        do {
            let emit: (AgentRuntimeEvent) -> Void = { event in
                switch event {
                case .started(let externalID):
                    self.history.recordRuntimeStarted(
                        sessionId: job.conversationID, runtime: job.runtime,
                        externalSessionID: externalID,
                        fresh: preparation.requiresFreshSession)
                case .activity(let detail): progress(detail)
                case .permission(let permission):
                    progress("Blocked for permission: \(permission.title)")
                case .textDelta, .usage, .completed, .failed, .interrupted: break
                }
            }
            let result: AgentTurnResult
            if copiesOnly { result = try await SourceReviewRuntime.shared.run(request, emit: emit) }
            else { result = try await runtime.run(request, binding: binding, emit: emit) }
            let message = history.completeRuntimeTurn(
                sessionId: job.conversationID, runtime: job.runtime,
                text: result.text, externalSessionID: result.externalSessionID,
                runtimeVersion: result.runtimeVersion)
            return AgentJobExecutionResult(
                resultMessageID: message?.id, usage: result.usage)
        } catch {
            history.endRuntimeTurnWithoutFinal(
                sessionId: job.conversationID,
                interrupted: error is CancellationError)
            throw error
        }
    }

    func cancel(runID: String) async {
        guard let value = lock.withLock({ active[runID] }) else { return }
        await SourceReviewRuntime.shared.cancel(turnID: value.1)
        if value.0 == .codex { await codex.cancel(turnID: value.1) }
        else { await openCode.cancel(turnID: value.1) }
    }
}
