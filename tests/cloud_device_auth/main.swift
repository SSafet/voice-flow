import Foundation
import CryptoKit

private struct Failure: Error, CustomStringConvertible { let description: String }
private let assertionCounter = Counter()
private func expect(_ value: Bool, _ detail: String) throws {
    guard value else { throw Failure(description: detail) }; assertionCounter.increment()
}
private func rejects(_ detail: String, matching: (Error) -> Bool = { _ in true }, _ action: () async throws -> Void) async throws {
    do { try await action() } catch {
        guard matching(error) else { throw Failure(description: "\(detail): unexpected \(error)") }
        assertionCounter.increment(); return
    }
    throw Failure(description: "\(detail): unexpectedly succeeded")
}
private func uncertain(_ error: Error) -> Bool { if case CloudSyncError.loginUncertain = error { return true }; return false }
private func signedOut(_ error: Error) -> Bool { if case CloudSyncError.signInRequired = error { return true }; return false }

/// Every test exercises the real Codable vault, but no Security/Keychain calls.
private final class MemoryItems: CloudKeychainItems {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var history: [Data] = []
    var failWrite: ((String, Data) -> Bool)?
    var failRemove = false
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func write(account: String, bytes: Data) throws {
        try lock.withLock {
            if failWrite?(account, bytes) == true { throw CloudSyncError.storage("injected write") }
            values[account] = bytes; history.append(bytes)
        }
    }
    func remove(account: String) throws {
        try lock.withLock {
            if failRemove { throw CloudSyncError.storage("injected remove") }
            _ = values.removeValue(forKey: account)
        }
    }
    func credentialsHistory() -> [CloudCredentials] { lock.withLock { history.compactMap { try? JSONDecoder().decode(CloudCredentials.self, from: $0) } } }
}
private final class Counter: @unchecked Sendable {
    let lock = NSLock(); var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
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
    func fresh(_ vault: CloudCredentialVault, callback: (@Sendable () -> Void)? = nil) async throws -> (CloudHTTPClient, CloudCredentials) {
        let client = try CloudHTTPClient(origin: origin, vault: vault, allowLoopback: true, onInvalidation: callback)
        let challenge = try await client.start(email: "FIXTURE@example.invalid")
        let credential = try await client.complete(challenge: challenge, code: "123456", label: String(repeating: "🎙️", count: 100))
        return (client, credential)
    }
    func restart(_ credential: CloudCredentials, _ vault: CloudCredentialVault, callback: (@Sendable () -> Void)? = nil) throws -> CloudHTTPClient {
        try CloudHTTPClient(origin: origin, credentials: credential, vault: vault, allowLoopback: true, onInvalidation: callback)
    }
    var legacy: CloudCredentials {
        CloudCredentials(origin: origin, userID: "01J00000000000000000000001", email: "fixture@example.invalid",
                         deviceID: "01J00000000000000000000002", refreshToken: "legacy-fixture-refresh")
    }
}

@main private struct DeviceAuthTests {
    static func main() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let complete = "/api/v1/auth/native/login/complete", refresh = "/api/v1/auth/native/refresh"
        let enroll = "/api/v1/auth/device/key", token = "/api/v1/auth/device/token", challengePath = "/api/v1/auth/device/challenge"
        func newVault() -> (MemoryItems, CloudKeychainVault) { let items = MemoryItems(); return (items, CloudKeychainVault(items: items)) }

