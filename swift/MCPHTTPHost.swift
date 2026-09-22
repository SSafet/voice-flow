import Foundation
import MCP

/// The SDK owns protocol decoding, dispatch, errors, HTTP validation and cancellation.
/// The app retains only its existing voice-session identity and JSON-only HTTP choice.
/// SDK stateless transport explicitly supports externally managed sessions.
actor MCPHTTPHost {
    private enum Envelope: MCP.Method {
        static let name = ""
        typealias Parameters = Value
        typealias Result = Value
    }
    private struct Peer {
        let server: Server
        let transport: StatelessHTTPServerTransport
        let generation: UUID
        var calls: [ID: MCPToolCancellation] = [:]
        var active: Set<ID> = []
        var cancelled: Set<ID> = []
        var touched = Date()
    }
    private var stopping = false
    private weak var owner: MCPServer?
    private var peers: [String: Peer] = [:]
    private var starting: [String: (generation: UUID, task: Task<Peer, Error>)] = [:]
    private let workers = DispatchQueue(label: "voiceflow.mcp.tools", qos: .userInitiated, attributes: .concurrent)

    init(owner: MCPServer) { self.owner = owner }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard !stopping, let owner else { return .error(statusCode: 503, .internalError("App unavailable")) }
        // DELETE has no SDK stateless handler, so retain SDK's origin validator
        // at admission too; a browser cannot terminate another client's waits.
        if let refused = OriginValidator.localhost().validate(request, context: .init(httpMethod: request.method)) { return refused }
        let sessionID = request.header("Mcp-Session-Id")
        if let sessionID, sessionID.isEmpty || sessionID.utf8.count > 256 || !sessionID.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) {
            return .error(statusCode: 400, .invalidRequest("Invalid session identifier"))
        }
        if request.method == "DELETE" {
            if let sessionID {
                await close(sessionID)
                if let closed = owner.sessions.close(sessionID) { owner.onSessionEnded?(closed) }
            }
            return .ok()
        }
        guard request.method == "POST" else {
            return .error(statusCode: 405, .invalidRequest("This endpoint returns JSON; GET/SSE is unavailable"), extraHeaders: ["Allow": "POST, DELETE"])
        }
        guard let body = request.body, body.count <= 1_048_576 else {
            return .error(statusCode: 413, .invalidRequest("Request body is too large"))
        }
        let envelope = try? JSONDecoder().decode(Request<Envelope>.self, from: body)
        // A malformed request with an ID cannot enter SDK's response waiter: the
        // SDK may reply using a random ID when decoding fails, leaving it parked.
        if let value = try? JSONDecoder().decode(Value.self, from: body),
           case .object(let object) = value, object["id"] != nil, envelope == nil {
            return .error(statusCode: 400, .invalidRequest("Invalid JSON-RPC request"))
        }
        let initializing = envelope?.method == Initialize.name
        let created = initializing ? owner.sessions.begin() : nil
        let identity = created?.id ?? sessionID ?? (envelope?.method == CallTool.name ? MCPServer.anonymousSessionId : nil)
        let key = identity ?? "_unscoped"
        if let identity {
            let touched = owner.sessions.touch(identity)
            if touched.isNew || created != nil, let session = touched.session { owner.onSessionConnected?(session) }
        }
        await prune()
        do {
            if peers[key] == nil { try await makePeer(key) }
            guard var peer = peers[key] else { throw MCPError.internalError("Peer unavailable") }
            if let id = envelope?.id {
                guard !peer.active.contains(id) else {
                    return .error(statusCode: 409, .invalidRequest("Request ID is already active in this session"))
                }
                peer.active.insert(id)
            }
            peer.touched = Date()
            peers[key] = peer
            if let identity { owner.sessions.beginActivity(identity) }
            defer {
                if let id = envelope?.id, peers[key]?.generation == peer.generation {
                    peers[key]?.touched = Date()
                    peers[key]?.active.remove(id)
                    peers[key]?.cancelled.remove(id)
                }
                if let identity { owner.sessions.endActivity(identity) }
            }
            DispatchQueue.main.async { MCPServer.recordActivity() }
            let generation = peer.generation
            let result = await withTaskCancellationHandler(operation: {
                await peer.transport.handleRequest(request)
            }, onCancel: { [weak self] in
                guard let id = envelope?.id else { return }
                Task { await self?.cancel(key, generation: generation, id: id) }
            })
            // Only successful initialize responses issue a new app identity.
            if let created {
                if result.statusCode != 200 || (result.bodyData.flatMap { try? JSONDecoder().decode(Response<Initialize>.self, from: $0) }?.result.isSuccess != true) {
                    await close(created.id)
                    _ = owner.sessions.close(created.id)
                    return result
                }
                if let data = result.bodyData {
                    var headers = result.headers
                    headers["Mcp-Session-Id"] = created.id
                    return .data(data, headers: headers)
                }
            }
            return result
        } catch {
            if let created { _ = owner.sessions.close(created.id) }
            return .error(statusCode: 500, .internalError("MCP initialization failed"))
        }
    }

    private func makePeer(_ key: String) async throws {
        guard let owner else { throw MCPError.connectionClosed }
        let instructions = owner.serverInstructions
        let catalog = try JSONDecoder().decode([Tool].self, from: JSONSerialization.data(withJSONObject: MCPServer.toolDefinitions))
        let generation = starting[key]?.generation ?? UUID()
        let task = starting[key]?.task ?? Task<Peer, Error> { [weak self] in
            let server = Server(name: "voice-flow", version: "2.0.0", instructions: instructions,
                                capabilities: .init(tools: .init()), configuration: .default)
            let transport = StatelessHTTPServerTransport()
            await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: catalog) }
            await server.withMethodHandler(CallTool.self) { [weak self] params in
                guard let self else { throw MCPError.connectionClosed }
                let request = Server.currentHandlerContext?.httpContext?.body.flatMap {
                    try? JSONDecoder().decode(Request<Envelope>.self, from: $0)
                }
                return await self.call(params, key: key, generation: generation, id: request?.id)
            }
            try await server.start(transport: transport)
            return Peer(server: server, transport: transport, generation: generation)
        }
        starting[key] = (generation, task)
        let peer: Peer
        do { peer = try await task.value }
        catch {
            if starting[key]?.generation == generation { starting.removeValue(forKey: key) }
            throw error
        }
        if peers[key]?.generation == generation { return }
        guard starting[key]?.generation == generation else {
            await peer.server.stop()
            throw MCPError.connectionClosed
        }
        starting.removeValue(forKey: key)
        peers[key] = peer
    }

    private func call(_ params: CallTool.Parameters, key: String, generation: UUID, id: ID?) async -> CallTool.Result {
        guard let owner, let callback = owner.callTool, let id, peers[key]?.generation == generation else {
            return MCPServer.ToolResult.fail("Voice Flow is still starting up.").sdkResult
        }
        guard MCPServer.toolDefinitions.contains(where: { $0["name"] as? String == params.name }) else {
            return MCPServer.ToolResult.fail("Unknown tool: \(params.name)").sdkResult
        }
        let cancellation = MCPToolCancellation()
        peers[key]?.calls[id] = cancellation
        if peers[key]?.cancelled.contains(id) == true { cancellation.cancel() }
        defer { if peers[key]?.generation == generation { peers[key]?.calls.removeValue(forKey: id) } }
        let session = owner.sessions.session(key)
        let arguments = ((try? JSONEncoder().encode(params.arguments ?? [:])).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                workers.async {
                    let result = cancellation.isCancelled ? MCPServer.ToolResult.fail("Request cancelled.") : callback(params.name, arguments, session, cancellation)
                    continuation.resume(returning: result)
                }
            }
        }, onCancel: { cancellation.cancel() })
        // Returning a bounded tool error releases the SDK JSON HTTP waiter. Throwing
        // CancellationError deliberately suppresses the response in SDK 0.12.1.
        if cancellation.isCancelled { return MCPServer.ToolResult.fail("Request cancelled.").sdkResult }
        if !result.isError, params.name != "set_session_name", let session, owner.sessions.consumeNameNudge(session.id) {
            return result.appending("\n\n(This session is unnamed — call set_session_name with a short project/task label so the user can tell their Claude sessions apart.)").sdkResult
        }
        return result.sdkResult
    }

    private func cancel(_ key: String, generation: UUID, id: ID) {
        guard peers[key]?.generation == generation, peers[key]?.active.contains(id) == true else { return }
        peers[key]?.cancelled.insert(id)
        peers[key]?.calls[id]?.cancel()
    }

    private func close(_ key: String) async {
        if let pending = starting.removeValue(forKey: key), let peer = try? await pending.task.value { await peer.server.stop() }
        guard let peer = peers.removeValue(forKey: key) else { return }
        peer.calls.values.forEach { $0.cancel() }
        await peer.server.stop()
    }

    private func prune() async {
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        for (key, peer) in peers where peer.active.isEmpty && peer.touched < cutoff { await close(key) }
    }

    func stop() async {
        stopping = true
        for key in Set(peers.keys).union(starting.keys) { await close(key) }
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
