import Foundation

final class OpenCodeAgentRuntime: AgentRuntime {
    let kind: AgentRuntimeKind = .opencode
    let capabilities = AgentRuntimeCapabilities(
        images: true, nativeTools: true, skills: true,
        externalMCP: true, permissions: true)

    private struct ActiveTurn {
        let client: any OpenCodeClienting
        let sessionID: String
        let directory: URL
    }

    private final class PermissionOutcome {
        private let lock = NSLock()
        private var rejected = false
        func record(_ response: AgentPermissionResponse) {
            if response == .reject { lock.withLock { rejected = true } }
        }
        var wasRejected: Bool { lock.withLock { rejected } }
    }

    private let supervisor: any OpenCodeServing
    private let factory: any OpenCodeClientFactory
    private let lock = NSLock()
    private var active: [UUID: ActiveTurn] = [:]

    init(supervisor: any OpenCodeServing = OpenCodeSupervisor.shared,
         factory: any OpenCodeClientFactory = DefaultOpenCodeClientFactory()) {
        self.supervisor = supervisor
        self.factory = factory
    }

    func status() async -> AgentRuntimeStatus {
        await supervisor.status(for: .workspace)
    }

    func run(_ request: AgentTurnRequest,
             binding: RuntimeBinding?,
             emit: @escaping (AgentRuntimeEvent) -> Void) async throws -> AgentTurnResult {
        let permissionOutcome = PermissionOutcome()
        do {
            let connection = try await supervisor.acquireConnection(
                for: request.trustProfile, modelID: request.model?.model)
            defer {
                Task { await self.supervisor.releaseConnection(for: request.trustProfile) }
            }
            let client = factory.make(connection: connection)
            if let endpoint = connection.toolEndpoint, let token = connection.toolToken {
                try AgentToolProjection(endpoint: endpoint, token: token)
                    .project(into: request.workingDirectory)
            }
            if let assistant = request.assistant {
                _ = try AgentSkillStore.project(for: assistant)
            }
            let sessionID: String
            var effectiveRequest = request
            if let existing = binding?.externalSessionID,
               try await client.sessionExists(
                   sessionID: existing, directory: request.workingDirectory) {
                sessionID = existing
            } else {
                sessionID = try await client.createSession(
                    directory: request.workingDirectory,
                    title: "Voice Flow · \(request.conversationID.prefix(8))").id
                if binding?.externalSessionID != nil {
                    let handoff = AgentPromptComposer.canonicalHandoff(request.priorMessages)
                    effectiveRequest = request.replacingPrompt(
                        [AgentPromptComposer.systemRole, handoff, request.prompt]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n\n"))
                }
            }
            emit(.started(externalSessionID: sessionID))
            let prepared = AgentToolSessionRegistry.shared.takePrepared(turnID: request.turnID)
            AgentToolSessionRegistry.shared.register(AgentToolSession(
                conversationID: request.conversationID,
                runID: request.turnID,
                runtimeSessionID: sessionID,
                // Let pinned OpenCode generate its sortable msg_* identifier.
                // The capability stays scoped to this active session/run and
                // is removed before another turn can use it.
                runtimeMessageID: nil,
                directory: request.workingDirectory,
                assistant: request.assistant,
                policy: AgentPermissionPolicy(
                    profile: request.trustProfile, overrides: prepared.overrides),
                expiresAt: Date().addingTimeInterval(3_600),
                environment: prepared.environment))
            lock.withLock {
                active[request.turnID] = ActiveTurn(
                    client: client, sessionID: sessionID, directory: request.workingDirectory)
            }
            defer {
                AgentToolSessionRegistry.shared.remove(runtimeSessionID: sessionID)
                lock.withLock { active.removeValue(forKey: request.turnID) }
            }

            let result = try await client.sendMessage(
                sessionID: sessionID, directory: request.workingDirectory,
                request: effectiveRequest,
                onEvent: { event in
                    switch event {
                    case .textDelta(let partID, let delta):
                        emit(.textDelta(partID: partID, delta: delta))
                    case .activity(let label):
                        emit(.activity(label))
                    case .permission(let permission):
                        emit(.permission(permission))
                        Task {
                            let response = await AgentPermissionBroker.shared.request(
                                AgentPermissionPrompt(
                                    id: "opencode:\(sessionID):\(permission.id)",
                                    conversationID: request.conversationID,
                                    runID: request.turnID,
                                    title: permission.title,
                                    detail: permission.detail))
                            permissionOutcome.record(response)
                            do {
                                try await client.respondPermission(
                                    sessionID: sessionID, directory: request.workingDirectory,
                                    permissionID: permission.id, response: response)
                            } catch {
                                emit(.failed(AgentRuntimeFailure(
                                    code: "opencode_permission_reply_failed",
                                    message: error.localizedDescription,
                                    retryable: false)))
                            }
                        }
                    case .failed(let failure):
                        emit(.failed(failure))
                    }
                })
            emit(.completed(text: result.text))
            return AgentTurnResult(
                externalSessionID: sessionID,
                runtimeVersion: connection.version,
                text: result.text,
                usage: result.usage)
        } catch OpenCodeClientError.emptyFinal where permissionOutcome.wasRejected {
            let failure = AgentRuntimeFailure(
                code: "opencode_permission_rejected",
                message: "The requested OpenCode action was rejected.",
                retryable: false)
            emit(.failed(failure))
            throw failure
        } catch is CancellationError {
            emit(.interrupted)
            throw CancellationError()
        } catch let failure as AgentRuntimeFailure {
            emit(.failed(failure))
            throw failure
        } catch {
            let failure = AgentRuntimeFailure(
                code: "opencode_turn_failed",
                message: error.localizedDescription,
                retryable: true)
            emit(.failed(failure))
            throw failure
        }
    }

    func cancel(turnID: UUID) async {
        let turn = lock.withLock { active[turnID] }
        guard let turn else { return }
        await turn.client.abort(sessionID: turn.sessionID, directory: turn.directory)
    }
}