        do {
            let (items, vault) = newVault()
            let legacy = fixture.legacy
            var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
            old.removeValue(forKey: "version"); old.removeValue(forKey: "enrollment"); old.removeValue(forKey: "legacyRefreshUncertain")
            try items.write(account: legacy.partition, bytes: JSONSerialization.data(withJSONObject: old))
            try expect(try vault.load(partition: legacy.partition)?.version == 1, "old refresh-only Keychain item decodes")
            old["version"] = 3
            try items.write(account: legacy.partition, bytes: JSONSerialization.data(withJSONObject: old))
            try await rejects("future version fails closed") { _ = try vault.load(partition: legacy.partition) }
            try items.write(account: "wrong-partition", bytes: JSONEncoder().encode(legacy))
            try await rejects("partition swapping refused") { _ = try vault.load(partition: "wrong-partition") }
        }
        do {
            try await fixture.reset(); let (items, vault) = newVault()
            let (client, credential) = try await fixture.fresh(vault)
            try expect(credential.enrollment == .enrolled && credential.refreshToken == nil && credential.privateKey?.count == 32, "fresh key identity has no refresh token")
            try expect(try credential.signingKey().publicKey.derRepresentation.count == 91, "CryptoKit uses canonical SPKI DER")
            try expect(try vault.loadPending(origin: fixture.origin) == nil, "durable identity removes completed pending login")
            let identity = try await client.identity()
            try expect(identity.ownerID == credential.userID && identity.deviceID == credential.deviceID, "lease identity comes from authenticated response")
            try await client.capabilities()
            try expect(try await fixture.count(token) == 0, "fresh token serves sync without second auth owner")
            try expect(items.credentialsHistory().last?.privateKey == credential.privateKey, "actual encoded vault retains key")
            await client.retire()
        }
        do {
            try await fixture.reset(); let (_, vault) = newVault()
            let client = try CloudHTTPClient(origin: fixture.origin, vault: vault, allowLoopback: true)
            let challenge = try await client.start(email: "fixture@example.invalid")
            try await rejects("wrong code is explicit refusal") { _ = try await client.complete(challenge: challenge, code: "000000", label: "Test") }
            let pending = try vault.loadPending(origin: fixture.origin)!
            try expect(!pending.dispatched, "known code refusal can re-enter code")
            let success = try await client.complete(challenge: challenge, code: "123456", label: "Test")
            try expect(success.privateKey == pending.privateKey, "same pending key reused after invalid code")
            _ = try await client.complete(challenge: challenge, code: "123456", label: "Test")
            try expect(try await fixture.count(complete) == 2, "completed local selection retry does not enroll again")
        }
        for loss in ["loginLost", "loginDisconnected"] {
            try await fixture.reset(); let (_, vault) = newVault()
            let client = try CloudHTTPClient(origin: fixture.origin, vault: vault, allowLoopback: true)
            let challenge = try await client.start(email: "fixture@example.invalid")
            try await fixture.configure([loss: true])
            try await rejects("ambiguous enrollment", matching: uncertain) { _ = try await client.complete(challenge: challenge, code: "123456", label: "Test") }
            try expect(try vault.loadPending(origin: fixture.origin)?.dispatched == true, "ambiguous enrollment retains exact private key")
            try await rejects("same completion never auto-resends", matching: uncertain) { _ = try await client.complete(challenge: challenge, code: "123456", label: "Test") }
            try expect(try await fixture.count(complete) == 1, "one ambiguous completion dispatch")
            try await client.cancelLogin()
            try expect(try vault.loadPending(origin: fixture.origin) == nil, "explicit cancel removes pending secret")
        }
        do {
            try await fixture.reset(); let (items, vault) = newVault()
            let client = try CloudHTTPClient(origin: fixture.origin, vault: vault, allowLoopback: true)
            let challenge = try await client.start(email: "fixture@example.invalid")
            items.failWrite = { account, _ in account.hasPrefix("pending-login:") }
            try await rejects("pending key save failure blocks network") { _ = try await client.complete(challenge: challenge, code: "123456", label: "Test") }
            try expect(try await fixture.count(complete) == 0, "no login dispatch without durable key")
            items.failWrite = { account, _ in !account.hasPrefix("pending-login:") }
            try await rejects("identity save failure is uncertain", matching: uncertain) { _ = try await client.complete(challenge: challenge, code: "123456", label: "Test") }
            try expect(try vault.loadPending(origin: fixture.origin)?.dispatched == true, "identity persistence failure retains enrollment key")
            try await rejects("no ephemeral identity after failed persistence", matching: signedOut) { _ = try await client.identity() }
        }
        do {
            try await fixture.reset(); let (items, vault) = newVault(); try vault.save(fixture.legacy)
            let client = try fixture.restart(fixture.legacy, vault)
            _ = try await client.identity()
            let stored = try vault.load(partition: fixture.legacy.partition)!
            try expect(stored.enrollment == .enrolled && stored.refreshToken == nil, "legacy account migrates in same Keychain item")
            let history = items.credentialsHistory()
            try expect(history.contains { $0.enrollment == .pending && $0.privateKey != nil && !$0.legacyRefreshUncertain }, "key persists before legacy refresh")
            try expect(history.contains { $0.enrollment == .enrolled && $0.refreshToken != nil }, "enrolled key persists before proof retires refresh")
            let enrollments = try await fixture.count(enroll)
            try expect(try await fixture.count(refresh) == 1 && enrollments == 1, "one refresh and same-device enrollment")
            try expect(try await fixture.count(complete) == 0, "migration never mints a new device")
            try expect(try await fixture.helper("status")["refreshActive"] as? Bool == false, "proof retired server refresh")
        }
        do {
            try await fixture.reset(); let (_, vault) = newVault(); try vault.save(fixture.legacy)
            try await fixture.configure(["refreshLost": true])
            let client = try fixture.restart(fixture.legacy, vault)
            try await rejects("legacy rotation reply lost") { _ = try await client.identity() }
            let stored = try vault.load(partition: fixture.legacy.partition)!
            try expect(stored.legacyRefreshUncertain && stored.privateKey != nil, "rotation ambiguity persists with key")
            let restarted = try fixture.restart(stored, vault)
            try await rejects("rotated legacy token never resent", matching: uncertain) { _ = try await restarted.identity() }
            try expect(try await fixture.count(refresh) == 1, "one legacy rotation despite restart")
        }
        do {
            try await fixture.reset(); let (_, vault) = newVault(); try vault.save(fixture.legacy)
            try await fixture.configure(["enrollLost": true])
            let client = try fixture.restart(fixture.legacy, vault)
            try await rejects("enrollment response lost") { _ = try await client.identity() }
            let pending = try vault.load(partition: fixture.legacy.partition)!
            try expect(pending.enrollment == .pending && !pending.legacyRefreshUncertain, "same-device enrollment remains recoverable")
            await client.retire(); try await fixture.configure(["enrollLost": false])
            let restarted = try fixture.restart(pending, vault); _ = try await restarted.identity()
            try expect(try vault.load(partition: pending.partition)?.privateKey == pending.privateKey, "restart retries exact same key enrollment")
            try expect(try await fixture.count(enroll) == 2, "idempotent enrollment accepted twice")
        }
        for failCleanup in [false, true] {
            try await fixture.reset(); let (items, vault) = newVault(); try vault.save(fixture.legacy)
            if failCleanup {
                items.failWrite = { _, bytes in
                    guard let value = try? JSONDecoder().decode(CloudCredentials.self, from: bytes) else { return false }
                    return value.enrollment == .enrolled && value.refreshToken == nil
                }
            } else { try await fixture.configure(["proofLost": true]) }
            let client = try fixture.restart(fixture.legacy, vault)
            try await rejects("proof response/cleanup persistence failure") { _ = try await client.identity() }
            let saved = try vault.load(partition: fixture.legacy.partition)!
            try expect(saved.enrollment == .enrolled && saved.privateKey != nil && saved.refreshToken != nil, "key durably enrolled despite revoked legacy token")
            await client.retire(); items.failWrite = nil; try await fixture.configure(["proofLost": false])
            let restarted = try fixture.restart(saved, vault); _ = try await restarted.identity()
            try expect(try await fixture.count(refresh) == 1, "restart never falls back to revoked legacy refresh")
            try expect(try await fixture.count(token) == 2, "restart gets fresh challenge with persisted key")
        }
        do {
            try await fixture.reset(); let (_, vault) = newVault(); let notices = Counter()
            let (client, _) = try await fixture.fresh(vault, callback: { notices.increment() })
            let identity = try await client.identity()
            _ = try await client.homes()
            let binding = CloudRuntimeBinding(identity: identity, servingHomeID: "fixture-home", environmentID: "environment-one", environmentGeneration: UUID())
            try await fixture.configure(["expireAccess": true, "delayToken": 80])
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<24 {
                    group.addTask {
                        if index % 2 == 0 { try await client.capabilities() }
                        else { let lease = try await client.runtimeCredentials(for: binding); try expect(await client.isCurrent(lease, for: binding), "concurrent lease still bound") }
                    }
                }
                try await group.waitForAll()
            }
            try expect(try await fixture.count(token) == 1, "24 sync/runtime requests coalesce one proof renewal after 401")
            let lease = try await client.runtimeCredentials(for: binding)
            try expect(lease.binding == binding && lease.expiresAt > Date(), "lease has native-only exact binding and expiry")
            let other = CloudRuntimeBinding(identity: identity, servingHomeID: "fixture-home", environmentID: "environment-one", environmentGeneration: UUID())
            try expect(await !client.isCurrent(lease, for: other), "lease cannot cross native environment generation")
            try await fixture.configure(["home": "other-home"])
            try await rejects("serving home changes invalidate old binding") { _ = try await client.runtimeCredentials(for: binding) }
            try expect(await !client.isCurrent(lease, for: binding) && notices.value == 1, "home change retires leases and notifies native consumer")
        }
        do {
            try await fixture.reset(); let (_, vault) = newVault(); let (client, _) = try await fixture.fresh(vault)
            let identity = try await client.identity(); try await fixture.configure(["home": NSNull()])
            let binding = CloudRuntimeBinding(identity: identity, servingHomeID: "fixture-home", environmentID: "environment-one", environmentGeneration: UUID())
            try await rejects("absent serving home requires explicit flow", matching: { if case CloudSyncError.homeSelectionRequired = $0 { return true }; return false }) { _ = try await client.runtimeCredentials(for: binding) }
            try expect(try await fixture.count("/api/v1/me/homes") == 0, "no automatic home create/takeover")
        }
        do {
            try await fixture.reset(); let (_, vault) = newVault(); let (first, credential) = try await fixture.fresh(vault); await first.retire()
            try await fixture.configure(["challengeExpired": true])
            let client = try fixture.restart(credential, vault); _ = try await client.identity()
            let tokens = try await fixture.count(token)
            try expect(try await fixture.count(challengePath) == 2 && tokens == 2, "explicit expired challenge retries fresh nonce once")
        }
        for code in ["auth.device_revoked", "auth.user_disabled", "auth.device_proof_invalid"] {
            try await fixture.reset(); let (_, vault) = newVault(); let notices = Counter()
            let (first, credential) = try await fixture.fresh(vault); await first.retire()
            let client = try fixture.restart(credential, vault, callback: { notices.increment() })
            try await fixture.configure(["terminal": code])
            try await rejects("terminal refusal invalidates identity", matching: signedOut) { _ = try await client.identity() }
            try expect(try vault.load(partition: credential.partition) == nil && notices.value == 1, "terminal refusal destroys restartable secret and notifies")
            try await rejects("retired owner cannot mint new lease", matching: signedOut) { _ = try await client.identity() }
        }
        do {
            try await fixture.reset(); let (_, vault) = newVault(); let (first, credential) = try await fixture.fresh(vault); await first.retire()
            let client = try fixture.restart(credential, vault)
            try await fixture.configure(["wrongOwner": true])
            try await rejects("renewal never silently rebinds account", matching: signedOut) { _ = try await client.identity() }
            try expect(try vault.load(partition: credential.partition) == nil, "mismatched owner retires original identity")
        }
        do {
            try await fixture.reset(); let (items, vault) = newVault(); let (client, credential) = try await fixture.fresh(vault)
            items.failRemove = true; try await fixture.configure(["refuseAll": true])
            try await client.logout()
            let retired = try vault.load(partition: credential.partition)!
            try expect(retired.enrollment == .retired && retired.privateKey == nil && retired.refreshToken == nil, "offline logout leaves keyless tombstone if deletion fails")
            try await rejects("retired Keychain record cannot restart") { _ = try fixture.restart(retired, vault) }
        }
        do {
            try await fixture.reset(); let (_, vault) = newVault(); let (first, credential) = try await fixture.fresh(vault); await first.retire()
            let client = try fixture.restart(credential, vault); try await fixture.configure(["delayToken": 150])
            let pending = Task { try await client.identity() }
            for _ in 0..<100 { if try await fixture.count(token) > 0 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try await client.logout()
            try await rejects("logout cancels in-flight proof without resurrection") { _ = try await pending.value }
            try expect(try vault.load(partition: credential.partition) == nil, "late proof never restores signed-out key")
        }
        do {
            try await fixture.reset(); let (_, vault) = newVault(); let (client, credential) = try await fixture.fresh(vault)
            try await fixture.configure(["redirect": true])
            try await rejects("authorization redirect rejected") { try await client.capabilities() }
            try expect(try await fixture.count("leaks") == 0, "other origin receives no bearer")
            try expect(try vault.load(partition: credential.partition)?.privateKey == credential.privateKey, "ordinary HTTP failures preserve identity")
            let status = try await fixture.helper("status")
            try expect(!(status["events"] as! [String]).contains { $0.hasPrefix("INVALID:") }, "exact server protocol, raw signatures and no cookie replay verified")
        }
        print("PASS cloud_device_auth: \(assertionCounter.value) assertions; isolated real HTTP + CryptoKit/Node SPKI/P1363 verification + encoded in-memory Keychain + failure injection")
    }
}
