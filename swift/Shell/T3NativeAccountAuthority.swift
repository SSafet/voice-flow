import Foundation

/// Native account composition only. The closure supplied by App must return
/// CloudSyncController.credentialOwner(); this object never creates or retires it.
actor T3NativeAccountAuthority {
    enum Destination: Sendable {
        case nativeServingHome(id: String)
        case cloud
    }
    typealias CredentialOwner = @MainActor @Sendable () async throws -> CloudHTTPClient
    typealias OwnedEnvironment = @MainActor @Sendable () throws -> T3AuthorityEnvironmentIdentity

    /// A transient permission checkpoint, not credentials or a second identity
    /// authority. Root combines it with current native policy/turn ownership.
    struct Snapshot: Sendable, Equatable {
        let environment: T3AuthorityEnvironmentIdentity
        let binding: T3NativeAuthorityBinding
        let gatewayOrigin: String
        let validatedUntil: Date

        fileprivate func sameIdentity(as other: Self) -> Bool {
            environment == other.environment && binding == other.binding && gatewayOrigin == other.gatewayOrigin
        }
    }
    private final class Permission: @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        private var snapshot: Snapshot?
        private let onRevoke: @Sendable () -> Void
        private let nativeCurrent: @Sendable () -> Bool
        init(nativeCurrent: @escaping @Sendable () -> Bool, onRevoke: @escaping @Sendable () -> Void) {
            self.nativeCurrent = nativeCurrent; self.onRevoke = onRevoke
        }
        private func observeRetirement() { if !nativeCurrent() { revoke() } }
        var active: Bool { observeRetirement(); return lock.withLock { !revoked && nativeCurrent() } }
        var current: Snapshot? {
            observeRetirement()
            return lock.withLock { !revoked && nativeCurrent() && snapshot.map({ $0.validatedUntil > Date() }) == true ? snapshot : nil }
        }
        func permits(_ value: Snapshot) -> Bool {
            observeRetirement()
            return lock.withLock {
                !revoked && nativeCurrent() && value.validatedUntil > Date() && snapshot.map {
                    $0.validatedUntil > Date() && $0.sameIdentity(as: value)
                } == true
            }
        }
        func publish(_ value: Snapshot) -> Bool {
            observeRetirement()
            return lock.withLock {
                guard !revoked, nativeCurrent(), value.validatedUntil > Date(), snapshot.map({ $0.sameIdentity(as: value) }) != false else { return false }
                snapshot = value
                return true
            }
        }
        func suspend() { lock.withLock { snapshot = nil } }
        func revoke() {
            let changed = lock.withLock {
                guard !revoked else { return false }
                revoked = true; snapshot = nil
                return true
            }
            // Checkpoints are already closed before caller-owned async cleanup.
            if changed { onRevoke() }
        }
    }

    private let owner: CloudHTTPClient
    private let identity: CloudIdentityDescriptor
    private let servingHomeID: String
    private let credentialOwner: CredentialOwner
    private let ownedEnvironment: OwnedEnvironment
    private var environment: T3AuthorityEnvironmentIdentity?
    private nonisolated let permission: Permission

    private init(owner: CloudHTTPClient, identity: CloudIdentityDescriptor, checkpoint: UInt64, servingHomeID: String,
                 credentialOwner: @escaping CredentialOwner, ownedEnvironment: @escaping OwnedEnvironment,
                 onRevoke: @escaping @Sendable () -> Void) {
        self.owner = owner; self.identity = identity; self.servingHomeID = servingHomeID
        self.credentialOwner = credentialOwner; self.ownedEnvironment = ownedEnvironment
        permission = Permission(nativeCurrent: { owner.nativeAuthorityCheckpoint == checkpoint }, onRevoke: onRevoke)
    }

    /// Call before launching the owned environment. No environment file is
    /// required yet; the account actor/identity are fixed before any lease request.
    static func connect(destination: Destination,
                        credentialOwner: @escaping CredentialOwner,
                        ownedEnvironment: @escaping OwnedEnvironment,
                        onRevoke: @escaping @Sendable () -> Void = {}) async throws -> T3NativeAccountAuthority {
        guard case .nativeServingHome(let homeID) = destination, CloudWire.validID(homeID) else {
            throw T3NativeAuthorityError.unavailable
        }
        do {
            let owner = try await credentialOwner()
            try Task.checkCancellation()
            guard let checkpoint = owner.nativeAuthorityCheckpoint else { throw T3NativeAuthorityError.unavailable }
            let identity = try await owner.identity()
            try Task.checkCancellation()
            let current = try await credentialOwner()
            try Task.checkCancellation()
            guard current === owner, try await owner.identity() == identity else { throw T3NativeAuthorityError.unavailable }
            try Task.checkCancellation()
            guard owner.nativeAuthorityCheckpoint == checkpoint else { throw T3NativeAuthorityError.unavailable }
            return .init(owner: owner, identity: identity, checkpoint: checkpoint, servingHomeID: homeID,
                         credentialOwner: credentialOwner, ownedEnvironment: ownedEnvironment, onRevoke: onRevoke)
        } catch is CancellationError { throw CancellationError() }
        catch { throw T3NativeAuthorityError.unavailable }
    }

    nonisolated var currentSnapshot: Snapshot? { permission.current }
    nonisolated func permits(_ snapshot: Snapshot) -> Bool { permission.permits(snapshot) }
    /// Wire controller identity retirement and child exit to this synchronously;
    /// only after it returns should App schedule broker/tools shutdown.
    nonisolated func revoke() { permission.revoke() }
    func stop() { revoke(); environment = nil }

    private func active() throws {
        try Task.checkCancellation()
        guard permission.active else { throw T3NativeAuthorityError.unavailable }
    }
    private func currentOwner() async throws {
        try active()
        let selected = try await credentialOwner()
        try active()
        guard selected === owner else { revoke(); throw T3NativeAuthorityError.unavailable }
        let descriptor = try await owner.identity()
        try active()
        guard descriptor == identity else { revoke(); throw T3NativeAuthorityError.unavailable }
    }
    private func currentEnvironment() async throws -> T3AuthorityEnvironmentIdentity {
        try active()
        let current: T3AuthorityEnvironmentIdentity
        do { current = try await ownedEnvironment() }
        catch {
            if environment != nil, !Task.isCancelled { revoke() }
            throw error
        }
        try active()
        guard CloudWire.validID(current.environmentID) else { revoke(); throw T3NativeAuthorityError.unavailable }
        if let environment, environment != current { revoke(); throw T3NativeAuthorityError.unavailable }
        return current
    }
    private func nativeBinding(_ environment: T3AuthorityEnvironmentIdentity) -> CloudRuntimeBinding {
        .init(identity: identity, servingHomeID: servingHomeID, environmentID: environment.environmentID,
              environmentGeneration: environment.generation)
    }
    private var wireBinding: T3NativeAuthorityBinding {
        .init(ownerId: identity.ownerID, deviceId: identity.deviceID, homeId: servingHomeID, identityGeneration: identity.generation.uuidString)
    }
    private func revalidate(_ lease: CloudRuntimeCredentialLease, environment: T3AuthorityEnvironmentIdentity) async throws -> Bool {
        try await currentOwner()
        let owned = try await currentEnvironment()
        try active()
        guard owned == environment else { revoke(); return false }
        let current = await owner.isCurrent(lease, for: nativeBinding(environment))
        try active()
        if !current { revoke() }
        return current
    }

    func lease(for requested: T3AuthorityEnvironmentIdentity) async throws -> T3NativeAuthorityLease {
        do {
            try await currentOwner()
            let owned = try await currentEnvironment()
            guard owned == requested else { throw T3NativeAuthorityError.unavailable }
            environment = owned
            let native = try await owner.runtimeCredentials(for: nativeBinding(owned))
            try active()
            guard try await revalidate(native, environment: owned), native.expiresAt > Date() else {
                throw T3NativeAuthorityError.unavailable
            }
            let snapshot = Snapshot(environment: owned, binding: wireBinding, gatewayOrigin: identity.origin, validatedUntil: native.expiresAt)
            guard permission.publish(snapshot) else { throw T3NativeAuthorityError.unavailable }
            return .init(environment: owned, binding: wireBinding, gatewayOrigin: identity.origin,
                         accessToken: native.accessToken, expiresAt: native.expiresAt)
        } catch is CancellationError { throw CancellationError() }
        catch {
            failed(error)
            throw T3NativeAuthorityError.unavailable
        }
    }

    /// The input is the native lease returned above, not untrusted wire input.
    /// Reconstructing the actor's value avoids storing a second copy of the token.
    func isCurrent(_ lease: T3NativeAuthorityLease) async -> Bool {
        guard lease.binding == wireBinding, lease.gatewayOrigin == identity.origin,
              lease.expiresAt > Date(), environment == lease.environment else { return false }
        do {
            let native = CloudRuntimeCredentialLease(binding: nativeBinding(lease.environment), accessToken: lease.accessToken, expiresAt: lease.expiresAt)
            return try await revalidate(native, environment: lease.environment)
        } catch is CancellationError { return false }
        catch { failed(error); return false }
    }
    private func failed(_ error: Error) {
        switch error {
        case CloudSyncError.identityChanged, CloudSyncError.signInRequired, CloudSyncError.homeSelectionRequired:
            revoke()
        default:
            // Network failure does not select another actor/account. Checkpoints
            // remain unavailable until this exact owner validates a fresh lease.
            permission.suspend()
        }
    }
}
