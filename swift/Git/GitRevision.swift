import Foundation

/// A request this package refuses, in one of the contract's stable codes.
struct GitOperationError: Error, Equatable {
    let code: String
    let message: String
}

enum CheckpointPhase: String, Equatable, Sendable {
    case before
    case after
}

/// The names of this project's checkpoint references, the one set of names a
/// client may use on either Mac (06 §3.16, branch 04's reference names).
enum CheckpointRefs {
    static let prefix = "refs/atika/checkpoints/"

    static func ref(threadId: String, turnId: String, phase: CheckpointPhase) -> String {
        "\(prefix)\(threadId)/\(turnId)-\(phase.rawValue)"
    }

    static func threadPrefix(_ threadId: String) -> String {
        "\(prefix)\(threadId)/"
    }

    static func isCheckpointRef(_ value: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let remainder = value.dropFirst(prefix.count)
        guard !remainder.isEmpty else { return false }
        guard !remainder.hasPrefix("/"), !remainder.hasSuffix("/") else { return false }
        guard !remainder.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        return remainder.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// The gate for every value a client may name as a revision: `HEAD`, a commit
/// id this repository resolves, or one of this project's checkpoint references
/// — and nothing else.
enum GitRevision {
    static func isCommitId(_ value: String) -> Bool {
        guard value.count >= 4, value.count <= 40 else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func accept(_ value: String, folder: URL, runner: GitRunner)
        -> Result<String, GitOperationError> {
        if value == "HEAD" {
            return .success(value)
        }
        guard isCommitId(value) || CheckpointRefs.isCheckpointRef(value) else {
            return .failure(refusal(value))
        }
        switch runner.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(value)^{commit}"],
                          in: folder, query: true) {
        case .success:
            return .success(value)
        case .failure:
            return .failure(refusal(value))
        }
    }

    private static func refusal(_ value: String) -> GitOperationError {
        GitOperationError(
            code: "invalid_params",
            message: "the revision \"\(value)\" is not HEAD, a commit id or a checkpoint reference of this project")
    }
}
