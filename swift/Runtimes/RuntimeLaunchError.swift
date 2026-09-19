import Foundation

/// A refusal of the runtime launcher, raised before any process exists.
///
/// Every refusal carries one of the contract's two codes — `runtimeUnavailable`
/// for a sandbox that does not work, a runtime that is not installed and a
/// runtime that is not signed in, and `disabledOnDevice` for one of the
/// person's three switches being off — and a message that names what is wrong
/// rather than leaving the person to guess.
struct RuntimeLaunchError: LocalizedError, Equatable {
    let code: TPErrorCode
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }

    static func sandboxUnavailable(_ detail: String) -> RuntimeLaunchError {
        RuntimeLaunchError(
            code: .runtimeUnavailable,
            message: "the sandbox is unavailable: \(detail)",
            retryable: false)
    }

    static func notInstalled(_ runtime: AgentRuntimeKind) -> RuntimeLaunchError {
        RuntimeLaunchError(
            code: .runtimeUnavailable,
            message: "\(runtime.label) is not installed on this Mac",
            retryable: true)
    }

    static func notSignedIn(_ runtime: AgentRuntimeKind) -> RuntimeLaunchError {
        RuntimeLaunchError(
            code: .runtimeUnavailable,
            message: "\(runtime.label) is not signed in; sign in to the runtime first",
            retryable: true)
    }

    static func switchOff(_ runtime: AgentRuntimeKind, switchName: String) -> RuntimeLaunchError {
        RuntimeLaunchError(
            code: .disabledOnDevice,
            message: "\(runtime.label) will not start while the \(switchName) switch is off",
            retryable: true)
    }
}
