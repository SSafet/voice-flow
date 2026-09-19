import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import NIOCore

/// The name both listeners put in their `Server` header. It carries this process's
/// own number, so an answer on the proof's port can be told apart from an answer by
/// any other server — including a stale copy of this same program left over from an
/// earlier run, which every task in this plan invites by using one fixed port.
public func proofServerName() -> String {
    "loopback-proof/\(ProcessInfo.processInfo.processIdentifier)"
}

public let secretHeaderName = HTTPField.Name("x-loopback-secret")!

struct HostOriginGuard<Context: RequestContext>: RouterMiddleware {
    let hosts: Set<String>
    let origin: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let host = request.head.authority?.lowercased(), hosts.contains(host) else {
            throw HTTPError(.forbidden, message: "host not allowed")
        }
        if let requestOrigin = request.headers[.origin], requestOrigin != origin {
            throw HTTPError(.forbidden, message: "origin not allowed")
        }
        return try await next(request, context)
    }
}

struct SecretGuard<Context: RequestContext>: RouterMiddleware {
    let state: ProofState

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let presented = request.headers[secretHeaderName]
        guard let presented, presented == state.secret else {
            throw HTTPError(.unauthorized, message: "secret missing or wrong")
        }
        return try await next(request, context)
    }
}

public struct ProofServer: Sendable {
    public let port: Int
    public let state: ProofState

    public init(port: Int, state: ProofState) {
        self.port = port
        self.state = state
    }

    var allowedHosts: Set<String> {
        ["localhost:\(port)", "127.0.0.1:\(port)", "[::1]:\(port)"]
    }

    var pageOrigin: String { "http://localhost:\(port)" }

    func makeRouters() -> (Router<BasicWebSocketRequestContext>, Router<BasicWebSocketRequestContext>) {
        let state = self.state
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.add(middleware: HostOriginGuard(hosts: allowedHosts, origin: pageOrigin))

        // The page. No secret: it stands for the interface bundle, which Atika
        // serves publicly anyway.
        router.get("/") { _, _ -> Response in
            Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: ByteBuffer(string: "<!doctype html><title>loopback proof</title><p>the proof server answers"))
            )
        }

        let guarded = router.group().add(middleware: SecretGuard(state: state))

        guarded.get("/probe/guarded") { _, _ -> Response in
            jsonResponse(#"{"ok":true}"#)
        }

        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        wsRouter.add(middleware: HostOriginGuard(hosts: allowedHosts, origin: pageOrigin))
        return (router, wsRouter)
    }

    /// Two listeners, one router pair: `localhost` may resolve to either address.
    public func run() async throws {
        let (router, wsRouter) = makeRouters()
        var logger = Logger(label: "loopback-proof")
        logger.logLevel = .error

        let name = proofServerName()
        let ipv4 = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: name),
            logger: logger
        )
        let ipv6 = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname("::1", port: port), serverName: name),
            logger: logger
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await runListener(ipv4, address: "127.0.0.1") }
            group.addTask { try await runListener(ipv6, address: "::1") }
            try await group.waitForAll()
        }
    }

    /// Writes down which listener stopped, and why, at the moment it stops. A
    /// throwing task group only hands its error back once every other child has
    /// finished unwinding, which is later than the readiness wait — measured on
    /// this Mac, a failed bind on one address was still unreported when the
    /// program gave up and printed why nothing answered.
    private func runListener(_ application: some ApplicationProtocol, address: String) async throws {
        do {
            try await application.runService()
        } catch {
            await state.recordServerError("the listener on \(address):\(port) stopped: \(error)")
            throw error
        }
    }
}

func jsonResponse(_ json: String) -> Response {
    Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(string: json))
    )
}
