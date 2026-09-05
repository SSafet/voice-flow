import Foundation

/// Runtime-neutral adapter over the Codex CLI. Turns run through the
/// long-lived app-server (streamed deltas, request-based interrupt); when
/// that cannot start — an older CLI — the per-turn `codex exec` path takes
/// over for the rest of the run. A remembered thread that no longer exists
/// on disk starts fresh with the canonical handoff, as OpenCode does.
final class CodexAgentRuntime: AgentRuntime {
    let kind: AgentRuntimeKind = .codex
    let capabilities = AgentRuntimeCapabilities(
        images: true, nativeTools: false, skills: true,
        externalMCP: false, permissions: false)

    private let primary: any CodexExecuting
    private let fallback: (any CodexExecuting)?
    private let lock = NSLock()
    private var useFallback = false
    private var threads: [UUID: String] = [:]
    /// Cancels that arrived before the turn had a thread: applied the
    /// moment it gets one, never widened to every turn on the server.
    private var pendingCancels: Set<UUID> = []

    init(backend: any CodexExecuting = CodexAppServerBackend(),
         fallback: (any CodexExecuting)? = CodexExecBackend()) {
        self.primary = backend
        self.fallback = fallback
    }

    private var backend: any CodexExecuting {
        lock.withLock { useFallback ? (fallback ?? primary) : primary }
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
            defer {
                lock.withLock {
                    threads.removeValue(forKey: request.turnID)
                    pendingCancels.remove(request.turnID)
                }
            }
            let result = try await runTurn(
                request, resumeThread: binding?.externalSessionID, prompt: request.prompt,
                emit: emit, onThreadStarted: { [weak self] id in
                    externalSessionID = id
                    guard let self else { return }
                    let cancelNow: Bool = self.lock.withLock {
                        self.threads[request.turnID] = id
                        return self.pendingCancels.remove(request.turnID) != nil
                    }
                    if cancelNow { self.backend.interrupt(threadId: id) }
                })
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
        let threadId: String? = lock.withLock {
            if let id = threads[turnID] { return id }
            pendingCancels.insert(turnID)
            return nil
        }
        guard let threadId else { return }
        backend.interrupt(threadId: threadId)
    }

    /// End the long-lived app-server, if that is what the backend is.
    func shutdown() {
        (primary as? CodexAppServerBackend)?.shutdown()
    }

    private func runTurn(_ request: AgentTurnRequest, resumeThread: String?, prompt: String,
                         emit: @escaping (AgentRuntimeEvent) -> Void,
                         onThreadStarted: @escaping (String) -> Void,
                         using override: (any CodexExecuting)? = nil) async throws -> CodexExecBackend.TurnResult {
        let backend = override ?? self.backend
        do {
            return try await backend.run(
                prompt: prompt,
                images: request.screenshots,
                resumeThread: resumeThread,
                workingDirectory: request.workingDirectory,
                extraWritableRoots: request.extraWritableRoots,
                model: request.model?.model,
                reasoningEffort: request.model?.reasoningEffort,
                onThreadStarted: { id in
                    onThreadStarted(id)
                    emit(.started(externalSessionID: id))
                },
                onToolActivity: { emit(.activity($0)) },
                onAgentText: { emit(.textDelta(partID: "codex-agent", delta: $0)) })
        } catch CodexBackendError.appServerUnavailable(let reason) where fallback != nil && !lock.withLock({ useFallback }) {
            vflog("codex: app-server unavailable (\(reason)) — using codex exec")
            lock.withLock { useFallback = true }
            return try await runTurn(request, resumeThread: resumeThread, prompt: prompt,
                                     emit: emit, onThreadStarted: onThreadStarted)
        } catch CodexBackendError.appServerBusy where override == nil && fallback != nil {
            vflog("codex: app-server busy with another workspace — this turn runs through codex exec")
            return try await runTurn(request, resumeThread: resumeThread, prompt: prompt,
                                     emit: emit, onThreadStarted: onThreadStarted, using: fallback)
        } catch CodexBackendError.threadNotFound(let id) where resumeThread != nil {
            vflog("codex: thread \(id) is gone — starting fresh with the canonical handoff")
            emit(.activity("Resuming from history"))
            let handoff = AgentPromptComposer.canonicalHandoff(request.priorMessages)
            let fresh = [AgentPromptComposer.systemRole, handoff, request.prompt]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            return try await runTurn(request, resumeThread: nil, prompt: fresh,
                                     emit: emit, onThreadStarted: onThreadStarted, using: override)
        }
    }
}
