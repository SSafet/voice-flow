import Foundation

private func check(_ value: Bool, _ detail: String) throws {
    if !value { throw NSError(domain: "AuthorityBrokerProof", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
}

actor Fixture {
    var environment = T3AuthorityEnvironmentIdentity(environmentID: "owned-environment", generation: UUID())
    var binding = T3NativeAuthorityBinding(ownerId: "owner", deviceId: "device", homeId: "home", identityGeneration: "00000000-0000-4000-8000-000000000ABC")
    var origin = "https://gateway.example"
    var token = "fixture.token-only"
    var expiry = Date().addingTimeInterval(300)
    var current = true
    var currentChecks = 0
    var failCurrentCheck: Int?
    var paused = false
    var ignoreCancellation = false
    var ownershipCalls = 0
    var ownershipAvailable = true
    var providerCalls = 0
    var cancellationCalls = 0
    var gates: [UUID: CheckedContinuation<Void, Error>] = [:]
    var entered: [(Int, CheckedContinuation<Void, Never>)] = []
    var cancelled: [CheckedContinuation<Void, Never>] = []

    func own() throws -> T3AuthorityEnvironmentIdentity {
        ownershipCalls += 1
        guard ownershipAvailable else { throw T3NativeAuthorityError.unavailable }
        return environment
    }
    func setOwnershipAvailable(_ value: Bool) { ownershipAvailable = value }
    func counts() -> (Int, Int) { (ownershipCalls, providerCalls) }
    func valid(_ lease: T3NativeAuthorityLease) -> Bool {
        currentChecks += 1
        return current && failCurrentCheck != currentChecks && lease.binding == binding && lease.environment == environment && lease.gatewayOrigin == origin && lease.expiresAt > Date()
    }
    func failRevalidation(at check: Int) { failCurrentCheck = check }
    func configure(paused: Bool = false, ignoreCancellation: Bool = false, token: String? = nil,
                   expiry: Date? = nil, origin: String? = nil, changedIdentity: Bool = false, changedEnvironment: Bool = false) {
        self.paused = paused; self.ignoreCancellation = ignoreCancellation
        if let token { self.token = token }; if let expiry { self.expiry = expiry }; if let origin { self.origin = origin }
        if changedIdentity { binding = .init(ownerId: "other-owner", deviceId: "device", homeId: "home", identityGeneration: UUID().uuidString) }
        if changedEnvironment { environment = .init(environmentID: environment.environmentID, generation: UUID()) }
    }
    func waitForCalls(_ count: Int) async {
        if providerCalls >= count { return }
        await withCheckedContinuation { entered.append((count, $0)) }
    }
    func waitForCancellation() async {
        if cancellationCalls > 0 { return }
        await withCheckedContinuation { cancelled.append($0) }
    }
    func cancel(_ id: UUID) {
        cancellationCalls += 1
        cancelled.forEach { $0.resume() }; cancelled.removeAll()
        if !ignoreCancellation { gates.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    }
    func release() { let values = gates.values; gates.removeAll(); values.forEach { $0.resume() } }
    func lease(_ environment: T3AuthorityEnvironmentIdentity) async throws -> T3NativeAuthorityLease {
        providerCalls += 1
        let ready = entered.filter { $0.0 <= providerCalls }
        entered.removeAll { $0.0 <= providerCalls }; ready.forEach { $0.1.resume() }
        if paused {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gates[id] = continuation
                    if Task.isCancelled { cancel(id) }
                }
            } onCancel: { Task { await self.cancel(id) } }
        }
        return .init(environment: environment, binding: binding, gatewayOrigin: origin, accessToken: token, expiresAt: expiry)
    }
}

struct Reply {
    let status: Int
    let bytes: Data
    let response: HTTPURLResponse
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:] }
}

func request(_ boot: T3NativeAuthorityBootstrap, environment: String = "owned-environment",
                     headers: [String: String] = [:], expected: T3NativeAuthorityBinding? = nil,
                     raw: Data? = nil, path: String = "/v1/authority/lease", timeout: TimeInterval = 5,
                     method: String = "POST") async throws -> Reply {
    var input: [String: Any] = ["environmentId": environment]
    if let expected { input["expectedBinding"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) }
    var request = URLRequest(url: URL(string: boot.origin + path)!)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer " + boot.credential, forHTTPHeaderField: "Authorization")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    if method != "GET" { request.httpBody = try raw ?? JSONSerialization.data(withJSONObject: input) }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCache = nil
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.data(for: request)
    let http = response as! HTTPURLResponse
    return .init(status: http.statusCode, bytes: bytes, response: http)
}

