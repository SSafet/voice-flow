import Foundation

/// Private stdin bootstrap material; never include this value in renderer config,
/// process arguments, environment variables, settings, or diagnostic payloads.
struct T3NativeAuthorityBootstrap: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let origin: String
    let credential: String
    var description: String { "T3NativeAuthorityBootstrap(private)" }
    var debugDescription: String { description }
}

/// Established by the owner of the exact launched process, not by an HTTP caller.
struct T3AuthorityEnvironmentIdentity: Sendable, Equatable {
    let environmentID: String
    let generation: UUID
}

struct T3NativeAuthorityBinding: Sendable, Codable, Equatable {
    let ownerId: String
    let deviceId: String
    let homeId: String
    // The spelling of the native UUID is part of the pinned wire identity.
    let identityGeneration: String
}

/// An ephemeral response from the existing credential owner, not a token cache.
struct T3NativeAuthorityLease: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let environment: T3AuthorityEnvironmentIdentity
    let binding: T3NativeAuthorityBinding
    let gatewayOrigin: String
    let accessToken: String
    let expiresAt: Date
    var description: String { "T3NativeAuthorityLease(private)" }
    var debugDescription: String { description }
}

enum T3NativeAuthorityError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "Native Atika authority is unavailable." }
}
