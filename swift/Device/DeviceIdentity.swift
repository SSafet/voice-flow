import Foundation
import GRDB

// C19, the device identity. The gateway calls live behind `DeviceGateway`; the
// app's client is `HTTPDeviceGateway` and the tests' is a fake. The identity
// actor holds the endpoint state, the access token in memory and the one small
// non-secret row in K8's `threads.sqlite`. The private key never enters the
// database and the access token is never persisted (05 §3.2).

enum DeviceSignOutReason: String, Equatable { case none, revoked }

enum DeviceIdentityState: Equatable {
    case signedOut(DeviceSignOutReason)
    case ready
    case unreachable
}

enum DeviceIdentityError: Error, Equatable {
    case notSignedIn
    case unreachable
    case invalidResponse
    case unauthorized
    case insecureOrigin
    case server(code: String, message: String)
    case storage(String)
}

struct SignInChallenge: Equatable { let state: String; let email: String; let expiresAt: String }

struct ContinuableHome: Equatable {
    let homeId: String
    let label: String
    let deviceLastSeenAt: String?
    let projectCount: Int
    let threadCount: Int
}

struct DeviceSignInResult: Equatable {
    let deviceId: String
    let userId: String
    let email: String
    let label: String
    let accessToken: String
    let accessExpiresIn: Int
    let continuableHomes: [ContinuableHome]
}

struct HomeTakeover: Equatable { let homeId: String }
struct DeviceChallenge: Equatable { let nonce: String; let sentAt: String; let expiresInSec: Int }
struct DeviceToken: Equatable { let accessToken: String; let accessExpiresIn: Int; let userId: String; let email: String }

enum DeviceIdentityRoutes {
    static let signInStart = "/api/v1/auth/native/login/start"
    static let signInComplete = "/api/v1/auth/native/login/complete"
    static let enrollKey = "/api/v1/auth/device/key"
    static let challenge = "/api/v1/auth/device/challenge"
    static let token = "/api/v1/auth/device/token"
    static func device(_ id: String) -> String { "/api/v1/me/devices/\(id)" }
    static func takeoverStart(_ homeId: String) -> String { "/api/v1/me/homes/\(homeId)/takeover/start" }
    static func takeoverConfirm(_ homeId: String) -> String { "/api/v1/me/homes/\(homeId)/takeover/confirm" }
}

protocol DeviceGateway {
    func startSignIn(email: String) async throws -> SignInChallenge
    func completeSignIn(state: String, email: String, code: String, label: String,
                        publicKeyBase64: String, keyProofBase64: String) async throws -> DeviceSignInResult
    func enrollKey(deviceId: String, publicKeyBase64: String, keyProofBase64: String, accessToken: String) async throws
    func challenge(deviceId: String) async throws -> DeviceChallenge
    func token(deviceId: String, nonce: String, signatureBase64: String) async throws -> DeviceToken
    func revokeDevice(deviceId: String, accessToken: String) async throws
    func startTakeover(homeId: String, accessToken: String) async throws
    func confirmTakeover(homeId: String, code: String, accessToken: String) async throws -> HomeTakeover
}

protocol LegacyRefreshTokenStore { func removeRefreshMaterial() throws }

/// The app's HTTP client for the gateway half of L1. It speaks only `https`,
/// sends exactly the routes and fields of 05 §3.2, never sends a refresh token,
/// and takes its `URLSession` so the suite can hold it to the wire through a
/// `URLProtocol` stub with no port bound and nothing timed.
final class HTTPDeviceGateway: DeviceGateway {
    private let origin: String
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let noRedirects = NoRedirects()

    init(origin: String, session: URLSession = .shared) throws {
        guard let url = URL(string: origin), url.scheme == "https" else {
            throw DeviceIdentityError.insecureOrigin
        }
        var normalized = origin
        while normalized.hasSuffix("/") { normalized.removeLast() }
        self.origin = normalized
        self.session = session
    }

    func startSignIn(email: String) async throws -> SignInChallenge {
        let answer: StartSignInAnswer = try await perform(
            method: "POST", path: DeviceIdentityRoutes.signInStart, body: ["email": email],
            as: StartSignInAnswer.self)
        return SignInChallenge(state: answer.challenge.state, email: answer.challenge.email,
                               expiresAt: answer.challenge.expiresAt)
    }

