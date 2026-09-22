import Foundation
import Security
import CryptoKit

/// One existing Keychain item per origin/account. Version 1 decodes the former
/// refresh-only shape; version 2 keeps the device key and migration phase together.
struct CloudCredentials: Codable {
    enum Enrollment: String, Codable { case legacy, pending, enrolled, retired }
    var version = 2
    var origin: String
    var userID: String
    var email: String
    var deviceID: String
    var refreshToken: String?
    var privateKey: Data?
    var enrollment: Enrollment
    var legacyRefreshUncertain: Bool
    var partition: String { CloudSyncStore.partition(origin: origin, userID: userID) }

    init(origin: String, userID: String, email: String, deviceID: String, refreshToken: String? = nil,
         privateKey: Data? = nil, enrollment: Enrollment = .legacy, legacyRefreshUncertain: Bool = false) {
        self.origin = origin; self.userID = userID; self.email = email; self.deviceID = deviceID
        self.refreshToken = refreshToken; self.privateKey = privateKey; self.enrollment = enrollment
        self.legacyRefreshUncertain = legacyRefreshUncertain
    }
    enum CodingKeys: String, CodingKey {
        case version, origin, userID, email, deviceID, refreshToken, privateKey, enrollment, legacyRefreshUncertain
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard [1, 2].contains(version) else { throw CloudSyncError.updateRequired }
        origin = try box.decode(String.self, forKey: .origin)
        userID = try box.decode(String.self, forKey: .userID)
        email = try box.decode(String.self, forKey: .email)
        deviceID = try box.decode(String.self, forKey: .deviceID)
        refreshToken = try box.decodeIfPresent(String.self, forKey: .refreshToken)
        privateKey = try box.decodeIfPresent(Data.self, forKey: .privateKey)
        enrollment = try box.decodeIfPresent(Enrollment.self, forKey: .enrollment) ?? .legacy
        legacyRefreshUncertain = try box.decodeIfPresent(Bool.self, forKey: .legacyRefreshUncertain) ?? false
    }
    func validated() throws {
        guard [1, 2].contains(version), CloudWire.validID(userID), CloudWire.validID(deviceID), deviceID.count == 26,
              !email.isEmpty, email.utf8.count <= 320 else { throw CloudSyncError.invalidResponse }
        switch enrollment {
        case .legacy:
            guard privateKey == nil, refreshToken?.isEmpty == false else { throw CloudSyncError.invalidResponse }
        case .pending:
            guard refreshToken?.isEmpty == false else { throw CloudSyncError.invalidResponse }
            _ = try signingKey()
        case .enrolled: _ = try signingKey()
        case .retired: throw CloudSyncError.signInRequired
        }
    }
    func signingKey() throws -> P256.Signing.PrivateKey {
        guard let privateKey, privateKey.count == 32 else { throw CloudSyncError.invalidResponse }
        return try P256.Signing.PrivateKey(rawRepresentation: privateKey)
    }
    func retired() -> Self {
        var next = self; next.version = 2; next.privateKey = nil; next.refreshToken = nil
        next.enrollment = .retired; next.legacyRefreshUncertain = false
        return next
    }
}

