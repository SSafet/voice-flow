import Foundation

/// Bridges Swift task cancellation to the app's existing blocking UI/inbox calls.
/// One instance belongs to one request, never to a session's future listener.
final class MCPToolCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler() }
        else { handlers.append(handler); lock.unlock() }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let callbacks = handlers
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    func wait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) {
        onCancel { semaphore.signal() }
        if !isCancelled { _ = semaphore.wait(timeout: .now() + timeout) }
    }
}
