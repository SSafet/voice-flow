import Foundation
import MCP

/// Mounted only behind the owned-child broker's capability/Host/origin guard.
/// HTTP/MCP session IDs are not authorization and create no app session objects.
actor T3NativeToolMCP {
    enum Configuration: MCP.Method {
        static let name = "atika/native/configuration"
        struct Parameters: Codable, Hashable, Sendable { let version: Int }
        typealias Result = T3NativeConfiguration
    }
    enum Preflight: MCP.Method {
        static let name = "voiceflow/native/preflight"
        struct Parameters: Codable, Hashable, Sendable { let version: Int; let call: T3NativeToolCall }
        typealias Result = T3NativeToolPreflight
    }
    enum Approve: MCP.Method {
        static let name = "voiceflow/native/approve"
        struct Parameters: Codable, Hashable, Sendable {
            let version: Int; let call: T3NativeToolCall; let requestId: String; let decision: String
        }
        typealias Result = T3NativeToolPreflight
    }
    enum CloseTurn: MCP.Method {
        static let name = "voiceflow/native/closeTurn"
        struct Parameters: Codable, Hashable, Sendable { let version: Int; let threadId: String; let turnId: String }
        struct Result: Codable, Hashable, Sendable { let version: Int; let closed: Bool }
    }
    struct ExecutionMetadata: Codable {
        let version: Int; let threadId: String; let turnId: String; let callId: String
        let manifestRevision: String; let executionToken: String
    }
    private enum Envelope: MCP.Method {
        static let name = ""
        typealias Parameters = Value
        typealias Result = Value
    }
    private let configuration: (@Sendable () async throws -> T3NativeConfiguration)?
    private let service: T3NativeToolService
    private let environment: T3NativeToolEnvironment
    private let onTurnClosed: @Sendable (String, String) async -> Void
    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var starting: Task<Void, Error>?
    private var stopping = false
    private var active: [String: T3NativeToolLifetime] = [:]
    nonisolated let lifetime: T3NativeToolLifetime
    init(service: T3NativeToolService, environment: T3NativeToolEnvironment,
         configuration: (@Sendable () async throws -> T3NativeConfiguration)? = nil,
         onTurnClosed: @escaping @Sendable (String, String) async -> Void) {
        self.configuration = configuration
        self.service = service; self.environment = environment; self.onTurnClosed = onTurnClosed; lifetime = service.lifetime
    }
    nonisolated func revoke() { lifetime.revoke() }
    func handle(_ request: HTTPRequest, ownedEnvironment: T3NativeToolEnvironment) async -> HTTPResponse {
        do { try lifetime.check() } catch { return .error(statusCode: 403, .invalidRequest("Native capability revoked")) }
        guard !stopping, ownedEnvironment == environment,
              ownedEnvironment == service.binding.environment else { return .error(statusCode: 403, .invalidRequest("Owned environment mismatch")) }
        guard request.method == "POST", request.path == "/v1/tools/mcp" else { return .error(statusCode: 405, .invalidRequest("POST /v1/tools/mcp required")) }
        guard let bytes = request.body, bytes.count <= 96 * 1024 else { return .error(statusCode: 413, .invalidRequest("Native request too large")) }
        let envelope = try? JSONDecoder().decode(Request<Envelope>.self, from: bytes)
        if let value = try? JSONDecoder().decode(Value.self, from: bytes), case .object(let object) = value,
           object["id"] != nil, envelope == nil { return .error(statusCode: 400, .invalidRequest("Invalid JSON-RPC request")) }
        if let id = envelope?.id, active[id.description] != nil { return .error(statusCode: 409, .invalidRequest("Request ID active")) }
        do {
            try await start()
            try lifetime.check()
            guard let transport, !stopping else { throw MCPError.connectionClosed }
            if let id = envelope?.id, active[id.description] != nil { return .error(statusCode: 409, .invalidRequest("Request ID active")) }
            guard active.count < 128 else { return .error(statusCode: 429, .invalidRequest("Native request capacity")) }
            let requestLife = T3NativeToolLifetime()
            if let id = envelope?.id { active[id.description] = requestLife }
            defer { if let id = envelope?.id { active.removeValue(forKey: id.description) }; requestLife.revoke() }
            return await withTaskCancellationHandler(operation: {
                await transport.handleRequest(request)
            }, onCancel: { requestLife.revoke() })
        } catch { return .error(statusCode: 503, .internalError("Native tools unavailable")) }
    }
    private func start() async throws {
        if let starting { return try await starting.value }
        if server != nil { return }
        let service = service, onTurnClosed = onTurnClosed
        let task = Task { [self] in
            let server = Server(name: "voiceflow-owned-native", version: "1.0.0", capabilities: .init(tools: .init()), configuration: .default)
            let transport = StatelessHTTPServerTransport()
            let manifest = service.manifest
            await server.withMethodHandler(ListTools.self) { _ in
                let value = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(manifest))
                return ListTools.Result(tools: manifest.tools, _meta: Metadata(additionalFields: ["ai.atika/nativeManifest": value]))
            }
            await server.withMethodHandler(Configuration.self) { [configuration] params in
                guard params.version == 1, let configuration else { throw MCPError.invalidParams("native_configuration_unavailable") }
                try service.lifetime.check()
                let result = try await configuration()
                try service.lifetime.check()
                guard result.binding == manifest.binding, result.policyRevision == manifest.policyRevision else {
                    throw MCPError.invalidParams("native_configuration_changed")
                }
                return result
            }
            await server.withMethodHandler(Preflight.self) { params in
                guard params.version == 1 else { throw MCPError.invalidParams("Unsupported native version") }
                do { return try await service.preflight(params.call) }
                catch { throw MCPError.invalidParams((error as? T3NativeToolFailure)?.code ?? "native_preflight_failed") }
            }
            await server.withMethodHandler(Approve.self) { params in
                guard params.version == 1, ["allow-once", "reject"].contains(params.decision) else { throw MCPError.invalidParams("Invalid native approval") }
                do { return try await service.approve(params.call, requestId: params.requestId, allowOnce: params.decision == "allow-once") }
                catch { throw MCPError.invalidParams((error as? T3NativeToolFailure)?.code ?? "native_approval_failed") }
            }
            await server.withMethodHandler(CloseTurn.self) { params in
                guard params.version == 1, T3NativeToolService.validID(params.threadId), T3NativeToolService.validID(params.turnId) else {
                    throw MCPError.invalidParams("Invalid native turn")
                }
                do {
                    try await service.closeTurn(threadId: params.threadId, turnId: params.turnId)
                    await onTurnClosed(params.threadId, params.turnId)
                    return .init(version: 1, closed: true)
                } catch { throw MCPError.invalidParams((error as? T3NativeToolFailure)?.code ?? "native_close_failed") }
            }
            await server.withMethodHandler(CallTool.self) { [weak self] params in
                do {
                    guard let meta = params._meta?["ai.atika/nativeCall"] else { throw T3NativeToolFailure(code: "native_execution_metadata_required") }
                    let value = try JSONDecoder().decode(ExecutionMetadata.self, from: JSONEncoder().encode(meta))
                    guard value.version == 1 else { throw T3NativeToolFailure(code: "native_version_unsupported") }
                    let call = T3NativeToolCall(threadId: value.threadId, turnId: value.turnId, callId: value.callId, tool: params.name,
                                              arguments: params.arguments ?? [:], manifestRevision: value.manifestRevision)
                    guard let self, let bytes = Server.currentHandlerContext?.httpContext?.body,
                          let id = (try? JSONDecoder().decode(Request<Envelope>.self, from: bytes))?.id,
                          let requestLife = await self.active[id.description] else { throw T3NativeToolFailure(code: "native_request_unavailable") }
                    return await service.execute(call, token: value.executionToken, requestLifetime: requestLife)
                } catch { return T3NativeToolService.failure(error) }
            }
            try await server.start(transport: transport)
            if self.stopping { await server.stop(); throw MCPError.connectionClosed }
            self.server = server; self.transport = transport
        }
        starting = task
        defer { starting = nil }
        try await task.value
    }
    func stop() async {
        stopping = true; revoke()
        if let starting { _ = try? await starting.value }
        await server?.stop(); server = nil; transport = nil
    }
}
