import Foundation

final class FixtureVault: CloudCredentialVault {
    private let lock = NSLock()
    private var values: [String: CloudCredentials] = [:]
    func load(partition: String) throws -> CloudCredentials? { lock.withLock { values[partition] } }
    func save(_ value: CloudCredentials) throws { lock.withLock { values[value.partition] = value } }
    func remove(partition: String) throws { _ = lock.withLock { values.removeValue(forKey: partition) } }
}
struct FixtureConfig: Decodable { var origin: String; var emails: [String] }
func assertSync(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fatalError(message) }
}
@main struct NativeCloudSmoke {
    static func main() async throws {
        let fixture = try JSONDecoder().decode(FixtureConfig.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-native-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultA = FixtureVault(); let vaultB = FixtureVault(); let vaultOther = FixtureVault()
        let mac = try CloudHTTPClient(origin: fixture.origin, vault: vaultA, allowLoopback: true)
        let phone = try CloudHTTPClient(origin: fixture.origin, vault: vaultB, allowLoopback: true)
        let other = try CloudHTTPClient(origin: fixture.origin, vault: vaultOther, allowLoopback: true)
        func helper(_ path: String, body: [String: String]? = nil) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: fixture.origin + path)!)
            if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard (response as! HTTPURLResponse).statusCode == 200 else { throw CloudSyncError.invalidResponse }
            return try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        }
        func login(_ client: CloudHTTPClient, email: String) async throws -> CloudCredentials {
            let challenge = try await client.start(email: email)
            let code = try await helper("/fixture/code?email=\(email)")["code"] as! String
            return try await client.complete(challenge: challenge, code: code, label: "Synthetic Mac")
        }
        let credentialA = try await login(mac, email: fixture.emails[0])
        let credentialB = try await login(phone, email: fixture.emails[0])
        let credentialOther = try await login(other, email: fixture.emails[1])
        try assertSync(credentialA.deviceID != credentialB.deviceID, "server minted separate device IDs")
        try assertSync(credentialA.userID == credentialB.userID && credentialA.userID != credentialOther.userID, "real account identities")
        let partition = credentialA.partition
        let dbA = try CloudSyncStore(url: root.appendingPathComponent("mac.sqlite"))
        let dbB = try CloudSyncStore(url: root.appendingPathComponent("phone.sqlite"))
        func pull(_ client: CloudHTTPClient, db: CloudSyncStore) async throws {
            while true { let page = try await client.pull(cursor: db.state(partition).cursor); try db.apply(page, partition: partition); if !page.hasMore { return } }
        }
        func send(_ client: CloudHTTPClient, db: CloudSyncStore) async throws {
            while true {
                let pending = try db.nextOperations(partition)
                if pending.isEmpty { return }
                let response = try await client.mutate(pending)
                try db.acknowledge(response, sent: pending, partition: partition)
            }
        }
        let edits = (0..<1200).map { CloudLocalEdit(collection: .dictations, recordId: "offline-\($0)", payload: CloudPayload(text: "Portable words \($0)", destination: "kept")) }
        try dbA.capture(edits, partition: partition, markImported: true)
        try await mac.capabilities()
        try await send(mac, db: dbA)
        try await pull(mac, db: dbA)
        try await pull(phone, db: dbB)
        try assertSync(dbA.state(partition).pendingCount == 0 && dbB.state(partition).records.count == 1200, "native 1200-record cloud import")
        try assertSync(dbB.state(partition).records["dictations:offline-1199"]?.payload?.text == "Portable words 1199", "content across pages")
        print("PASS native HTTP: code login, separate device enrollment, 1200-record import/pagination")

        try dbA.capture([CloudLocalEdit(collection: .dictations, recordId: "offline-0", payload: CloudPayload(text: "Mac edit", destination: "kept"))], partition: partition)
        try dbB.capture([CloudLocalEdit(collection: .dictations, recordId: "offline-0", payload: CloudPayload(text: "Phone edit", destination: "kept"))], partition: partition)
        try await send(mac, db: dbA); try await send(phone, db: dbB)
        try assertSync(dbB.state(partition).conflicts.count == 1, "offline collision is retained")
        try dbA.capture([CloudLocalEdit(collection: .dictations, recordId: "offline-0", payload: nil)], partition: partition)
        try await send(mac, db: dbA)
        let conflict = try dbB.state(partition).conflicts[0]
        let tombstone = try await phone.record(collection: .dictations, id: "offline-0")
        try assertSync(tombstone.deletedAt != nil, "delete is retained")
        try dbB.resolve(conflict, remote: tombstone, choice: .proposal, partition: partition)
        try await send(phone, db: dbB); try await pull(phone, db: dbB); try await pull(mac, db: dbA)
        try assertSync(dbA.state(partition).records["dictations:offline-0"]?.payload?.text == "Phone edit", "explicit conflict resolution restores deleted record")
        try assertSync(dbB.state(partition).conflicts.isEmpty, "resolved event closes retained proposal")
        print("PASS native HTTP: offline edits, retained conflict, tombstone, explicit restore/resolution")

        try dbA.capture([CloudLocalEdit(collection: .dictations, recordId: "lost-response", payload: CloudPayload(text: "Exactly once", destination: "kept"))], partition: partition)
        let pending = try dbA.nextOperations(partition)
        _ = try await helper("/fixture/drop-next", body: [:])
        do { _ = try await mac.mutate(pending); fatalError("response loss fixture did not fail") } catch CloudSyncError.server(503, _) { }
        let persisted = try vaultA.load(partition: partition)!
        let restarted = try CloudHTTPClient(origin: fixture.origin, credentials: persisted, vault: vaultA, allowLoopback: true)
        let response = try await restarted.mutate(pending)
        try dbA.acknowledge(response, sent: pending, partition: partition)
        try await pull(restarted, db: dbA)
        let after = try dbA.state(partition)
        try assertSync(after.records["dictations:lost-response"]?.remote?.version == "1", "lost response retry has one revision")
        do { _ = try await other.pull(cursor: after.cursor); fatalError("foreign cursor accepted") } catch CloudSyncError.server(400, _) { }
        print("PASS native HTTP: dropped committed response, recreated client/refresh, exact receipt, foreign-account cursor rejection")

        _ = try await helper("/fixture/redirect-next", body: [:])
        do { try await restarted.capabilities(); fatalError("redirect followed") } catch CloudSyncError.server(302, _) { }
        let redirectStatus = try await helper("/fixture/status")
        try assertSync(redirectStatus["leakedRequests"] as? Int == 0, "redirect received no credentials")
        _ = try await helper("/fixture/revoke", body: ["deviceId": credentialA.deviceID])
        try dbA.capture([CloudLocalEdit(collection: .dictations, recordId: "revoked-offline", payload: CloudPayload(text: "Keep here", destination: "kept"))], partition: partition)
        do { try await restarted.capabilities(); fatalError("revoked device accepted") } catch CloudSyncError.signInRequired { }
        try assertSync(dbA.state(partition).pendingCount == 1, "revocation does not lose local queue")
        print("PASS native HTTP: redirects rejected, revoked access+refresh rejected, local queue retained")
    }
}
