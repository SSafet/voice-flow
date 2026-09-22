import Foundation
import CryptoKit
import MCP

struct T3NativeToolEnvironment: Codable, Hashable, Sendable {
    let environmentId: String
    let launchGeneration: UUID
}
struct T3NativeToolBinding: Codable, Hashable, Sendable {
    let environment: T3NativeToolEnvironment
    let ownerId: String
    let deviceId: String
    let homeId: String
    let identityGeneration: String
}
enum T3NativeToolDecision: String, Codable, Sendable { case allow, ask, deny }
enum T3NativeToolAction: String, Sendable {
    case observe = "computer.observe", control = "computer.control"
    case capturedRead = "captured.read", overlayRead = "overlay.read", overlayWrite = "overlay.write"
}
struct T3NativeToolCall: Codable, Hashable, Sendable {
    let threadId: String
    let turnId: String
    let callId: String
    let tool: String
    let arguments: [String: Value]
    let manifestRevision: String
    var key: String { "\(threadId)\0\(turnId)\0\(callId)" }
}
struct T3NativeToolAuthority: Sendable {
    let binding: T3NativeToolBinding
    let backendRevision: String
    let policyRevision: String
    let decision: T3NativeToolDecision
}
struct T3NativeToolPreflight: Codable, Hashable, Sendable {
    let version: Int
    let decision: T3NativeToolDecision
    let callDigest: String
    let review: String
    let requestId: String?
    let executionToken: String?
}
struct T3NativeToolManifest: Codable, Sendable {
    let version: Int
    let binding: T3NativeToolBinding
    let revision: String
    let backendRevision: String
    let policyRevision: String
    let tools: [Tool]
}
struct T3NativeToolFailure: Error, LocalizedError {
    let code: String
    var errorDescription: String? { code }
}
struct T3NativeToolOperation {
    let action: T3NativeToolAction
    let arguments: [String: Any]
    let review: String
}
/// Revocation is synchronous, including while a native primitive is executing.
final class T3NativeToolLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    func revoke() { lock.withLock { alive = false } }
    func check() throws {
        guard lock.withLock({ alive }) else { throw T3NativeToolFailure(code: "native_revoked") }
        try Task.checkCancellation()
    }
}
struct T3NativeToolCheckpoint: Sendable {
    let check: @Sendable () throws -> Void
}
struct T3NativeToolBackend {
    /// Supplied by the trusted native host; must read current identity and hard
    /// restrictions, not the client's runtimeMode or an approval boolean.
    let authority: @Sendable (T3NativeToolCall, T3NativeToolAction) -> T3NativeToolAuthority?
    let perform: (T3NativeToolCall, T3NativeToolOperation, T3NativeToolCheckpoint) async throws -> CallTool.Result
}

