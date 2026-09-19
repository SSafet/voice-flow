import Foundation
import CryptoKit

/// The fake gateway. It speaks the same `DeviceGateway` protocol the app's HTTP
/// gateway speaks, and it does not trust the client: every signature the client
/// sends is checked with CryptoKit, every nonce is single use, and every refusal
/// is a named server error. What the tests assert is the device identity's
/// behaviour, never this class's own bookkeeping.
final class FakeGateway: DeviceGateway {
    struct CompleteSignInCall: Equatable {
        var state: String
        var email: String
        var code: String
        var label: String
        var publicKeyBase64: String
        var keyProofBase64: String
    }
    struct EnrollKeyCall: Equatable {
        var deviceId: String
        var publicKeyBase64: String
        var keyProofBase64: String
        var accessToken: String
    }
    struct ChallengeCall: Equatable { var deviceId: String; var nonce: String; var sentAt: String }
    struct TokenCall: Equatable { var deviceId: String; var nonce: String; var signatureBase64: String }
    struct DeviceCall: Equatable { var deviceId: String; var accessToken: String }
    struct TakeoverCodeCall: Equatable { var homeId: String; var accessToken: String }
    struct TakeoverConfirmCall: Equatable { var homeId: String; var code: String; var accessToken: String }

    // Behaviour the tests steer.
    var deviceIdValue = "device-000000000000000001"
    var userIdValue = "user-1"
    var deviceLabel = "Synthetic Mac"
    var accessTokenValue = "access-token-1"
    var accessExpiresIn = 3600
    /// Every challenge issues a nonce of its own, as the gateway does: a nonce
    /// is single use, so a second token can never be minted from the first one.
    var challengeNoncePrefix = "challenge-nonce"
    var challengeSentAt = "2026-09-19T10:00:00.000Z"
    var challengeExpiresInSec = 60
    var continuableHomes: [ContinuableHome] = []
    var completeSignInError: DeviceIdentityError?
    var challengeError: DeviceIdentityError?
    var tokenError: DeviceIdentityError?
    var unreachable = false
    var revoked = false
    var invalidTokenResponse = false
    var takeoverCodes: [String: String] = [:]

    // What the gateway observed.
    private(set) var startSignInEmails: [String] = []
    private(set) var completeSignInCalls: [CompleteSignInCall] = []
    private(set) var enrollKeyCalls: [EnrollKeyCall] = []
    private(set) var challengeCalls: [ChallengeCall] = []
    private(set) var tokenCalls: [TokenCall] = []
    private(set) var revokeCalls: [DeviceCall] = []
    private(set) var takeoverStarts: [TakeoverCodeCall] = []
    private(set) var takeoverConfirms: [TakeoverConfirmCall] = []
    private(set) var enrolledPublicKey: String?
    private var nonceCount = 0
    private var issuedNonces: [String: String] = [:]   // nonce -> the sentAt it was issued with
    private var usedNonces: Set<String> = []

    private func offlineOrRevoked() throws {
        if unreachable { throw DeviceIdentityError.unreachable }
        if revoked { throw DeviceIdentityError.unauthorized }
    }

    func startSignIn(email: String) async throws -> SignInChallenge {
        try offlineOrRevoked()
        startSignInEmails.append(email)
        return SignInChallenge(state: "signin-state-1", email: email, expiresAt: "2026-09-19T10:05:00.000Z")
    }

    func completeSignIn(state: String, email: String, code: String, label: String,
                        publicKeyBase64: String, keyProofBase64: String) async throws -> DeviceSignInResult {
        try offlineOrRevoked()
        if let completeSignInError { throw completeSignInError }
        completeSignInCalls.append(CompleteSignInCall(
            state: state, email: email, code: code, label: label,
            publicKeyBase64: publicKeyBase64, keyProofBase64: keyProofBase64))
        let proofText = DeviceKeyStore.keyProofText(state: state, email: email, publicKeyBase64: publicKeyBase64)
        guard P256Check.verify(publicKeyBase64: publicKeyBase64, signatureBase64: keyProofBase64, message: proofText) else {
            throw DeviceIdentityError.server(code: "key_proof_invalid", message: "the key proof does not verify")
        }
        signingPublicKey = publicKeyBase64
        return DeviceSignInResult(deviceId: deviceIdValue, userId: userIdValue, email: email, label: label,
                                  accessToken: accessTokenValue, accessExpiresIn: accessExpiresIn,
                                  continuableHomes: continuableHomes)
    }

    func enrollKey(deviceId: String, publicKeyBase64: String, keyProofBase64: String,
                   accessToken: String) async throws {
        try offlineOrRevoked()
        enrollKeyCalls.append(EnrollKeyCall(deviceId: deviceId, publicKeyBase64: publicKeyBase64,
                                            keyProofBase64: keyProofBase64, accessToken: accessToken))
        let proofText = DeviceKeyStore.enrollmentProofText(deviceId: deviceId, publicKeyBase64: publicKeyBase64)
        guard P256Check.verify(publicKeyBase64: publicKeyBase64, signatureBase64: keyProofBase64, message: proofText) else {
            throw DeviceIdentityError.server(code: "key_proof_invalid", message: "the enrollment proof does not verify")
        }
        // The server sets public_key only if empty (05 §6 step 2), so a second
        // enrolment with another key leaves the first in place.
        if enrolledPublicKey == nil { enrolledPublicKey = publicKeyBase64 }
        signingPublicKey = publicKeyBase64
    }

