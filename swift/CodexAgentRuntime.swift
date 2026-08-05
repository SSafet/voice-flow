import Foundation

/// Runtime-neutral adapter around the existing Codex CLI JSONL backend.
final class CodexAgentRuntime: AgentRuntime {
    let kind: AgentRuntimeKind = .codex
    let capabilities = AgentRuntimeCapabilities(
        images: true, nativeTools: false, skills: true,
        externalMCP: false, permissions: false)

    private let backend: any CodexExecuting

    init(backend: any CodexExecuting = CodexExecBackend()) {
        self.backend = backend
    }

    func status() async -> AgentRuntimeStatus {
        guard CodexExecBackend.findBinary() != nil else {
            return AgentRuntimeStatus(
                health: .stopped, version: nil, detail: "Codex CLI is not installed.")
        }
        guard CodexExecBackend.isLoggedIn else {
            return AgentRuntimeStatus(
                health: .degraded, version: nil, detail: "Codex CLI is not signed in.")
        }
        return AgentRuntimeStatus(health: .healthy, version: nil, detail: nil)
    }

    func run(_ request: AgentTurnRequest,
             binding: RuntimeBinding?,
             emit: @escaping (AgentRuntimeEvent) -> Void) async throws -> AgentTurnResult {
        var externalSessionID = binding?.externalSessionID
        do {
            let result = try await backend.run(
                prompt: request.prompt,
                images: request.screenshots,
                resumeThread: binding?.externalSessionID,
                workingDirectory: request.workingDirectory,
                extraWritableRoots: request.extraWritableRoots,
                reasoningEffort: request.model?.reasoningEffort,
                onThreadStarted: { id in
                    externalSessionID = id
                    emit(.started(externalSessionID: id))
                },
                onToolActivity: { emit(.activity($0)) },
                onAgentText: { emit(.textDelta(partID: "codex-agent", delta: $0)) })
            externalSessionID = result.threadId ?? externalSessionID
            emit(.completed(text: result.text))
            return AgentTurnResult(
                externalSessionID: externalSessionID,
                runtimeVersion: nil,
                text: result.text,
                usage: nil)
        } catch is CancellationError {
            emit(.interrupted)
            throw CancellationError()
        } catch {
            let failure = AgentRuntimeFailure(
                code: "codex_turn_failed",
                message: error.localizedDescription,
                retryable: true)
            emit(.failed(failure))
            throw failure
        }
    }

    func cancel(turnID: UUID) async {
        backend.interrupt()
    }
}
