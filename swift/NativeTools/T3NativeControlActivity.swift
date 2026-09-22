import Foundation

/// Only active native computer effects give Escape its emergency-stop meaning.
/// The counter covers concurrent tool calls; ordinary external Escape is untouched.
final class T3NativeControlActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isActive: Bool { lock.withLock { count > 0 } }
    func begin() { lock.withLock { count += 1 } }
    func end() { lock.withLock { count = max(0, count - 1) } }
}