@main private struct BrokerProof {
    static func main() async throws {
        setbuf(stdout, nil)
        // A fixture failure must not leave a hanging waiter or listener behind.
        let watchdog = Task { try await Task.sleep(for: .seconds(75)); fatalError("broker proof timed out") }
        defer { watchdog.cancel() }
        var assertions = 0
        func expect(_ value: Bool, _ detail: String) throws { try check(value, detail); assertions += 1 }
        func make(_ fixture: Fixture, timeout: Duration = .seconds(5)) -> T3NativeAuthorityBroker {
            .init(ownedEnvironment: { try await fixture.own() }, leaseProvider: { try await fixture.lease($0) },
                  isCurrent: { await fixture.valid($0) }, requestTimeout: timeout)
        }
        let fixture = Fixture(), broker = make(fixture)
        let boot = try await broker.start()
        try expect(boot.origin.hasPrefix("http://127.0.0.1:"), "numeric loopback ephemeral origin")
        try expect(boot.credential.count == 43 && !boot.credential.contains("="), "32-byte unpadded capability")
        try expect(!String(reflecting: boot).contains(boot.credential), "private bootstrap diagnostics")
        for headers in [["Origin": "null"], ["Origin": "https://browser.example"], ["Sec-Fetch-Site": "none"],
                        ["Referer": "https://browser.example/"], ["Cookie": "anything"], ["Host": "localhost:1234"],
                        ["Authorization": "Bearer " + String(repeating: "x", count: 43)], ["Content-Type": "text/plain"]] {
            try expect(try await request(boot, headers: headers).status == 403, "untrusted HTTP request refused")
        }
        let untouched = await fixture.counts()
        try expect(untouched == (0, 0), "HTTP authentication rejects before identity access")
        try expect(try await request(boot, environment: "arbitrary-requester").status == 403, "caller cannot select environment")
        try expect(await fixture.counts().1 == 0, "wrong environment never reaches credential owner")
        for data in [Data("{".utf8), Data(repeating: 97, count: 4097)] {
            try expect(try await request(boot, raw: data).status == 503, "invalid or oversized body refused")
        }
        try expect(await fixture.counts().1 == 0, "invalid bodies never reach provider")
        let success = try await request(boot)
        try expect(success.status == 200 && success.json["version"] as? Int == 1, "wire version and HTTP success")
        try expect(success.json["gatewayOrigin"] as? String == "https://gateway.example", "native gateway origin retained")
        try expect((success.json["binding"] as? [String: Any])?["identityGeneration"] as? String == "00000000-0000-4000-8000-000000000ABC", "UUID spelling retained")
        try expect(success.response.value(forHTTPHeaderField: "Cache-Control") == "no-store", "leases cannot be cached")
        let binding = await fixture.binding
        await fixture.configure(token: "renewed.fixture-token")
        let renewed = try await request(boot, expected: binding)
        try expect(renewed.json["accessToken"] as? String == "renewed.fixture-token", "each lease delegates renewal to existing owner")
        let mismatch = T3NativeAuthorityBinding(ownerId: "unrelated", deviceId: "device", homeId: "home", identityGeneration: binding.identityGeneration)
        let beforeMismatch = await fixture.counts().1
        try expect(try await request(boot, expected: mismatch).status == 409, "expected identity mismatch is visible")
        try expect(await fixture.counts().1 == beforeMismatch, "mismatched pin avoids renewal")
        await broker.invalidate()
        try expect(try await request(boot).status == 503, "revoked launch refuses existing capability")
        do { _ = try await broker.start(); throw NSError(domain: "restart allowed", code: 1) }
        catch T3NativeAuthorityError.unavailable { assertions += 1 }
        await broker.stop(); await broker.stop()
        let stopped = make(Fixture())
        await stopped.stop()
        do { _ = try await stopped.start(); throw NSError(domain: "stopped broker restarted", code: 1) }
        catch T3NativeAuthorityError.unavailable { assertions += 1 }

        let cancelledStartup = make(Fixture())
        let startup = Task { try await cancelledStartup.start() }
        startup.cancel()
        do { _ = try await startup.value; throw NSError(domain: "cancelled startup succeeded", code: 1) }
        catch T3NativeAuthorityError.unavailable { assertions += 1 }
        await cancelledStartup.stop()

        let ownership = Fixture(), ownershipBroker = make(ownership)
        let ownershipBoot = try await ownershipBroker.start()
        await ownership.setOwnershipAvailable(false)
        try expect(try await request(ownershipBoot).status == 503, "identity file must exist before first lease")
        await ownership.setOwnershipAvailable(true)
        try expect(try await request(ownershipBoot).status == 200, "initial identity startup can finish without a new broker")
        await ownership.setOwnershipAvailable(false)
        try expect(try await request(ownershipBoot).status == 503, "loss of established owned identity revokes launch")
        await ownership.setOwnershipAvailable(true)
        try expect(try await request(ownershipBoot).status == 503, "recreated identity cannot resurrect launch")
        await ownershipBroker.stop()

        // Concurrent calls pass through to the existing credential owner's renewal
        // coalescing; the broker introduces no second cache or refresh owner.
        let concurrent = Fixture(), concurrentBroker = make(concurrent)
        await concurrent.configure(paused: true)
        let concurrentBoot = try await concurrentBroker.start()
        let first = Task { try await request(concurrentBoot) }, second = Task { try await request(concurrentBoot) }
        await concurrent.waitForCalls(2)
        await concurrent.release()
        let firstReply = try await first.value, secondReply = try await second.value
        try expect(firstReply.status == 200 && secondReply.status == 200, "concurrent renewal passthrough")
        await concurrentBroker.stop()

        // A disconnected HTTP caller cancels its native renewal without changing
        // another request or revoking the launch.
        let cancellation = Fixture(), cancellationBroker = make(cancellation)
        await cancellation.configure(paused: true)
        let cancellationBoot = try await cancellationBroker.start()
        let cancelled = Task { try await request(cancellationBoot) }
        await cancellation.waitForCalls(1)
        let cancelledAt = Date()
        cancelled.cancel()
        do { _ = try await cancelled.value; throw NSError(domain: "request not cancelled", code: 1) } catch is URLError { assertions += 1 }
        await cancellation.waitForCancellation()
        try expect(Date().timeIntervalSince(cancelledAt) < 2, "disconnected lease cancels before request deadline")
        await cancellation.configure()
        try expect(try await request(cancellationBoot).status == 200, "HTTP cancellation does not revoke another request")
        await cancellationBroker.stop()

        // Revocation releases HTTP waiters even if an upstream provider ignores
        // cancellation; its delayed success can never escape the launch boundary.
        for stopping in [false, true] {
            let blocked = Fixture(), blockedBroker = make(blocked)
            await blocked.configure(paused: true, ignoreCancellation: true)
            let blockedBoot = try await blockedBroker.start()
            let call = Task { try await request(blockedBoot) }
            await blocked.waitForCalls(1)
            if stopping { await blockedBroker.stop() } else { await blockedBroker.invalidate() }
            do { try expect(try await call.value.status == 503, "revocation releases pending HTTP waiter") }
            catch is URLError { try expect(stopping, "transport close only on stop") }
            await blocked.waitForCancellation()
            await blocked.release()
            if !stopping { try expect(try await request(blockedBoot).status == 503, "late provider result cannot restore launch") }
            await blockedBroker.stop()
        }

        let timed = Fixture(), timedBroker = make(timed, timeout: .milliseconds(50))
        await timed.configure(paused: true, ignoreCancellation: true)
        let timedBoot = try await timedBroker.start()
        try expect(try await request(timedBoot).status == 503, "bounded request deadline releases HTTP waiter")
        await timed.waitForCancellation(); await timed.release(); await timedBroker.stop()

        for check in [1, 2] {
            let stale = Fixture(), staleBroker = make(stale)
            await stale.failRevalidation(at: check)
            let staleBoot = try await staleBroker.start()
            try expect(try await request(staleBoot).status == 503, "lease is rechecked after renewal and ownership await")
            let before = await stale.counts()
            try expect(try await request(staleBoot).status == 503, "failed current check revokes capability")
            try expect(await stale.counts() == before, "failed current check cannot re-enter owner")
            await staleBroker.stop()
        }

        for mutation in ["identity", "gateway", "launch"] {
            let changed = Fixture(), changedBroker = make(changed)
            let changedBoot = try await changedBroker.start()
            _ = try await request(changedBoot)
            await changed.configure(origin: mutation == "gateway" ? "https://other.example" : nil,
                                    changedIdentity: mutation == "identity", changedEnvironment: mutation == "launch")
            try expect(try await request(changedBoot).status == 503, "native identity or launch change revokes broker")
            let after = await changed.counts()
            try expect(try await request(changedBoot).status == 503, "revocation is permanent")
            try expect(await changed.counts() == after, "revoked broker cannot re-enter owner")
            await changedBroker.stop()
        }
        for mutation in ["expired", "oversized", "unsafe-token", "unsafe-origin"] {
            let invalid = Fixture(), invalidBroker = make(invalid)
            await invalid.configure(token: mutation == "oversized" ? String(repeating: "a", count: 16385) : (mutation == "unsafe-token" ? "secret\nbody" : nil),
                                    expiry: mutation == "expired" ? Date().addingTimeInterval(-1) : nil,
                                    origin: mutation == "unsafe-origin" ? "http://evil.example" : nil)
            let invalidBoot = try await invalidBroker.start()
            let response = try await request(invalidBoot)
            try expect(response.status == 503, "invalid credential response refused")
            try expect(String(decoding: response.bytes, as: UTF8.self) == "{\"error\":\"Native Atika authority is unavailable.\"}", "failure text excludes token and upstream content")
            await invalidBroker.stop()
        }
        print("ok - \(assertions) native authority real HTTP assertions")
        try await ToolsMountProof.run()
    }
}
