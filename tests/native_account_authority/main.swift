import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }
private final class MemoryItems: CloudKeychainItems {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(account: String, bytes: Data) throws { lock.withLock { values[account] = bytes } }
    func remove(account: String) throws { lock.withLock { _ = values.removeValue(forKey: account) } }
}
private final class Revocation: @unchecked Sendable {
    private let lock = NSLock()
    private var authority: T3NativeAccountAuthority?
    private var count = 0
    private var sawClosed = false
    private var deferred = 0
    func attach(_ value: T3NativeAccountAuthority) { lock.withLock { authority = value } }
    func notify() { lock.withLock { authority }?.revoke() }
    func deferNotification() { lock.withLock { deferred += 1 } }
    var deferredNotifications: Int { lock.withLock { deferred } }
    func observe() {
        let current = lock.withLock { authority }
        lock.withLock { count += 1; sawClosed = current?.currentSnapshot == nil }
    }
    var observations: (Int, Bool) { lock.withLock { (count, sawClosed) } }
}
@MainActor private final class Selection {
    var owner: CloudHTTPClient
    var environment = T3AuthorityEnvironmentIdentity(environmentID: "fixture-environment", generation: UUID())
    var ownsEnvironment = false
    var ownerReads = 0
    init(owner: CloudHTTPClient) { self.owner = owner }
    func selectedOwner() -> CloudHTTPClient { ownerReads += 1; return owner }
    func owned() throws -> T3AuthorityEnvironmentIdentity {
        guard ownsEnvironment else { throw T3NativeAuthorityError.unavailable }
        return environment
    }
}
private struct Fixture: Decodable {
    let origin: String
    func helper(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: origin + "/fixture/" + path)!)
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(description: "fixture helper") }
        return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    }
    func reset() async throws { _ = try await helper("reset", [:]) }
    func configure(_ value: [String: Any]) async throws { _ = try await helper("configure", value) }
    func count(_ path: String) async throws -> Int { (try await helper("status")["counts"] as? [String: Int])?[path] ?? 0 }
    func fresh(_ notices: Revocation, deliverInvalidation: Bool = true) async throws -> (CloudHTTPClient, CloudKeychainVault, CloudCredentials) {
        let vault = CloudKeychainVault(items: MemoryItems())
        let client = try CloudHTTPClient(origin: origin, vault: vault, allowLoopback: true, onInvalidation: {
            if deliverInvalidation { notices.notify() } else { notices.deferNotification() }
        })
        let challenge = try await client.start(email: "fixture@example.invalid")
        let credentials = try await client.complete(challenge: challenge, code: "123456", label: "isolated authority fixture")
        return (client, vault, credentials)
    }
    func waitForCount(_ path: String, atLeast target: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while try await count(path) < target {
            guard Date() < deadline else { throw Failure(description: "fixture request did not arrive") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@main private struct AccountAuthorityProof {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var assertions = 0
        func expect(_ value: Bool, _ detail: String) throws {
            guard value else { throw Failure(description: detail) }; assertions += 1
        }
        func refuses(_ detail: String, _ action: () async throws -> Void) async throws {
            do { try await action() } catch {
                try expect(error.localizedDescription == T3NativeAuthorityError.unavailable.localizedDescription || error is CancellationError, "private error is constant")
                assertions += 1; return
            }
            throw Failure(description: detail)
        }
        func connect(_ selection: Selection, _ notices: Revocation, home: String = "fixture-home") async throws -> T3NativeAccountAuthority {
            let authority = try await T3NativeAccountAuthority.connect(destination: .nativeServingHome(id: home),
                credentialOwner: { selection.selectedOwner() }, ownedEnvironment: { try selection.owned() }, onRevoke: { notices.observe() })
            notices.attach(authority)
            return authority
        }
        let tokenPath = "/api/v1/auth/device/token"
        do {
            try await fixture.reset(); let notices = Revocation()
            let (owner, _, _) = try await fixture.fresh(notices)
            let selection = Selection(owner: owner)
            for destination in [T3NativeAccountAuthority.Destination.cloud, .nativeServingHome(id: "")] {
                try await refuses("cloud/absent serving-home choice admitted") {
                    _ = try await T3NativeAccountAuthority.connect(destination: destination,
                        credentialOwner: { selection.selectedOwner() }, ownedEnvironment: { try selection.owned() })
                }
            }
            try expect(selection.ownerReads == 0, "unsupported target refused before owner access")
            let authority = try await connect(selection, notices)
            try expect(authority.currentSnapshot == nil, "connect needs no child file and grants no native permission")
            try await refuses("unestablished environment leased") { _ = try await authority.lease(for: selection.environment) }
            selection.ownsEnvironment = true
            let lease = try await authority.lease(for: selection.environment)
            let identity = try await owner.identity()
            try expect(lease.binding.ownerId == identity.ownerID && lease.binding.deviceId == identity.deviceID && lease.binding.identityGeneration == identity.generation.uuidString,
                       "actual native actor maps owner/device/exact generation")
            try expect(lease.binding.homeId == "fixture-home" && lease.environment == selection.environment && lease.gatewayOrigin == fixture.origin,
                       "explicit home and exact owned launch mapped")
            let currentLease = await authority.isCurrent(lease)
            try expect(lease.expiresAt > Date() && currentLease, "lease revalidation uses native actor")
            let snapshot = try unwrap(authority.currentSnapshot)
            try expect(snapshot.binding == lease.binding && snapshot.environment == lease.environment && snapshot.validatedUntil == lease.expiresAt, "token-free snapshot matches validated lease")
            try expect(authority.permits(snapshot), "synchronous checkpoint accepts current immutable snapshot")
            let expired = T3NativeAccountAuthority.Snapshot(environment: snapshot.environment, binding: snapshot.binding,
                gatewayOrigin: snapshot.gatewayOrigin, validatedUntil: Date().addingTimeInterval(-1))
            try expect(!authority.permits(expired), "expired checkpoint cannot authorize native actions")
            try expect(!String(reflecting: snapshot).contains(lease.accessToken), "snapshot has no access token")
            let before = try await fixture.count(tokenPath)
            let checkpoint = owner.nativeAuthorityCheckpoint
            try await owner.capabilities()
            try expect(try await fixture.count(tokenPath) == before, "sync and broker share existing proof owner")

            // Twenty-four sync and authority callers coalesce refresh in the
            // existing native actor; this adapter has no refresh/cache machinery.
            try await fixture.configure(["expireAccess": true, "delayToken": 80])
            let environment = selection.environment
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<24 {
                    group.addTask {
                        if index % 2 == 0 { try await owner.capabilities() }
                        else { _ = try await authority.lease(for: environment) }
                    }
                }
                try await group.waitForAll()
            }
            try expect(try await fixture.count(tokenPath) == before + 1, "24 mixed calls coalesce one native proof renewal")
            let renewed = try await authority.lease(for: environment)
            try expect(renewed.binding == lease.binding && renewed.accessToken != lease.accessToken, "ordinary renewal preserves identity without token cache")
            try expect(owner.nativeAuthorityCheckpoint == checkpoint, "ordinary proof renewal preserves native checkpoint")
            try expect(authority.permits(snapshot), "ordinary renewal does not invalidate identity checkpoint")

            try await fixture.configure(["refuseAll": true])
            try await refuses("offline gateway passed lease") { _ = try await authority.lease(for: environment) }
            try expect(authority.currentSnapshot == nil && !authority.permits(snapshot), "failed fresh validation suspends native checkpoints")
            try await fixture.configure(["refuseAll": false])
            _ = try await authority.lease(for: environment)
            try expect(authority.currentSnapshot?.binding == snapshot.binding, "same identity can recover from network failure")

            authority.revoke()
            try expect(authority.currentSnapshot == nil && !authority.permits(snapshot), "revocation immediately closes permission snapshot")
            try expect(notices.observations == (1, true), "revocation callback sees checkpoint already closed")
            try await refuses("revoked authority reopened") { _ = try await authority.lease(for: environment) }
            await authority.stop(); await authority.stop()
            try expect(notices.observations.0 == 1, "cleanup is idempotent")
            try await owner.capabilities()
            assertions += 1 // adapter teardown must not retire sync's actor
        }
        for changed in ["home", "missing-home", "launch", "missing-child", "owner", "retired", "wrong-request"] {
            try await fixture.reset(); let notices = Revocation()
            let (owner, vault, credentials) = try await fixture.fresh(notices)
            let selection = Selection(owner: owner); selection.ownsEnvironment = true
            let authority = try await connect(selection, notices)
            let lease = try await authority.lease(for: selection.environment)
            let snapshot = try unwrap(authority.currentSnapshot)
            if changed == "home" { try await fixture.configure(["home": "other-home"]) }
            if changed == "missing-home" { try await fixture.configure(["home": NSNull()]) }
            if changed == "launch" { selection.environment = .init(environmentID: selection.environment.environmentID, generation: UUID()) }
            if changed == "missing-child" { selection.ownsEnvironment = false }
            if changed == "owner" {
                selection.owner = try CloudHTTPClient(origin: fixture.origin, credentials: credentials, vault: vault, allowLoopback: true)
            }
            if changed == "retired" { await owner.retire() }
            let requested = changed == "wrong-request" ? T3AuthorityEnvironmentIdentity(environmentID: "another-environment", generation: UUID()) : selection.environment
            try await refuses("changed authority leased") { _ = try await authority.lease(for: requested) }
            try expect(authority.currentSnapshot == nil && !authority.permits(snapshot), "changed state closes checkpoint")
            if changed != "wrong-request" { try expect(await !authority.isCurrent(lease), "old native lease refused") }
            try expect(try await fixture.count("/api/v1/me/homes") == 0, "no home create or takeover")
            await authority.stop()
        }
        // A non-serving explicit choice is refused even before a snapshot exists.
        do {
            try await fixture.reset(); let notices = Revocation()
            let (owner, _, _) = try await fixture.fresh(notices)
            let selection = Selection(owner: owner); selection.ownsEnvironment = true
            let authority = try await connect(selection, notices, home: "not-this-mac")
            try await refuses("non-serving home leased") { _ = try await authority.lease(for: selection.environment) }
            try expect(authority.currentSnapshot == nil, "non-serving target cannot publish native permission")
            await authority.stop()
        }
        // Retire permission while the actual native proof request awaits HTTP.
        // A delayed successful renewal must not republish the old snapshot.
        for change in ["revoke", "replace-owner", "replace-launch"] {
            try await fixture.reset(); let notices = Revocation()
            let (owner, vault, credentials) = try await fixture.fresh(notices)
            let selection = Selection(owner: owner); selection.ownsEnvironment = true
            let authority = try await connect(selection, notices)
            _ = try await authority.lease(for: selection.environment)
            try await fixture.configure(["expireAccess": true, "delayToken": 150])
            let pending = Task { try await authority.lease(for: selection.environment) }
            try await fixture.waitForCount(tokenPath, atLeast: 1)
            if change == "revoke" { authority.revoke() }
            if change == "replace-owner" { selection.owner = try CloudHTTPClient(origin: fixture.origin, credentials: credentials, vault: vault, allowLoopback: true) }
            if change == "replace-launch" { selection.environment = .init(environmentID: selection.environment.environmentID, generation: UUID()) }
            try await refuses("late renewal crossed invalidation") { _ = try await pending.value }
            try expect(authority.currentSnapshot == nil, "delayed proof cannot revive permission")
            await authority.stop()
        }
        do {
            try await fixture.reset(); let notices = Revocation()
            let (owner, _, _) = try await fixture.fresh(notices)
            let selection = Selection(owner: owner); selection.ownsEnvironment = true
            let authority = try await connect(selection, notices)
            _ = try await authority.lease(for: selection.environment)
            try await fixture.configure(["expireAccess": true, "delayToken": 150])
            let pending = Task { try await authority.lease(for: selection.environment) }
            let sync = Task { try await owner.capabilities() }
            try await fixture.waitForCount(tokenPath, atLeast: 1)
            pending.cancel()
            try await refuses("cancelled lease published") { _ = try await pending.value }
            try await sync.value
            try expect(try await fixture.count(tokenPath) == 1, "cancelling one lease cannot cancel shared sync renewal")
            try expect(notices.observations.0 == 0, "request cancellation does not retire account authority")
            _ = try await authority.lease(for: selection.environment)
            try expect(authority.currentSnapshot != nil, "same authority remains usable after request cancellation")
            await authority.stop()
        }
        do {
            try await fixture.reset(); let notices = Revocation()
            let (first, vault, credentials) = try await fixture.fresh(notices)
            await first.retire()
            let restarting = try CloudHTTPClient(origin: fixture.origin, credentials: credentials, vault: vault, allowLoopback: true)
            let selection = Selection(owner: restarting)
            try await fixture.configure(["delayToken": 150])
            let pending = Task { try await connect(selection, notices) }
            try await fixture.waitForCount(tokenPath, atLeast: 1)
            selection.owner = try CloudHTTPClient(origin: fixture.origin, credentials: credentials, vault: vault, allowLoopback: true)
            try await refuses("account changed during connect") { _ = try await pending.value }
        }
        for change in ["retire", "home"] {
            try await fixture.reset(); let notices = Revocation()
            let (owner, _, _) = try await fixture.fresh(notices, deliverInvalidation: false)
            let selection = Selection(owner: owner); selection.ownsEnvironment = true
            let authority = try await connect(selection, notices)
            _ = try await authority.lease(for: selection.environment)
            let snapshot = try unwrap(authority.currentSnapshot)
            let checkpoint = owner.nativeAuthorityCheckpoint
            if change == "retire" { await owner.retire() }
            else { try await fixture.configure(["home": "another-selected-home"]); _ = try await owner.homes() }
            try expect(notices.deferredNotifications == 1 && notices.observations.0 == 0, "controller-style retirement notification is still queued")
            // No actor hop or delivered observer callback is needed for this
            // primitive checkpoint to see the real credential owner's invalidation.
            try expect(authority.currentSnapshot == nil && !authority.permits(snapshot), "same actor retirement closes synchronous native checkpoint before callback delivery")
            try expect(notices.observations == (1, true), "direct checkpoint revokes before cleanup callback")
            if change == "retire" {
                try expect(owner.nativeAuthorityCheckpoint == nil, "retired owner checkpoint is permanent nil")
                await owner.retire()
                try expect(owner.nativeAuthorityCheckpoint == nil, "repeat retirement cannot reopen checkpoint")
            } else {
                try expect(owner.nativeAuthorityCheckpoint != checkpoint && owner.nativeAuthorityCheckpoint != nil, "home change advances checkpoint without retiring sync actor")
                let newlySelected = try await connect(selection, Revocation(), home: "another-selected-home")
                _ = try await newlySelected.lease(for: selection.environment)
                try expect(newlySelected.currentSnapshot?.binding.homeId == "another-selected-home", "explicit new home composition can use the same sync owner")
                await newlySelected.stop()
                try await fixture.configure(["home": "fixture-home"]); _ = try await owner.homes()
                try expect(authority.currentSnapshot == nil, "returning to previous home cannot revive prior generation")
            }
            try await refuses("old component rebound after queued invalidation") { _ = try await authority.lease(for: selection.environment) }
            await authority.stop()
        }
        print("ok - \(assertions) native account authority assertions with real auth actor and HTTP")
    }
    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(description: "missing validated snapshot") }; return value
    }
}
