import Foundation

final class FixtureVault: CloudCredentialVault {
    private let lock = NSLock()
    private var values: [String: CloudCredentials] = [:]
    func load(partition: String) throws -> CloudCredentials? { lock.withLock { values[partition] } }
    func save(_ value: CloudCredentials) throws { lock.withLock { values[value.partition] = value } }
    func remove(partition: String) throws { _ = lock.withLock { values.removeValue(forKey: partition) } }
}
struct FixtureConfig: Decodable { var origin: String; var emails: [String] }
@main struct FixtureClient {
    static func main() async throws {
        guard CommandLine.arguments.count >= 5 else { fatalError("fixture-path sqlite-path put|read record-id [text]") }
        let args = CommandLine.arguments
        let fixture = try JSONDecoder().decode(FixtureConfig.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let client = try CloudHTTPClient(origin: fixture.origin, vault: FixtureVault(), allowLoopback: true)
        let challenge = try await client.start(email: fixture.emails[0])
        var codeURL = URLComponents(string: fixture.origin + "/fixture/code")!
        codeURL.queryItems = [URLQueryItem(name: "email", value: fixture.emails[0])]
        let (codeBytes, _) = try await URLSession.shared.data(from: codeURL.url!)
        let code = (try JSONSerialization.jsonObject(with: codeBytes) as! [String: String])["code"]!
        let credentials = try await client.complete(challenge: challenge, code: code, label: "Swift device QA")
        let db = try CloudSyncStore(url: URL(fileURLWithPath: args[2]))
        let partition = credentials.partition
        try await client.capabilities()
        func pull() async throws {
            while true {
                let page = try await client.pull(cursor: db.state(partition).cursor)
                try db.apply(page, partition: partition)
                if !page.hasMore { return }
            }
        }
        try await pull()
        if args[3] == "put" {
            guard args.count == 6 else { fatalError("put requires text") }
            try db.capture([CloudLocalEdit(collection: .dictations, recordId: args[4], payload: CloudPayload(text: args[5], destination: "kept"))], partition: partition)
            while true {
                let pending = try db.nextOperations(partition)
                if pending.isEmpty { break }
                let receipts = try await client.mutate(pending)
                try db.acknowledge(receipts, sent: pending, partition: partition)
            }
            try await pull()
        } else if args[3] != "read" { fatalError("expected put or read") }
        guard let record = try db.state(partition).records[CloudSyncStore.key(.dictations, args[4])] else { fatalError("record missing") }
        let result: [String: Any] = ["recordId": record.recordId, "text": record.payload?.text ?? NSNull(), "version": record.remote?.version ?? "0", "pending": record.pending.count, "conflicts": record.conflicts.count]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        try await client.logout()
    }
}
