import Foundation
import MCP

private final class ToolRevocation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func revoke() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor ToolsFixture {
    let revocation = ToolRevocation()
    let transport = StatelessHTTPServerTransport()
    let server = Server(name: "isolated-mount-proof", version: "1", capabilities: .init(tools: .init()))
    var calls = 0
    var cancelled = 0
    var stops = 0
    var cancellationSawRevoked = false
    var mode = "sdk"
    var gates: [UUID: CheckedContinuation<Void, Error>] = [:]
    var entries: [(Int, CheckedContinuation<Void, Never>)] = []
    var cancellations: [CheckedContinuation<Void, Never>] = []
    var lastHeaders: [String: String] = [:]
    var lastEnvironment: T3AuthorityEnvironmentIdentity?

    func start() async throws {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: [.init(name: "fixture_echo", description: "isolated fixture", inputSchema: ["type": "object"])])
        }
        await server.withMethodHandler(CallTool.self) { params in
            CallTool.Result(content: [.text(text: params.name == "fixture_echo" ? "fixture result" : "unknown", annotations: nil, _meta: nil)])
        }
        try await server.start(transport: transport)
    }
    func stop() async { stops += 1; await transport.disconnect(); await server.stop() }
    func configure(_ value: String) { mode = value }
    func waitForCalls(_ value: Int) async {
        if calls >= value { return }
        await withCheckedContinuation { entries.append((value, $0)) }
    }
    func waitForCancellation() async {
        if cancelled > 0 { return }
        await withCheckedContinuation { cancellations.append($0) }
    }
    func cancel(_ id: UUID) {
        cancelled += 1
        cancellationSawRevoked = revocation.calls > 0
        cancellations.forEach { $0.resume() }; cancellations.removeAll()
        gates.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    func release() { let values = gates.values; gates.removeAll(); values.forEach { $0.resume() } }
    func handle(_ request: MCP.HTTPRequest, environment: T3AuthorityEnvironmentIdentity) async -> MCP.HTTPResponse {
        calls += 1
        lastHeaders = request.headers
        lastEnvironment = environment
        let ready = entries.filter { $0.0 <= calls }; entries.removeAll { $0.0 <= calls }; ready.forEach { $0.1.resume() }
        switch mode {
        case "blocked":
            let id = UUID()
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        gates[id] = continuation
                        if Task.isCancelled { cancel(id) }
                    }
                } onCancel: { Task { await self.cancel(id) } }
                return .data(Data("{\"result\":\"released\"}".utf8))
            } catch { return .error(statusCode: 503, .internalError("fixture cancelled")) }
        case "long":
            do { try await Task.sleep(for: .seconds(16)) }
            catch { return .error(statusCode: 503, .internalError("fixture cancelled")) }
            return .data(Data("{\"result\":\"long completed\"}".utf8))
        case "images":
            let content: [[String: String]] = (0..<12).map { _ in
                ["type": "image", "mimeType": "image/jpeg", "data": Data(repeating: 97, count: 400_000).base64EncodedString()]
            }
            return .data(try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 4, "result": ["content": content]]),
                         headers: ["Set-Cookie": "fixture-private", "Authorization": "fixture-secret", "Access-Control-Allow-Origin": "*"])
        case "too-large": return .data(Data(repeating: 97, count: 7 * 1024 * 1024 + 1))
        case "sse": return .stream(AsyncThrowingStream { $0.finish() }, headers: ["Content-Type": "text/event-stream"])
        default: return await transport.handleRequest(request)
        }
    }
}

