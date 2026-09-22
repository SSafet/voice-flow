import Foundation

/// Bridges Swift task cancellation to the app's existing blocking UI/inbox calls.
/// One instance belongs to one request, never to a session's future listener.
final class MCPToolCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private enum State { case active, cancelled, consumed }
    private var state: State = .active
    private var handlers: [() -> Void] = []
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return state == .cancelled }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if state == .cancelled { lock.unlock(); handler() }
        else {
            if state == .active { handlers.append(handler) }
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        guard state == .active else { lock.unlock(); return }
        state = .cancelled
        let callbacks = handlers
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    /// Called under the inbox queue BEFORE removing a nonempty message batch.
    /// Exactly one side wins: cancellation keeps the original messages queued;
    /// consumption commits the successful response and later cancel is advisory.
    /// This is a server-side boundary, not a network delivery acknowledgement.
    func claimConsumption() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state != .cancelled else { return false }
        state = .consumed
        handlers.removeAll()
        return true
    }

    func wait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) {
        onCancel { semaphore.signal() }
        if !isCancelled { _ = semaphore.wait(timeout: .now() + timeout) }
    }
}
