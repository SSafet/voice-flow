import Foundation
import Security
import CryptoKit
import Hummingbird
import HummingbirdCore
import NIOCore
import Logging
import MCP
import HTTPTypes

/// One capability and one native-owned child per lifetime. Hummingbird owns HTTP
/// parsing, connections and cancellation; the existing native actor owns credentials.
actor T3NativeAuthorityBroker {
    typealias OwnedEnvironment = @Sendable () async throws -> T3AuthorityEnvironmentIdentity
    typealias LeaseProvider = @Sendable (T3AuthorityEnvironmentIdentity) async throws -> T3NativeAuthorityLease
    typealias IsCurrent = @Sendable (T3NativeAuthorityLease) async -> Bool

    /// The official SDK and the native tool service own MCP/policy. This mount
    /// only adapts authenticated HTTP on the already-owned listener.
    struct ToolsMount: Sendable {
        let handle: @Sendable (MCP.HTTPRequest, T3AuthorityEnvironmentIdentity) async -> MCP.HTTPResponse
        let revoke: @Sendable () -> Void
        let stop: @Sendable () async -> Void
        let requestTimeout: Duration

        init(handle: @escaping @Sendable (MCP.HTTPRequest, T3AuthorityEnvironmentIdentity) async -> MCP.HTTPResponse,
             revoke: @escaping @Sendable () -> Void,
             stop: @escaping @Sendable () async -> Void,
             requestTimeout: Duration = .seconds(120)) {
            self.handle = handle
            self.revoke = revoke
            self.stop = stop
            self.requestTimeout = min(.seconds(600), max(.milliseconds(1), requestTimeout))
        }
    }

    private enum Route {
        case lease, tools
        var path: String { self == .lease ? "/v1/authority/lease" : "/v1/tools/mcp" }
    }

    private struct Context: Hummingbird.RequestContext {
        var coreContext: CoreRequestContextStorage
        let channel: any Channel
        init(source: ApplicationRequestContextSource) {
            coreContext = .init(source: source)
            channel = source.channel
        }
    }
    /// Hummingbird permits remote half-close. This private request/reply channel
    /// treats input EOF as disconnect, so cancelled fetches cannot leave native
    /// work parked until its much longer execution deadline.
    private final class CloseOnInputEOF: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = NIOAny
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let event = event as? ChannelEvent, case .inputClosed = event {
                context.close(promise: nil)
            }
            context.fireUserInboundEventTriggered(event)
        }
    }
    private struct LeaseRequest: Decodable {
        let environmentId: String
        let expectedBinding: T3NativeAuthorityBinding?
    }
    private struct LeaseResponse: Encodable {
        let version = 1
        let binding: T3NativeAuthorityBinding
        let gatewayOrigin: String
        let accessToken: String
        let accessTokenExpiresAt: String
    }
    private struct Pending {
        let continuation: CheckedContinuation<Hummingbird.Response, Never>
        let work: Task<Void, Never>
        let timeout: Task<Void, Never>
    }
    private let ownedEnvironment: OwnedEnvironment
    private let leaseProvider: LeaseProvider
    private let isCurrent: IsCurrent
    private let requestTimeout: Duration
    private let tools: ToolsMount?
    private var toolsStopped = false
    private var server: Task<Void, Never>?
    private var started = false
    private var revoked = false
    private var capabilityDigest: SHA256.Digest?
    private var host: String?
    private var pinnedEnvironment: T3AuthorityEnvironmentIdentity?
    private var pinnedAuthority: (binding: T3NativeAuthorityBinding, origin: String)?
    private var pending: [UUID: Pending] = [:]

    init(ownedEnvironment: @escaping OwnedEnvironment,
         leaseProvider: @escaping LeaseProvider,
         isCurrent: @escaping IsCurrent,
         requestTimeout: Duration = .seconds(10),
         tools: ToolsMount? = nil) {
        self.ownedEnvironment = ownedEnvironment
        self.leaseProvider = leaseProvider
        self.isCurrent = isCurrent
        self.requestTimeout = min(.seconds(60), max(.milliseconds(1), requestTimeout))
        self.tools = tools
    }

    func start() async throws -> T3NativeAuthorityBootstrap {
        guard !started, !revoked else { throw T3NativeAuthorityError.unavailable }
        started = true
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            invalidate(); throw T3NativeAuthorityError.unavailable
        }
        let capability = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        capabilityDigest = SHA256.hash(data: Data(capability.utf8))
        let router = Router(context: Context.self)
        router.post("/v1/authority/lease") { [self] request, context in
            await handle(request, channel: context.channel, route: .lease)
        }
        if tools != nil {
            router.post("/v1/tools/mcp") { [self] request, context in
                await handle(request, channel: context.channel, route: .tools)
            }
            // Streamable HTTP clients probe GET for a server notification stream.
            // This stateless mount has no stream and exposes no data on this route.
            router.get("/v1/tools/mcp") { _, _ in
                Hummingbird.Response(status: .methodNotAllowed,
                    headers: [.allow: "POST", .cacheControl: "no-store", .connection: "close"])
            }
        }
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        // No request or service logger can print private headers, body or causes.
        let logger = Logger(label: "T3NativeAuthority", factory: { _ in SwiftLogNoOpLogHandler() })
        let app = Application(
            router: router,
            server: .http1(configuration: .init(
                additionalChannelHandlers: [CloseOnInputEOF()],
                idleTimeout: .seconds(15),
                httpDecoderConfiguration: .init(maxHeaderFieldSize: 1024, maxHeaderListSize: 4096, maxHeaderFieldCount: 24))),
            configuration: .init(address: .hostname("127.0.0.1", port: 0), backlog: 16,
                                 availableConnectionsDelegate: MaximumAvailableConnections(32, logger: logger)),
            onServerRunning: { [self] channel in
                if let port = channel.localAddress?.port, await didBind(port) { continuation.yield(port) }
                continuation.finish()
            },
            logger: logger)
        server = Task { [self] in
            do { try await app.run() } catch { /* Constant failure at the private boundary. */ }
            invalidate()
            continuation.finish()
        }
        return try await withTaskCancellationHandler {
            guard let port = await ports.first(where: { _ in true }), !revoked, !Task.isCancelled else {
                await stop(); throw T3NativeAuthorityError.unavailable
            }
            return .init(origin: "http://127.0.0.1:\(port)", credential: capability)
        } onCancel: { Task { await self.stop() } }
    }

    private func didBind(_ port: Int) -> Bool {
        guard !revoked, (1...65535).contains(port) else { return false }
        host = "127.0.0.1:\(port)"
        return true
    }

    /// Native account/home/generation changes must call this before reusing the
    /// owner. An invalidated launch cannot be restarted or transparently rebound.
    func invalidate() {
        guard !revoked else { return }
        revoked = true
        capabilityDigest = nil
        // Revoke primitive execution synchronously before releasing HTTP waiters.
        tools?.revoke()
        for id in Array(pending.keys) { finish(id, response: Self.failure(.serviceUnavailable)) }
    }

    func stop() async {
        invalidate()
        let task = server
        server = nil
        task?.cancel()
        if !toolsStopped {
            toolsStopped = true
            await tools?.stop()
        }
        await task?.value
    }

    private func handle(_ request: Hummingbird.Request, channel: any Channel, route: Route) async -> Hummingbird.Response {
        guard !revoked, let host, let capabilityDigest else { return Self.failure(.serviceUnavailable) }
        // Browsers always supply fetch metadata and/or Origin for this cross-port
        // POST. Reject them, Host aliases, duplicate auth, and ambient cookies.
        guard request.head.authority == host, request.uri.path == route.path,
              request.uri.query == nil,
              !request.headers.contains(where: { field in
                  let name = field.name.canonicalName
                  return name == "host" || name == "origin" || name == "referer" || name == "cookie" || name.hasPrefix("sec-fetch-")
              }),
              request.headers[values: .contentType] == ["application/json"],
              request.headers[values: .authorization].count == 1,
              let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer "),
              authorization.utf8.count == 50 else { return Self.failure(.forbidden) }
        let digest = SHA256.hash(data: Data(authorization.dropFirst(7).utf8))
        // Hash both values to fixed length before a non-short-circuit comparison.
        var difference: UInt8 = 0
        for (left, right) in zip(digest, capabilityDigest) { difference |= left ^ right }
        guard difference == 0 else { return Self.failure(.forbidden) }
        guard pending.count < 16 else { return Self.failure(.serviceUnavailable) }
        let id = UUID()
        let timeoutDuration = route == .tools ? tools!.requestTimeout : requestTimeout
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let work = Task { [self] in
                    if route == .lease { await performLease(request, id: id) }
                    else { await performTools(request, id: id) }
                }
                let timeout = Task { [self] in
                    do { try await Task.sleep(for: timeoutDuration) } catch { return }
                    finish(id, response: Self.failure(.serviceUnavailable))
                }
                pending[id] = .init(continuation: continuation, work: work, timeout: timeout)
                channel.closeFuture.whenComplete { _ in Task { await self.cancel(id) } }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func cancel(_ id: UUID) { finish(id, response: Self.failure(.serviceUnavailable)) }
    private func finish(_ id: UUID, response: Hummingbird.Response) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.work.cancel()
        request.timeout.cancel()
        request.continuation.resume(returning: response)
    }
    private func active(_ id: UUID) throws {
        guard !revoked, pending[id] != nil, !Task.isCancelled else { throw T3NativeAuthorityError.unavailable }
    }

    private func currentEnvironment() async throws -> T3AuthorityEnvironmentIdentity {
        do { return try await ownedEnvironment() }
        catch {
            // An identity file may legitimately not exist during initial startup.
            // Once pinned, loss of the owned child/file retires the whole launch.
            if pinnedEnvironment != nil, !Task.isCancelled { invalidate() }
            throw T3NativeAuthorityError.unavailable
        }
    }

    private func performLease(_ request: Hummingbird.Request, id: UUID) async {
        do {
            let body = try await request.body.collect(upTo: 4096)
            try active(id)
            let input = try JSONDecoder().decode(LeaseRequest.self, from: Data(body.readableBytesView))
            guard Self.identifier(input.environmentId) else { throw T3NativeAuthorityError.unavailable }
            let environment = try await currentEnvironment()
            try active(id)
            guard Self.identifier(environment.environmentID), environment.environmentID == input.environmentId else {
                finish(id, response: Self.failure(.forbidden)); return
            }
            if let pinnedEnvironment, pinnedEnvironment != environment { invalidate(); return }
            pinnedEnvironment = environment
            if let expected = input.expectedBinding, let pinnedAuthority, expected != pinnedAuthority.binding {
                finish(id, response: Self.failure(.conflict)); return
            }
            let lease = try await leaseProvider(environment)
            try active(id)
            guard lease.environment == environment, Self.valid(lease) else { throw T3NativeAuthorityError.unavailable }
            // Both checks run after renewal. A cancelled/non-cooperative provider
            // cannot publish a lease after native invalidation or child replacement.
            let current = await isCurrent(lease)
            try active(id)
            let stillOwned = try await currentEnvironment()
            try active(id)
            guard current, stillOwned == environment else { invalidate(); return }
            guard await isCurrent(lease) else { invalidate(); return }
            try active(id)
            if let pinnedAuthority, pinnedAuthority.binding != lease.binding || pinnedAuthority.origin != lease.gatewayOrigin {
                invalidate(); return
            }
            guard input.expectedBinding == nil || input.expectedBinding == lease.binding else {
                finish(id, response: Self.failure(.conflict)); return
            }
            pinnedAuthority = (lease.binding, lease.gatewayOrigin)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let output = LeaseResponse(binding: lease.binding, gatewayOrigin: lease.gatewayOrigin,
                                       accessToken: lease.accessToken, accessTokenExpiresAt: formatter.string(from: lease.expiresAt))
            let bytes = try JSONEncoder().encode(output)
            guard bytes.count <= 32768, lease.expiresAt > Date() else { throw T3NativeAuthorityError.unavailable }
            finish(id, response: Hummingbird.Response(status: .ok,
                headers: [.contentType: "application/json", .cacheControl: "no-store", .connection: "close"],
                body: .init(byteBuffer: ByteBuffer(bytes: bytes))))
        } catch {
            finish(id, response: Self.failure(.serviceUnavailable))
        }
    }

    private func performTools(_ request: Hummingbird.Request, id: UUID) async {
        guard let tools else { finish(id, response: Self.failure(.serviceUnavailable)); return }
        do {
            let body = try await request.body.collect(upTo: 96 * 1024)
            try active(id)
            // The launch capability terminates here. Only protocol headers enter
            // the SDK, so native tools cannot accidentally log or return it.
            var headers: [String: String] = [:]
            for name in ["accept", "content-type", "mcp-protocol-version", "mcp-session-id", "last-event-id"] {
                let values = request.headers[values: HTTPField.Name(name)!]
                guard values.count <= 1 else { finish(id, response: Self.failure(.forbidden)); return }
                if let value = values.first { headers[name] = value }
            }
            let environment = try await currentEnvironment()
            try active(id)
            guard Self.identifier(environment.environmentID) else { throw T3NativeAuthorityError.unavailable }
            if let pinnedEnvironment, pinnedEnvironment != environment { invalidate(); return }
            pinnedEnvironment = environment
            let sdkRequest = MCP.HTTPRequest(method: "POST", headers: headers, body: Data(body.readableBytesView), path: Route.tools.path)
            let response = await tools.handle(sdkRequest, environment)
            try active(id)
            let stillOwned = try await currentEnvironment()
            try active(id)
            guard stillOwned == environment else { invalidate(); return }
            // The mounted native service uses StatelessHTTPServerTransport. SSE
            // would bypass bounded JSON image output and is explicitly unavailable.
            if case .stream = response { finish(id, response: Self.failure(.notImplemented)); return }
            let bytes = response.bodyData ?? Data()
            guard bytes.count <= 7 * 1024 * 1024,
                  (200...599).contains(response.statusCode), !(300...399).contains(response.statusCode) else {
                throw T3NativeAuthorityError.unavailable
            }
            // Strip SDK/service extras (cookies, CORS, redirects or credentials).
            // Stateless JSON has no transport session cookie/header to propagate.
            finish(id, response: Hummingbird.Response(status: .init(code: response.statusCode),
                headers: [.contentType: "application/json", .cacheControl: "no-store", .connection: "close"],
                body: .init(byteBuffer: ByteBuffer(bytes: bytes))))
        } catch {
            finish(id, response: Self.failure(.serviceUnavailable))
        }
    }

    private static func failure(_ status: HTTPTypes.HTTPResponse.Status) -> Hummingbird.Response {
        Hummingbird.Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store", .connection: "close"],
                 body: .init(byteBuffer: ByteBuffer(string: "{\"error\":\"Native Atika authority is unavailable.\"}")))
    }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }
    private static func valid(_ lease: T3NativeAuthorityLease) -> Bool {
        let binding = lease.binding
        guard [binding.ownerId, binding.deviceId, binding.homeId].allSatisfy(identifier),
              binding.identityGeneration.count == 36, UUID(uuidString: binding.identityGeneration) != nil,
              lease.expiresAt.timeIntervalSince1970.isFinite, lease.expiresAt > Date(),
              (1...16384).contains(lease.accessToken.utf8.count),
              lease.accessToken.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95, 126].contains($0) }),
              let url = URLComponents(string: lease.gatewayOrigin), let scheme = url.scheme, let host = url.host,
              (scheme == "https" || (scheme == "http" && host == "127.0.0.1")),
              host == host.lowercased(), !(scheme == "https" && url.port == 443), !(scheme == "http" && url.port == 80),
              url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil,
              !host.isEmpty, url.port.map({ (1...65535).contains($0) }) != false else { return false }
        return lease.gatewayOrigin == "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }
}