    func completeSignIn(state: String, email: String, code: String, label: String,
                        publicKeyBase64: String, keyProofBase64: String) async throws -> DeviceSignInResult {
        let body: [String: Any] = [
            "state": state,
            "email": email,
            "code": code,
            "device": [
                "kind": "desktop",
                "label": label,
                "publicKey": publicKeyBase64,
                "keyProof": keyProofBase64,
            ],
        ]
        let answer: CompleteSignInAnswer = try await perform(
            method: "POST", path: DeviceIdentityRoutes.signInComplete, body: body,
            as: CompleteSignInAnswer.self)
        let homes = (answer.continuableHomes ?? []).map {
            ContinuableHome(homeId: $0.homeId, label: $0.label, deviceLastSeenAt: $0.deviceLastSeenAt,
                            projectCount: $0.projectCount, threadCount: $0.threadCount)
        }
        return DeviceSignInResult(deviceId: answer.deviceId, userId: answer.user.id, email: answer.user.email,
                                  label: label, accessToken: answer.accessToken,
                                  accessExpiresIn: answer.accessExpiresIn, continuableHomes: homes)
    }

    func enrollKey(deviceId: String, publicKeyBase64: String, keyProofBase64: String,
                   accessToken: String) async throws {
        let body: [String: Any] = ["publicKey": publicKeyBase64, "keyProof": keyProofBase64]
        let _: EmptyAnswer = try await perform(
            method: "POST", path: DeviceIdentityRoutes.enrollKey, body: body, bearer: accessToken,
            as: EmptyAnswer.self)
    }

    func challenge(deviceId: String) async throws -> DeviceChallenge {
        let answer: ChallengeAnswer = try await perform(
            method: "POST", path: DeviceIdentityRoutes.challenge, body: ["deviceId": deviceId],
            as: ChallengeAnswer.self)
        return DeviceChallenge(nonce: answer.nonce, sentAt: answer.sentAt, expiresInSec: answer.expiresInSec)
    }

    func token(deviceId: String, nonce: String, signatureBase64: String) async throws -> DeviceToken {
        let body: [String: Any] = ["deviceId": deviceId, "nonce": nonce, "signature": signatureBase64]
        let answer: TokenAnswer = try await perform(
            method: "POST", path: DeviceIdentityRoutes.token, body: body, as: TokenAnswer.self)
        return DeviceToken(accessToken: answer.accessToken, accessExpiresIn: answer.accessExpiresIn,
                           userId: answer.user.id, email: answer.user.email)
    }

    func revokeDevice(deviceId: String, accessToken: String) async throws {
        let _: EmptyAnswer = try await perform(
            method: "DELETE", path: DeviceIdentityRoutes.device(deviceId), bearer: accessToken,
            as: EmptyAnswer.self)
    }

    func startTakeover(homeId: String, accessToken: String) async throws {
        let _: EmptyAnswer = try await perform(
            method: "POST", path: DeviceIdentityRoutes.takeoverStart(homeId), bearer: accessToken,
            as: EmptyAnswer.self)
    }

    func confirmTakeover(homeId: String, code: String, accessToken: String) async throws -> HomeTakeover {
        let answer: TakeoverAnswer = try await perform(
            method: "POST", path: DeviceIdentityRoutes.takeoverConfirm(homeId), body: ["code": code],
            bearer: accessToken, as: TakeoverAnswer.self)
        return HomeTakeover(homeId: answer.homeId)
    }

    private func perform<T: Decodable>(method: String, path: String, body: [String: Any]? = nil,
                                       bearer: String? = nil, as type: T.Type) async throws -> T {
        guard let url = URL(string: origin + path) else { throw DeviceIdentityError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                throw DeviceIdentityError.invalidResponse
            }
            request.httpBody = data
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: noRedirects)
        } catch {
            throw DeviceIdentityError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw DeviceIdentityError.invalidResponse }
        if http.statusCode == 401 { throw DeviceIdentityError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw DeviceIdentityError.server(code: envelope.error.code, message: envelope.error.message)
            }
            throw DeviceIdentityError.invalidResponse
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DeviceIdentityError.invalidResponse
        }
    }
}

/// A redirect is not an answer: the gateway's routes are final, so the client
/// refuses to follow one.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct ErrorEnvelope: Decodable {
    struct Payload: Decodable { let code: String; let message: String }
    let error: Payload
}

private struct StartSignInAnswer: Decodable {
    struct Challenge: Decodable { let state: String; let email: String; let expiresAt: String }
    let challenge: Challenge
}

