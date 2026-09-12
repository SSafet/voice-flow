import Foundation
import Security

struct CloudCredentials: Codable {
    var origin: String
    var userID: String
    var email: String
    var deviceID: String
    var refreshToken: String
    var partition: String { CloudSyncStore.partition(origin: origin, userID: userID) }
}
protocol CloudCredentialVault {
    func load(partition: String) throws -> CloudCredentials?
    func save(_ value: CloudCredentials) throws
    func remove(partition: String) throws
}
/// Cloud refresh material has its own Keychain service and is never included
/// in provider-key/LAN transport. Updating an item is atomic; no delete gap.
final class CloudKeychainVault: CloudCredentialVault {
    private let service: String
    init(namespace: String = "com.voiceflow.cloud-sync") { service = namespace }
    private func query(_ partition: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: partition]
    }
    func load(partition: String) throws -> CloudCredentials? {
        var input = query(partition)
        input[kSecReturnData as String] = true
        input[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(input as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let bytes = item as? Data else { throw CloudSyncError.storage("keychain read") }
        return try JSONDecoder().decode(CloudCredentials.self, from: bytes)
    }
    func save(_ value: CloudCredentials) throws {
        let bytes = try JSONEncoder().encode(value)
        let result = SecItemUpdate(query(value.partition) as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw CloudSyncError.storage("keychain update") }
        var input = query(value.partition)
        input[kSecValueData as String] = bytes
        input[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(input as CFDictionary, nil) == errSecSuccess else { throw CloudSyncError.storage("keychain add") }
    }
    func remove(partition: String) throws {
        let result = SecItemDelete(query(partition) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CloudSyncError.storage("keychain remove") }
    }
}
private final class CloudNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct CloudLoginChallenge: Decodable {
    struct Challenge: Decodable { var state: String; var email: String; var expiresAt: String }
    var challenge: Challenge
}
private struct CloudAuthResponse: Decodable {
    struct User: Decodable { var id: String; var email: String }
    var accessToken: String; var accessExpiresIn: Int; var refreshToken: String
    var user: User; var deviceId: String
}
private struct CloudMutationRequest: Encodable { let protocolVersion = 1; var operations: [CloudOperation] }
private struct CloudMutationResponse: Decodable { var results: [CloudReceipt] }
private struct CloudRecordResponse: Decodable { var record: CloudRecord }
private struct CloudStatusResponse: Decodable { var protocolVersion: Int; var supportsBlobs: Bool }
private struct CloudEmptyResponse: Decodable { }
private struct CloudErrorResponse: Decodable { struct Detail: Decodable { var code: String }; var error: Detail }

actor CloudHTTPClient {
    let origin: String
    private let session: URLSession
    private let vault: CloudCredentialVault
    private var credentials: CloudCredentials?
    private var access: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?
    private var stopped = false

    init(origin: String, credentials: CloudCredentials? = nil, vault: CloudCredentialVault, allowLoopback: Bool = false) throws {
        self.origin = try CloudWire.origin(origin, allowLoopback: allowLoopback)
        if let credentials, credentials.origin != self.origin { throw CloudSyncError.invalidResponse }
        self.credentials = credentials
        self.vault = vault
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration, delegate: CloudNoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func start(email: String) async throws -> CloudLoginChallenge.Challenge {
        struct Body: Encodable { var email: String }
        let response: CloudLoginChallenge = try await send("/api/v1/auth/native/login/start", body: Body(email: email))
        return response.challenge
    }
    func complete(challenge: CloudLoginChallenge.Challenge, code: String, label: String) async throws -> CloudCredentials {
        struct Device: Encodable { let kind = "desktop"; var label: String }
        struct Body: Encodable { var state: String; var email: String; var code: String; var device: Device }
        let response: CloudAuthResponse = try await send("/api/v1/auth/native/login/complete",
            body: Body(state: challenge.state, email: challenge.email, code: code, device: Device(label: String(label.prefix(100)))))
        return try acceptAuth(response)
    }
    func capabilities() async throws {
        let status: CloudStatusResponse = try await authorized("/api/v1/sync")
        guard status.protocolVersion == 1 else { throw CloudSyncError.updateRequired }
    }
    func pull(cursor: String?) async throws -> CloudPage {
        var parts = URLComponents()
        parts.queryItems = cursor.map { [URLQueryItem(name: "cursor", value: $0)] }
        return try await authorized("/api/v1/sync/changes\(parts.percentEncodedQuery.map { "?\($0)" } ?? "")")
    }
    func mutate(_ operations: [CloudOperation]) async throws -> [CloudReceipt] {
        let response: CloudMutationResponse = try await authorized("/api/v1/sync/mutations", body: CloudMutationRequest(operations: operations))
        return response.results
    }
    func record(collection: CloudCollection, id: String) async throws -> CloudRecord {
        guard CloudWire.validID(id) else { throw CloudSyncError.invalidRecord }
        let response: CloudRecordResponse = try await authorized("/api/v1/sync/records/\(collection.rawValue)/\(id)")
        return response.record
    }
    func logout() async throws {
        stopped = true
        refreshing?.cancel()
        _ = try? await refreshing?.value
        guard let credentials else { return }
        struct Body: Encodable { var refreshToken: String }
        // Local sign-out remains available offline. A lost revoke reply cannot
        // reactivate this client; a device revoke in Atika ends all sessions.
        let _: CloudEmptyResponse? = try? await send("/api/v1/auth/native/logout", body: Body(refreshToken: credentials.refreshToken), bearer: access?.token)
        try vault.remove(partition: credentials.partition)
        self.credentials = nil; access = nil
    }

    private func acceptAuth(_ response: CloudAuthResponse) throws -> CloudCredentials {
        try Task.checkCancellation()
        guard !stopped else { throw CloudSyncError.signInRequired }
        guard CloudWire.validID(response.user.id), CloudWire.validID(response.deviceId),
              response.deviceId.count == 26, !response.refreshToken.isEmpty, !response.accessToken.isEmpty,
              response.accessExpiresIn > 0 else { throw CloudSyncError.invalidResponse }
        if let credentials, credentials.userID != response.user.id || credentials.deviceID != response.deviceId { throw CloudSyncError.invalidResponse }
        let next = CloudCredentials(origin: origin, userID: response.user.id, email: response.user.email,
                                    deviceID: response.deviceId, refreshToken: response.refreshToken)
        try vault.save(next) // successor is durable before waiting callers resume
        credentials = next
        access = (response.accessToken, Date().addingTimeInterval(Double(response.accessExpiresIn)))
        return next
    }
    private func accessToken(force: Bool = false) async throws -> String {
        guard !stopped else { throw CloudSyncError.signInRequired }
        if !force, let access, access.expires.timeIntervalSinceNow > 30 { return access.token }
        if let refreshing { return try await refreshing.value }
        guard let credentials else { throw CloudSyncError.signInRequired }
        let task = Task<String, Error> {
            struct Body: Encodable { var deviceId: String; var refreshToken: String }
            let response: CloudAuthResponse = try await send("/api/v1/auth/native/refresh",
                body: Body(deviceId: credentials.deviceID, refreshToken: credentials.refreshToken))
            _ = try acceptAuth(response)
            return response.accessToken
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
    private func authorized<Response: Decodable>(_ path: String) async throws -> Response {
        try await authorized(path, body: Optional<String>.none)
    }
    private func authorized<Body: Encodable, Response: Decodable>(_ path: String, body: Body?) async throws -> Response {
        let token = try await accessToken()
        do { return try await send(path, body: body, bearer: token) }
        catch CloudSyncError.signInRequired {
            let next = try await accessToken(force: true)
            return try await send(path, body: body, bearer: next)
        }
    }
    private func send<Body: Encodable, Response: Decodable>(_ path: String, body: Body?, bearer: String? = nil) async throws -> Response {
        try Task.checkCancellation()
        guard path.hasPrefix("/api/v1/"), let url = URL(string: origin + path) else { throw CloudSyncError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, bytes.count <= 2 * 1024 * 1024 else { throw CloudSyncError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONDecoder().decode(CloudErrorResponse.self, from: bytes))?.error.code ?? ""
            if response.statusCode == 401 { throw CloudSyncError.signInRequired }
            if code == "sync.cursor_expired" { throw CloudSyncError.historyChanged }
            throw CloudSyncError.server(response.statusCode, code)
        }
        do { return try JSONDecoder().decode(Response.self, from: bytes) }
        catch { throw CloudSyncError.invalidResponse }
    }
}