struct CloudPendingLogin: Codable {
    let version: Int
    let origin: String
    let state: String
    let email: String
    let privateKey: Data
    var dispatched: Bool
}
protocol CloudCredentialVault {
    func load(partition: String) throws -> CloudCredentials?
    func save(_ value: CloudCredentials) throws
    func remove(partition: String) throws
    func loadPending(origin: String) throws -> CloudPendingLogin?
    func savePending(_ value: CloudPendingLogin) throws
    func removePending(origin: String) throws
}
/// Injectable item boundary: tests use an in-memory implementation, never the
/// daily Keychain. The production implementation retains atomic SecItemUpdate.
protocol CloudKeychainItems {
    func read(account: String) throws -> Data?
    func write(account: String, bytes: Data) throws
    func remove(account: String) throws
}
private final class SystemCloudKeychainItems: CloudKeychainItems {
    let service: String
    init(service: String) { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> Data? {
        var input = query(account); input[kSecReturnData as String] = true; input[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(input as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let bytes = item as? Data else { throw CloudSyncError.storage("keychain read") }
        return bytes
    }
    func write(account: String, bytes: Data) throws {
        let result = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw CloudSyncError.storage("keychain update") }
        var input = query(account); input[kSecValueData as String] = bytes
        input[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(input as CFDictionary, nil) == errSecSuccess else { throw CloudSyncError.storage("keychain add") }
    }
    func remove(account: String) throws {
        let result = SecItemDelete(query(account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CloudSyncError.storage("keychain remove") }
    }
}
final class CloudKeychainVault: CloudCredentialVault {
    private let items: CloudKeychainItems
    init(namespace: String = "com.voiceflow.cloud-sync", items: CloudKeychainItems? = nil) {
        self.items = items ?? SystemCloudKeychainItems(service: namespace)
    }
    func load(partition: String) throws -> CloudCredentials? {
        guard let bytes = try items.read(account: partition) else { return nil }
        let value = try JSONDecoder().decode(CloudCredentials.self, from: bytes)
        guard value.partition == partition else { throw CloudSyncError.invalidResponse }
        return value
    }
    func save(_ value: CloudCredentials) throws { try items.write(account: value.partition, bytes: JSONEncoder().encode(value)) }
    func remove(partition: String) throws { try items.remove(account: partition) }
    private func pendingAccount(_ origin: String) -> String {
        "pending-login:" + SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func loadPending(origin: String) throws -> CloudPendingLogin? {
        guard let bytes = try items.read(account: pendingAccount(origin)) else { return nil }
        let value = try JSONDecoder().decode(CloudPendingLogin.self, from: bytes)
        guard value.version == 1, value.origin == origin, value.privateKey.count == 32 else { throw CloudSyncError.invalidResponse }
        return value
    }
    func savePending(_ value: CloudPendingLogin) throws { try items.write(account: pendingAccount(value.origin), bytes: JSONEncoder().encode(value)) }
    func removePending(origin: String) throws { try items.remove(account: pendingAccount(origin)) }
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
    var accessToken: String; var accessExpiresIn: Int; var refreshToken: String?
    var user: User; var deviceId: String?
}
private struct CloudHTTPFailure: Error { let status: Int; let code: String }

/// Native-only values. Neither private key nor refresh material is returned.
struct CloudIdentityDescriptor: Equatable {
    let origin: String; let ownerID: String; let deviceID: String; let generation: UUID
}
struct CloudRuntimeBinding: Equatable {
    let identity: CloudIdentityDescriptor
    let servingHomeID: String
    let environmentID: String
    let environmentGeneration: UUID
}
struct CloudRuntimeCredentialLease {
    let binding: CloudRuntimeBinding
    let accessToken: String
    let expiresAt: Date
}
struct CloudHomeOffer: Decodable {
    struct Serving: Decodable { let homeId: String; let label: String }
    struct Continuable: Decodable {
        let homeId: String; let label: String; let deviceRevoked: Bool
        let deviceLastSeenAt: String?; let projectCount: Int; let threadCount: Int
    }
    struct NotOffered: Decodable { let homeId: String; let label: String; let deviceLastSeenAt: String }
    let serving: Serving?
    let continuable: [Continuable]
    let notOffered: [NotOffered]
}
private struct CloudMutationRequest: Encodable { let protocolVersion = 1; var operations: [CloudOperation] }
private struct CloudMutationResponse: Decodable { var results: [CloudReceipt] }
private struct CloudRecordResponse: Decodable { var record: CloudRecord }
private struct CloudStatusResponse: Decodable { var protocolVersion: Int; var supportsBlobs: Bool }
private struct CloudEmptyResponse: Decodable { }
private struct CloudErrorResponse: Decodable { struct Detail: Decodable { var code: String }; var error: Detail }

/// Sync and native runtime share THIS actor. A runtime broker must obtain the
/// controller's owner, never instantiate a second client from Keychain bytes.
actor CloudHTTPClient {
    let origin: String
    private let session: URLSession
    private let vault: CloudCredentialVault
    private let onInvalidation: (@Sendable () -> Void)?
    private var credentials: CloudCredentials?
    private var access: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?
    private var stopped = false
    private var generation = UUID()
    private var loginInFlight = false
    private var completedLoginState: String?
    private var observedHome: String?
    private var hasObservedHome = false

    init(origin: String, credentials: CloudCredentials? = nil, vault: CloudCredentialVault, allowLoopback: Bool = false, onInvalidation: (@Sendable () -> Void)? = nil) throws {
        self.origin = try CloudWire.origin(origin, allowLoopback: allowLoopback)
        if let credentials {
            guard credentials.origin == self.origin else { throw CloudSyncError.invalidResponse }
            try credentials.validated()
        }
        self.credentials = credentials; self.vault = vault; self.onInvalidation = onInvalidation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: CloudNoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func start(email: String) async throws -> CloudLoginChallenge.Challenge {
        guard !stopped, credentials == nil, !loginInFlight else { throw CloudSyncError.signInRequired }
        loginInFlight = true; defer { loginInFlight = false }
        let expected = generation
        struct Body: Encodable { let email: String }
        do {
            let response: CloudLoginChallenge = try await send("/api/v1/auth/native/login/start", body: Body(email: email))
            try requireCurrent(expected)
            guard !response.challenge.state.isEmpty, response.challenge.state.utf8.count <= 64,
                  !response.challenge.email.isEmpty, response.challenge.email.utf8.count <= 320,
                  CloudWire.date(response.challenge.expiresAt) != nil else { throw CloudSyncError.invalidResponse }
            // This is an explicit new sign-in, never an automatic resend of an
            // ambiguous completion. Retire only this origin's pending key.
            try vault.removePending(origin: origin)
            return response.challenge
        } catch { throw publicError(error) }
    }
    func complete(challenge: CloudLoginChallenge.Challenge, code: String, label: String) async throws -> CloudCredentials {
        guard !stopped, !loginInFlight else { throw CloudSyncError.signInRequired }
        guard !challenge.state.isEmpty, challenge.state.utf8.count <= 64,
              !challenge.email.isEmpty, challenge.email.utf8.count <= 320,
              !code.isEmpty, code.utf8.count <= 32, !label.isEmpty else { throw CloudSyncError.invalidRecord }
        if completedLoginState == challenge.state, let credentials { return credentials }
        guard credentials == nil else { throw CloudSyncError.identityChanged }
        loginInFlight = true; defer { loginInFlight = false }
        let expected = generation
        struct Device: Encodable { let kind = "desktop"; let label: String; let publicKey: String; let keyProof: String }
        struct Body: Encodable { let state: String; let email: String; let code: String; let device: Device }
        var pending = try vault.loadPending(origin: origin) ?? CloudPendingLogin(version: 1, origin: origin,
            state: challenge.state, email: challenge.email, privateKey: P256.Signing.PrivateKey().rawRepresentation, dispatched: false)
        guard pending.state == challenge.state, pending.email == challenge.email, !pending.dispatched else { throw CloudSyncError.loginUncertain }
        let key = try P256.Signing.PrivateKey(rawRepresentation: pending.privateKey)
        let publicKey = key.publicKey.derRepresentation.base64EncodedString()
        let proof = try key.signature(for: Data("\(challenge.state)|\(challenge.email)|\(publicKey)".utf8)).rawRepresentation.base64EncodedString()
        pending.dispatched = true
        try vault.savePending(pending) // key + uncertain outcome are durable before POST
        let requestedAt = Date()
        do {
            let response: CloudAuthResponse = try await send("/api/v1/auth/native/login/complete", body: Body(state: challenge.state,
                email: challenge.email, code: code, device: Device(label: String(label.prefix(100)), publicKey: publicKey, keyProof: proof)))
            try requireCurrent(expected)
            try validateResponse(response)
            guard let deviceID = response.deviceId, CloudWire.validID(deviceID), deviceID.count == 26,
                  response.refreshToken == nil, response.user.email.lowercased() == challenge.email.lowercased() else { throw CloudSyncError.invalidResponse }
            let next = CloudCredentials(origin: origin, userID: response.user.id, email: response.user.email,
                deviceID: deviceID, privateKey: pending.privateKey, enrollment: .enrolled)
            try vault.save(next)
            credentials = next; setAccess(response, requestedAt: requestedAt); completedLoginState = challenge.state
            try? vault.removePending(origin: origin)
            return next
        } catch {
            guard !stopped, generation == expected else { throw CancellationError() }
            if let refusal = error as? CloudHTTPFailure, ["auth.code_invalid", "auth.code_expired", "validation.invalid_input", "update_required", "unsupported"].contains(refusal.code) {
                pending.dispatched = false; try vault.savePending(pending)
                throw publicError(error)
            }
            // A connection loss, malformed success or failed persistence can
            // follow server enrollment. No automatic or same-code retry.
            if let refusal = error as? CloudHTTPFailure, refusal.status < 500 { throw publicError(error) }
            throw CloudSyncError.loginUncertain
        }
    }
    func cancelLogin() throws {
        guard credentials == nil, !loginInFlight else { throw CloudSyncError.identityChanged }
        retire(); try vault.removePending(origin: origin)
    }
    /// Stop this actor without erasing offline account data or another identity.
    func retire() {
        guard !stopped else { return }
        stopped = true; generation = UUID(); access = nil; refreshing?.cancel(); refreshing = nil
        observedHome = nil; hasObservedHome = false
        onInvalidation?()
    }
    func identity() async throws -> CloudIdentityDescriptor {
        _ = try await accessToken()
        return try descriptor()
    }
    private func descriptor() throws -> CloudIdentityDescriptor {
        guard !stopped, let credentials, credentials.enrollment == .enrolled else { throw CloudSyncError.signInRequired }
        return .init(origin: origin, ownerID: credentials.userID, deviceID: credentials.deviceID, generation: generation)
    }
    func homes() async throws -> CloudHomeOffer {
        let offer: CloudHomeOffer = try await authorized("/api/v1/me/homes/continuable")
        guard offer.serving.map({ CloudWire.validID($0.homeId) }) != false,
              offer.continuable.allSatisfy({ CloudWire.validID($0.homeId) && $0.projectCount >= 0 && $0.threadCount >= 0 }),
              offer.notOffered.allSatisfy({ CloudWire.validID($0.homeId) }) else { throw CloudSyncError.invalidResponse }
        if hasObservedHome, observedHome != offer.serving?.homeId {
            generation = UUID(); onInvalidation?()
        }
        observedHome = offer.serving?.homeId; hasObservedHome = true
        return offer
    }
    func runtimeCredentials(for binding: CloudRuntimeBinding) async throws -> CloudRuntimeCredentialLease {
        guard CloudWire.validID(binding.environmentID), CloudWire.validID(binding.servingHomeID),
              try descriptor() == binding.identity else { throw CloudSyncError.identityChanged }
        let offer = try await homes() // current server ownership, never a saved/configured home
        guard try descriptor() == binding.identity else { throw CloudSyncError.identityChanged }
        guard let serving = offer.serving else { throw CloudSyncError.homeSelectionRequired }
        guard serving.homeId == binding.servingHomeID else { throw CloudSyncError.identityChanged }
        guard let access, access.expires > Date() else { throw CloudSyncError.signInRequired }
        return .init(binding: binding, accessToken: access.token, expiresAt: access.expires)
    }
    func isCurrent(_ lease: CloudRuntimeCredentialLease, for binding: CloudRuntimeBinding) -> Bool {
        !stopped && lease.binding == binding && (try? descriptor()) == binding.identity
            && observedHome == binding.servingHomeID && lease.expiresAt > Date()
    }

    func capabilities() async throws {
        let status: CloudStatusResponse = try await authorized("/api/v1/sync")
        guard status.protocolVersion == 1 else { throw CloudSyncError.updateRequired }
    }
    func pull(cursor: String?) async throws -> CloudPage {
        var parts = URLComponents(); parts.queryItems = cursor.map { [URLQueryItem(name: "cursor", value: $0)] }
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
        let prior = credentials, bearer = access.flatMap { $0.expires > Date() ? $0.token : nil }
        retire()
        guard let prior else { try vault.removePending(origin: origin); return }
        // Destruction is durable before network work. A failed subsequent delete
        // leaves a keyless retired row, never a restartable signed-in identity.
        try vault.save(prior.retired())
        credentials = nil
        try? vault.remove(partition: prior.partition)
        if prior.enrollment == .enrolled {
            let token: String?
            if let bearer { token = bearer }
            else if let result = try? await proofToken(prior),
                    (try? validateResponse(result.response)) != nil, result.response.user.id == prior.userID,
                    result.response.deviceId == nil, result.response.refreshToken == nil { token = result.response.accessToken }
            else { token = nil }
            if let token {
                let _: CloudEmptyResponse? = try? await send("/api/v1/me/devices/\(prior.deviceID)", body: Optional<String>.none, bearer: token, method: "DELETE")
            }
        } else if let refreshToken = prior.refreshToken {
            struct Body: Encodable { let refreshToken: String }
            let _: CloudEmptyResponse? = try? await send("/api/v1/auth/native/logout", body: Body(refreshToken: refreshToken), bearer: bearer)
        }
    }

    private func validateResponse(_ response: CloudAuthResponse) throws {
        guard CloudWire.validID(response.user.id), !response.user.email.isEmpty, response.user.email.utf8.count <= 320,
              !response.accessToken.isEmpty, response.accessToken.utf8.count <= 32_768,
              (1...86_400).contains(response.accessExpiresIn) else { throw CloudSyncError.invalidResponse }
    }
    private func setAccess(_ response: CloudAuthResponse, requestedAt: Date) {
        // Conservatively start lifetime before the HTTP request, never after a
        // delayed response. Broker consumers must also reject expired leases.
        access = (response.accessToken, requestedAt.addingTimeInterval(Double(response.accessExpiresIn)))
    }
    private func requireCurrent(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard !stopped, generation == expected else { throw CancellationError() }
    }
    private func invalidateIdentity() throws {
        let prior = credentials; retire(); credentials = nil
        if let prior { try vault.save(prior.retired()); try? vault.remove(partition: prior.partition) }
    }
    private func accessToken(rejectedToken: String? = nil) async throws -> String {
        guard !stopped else { throw CloudSyncError.signInRequired }
        if let refreshing { return try await refreshing.value }
        if let access, access.expires.timeIntervalSinceNow > 30,
           rejectedToken == nil || access.token != rejectedToken { return access.token }
        guard credentials != nil else { throw CloudSyncError.signInRequired }
        let expected = generation
        let task = Task<String, Error> { try await renew(expected: expected) }
        refreshing = task
        defer { refreshing = nil }
        do { return try await task.value }
        catch { throw publicError(error) }
    }
    private func renew(expected: UUID) async throws -> String {
        do {
            guard var next = credentials else { throw CloudSyncError.signInRequired }
            if next.enrollment != .enrolled {
                if next.privateKey == nil {
                    next.version = 2; next.privateKey = P256.Signing.PrivateKey().rawRepresentation; next.enrollment = .pending
                    try vault.save(next); credentials = next // survives lost enrollment reply/restart
                }
                let bearer: String
                if let access, access.expires.timeIntervalSinceNow > 30 { bearer = access.token }
                else {
                    guard let refreshToken = next.refreshToken, !next.legacyRefreshUncertain else { throw CloudSyncError.loginUncertain }
                    struct Body: Encodable { let deviceId: String; let refreshToken: String }
                    next.legacyRefreshUncertain = true
                    try vault.save(next); credentials = next
                    let requestedAt = Date()
                    let response: CloudAuthResponse = try await send("/api/v1/auth/native/refresh", body: Body(deviceId: next.deviceID, refreshToken: refreshToken))
                    try requireCurrent(expected); try validateResponse(response)
                    guard response.user.id == next.userID, response.deviceId == next.deviceID,
                          let successor = response.refreshToken, !successor.isEmpty else { throw CloudSyncError.identityChanged }
                    next.refreshToken = successor; next.legacyRefreshUncertain = false
                    try vault.save(next); credentials = next; setAccess(response, requestedAt: requestedAt); bearer = response.accessToken
                }
                let key = try next.signingKey(), publicKey = key.publicKey.derRepresentation.base64EncodedString()
                struct Body: Encodable { let publicKey: String; let keyProof: String }
                struct Answer: Decodable { let deviceId: String; let keyEnrolledAt: String }
                let answer: Answer = try await send("/api/v1/auth/device/key", body: Body(publicKey: publicKey,
                    keyProof: key.signature(for: Data("\(next.deviceID)|\(publicKey)".utf8)).rawRepresentation.base64EncodedString()), bearer: bearer)
                try requireCurrent(expected)
                guard answer.deviceId == next.deviceID, CloudWire.date(answer.keyEnrolledAt) != nil else { throw CloudSyncError.identityChanged }
                next.enrollment = .enrolled
                try vault.save(next); credentials = next // before proof can revoke old refresh tokens
            }
            let result = try await proofToken(next), response = result.response
            try requireCurrent(expected); try validateResponse(response)
            guard response.user.id == next.userID, response.deviceId == nil, response.refreshToken == nil else { throw CloudSyncError.identityChanged }
            next.email = response.user.email; next.refreshToken = nil; next.legacyRefreshUncertain = false
            try vault.save(next); credentials = next; setAccess(response, requestedAt: result.requestedAt)
            return response.accessToken
        } catch {
            guard !stopped, generation == expected else { throw CancellationError() }
            if isTerminalIdentity(error) { try invalidateIdentity(); throw CloudSyncError.signInRequired }
            throw error
        }
    }
    private func proofToken(_ identity: CloudCredentials) async throws -> (response: CloudAuthResponse, requestedAt: Date) {
        struct ChallengeBody: Encodable { let deviceId: String }
        struct Challenge: Decodable { let nonce: String; let sentAt: String; let expiresInSec: Int }
        struct TokenBody: Encodable { let deviceId: String; let nonce: String; let signature: String }
        let key = try identity.signingKey()
        for attempt in 0...1 {
            let challenge: Challenge = try await send("/api/v1/auth/device/challenge", body: ChallengeBody(deviceId: identity.deviceID))
            guard !challenge.nonce.isEmpty, challenge.nonce.utf8.count <= 64, challenge.expiresInSec == 60,
                  CloudWire.date(challenge.sentAt) != nil else { throw CloudSyncError.invalidResponse }
            let signature = try key.signature(for: Data("\(challenge.nonce)|\(identity.deviceID)|\(challenge.sentAt)".utf8)).rawRepresentation.base64EncodedString()
            do {
                let requestedAt = Date()
                let response: CloudAuthResponse = try await send("/api/v1/auth/device/token", body: TokenBody(deviceId: identity.deviceID, nonce: challenge.nonce, signature: signature))
                return (response, requestedAt)
            } catch let failure as CloudHTTPFailure where failure.code == "auth.device_challenge_expired" && attempt == 0 {
                // Only this explicit retryable refusal permits a new challenge.
                continue
            }
        }
        throw CloudSyncError.invalidResponse
    }
    private func authorized<Response: Decodable>(_ path: String) async throws -> Response {
        try await authorized(path, body: Optional<String>.none)
    }
    private func authorized<Body: Encodable, Response: Decodable>(_ path: String, body: Body?) async throws -> Response {
        let expected = generation
        let token = try await accessToken()
        try requireCurrent(expected)
        do {
            let answer: Response
            do { answer = try await send(path, body: body, bearer: token) }
            catch let failure as CloudHTTPFailure where failure.status == 401 && !isTerminalIdentity(failure) {
                let next = try await accessToken(rejectedToken: token)
                try requireCurrent(expected)
                answer = try await send(path, body: body, bearer: next)
            }
            try requireCurrent(expected)
            return answer
        } catch {
            guard !stopped, generation == expected else { throw CancellationError() }
            if isTerminalIdentity(error) || (error as? CloudHTTPFailure)?.status == 401 {
                try invalidateIdentity(); throw CloudSyncError.signInRequired
            }
            throw publicError(error)
        }
    }
    private func isTerminalIdentity(_ error: Error) -> Bool {
        if case CloudSyncError.identityChanged = error { return true }
        guard let refusal = error as? CloudHTTPFailure else { return false }
        return ["auth.device_proof_invalid", "auth.device_revoked", "auth.user_disabled", "auth.token_invalid", "auth.device_mismatch"].contains(refusal.code)
    }
    private func publicError(_ error: Error) -> Error {
        guard let failure = error as? CloudHTTPFailure else { return error }
        if failure.code == "update_required" { return CloudSyncError.updateRequired }
        if failure.code == "sync.cursor_expired" { return CloudSyncError.historyChanged }
        return CloudSyncError.server(failure.status, failure.code)
    }
    private func send<Body: Encodable, Response: Decodable>(_ path: String, body: Body?, bearer: String? = nil, method: String? = nil) async throws -> Response {
        try Task.checkCancellation()
        guard path.hasPrefix("/api/v1/"), let url = URL(string: origin + path) else { throw CloudSyncError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, bytes.count <= 2 * 1024 * 1024 else { throw CloudSyncError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONDecoder().decode(CloudErrorResponse.self, from: bytes))?.error.code ?? ""
            throw CloudHTTPFailure(status: response.statusCode, code: code)
        }
        do { return try JSONDecoder().decode(Response.self, from: bytes) }
        catch { throw CloudSyncError.invalidResponse }
    }
}