private struct CompleteSignInAnswer: Decodable {
    struct User: Decodable { let id: String; let email: String }
    struct Home: Decodable {
        let homeId: String
        let label: String
        let deviceLastSeenAt: String?
        let projectCount: Int
        let threadCount: Int
    }
    let deviceId: String
    let accessToken: String
    let accessExpiresIn: Int
    let user: User
    let continuableHomes: [Home]?
}

private struct ChallengeAnswer: Decodable { let nonce: String; let sentAt: String; let expiresInSec: Int }

private struct TokenAnswer: Decodable {
    struct User: Decodable { let id: String; let email: String }
    let accessToken: String
    let accessExpiresIn: Int
    let user: User
}

private struct TakeoverAnswer: Decodable { let homeId: String }

private struct EmptyAnswer: Decodable {}

actor DeviceIdentity {
    private struct IdentityRow: Equatable {
        var origin: String
        var userId: String
        var email: String
        var deviceId: String
        var label: String
        var homeId: String?
        var signedInAt: String
        var refreshMaterialRemoved: Bool
    }

    private let origin: String
    private let gateway: DeviceGateway
    private let keyProvider: DeviceKeyProvider
    private let database: DatabasePool
    private let legacyRefreshTokenStore: LegacyRefreshTokenStore?

    private var row: IdentityRow?
    private var currentState: DeviceIdentityState = .signedOut(.none)
    private var cachedToken: String?
    private var cachedTokenExpiry: Date?
    private var cachedHomes: [ContinuableHome] = []

    init(origin: String, gateway: DeviceGateway, keyProvider: DeviceKeyProvider,
         database: DatabasePool, legacyRefreshTokenStore: LegacyRefreshTokenStore?) {
        self.origin = origin
        self.gateway = gateway
        self.keyProvider = keyProvider
        self.database = database
        self.legacyRefreshTokenStore = legacyRefreshTokenStore
    }

    func load() throws {
        let stored = try withStorage { try readRow() }
        row = stored
        cachedToken = nil
        cachedTokenExpiry = nil
        cachedHomes = []
        currentState = stored == nil ? .signedOut(.none) : .ready
    }

    var state: DeviceIdentityState { currentState }
    var deviceId: String? { row?.deviceId }
    var homeId: String? { row?.homeId }
    var continuableHomes: [ContinuableHome] { cachedHomes }

    func startSignIn(email: String) async throws -> SignInChallenge {
        try await gatewayCall { try await gateway.startSignIn(email: email) }
    }

    func completeSignIn(challenge: SignInChallenge, code: String, label: String) async throws -> DeviceSignInResult {
        let key = try keyProvider.loadOrCreateKey()
        let publicKeyBase64 = DeviceKeyStore.publicKeyBase64(key)
        let keyProofBase64 = try DeviceKeyStore.signatureBase64(
            key, over: DeviceKeyStore.keyProofText(state: challenge.state, email: challenge.email,
                                                   publicKeyBase64: publicKeyBase64))
        let result = try await gatewayCall {
            try await gateway.completeSignIn(state: challenge.state, email: challenge.email, code: code,
                                             label: label, publicKeyBase64: publicKeyBase64,
                                             keyProofBase64: keyProofBase64)
        }
        guard !result.deviceId.isEmpty, !result.accessToken.isEmpty else {
            throw DeviceIdentityError.invalidResponse
        }
        let stored = IdentityRow(origin: origin, userId: result.userId, email: result.email,
                                 deviceId: result.deviceId, label: label, homeId: nil,
                                 signedInAt: Self.isoNow(), refreshMaterialRemoved: false)
        try withStorage { try writeRow(stored) }
        row = stored
        cachedToken = nil
        cachedTokenExpiry = nil
        cachedHomes = result.continuableHomes
        currentState = .ready
        return result
    }

    func accessToken(force: Bool = false) async throws -> String {
        if !force, let token = cachedToken, let expiry = cachedTokenExpiry, expiry.timeIntervalSinceNow > 30 {
            return token
        }
        guard let stored = row else { throw DeviceIdentityError.notSignedIn }

        let asked: DeviceChallenge
        do {
            asked = try await gateway.challenge(deviceId: stored.deviceId)
        } catch let error as DeviceIdentityError {
            if error == .unreachable {
                currentState = .unreachable
                throw error
            }
            if error == .unauthorized {
                try wipe(for: .revoked)
                throw DeviceIdentityError.notSignedIn
            }
            throw error
        }

        let key = try keyProvider.loadOrCreateKey()
        let signatureBase64 = try DeviceKeyStore.signatureBase64(
            key, over: DeviceKeyStore.deviceProofText(nonce: asked.nonce, deviceId: stored.deviceId,
                                                      sentAt: asked.sentAt))

        let minted: DeviceToken
        do {
            minted = try await gateway.token(deviceId: stored.deviceId, nonce: asked.nonce,
                                             signatureBase64: signatureBase64)
        } catch let error as DeviceIdentityError {
            if error == .unreachable {
                currentState = .unreachable
                throw error
            }
            if error == .unauthorized {
                try wipe(for: .revoked)
                throw DeviceIdentityError.notSignedIn
            }
            throw error
        }

        guard !minted.accessToken.isEmpty else { throw DeviceIdentityError.invalidResponse }
        cachedToken = minted.accessToken
        cachedTokenExpiry = Date().addingTimeInterval(TimeInterval(minted.accessExpiresIn))
        currentState = .ready
        retireLegacyRefreshMaterial()
        return minted.accessToken
    }

    func signOut() async throws {
        guard let stored = row else {
            currentState = .signedOut(.none)
            return
        }
        let token = try await accessToken()
        do {
            try await gateway.revokeDevice(deviceId: stored.deviceId, accessToken: token)
        } catch let error as DeviceIdentityError {
            if error == .unreachable {
                currentState = .unreachable
                throw error
            }
            if error != .unauthorized { throw error }
        }
        try wipe(for: .none)
    }

    func enrollKey(deviceId: String, accessToken: String) async throws {
        let key = try keyProvider.loadOrCreateKey()
        let publicKeyBase64 = DeviceKeyStore.publicKeyBase64(key)
        let keyProofBase64 = try DeviceKeyStore.signatureBase64(
            key, over: DeviceKeyStore.enrollmentProofText(deviceId: deviceId, publicKeyBase64: publicKeyBase64))
        try await gatewayCall {
            try await gateway.enrollKey(deviceId: deviceId, publicKeyBase64: publicKeyBase64,
                                        keyProofBase64: keyProofBase64, accessToken: accessToken)
        }
    }

    // MARK: - State changes

    /// A gateway that cannot be reached is named, and only a reachable gateway
    /// clears it. A named server refusal or a malformed answer leaves the last
    /// good state alone (rule 6).
    private func gatewayCall<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as DeviceIdentityError {
            if error == .unreachable { currentState = .unreachable }
            throw error
        }
    }

    private func wipe(for reason: DeviceSignOutReason) throws {
        try keyProvider.deleteKey()
        try withStorage { try deleteRow() }
        row = nil
        cachedToken = nil
        cachedTokenExpiry = nil
        cachedHomes = []
        currentState = .signedOut(reason)
    }

    /// The old refresh material is retired once, after the first token by signed
    /// challenge. A failure leaves the flag at 0 so the next mint tries again,
    /// and never blocks the token (rule 8).
    private func retireLegacyRefreshMaterial() {
        guard var stored = row, !stored.refreshMaterialRemoved, let store = legacyRefreshTokenStore else { return }
        do {
            try store.removeRefreshMaterial()
        } catch {
            return
        }
        stored.refreshMaterialRemoved = true
        try? withStorage { try markRefreshMaterialRemoved() }
        row = stored
    }

    // MARK: - The identity row

    private func readRow() throws -> IdentityRow? {
        try database.read { db in
            guard let record = try Row.fetchOne(db, sql: """
                SELECT origin, user_id, email, device_id, label, home_id, signed_in_at, refresh_material_removed
                FROM device_identity WHERE id = 1
                """) else { return nil }
            return IdentityRow(
                origin: record["origin"] as String,
                userId: record["user_id"] as String,
                email: record["email"] as String,
                deviceId: record["device_id"] as String,
                label: record["label"] as String,
                homeId: record["home_id"] as String?,
                signedInAt: record["signed_in_at"] as String,
                refreshMaterialRemoved: record["refresh_material_removed"] as Bool)
        }
    }

    private func writeRow(_ stored: IdentityRow) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO device_identity
                    (id, origin, user_id, email, device_id, label, home_id, signed_in_at, refresh_material_removed)
                VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [stored.origin, stored.userId, stored.email, stored.deviceId,
                                 stored.label, stored.homeId, stored.signedInAt,
                                 stored.refreshMaterialRemoved])
        }
    }

    private func deleteRow() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM device_identity WHERE id = 1")
        }
    }

    private func markRefreshMaterialRemoved() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE device_identity SET refresh_material_removed = 1 WHERE id = 1")
        }
    }

    private func withStorage<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DeviceIdentityError {
            throw error
        } catch {
            throw DeviceIdentityError.storage("\(error)")
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
