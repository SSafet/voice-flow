#if VOICE_FLOW_QA
import Foundation
import Security
import Darwin

enum QAControlError: LocalizedError {
    case isolatedRootRequired
    case randomFailure

    var errorDescription: String? {
        switch self {
        case .isolatedRootRequired:
            return "QA control requires VOICE_FLOW_CONFIG_ROOT."
        case .randomFailure:
            return "Could not generate the QA capability token."
        }
    }
}

/// Compile-time-only authority for deterministic app automation. The token is
/// emitted solely into the isolated QA root, mode 0600, and is never logged or
/// returned by an endpoint.
enum QAControlSecurity {
    static func installToken() throws -> String {
        guard VoiceFlowPaths.shared.isIsolated else {
            throw QAControlError.isolatedRootRequired
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw QAControlError.randomFailure
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let url = VoiceFlowPaths.shared.file("qa-control-token")
        try Data(token.utf8).write(to: url, options: [.atomic])
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
        return token
    }

    static func matches(_ candidate: String, token: String) -> Bool {
        let left = Array(candidate.utf8)
        let right = Array(token.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

struct QAEvent {
    let sequence: Int
    let time: Date
    let type: String
    let payload: [String: Any]

    var dictionary: [String: Any] {
        [
            "sequence": sequence,
            "time": ISO8601DateFormatter().string(from: time),
            "type": type,
            "payload": payload,
        ]
    }
}

/// Bounded normalized event journal lets automation await observable product
/// outcomes instead of sleeping or reaching into AppKit implementation state.
final class QAEventRecorder {
    static let shared = QAEventRecorder()
    private let lock = NSLock()
    private var nextSequence = 1
    private var entries: [QAEvent] = []

    func append(_ type: String, _ payload: [String: Any] = [:]) {
        lock.withLock {
            let sanitized = payload.mapValues { value -> Any in
                if let text = value as? String {
                    return String(AgentSecretPolicy.redacted(text).prefix(8_000))
                }
                return value
            }
            entries.append(QAEvent(
                sequence: nextSequence, time: Date(), type: type, payload: sanitized))
            nextSequence += 1
            if entries.count > 1_000 { entries.removeFirst(entries.count - 1_000) }
        }
    }

    func snapshot(after sequence: Int) -> [[String: Any]] {
        lock.withLock {
            entries.filter { $0.sequence > sequence }.map(\.dictionary)
        }
    }

    func reset() {
        lock.withLock {
            entries.removeAll()
            nextSequence = 1
        }
    }
}
#endif