enum ToolsMountProof {
    static func run() async throws {
        var assertions = 0
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "ToolsMountProof", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            assertions += 1
        }
        func make(_ owner: Fixture, _ fixture: ToolsFixture?, leaseTimeout: Duration = .seconds(10), toolsTimeout: Duration = .seconds(120)) async -> T3NativeAuthorityBroker {
            let mount: T3NativeAuthorityBroker.ToolsMount?
            if let fixture {
                let flag = fixture.revocation
                mount = .init(handle: { await fixture.handle($0, environment: $1) }, revoke: { flag.revoke() },
                              stop: { await fixture.stop() }, requestTimeout: toolsTimeout)
            } else { mount = nil }
            return .init(ownedEnvironment: { try await owner.own() }, leaseProvider: { try await owner.lease($0) },
                         isCurrent: { await owner.valid($0) }, requestTimeout: leaseTimeout, tools: mount)
        }
        @Sendable func rpc(_ boot: T3NativeAuthorityBootstrap, _ value: [String: Any], headers: [String: String] = [:]) async throws -> Reply {
            var protocolHeaders = ["Accept": "application/json", "MCP-Protocol-Version": "2025-03-26"]
            protocolHeaders.merge(headers) { _, new in new }
            return try await request(boot, headers: protocolHeaders, raw: JSONSerialization.data(withJSONObject: value), path: "/v1/tools/mcp", timeout: 25)
        }
        let list: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "proof", "version": "1"]]]

        let absentOwner = Fixture(), absent = await make(absentOwner, nil)
        let absentBoot = try await absent.start()
        try expect(try await rpc(absentBoot, list).status == 404, "unconfigured native tools are unavailable")
        try expect(await absentOwner.counts() == (0, 0), "unconfigured tools do not access owner")
        await absent.stop()
        print("ok - optional tools mount unavailable by default")

        let owner = Fixture(), fixture = ToolsFixture()
        try await fixture.start()
        let broker = await make(owner, fixture, leaseTimeout: .milliseconds(20))
        let boot = try await broker.start()
        let streamProbe = try await request(boot, path: "/v1/tools/mcp", method: "GET")
        try expect(streamProbe.status == 405 && streamProbe.bytes.isEmpty, "stateless SDK stream probe returns405 without data")
        try expect(streamProbe.response.value(forHTTPHeaderField: "Allow") == "POST" && streamProbe.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil, "stream probe advertises only POST and no browser access")
        try expect(await owner.counts() == (0, 0), "stream probe does not read authority")
        try expect(await fixture.calls == 0, "stream probe does not enter SDK")
        for headers in [["Origin": "null"], ["Sec-Fetch-Site": "same-origin"], ["Host": "localhost:1234"],
                        ["Authorization": "Bearer " + String(repeating: "x", count: 43)]] {
            try expect(try await rpc(boot, list, headers: headers).status == 403, "tools use private HTTP guard")
        }
        try expect(await owner.counts() == (0, 0), "tools HTTP denial precedes owner access")
        try expect(await fixture.calls == 0, "tools HTTP denial precedes SDK dispatch")
        try expect(try await request(boot, raw: Data(repeating: 97, count: 96 * 1024 + 1), path: "/v1/tools/mcp").status == 503, "tools request body bounded at 96 KiB")
        try expect(await fixture.calls == 0, "oversized request never reaches handler")
        try expect(try await request(boot, raw: Data("{}".utf8), path: "/v1/tools/mcp?extra=1").status == 403, "tools query strings are refused")
        await owner.setOwnershipAvailable(false)
        try expect(try await rpc(boot, list).status == 503, "tools require established owned identity")
        try expect(await fixture.calls == 0, "missing owned identity cannot enter tools service")
        await owner.setOwnershipAvailable(true)
        let initialized = try await rpc(boot, initialize)
        print("ok - SDK tools initialize returned")
        try expect(initialized.status == 200 && initialized.json["result"] != nil, "actual SDK initializes through Hummingbird")
        try expect(await fixture.lastHeaders["authorization"] == nil, "launch capability never enters SDK")
        try expect(await fixture.lastHeaders["mcp-protocol-version"] == "2025-03-26", "SDK protocol header retained")
        try expect(await fixture.lastEnvironment == owner.environment, "owned launch passed as typed context")
        let listed = try await rpc(boot, list)
        try expect(((listed.json["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first?["name"] as? String == "fixture_echo", "SDK catalog response preserved")
        try expect(try await rpc(boot, list, headers: ["Accept": "text/event-stream"]).status == 406, "SDK rejects SSE-only clients")
        let missingMethod = try await rpc(boot, ["jsonrpc": "2.0", "id": 100, "method": "unknown/fixture"])
        try expect(missingMethod.json["error"] != nil && missingMethod.json["id"] as? Int == 100, "SDK error and request identity preserved")
        let notification = try await rpc(boot, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        try expect(notification.status == 202 && notification.bytes.isEmpty, "SDK notification retains 202 and empty body")
        let cancelledNotification = try await rpc(boot, ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 123]])
        try expect(cancelledNotification.status == 202 && cancelledNotification.bytes.isEmpty, "SDK cancellation notification preserved")
        let called = try await rpc(boot, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "fixture_echo", "arguments": [:]]])
        try expect((((called.json["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) == "fixture result", "SDK tool response preserved")
        let priorOwn = await owner.counts().0
        _ = try await rpc(boot, list)
        try expect(await owner.counts().0 >= priorOwn + 2, "ownership checked before and after each handler")
        print("ok - SDK tools negotiation and notification semantics")

        await fixture.configure("images")
        let images = try await rpc(boot, list)
        try expect(images.status == 200 && images.bytes.count > 6_400_000 && images.bytes.count < 7 * 1024 * 1024, "12 bounded native image replies survive mount")
        try expect(images.response.value(forHTTPHeaderField: "Set-Cookie") == nil && images.response.value(forHTTPHeaderField: "Authorization") == nil && images.response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil, "service extras cannot bypass private response boundary")
        await fixture.configure("too-large")
        try expect(try await rpc(boot, list).status == 503, "oversized tools response rejected")
        await fixture.configure("sse")
        try expect(try await rpc(boot, list).status == 501, "SSE explicitly unavailable")

        // The real 16-second operation crosses both the old lease deadline and
        // Hummingbird's idle timeout. Active native work is governed by its own bound.
        await fixture.configure("long")
        async let longCall = rpc(boot, list)
        await owner.configure(paused: true)
        let lease = try await request(boot)
        try expect(lease.status == 503, "lease deadline stays narrow during a long native call")
        try expect(try await longCall.status == 200, "tools can run past 10-second lease and 15-second idle limits")
        print("ok - native tool call crosses lease and idle deadlines")
        await owner.configure()
        await fixture.configure("blocked")
        let beforeBlock = await fixture.calls
        let disconnected = Task { try await rpc(boot, list) }
        await fixture.waitForCalls(beforeBlock + 1)
        let cancelStarted = Date()
        disconnected.cancel()
        do { _ = try await disconnected.value; throw NSError(domain: "tool request not cancelled", code: 1) }
        catch is URLError { assertions += 1 }
        await fixture.waitForCancellation()
        try expect(Date().timeIntervalSince(cancelStarted) < 2, "disconnect cancels native handler promptly rather than waiting for120-second deadline")
        try expect(fixture.revocation.calls == 0, "one disconnected tool request does not revoke launch")
        await fixture.configure("sdk")
        try expect(try await rpc(boot, list).status == 200, "next SDK call survives previous disconnect")
        await broker.stop(); await broker.stop()
        print("ok - native tools disconnect and SDK shutdown")
        try expect(await fixture.stops == 1 && fixture.revocation.calls == 1, "SDK stop and synchronous revoke run exactly once")

        for mode in ["invalidate", "stop", "deadline", "new-launch", "new-identity"] {
            let blockedOwner = Fixture(), blockedTools = ToolsFixture()
            await blockedTools.configure("blocked")
            let blockedBroker = await make(blockedOwner, blockedTools, toolsTimeout: mode == "deadline" ? .milliseconds(30) : .seconds(120))
            let blockedBoot = try await blockedBroker.start()
            if mode == "new-identity" { _ = try await request(blockedBoot) }
            let call = Task { try await rpc(blockedBoot, list) }
            await blockedTools.waitForCalls(1)
            if mode == "invalidate" { await blockedBroker.invalidate() }
            if mode == "stop" { await blockedBroker.stop() }
            if mode == "new-launch" {
                await blockedOwner.configure(changedEnvironment: true)
                await blockedTools.release()
            }
            if mode == "new-identity" {
                await blockedOwner.configure(changedIdentity: true)
                try expect(try await request(blockedBoot).status == 503, "lease identity change revokes mounted tools")
            }
            do { try expect(try await call.value.status == 503, "tool waiter released on revocation/deadline/launch change") }
            catch is URLError { try expect(mode == "stop", "only shutdown may close transport") }
            if mode != "new-launch" { await blockedTools.waitForCancellation() }
            if mode == "invalidate" || mode == "stop" || mode == "new-identity" {
                try expect(await blockedTools.cancellationSawRevoked, "sync primitive revocation precedes handler cancellation")
            }
            if mode == "deadline" { try expect(blockedTools.revocation.calls == 0, "request deadline does not revoke entire launch") }
            else {
                let before = await blockedTools.calls
                if mode != "stop" { try expect(try await rpc(blockedBoot, list).status == 503, "revoked tools cannot be readmitted") }
                try expect(await blockedTools.calls == before, "revocation avoids handler readmission")
            }
            await blockedBroker.stop()
            try expect(await blockedTools.stops == 1 && blockedTools.revocation.calls == 1, "all shutdown paths stop mounted service once")
        }
        print("ok - \(assertions) SDK tools mount real HTTP assertions")
    }
}