    func challenge(deviceId: String) async throws -> DeviceChallenge {
        if let challengeError { throw challengeError }
        try offlineOrRevoked()
        nonceCount += 1
        let nonce = "\(challengeNoncePrefix)-\(nonceCount)"
        challengeCalls.append(ChallengeCall(deviceId: deviceId, nonce: nonce, sentAt: challengeSentAt))
        issuedNonces[nonce] = challengeSentAt
        return DeviceChallenge(nonce: nonce, sentAt: challengeSentAt, expiresInSec: challengeExpiresInSec)
    }

    func token(deviceId: String, nonce: String, signatureBase64: String) async throws -> DeviceToken {
        if let tokenError { throw tokenError }
        try offlineOrRevoked()
        tokenCalls.append(TokenCall(deviceId: deviceId, nonce: nonce, signatureBase64: signatureBase64))
        guard let sentAt = issuedNonces[nonce], !usedNonces.contains(nonce) else {
            throw DeviceIdentityError.server(code: "nonce_not_usable", message: "the nonce was never issued or was already used")
        }
        usedNonces.insert(nonce)
        let proofText = DeviceKeyStore.deviceProofText(nonce: nonce, deviceId: deviceId, sentAt: sentAt)
        guard P256Check.verify(publicKeyBase64: lastEnrolledPublicKey(), signatureBase64: signatureBase64, message: proofText) else {
            throw DeviceIdentityError.server(code: "invalid_signature", message: "the challenge signature does not verify")
        }
        if invalidTokenResponse {
            return DeviceToken(accessToken: "", accessExpiresIn: 0, userId: userIdValue, email: "user@example.test")
        }
        return DeviceToken(accessToken: accessTokenValue, accessExpiresIn: accessExpiresIn,
                           userId: userIdValue, email: "user@example.test")
    }

    /// The key the device enrolled at sign-in or by `enrollKey`; the fake
    /// gateway verifies every challenge signature against it.
    private var signingPublicKey: String?
    private func lastEnrolledPublicKey() -> String { signingPublicKey ?? enrolledPublicKey ?? completeSignInCalls.last?.publicKeyBase64 ?? "" }

    func revokeDevice(deviceId: String, accessToken: String) async throws {
        try offlineOrRevoked()
        revokeCalls.append(DeviceCall(deviceId: deviceId, accessToken: accessToken))
    }

    func startTakeover(homeId: String, accessToken: String) async throws {
        try offlineOrRevoked()
        takeoverStarts.append(TakeoverCodeCall(homeId: homeId, accessToken: accessToken))
        if takeoverCodes[homeId] == nil { takeoverCodes[homeId] = "takeover-code-1" }
    }

    func confirmTakeover(homeId: String, code: String, accessToken: String) async throws -> HomeTakeover {
        try offlineOrRevoked()
        takeoverConfirms.append(TakeoverConfirmCall(homeId: homeId, code: code, accessToken: accessToken))
        guard takeoverCodes[homeId] == code else {
            throw DeviceIdentityError.server(code: "takeover_not_confirmed",
                                             message: "That code is not right. Send a new one.")
        }
        return HomeTakeover(homeId: homeId)
    }
}

/// The transport the app's own `HTTPDeviceGateway` is held against: a
/// `URLProtocol` inside one throwaway `URLSession`, so the routes, the methods,
/// the headers and the request bodies of 05 §3.2 are observed exactly as the
/// gateway would see them, with no port bound and nothing left running. It
/// answers only what a test registered; an unregistered path answers 404 with
/// `no_stub`, so a wrong route is a named failure and never a silent success.
final class StubTransport: URLProtocol {
    struct Call: Equatable {
        var method: String
        var absoluteURL: String
        var path: String
        var authorization: String?
        var contentType: String?
        var accept: String?
        var bodyText: String
    }

    private struct Answer {
        var status: Int
        var json: String
        var transportFailure: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var calls: [Call] = []

    /// One session whose only transport is this stub. Nothing else on the
    /// machine is affected, and no other session can reach it.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        answers = [:]
        calls = []
    }

    static func answer(_ path: String, status: Int = 200, json: String) {
        lock.lock(); defer { lock.unlock() }
        answers[path] = Answer(status: status, json: json, transportFailure: false)
    }

    /// The network is simply not there: the request fails before any answer.
    static func failTransport(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        answers[path] = Answer(status: 0, json: "", transportFailure: true)
    }

    static func recorded(_ path: String) -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.path == path }
    }

    static func lastCall(_ path: String) -> Call? { recorded(path).last }

    static var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let call = Call(
            method: request.httpMethod ?? "",
            absoluteURL: request.url?.absoluteString ?? "",
            path: path,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            accept: request.value(forHTTPHeaderField: "Accept"),
            bodyText: String(decoding: Self.bodyData(request), as: UTF8.self))

        Self.lock.lock()
        Self.calls.append(call)
        let answer = Self.answers[path]
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if answer?.transportFailure == true {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let resolved = answer ?? Answer(
            status: 404,
            json: #"{"error":{"code":"no_stub","message":"no answer was registered for this path"}}"#,
            transportFailure: false)
        let response = HTTPURLResponse(url: url, statusCode: resolved.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(resolved.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
