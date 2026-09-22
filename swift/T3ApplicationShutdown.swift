import Foundation

/// AppKit can ask to quit repeatedly while a child is draining. All callers
/// join one retained task; no wait blocks the MainActor needed by Process exits.
@MainActor
final class T3ApplicationShutdown {
    private var task: Task<Void, Never>?
    private(set) var finished = false
    func drain(_ operation: @escaping @MainActor () async -> Void) async {
        if let task { await task.value; return }
        let next = Task { @MainActor in await operation(); self.finished = true }
        task = next
        await next.value
    }
}