/// Transient execution capabilities only. T3 owns approval persistence/UI.
/// A consumed call is never evicted while its launch can execute it.
actor T3NativeToolService {
    let binding: T3NativeToolBinding
    let manifest: T3NativeToolManifest
    nonisolated let lifetime = T3NativeToolLifetime()
    private let backend: T3NativeToolBackend
    private let now: () -> Date
    private let capacity: Int
    private enum Phase { case asking, allowed, rejected, consumed }
    private struct Entry {
        let digest: String
        let requestId: String?
        let token: String?
        let expires: Date
        var phase: Phase
    }
    private var calls: [String: Entry] = [:]
    private var closedTurns: Set<String> = []
    private var turnLifetimes: [String: T3NativeToolLifetime] = [:]

    init(binding: T3NativeToolBinding, backendRevision: String, policyRevision: String,
         tools: [Tool], backend: T3NativeToolBackend, capacity: Int = 4096, now: @escaping () -> Date = Date.init) throws {
        guard Self.validID(backendRevision), Self.validID(policyRevision), !tools.isEmpty,
              UUID(uuidString: binding.identityGeneration) != nil,
              Set(tools.map(\.name)).count == tools.count, capacity > 0,
              [binding.environment.environmentId, binding.ownerId, binding.deviceId, binding.homeId, binding.identityGeneration]
                .allSatisfy(Self.validID) else { throw T3NativeToolFailure(code: "native_configuration_invalid") }
        struct Revision: Encodable { let version = 1; let binding: T3NativeToolBinding; let backend: String; let policy: String; let tools: [Tool] }
        let revision = try Self.digest(Revision(binding: binding, backend: backendRevision, policy: policyRevision, tools: tools))
        self.binding = binding; self.backend = backend; self.now = now; self.capacity = capacity
        manifest = .init(version: 1, binding: binding, revision: revision, backendRevision: backendRevision, policyRevision: policyRevision, tools: tools)
    }
    nonisolated func revoke() { lifetime.revoke() }
    /// Root calls only when the T3 turn has closed. Old scope is permanently
    /// refused for this launch before releasing its individual call tombstones.
    func closeTurn(threadId: String, turnId: String) throws {
        guard Self.validID(threadId), Self.validID(turnId) else { throw T3NativeToolFailure(code: "native_call_invalid") }
        let key = "\(threadId)\0\(turnId)\0"
        guard closedTurns.count < capacity || closedTurns.contains(key) else { throw T3NativeToolFailure(code: "native_capacity") }
        closedTurns.insert(key)
        turnLifetimes.removeValue(forKey: key)?.revoke()
        calls = calls.filter { !$0.key.hasPrefix(key) }
    }
    func preflight(_ call: T3NativeToolCall) throws -> T3NativeToolPreflight {
        let operation = try validate(call), digest = try callDigest(call)
        let decision = try current(call, operation.action)
        if let entry = calls[call.key] {
            guard entry.digest == digest else { throw T3NativeToolFailure(code: "native_call_changed") }
            guard entry.phase != .consumed else { throw T3NativeToolFailure(code: "native_already_consumed") }
            guard now() < entry.expires else { throw T3NativeToolFailure(code: "native_expired") }
            if decision == .deny || entry.phase == .rejected { return answer(.deny, digest, operation.review, entry) }
            guard entry.phase != .allowed || entry.requestId != nil || decision == .allow else { throw T3NativeToolFailure(code: "native_policy_changed") }
            return answer(entry.phase == .asking ? .ask : .allow, digest, operation.review, entry)
        }
        guard calls.count < capacity else { throw T3NativeToolFailure(code: "native_capacity") }
        let entry = Entry(digest: digest, requestId: decision == .ask ? "native-\(UUID().uuidString)" : nil,
                          token: decision == .allow ? Self.token() : nil,
                          expires: now().addingTimeInterval(600), phase: decision == .ask ? .asking : decision == .allow ? .allowed : .rejected)
        calls[call.key] = entry
        let scope = "\(call.threadId)\0\(call.turnId)\0"
        if turnLifetimes[scope] == nil { turnLifetimes[scope] = T3NativeToolLifetime() }
        return answer(decision, digest, operation.review, entry)
    }
    func approve(_ call: T3NativeToolCall, requestId: String, allowOnce: Bool) throws -> T3NativeToolPreflight {
        let operation = try validate(call), digest = try callDigest(call)
        guard var entry = calls[call.key], entry.digest == digest, entry.requestId == requestId,
              entry.phase == .asking, now() < entry.expires else { throw T3NativeToolFailure(code: "native_approval_stale") }
        // Consume the decision before consulting live authority. Contradictory
        // duplicate replies can never turn a prior rejection into execution.
        entry.phase = .rejected; calls[call.key] = entry
        let permitted = try current(call, operation.action) != .deny && allowOnce
        if permitted {
            entry = Entry(digest: digest, requestId: requestId, token: Self.token(), expires: entry.expires, phase: .allowed)
            calls[call.key] = entry
        }
        return answer(permitted ? .allow : .deny, digest, operation.review, entry)
    }
    func execute(_ call: T3NativeToolCall, token: String, requestLifetime: T3NativeToolLifetime? = nil) async -> CallTool.Result {
        do {
            let operation = try validate(call), digest = try callDigest(call)
            guard var entry = calls[call.key], entry.digest == digest, entry.phase == .allowed,
                  entry.token == token, !token.isEmpty, now() < entry.expires else { throw T3NativeToolFailure(code: "native_execution_refused") }
            let currentDecision = try current(call, operation.action)
            guard currentDecision != .deny, entry.requestId != nil || currentDecision == .allow,
                  let turnLife = turnLifetimes["\(call.threadId)\0\(call.turnId)\0"] else { throw T3NativeToolFailure(code: "native_denied") }
            entry.phase = .consumed; calls[call.key] = entry // before any await/effect
            let requestLife = requestLifetime ?? T3NativeToolLifetime(), life = lifetime, backend = backend
            let wasApproved = entry.requestId != nil, action = operation.action, expires = entry.expires, now = now
            let binding = binding, manifest = manifest
            let checkpoint = T3NativeToolCheckpoint(check: {
                try life.check(); try turnLife.check(); try requestLife.check()
                guard now() < expires else { throw T3NativeToolFailure(code: "native_expired") }
                guard let authority = backend.authority(call, action), authority.binding == binding,
                      authority.backendRevision == manifest.backendRevision, authority.policyRevision == manifest.policyRevision,
                      authority.decision != .deny, wasApproved || authority.decision == .allow else { throw T3NativeToolFailure(code: "native_authority_changed") }
            })
            return await withTaskCancellationHandler(operation: {
                do {
                    try checkpoint.check()
                    let result = try await backend.perform(call, operation, checkpoint)
                    try checkpoint.check() // no stale bytes/results after an async read
                    return result
                } catch { return Self.failure(error) }
            }, onCancel: { requestLife.revoke() })
        } catch { return Self.failure(error) }
    }
    private func answer(_ decision: T3NativeToolDecision, _ digest: String, _ review: String, _ entry: Entry) -> T3NativeToolPreflight {
        .init(version: 1, decision: decision, callDigest: digest, review: review,
              requestId: entry.requestId, executionToken: decision == .allow ? entry.token : nil)
    }
    private func current(_ call: T3NativeToolCall, _ action: T3NativeToolAction) throws -> T3NativeToolDecision {
        try lifetime.check()
        guard let value = backend.authority(call, action), value.binding == binding,
              value.backendRevision == manifest.backendRevision, value.policyRevision == manifest.policyRevision else {
            throw T3NativeToolFailure(code: "native_authority_changed")
        }
        return value.decision
    }
    private func callDigest(_ call: T3NativeToolCall) throws -> String { try Self.digest(call) }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    private static func token() -> String { UUID().uuidString + UUID().uuidString }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
    static func failure(_ error: Error) -> CallTool.Result {
        let code = (error as? T3NativeToolFailure)?.code ?? (error is CancellationError ? "native_cancelled" : "native_operation_failed")
        return .init(content: [.text(text: code, annotations: nil, _meta: nil)], isError: true)
    }
    private func validate(_ call: T3NativeToolCall) throws -> T3NativeToolOperation {
        try lifetime.check()
        guard call.manifestRevision == manifest.revision,
              [call.threadId, call.turnId, call.callId].allSatisfy(Self.validID),
              !closedTurns.contains("\(call.threadId)\0\(call.turnId)\0"),
              manifest.tools.contains(where: { $0.name == call.tool }),
              let arguments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(call.arguments)) as? [String: Any],
              try JSONEncoder().encode(call.arguments).count <= 64 * 1024 else { throw T3NativeToolFailure(code: "native_call_invalid") }
        return try T3NativeToolCatalog.validate(tool: call.tool, arguments: arguments)
    }
}
