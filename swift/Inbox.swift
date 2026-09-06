import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Message Inbox — the user talks whenever, Claude reads whenever
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  ask_user blocks Claude on an answer; the inbox is the asynchronous
//  counterpart. Talk-hotkey messages queue here (persisted to
//  ~/.config/voice-flow/inbox.json, surviving restarts) and Claude drains
//  them with check_messages, or blocks in wait_for_message for a live
//  "listening mode". add() is called on the main thread; drain/wait come
//  from background MCP threads.

struct InboxMessage: Codable {
    let id: String?
    let time: String            // ISO8601
    let text: String
    let attachments: [String]   // absolute screenshot paths
    // Target MCP session id; nil = any session may take it (also what
    // pre-session inbox.json files decode to).
    let session: String?
}

final class MessageInbox {
    private static let maxQueued = 100

    private let storageURL: URL
    private let queue = DispatchQueue(label: "voiceflow.inbox")
    private var messages: [InboxMessage] = []
    private var waiters: [(session: String?, semaphore: DispatchSemaphore)] = []
    /// Exact sessions the user closed. This closes the registration race too:
    /// a wait that arrives just after deletion is terminated instead of
    /// parking. A fresh user-facing push clears the tombstone.
    private var closedSessions: Set<String> = []
    /// Waiters released because a newer wait() for the same session replaced
    /// them: a session keeps exactly one live listener — the latest — so
    /// stale background `vf listen` tasks finish instead of accumulating.
    private var superseded: Set<ObjectIdentifier> = []
    /// Waiters explicitly ended by exact-session deletion. Checked before a
    /// woken waiter drains so a later message cannot resurrect that session.
    private var terminated: Set<ObjectIdentifier> = []
    var onAdded: ((InboxMessage) -> Void)?

    init(storageURL: URL = VoiceFlowPaths.shared.file("inbox.json")) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let stored = try? JSONDecoder().decode([InboxMessage].self, from: data) {
            messages = stored
        }
    }

    /// Visibility is directional: an unscoped message may be claimed by any
    /// consumer, but an unscoped consumer may not claim a targeted message.
    private static func isVisible(messageSession: String?, to consumerSession: String?) -> Bool {
        guard let consumerSession else { return messageSession == nil }
        return messageSession == nil || messageSession == consumerSession
    }

    /// Compatibility lookup. Concrete session ids are exact; nil finds only
    /// an unscoped waiter and never aliases a targeted one.
    func hasWaiter(for session: String?) -> Bool {
        queue.sync { waiters.contains { $0.session == session } }
    }

    /// True only while this exact session has a parked waiter.
    func hasWaiter(exactSession session: String) -> Bool {
        queue.sync { waiters.contains { $0.session == session } }
    }

    var pendingCount: Int {
        queue.sync { messages.count }
    }

    /// How many messages a given session would receive right now.
    func pendingCount(for session: String?) -> Int {
        queue.sync { messages.filter { Self.isVisible(messageSession: $0.session, to: session) }.count }
    }

    func add(text: String, attachments: [String], session: String? = nil) {
        let message = InboxMessage(
            id: UUID().uuidString,
            time: ISO8601DateFormatter().string(from: Date()),
            text: text,
            attachments: attachments,
            session: session
        )
        queue.sync {
            messages.append(message)
            if messages.count > Self.maxQueued {
                messages.removeFirst(messages.count - Self.maxQueued)
            }
            persistLocked()
            for waiter in waiters where Self.isVisible(messageSession: session, to: waiter.session) {
                waiter.semaphore.signal()
            }
            // Keep signalled waiters registered until they actually return.
            // Exact-session deletion can then still mark an in-flight waiter
            // terminated before it reaches drainLocked().
        }
        onAdded?(message)
        vflog("inbox: queued message (\(text.prefix(60))…)")
    }

    /// Return the messages visible to `session` and remove them from the
    /// queue (other sessions' messages stay).
    func drain(session: String?) -> [InboxMessage] {
        queue.sync { drainLocked(session: session) }
    }

    /// Remove only messages targeted to this exact session. Unscoped and
    /// other sessions' messages remain available to their consumers.
    @discardableResult
    func removeQueued(exactSession session: String) -> Int {
        queue.sync {
            let previousCount = messages.count
            messages.removeAll { $0.session == session }
            let removedCount = previousCount - messages.count
            if removedCount > 0 { persistLocked() }
            return removedCount
        }
    }

    /// End every waiter parked on this exact session. The termination marker
    /// prevents an awakened waiter from draining a message queued after the
    /// deletion raced with it.
    @discardableResult
    func terminateWait(exactSession session: String) -> Int {
        queue.sync {
            closedSessions.insert(session)
            let matching = waiters.filter { $0.session == session }
            for waiter in matching {
                terminated.insert(ObjectIdentifier(waiter.semaphore))
                waiter.semaphore.signal()
            }
            waiters.removeAll { $0.session == session }
            return matching.count
        }
    }

    /// Backward-compatible name used by current session deletion call sites.
    func cancelWait(for session: String) {
        terminateWait(exactSession: session)
    }

    /// A new user-facing push is a deliberate re-engagement and allows the
    /// session to listen again.
    func clearUserClosed(_ session: String) {
        queue.sync { closedSessions.remove(session) }
    }

    /// Block until a message for `session` exists (or the timeout passes),
    /// then drain. Returns empty messages with both flags false on timeout.
    /// superseded is true when a
    /// newer wait() for the same session replaced this one — the caller must
    /// tell the agent this listener is obsolete (the newer one holds the
    /// session). terminated is true when exact-session deletion ended it.
    func wait(
        timeout: TimeInterval,
        session: String?
    ) -> (messages: [InboxMessage], superseded: Bool, terminated: Bool) {
        enum Immediate { case messages([InboxMessage]), terminated, parked }
        let semaphore = DispatchSemaphore(value: 0)
        let immediate: Immediate = queue.sync {
            if let session, closedSessions.contains(session) {
                return .terminated
            }
            let drained = drainLocked(session: session)
            if drained.isEmpty {
                // One live listener per session: release any older waiter
                // parked on this exact id before taking its place.
                if let session {
                    for waiter in waiters where waiter.session == session {
                        superseded.insert(ObjectIdentifier(waiter.semaphore))
                        waiter.semaphore.signal()
                    }
                    waiters.removeAll { $0.session == session }
                }
                waiters.append((session, semaphore))
                return .parked
            }
            return .messages(drained)
        }
        switch immediate {
        case .messages(let drained): return (drained, false, false)
        case .terminated: return ([], false, true)
        case .parked: break
        }
        let deadline = DispatchTime.now() + timeout
        while true {
            let expired = semaphore.wait(timeout: deadline) == .timedOut
            let result: (messages: [InboxMessage], superseded: Bool, terminated: Bool)? = queue.sync {
                // Keep the listener registered until it really finishes. An
                // unscoped message signals several eligible sessions and a
                // competing drain may claim it before this listener wakes.
                var finished = true
                defer {
                    if finished { waiters.removeAll { $0.semaphore === semaphore } }
                }
                // Checked before draining: a superseded waiter must not steal
                // messages that now belong to its replacement.
                if superseded.remove(ObjectIdentifier(semaphore)) != nil { return ([], true, false) }
                // A deleted session must not steal a message that raced with
                // deletion and was queued after its waiter had been released.
                if terminated.remove(ObjectIdentifier(semaphore)) != nil { return ([], false, true) }
                let drained = drainLocked(session: session)
                if !drained.isEmpty || expired { return (drained, false, false) }
                finished = false
                return nil
            }
            if let result { return result }
        }
    }

    /// Must be called on `queue`.
    private func drainLocked(session: String?) -> [InboxMessage] {
        let drained = messages.filter { Self.isVisible(messageSession: $0.session, to: session) }
        guard !drained.isEmpty else { return [] }
        messages.removeAll { Self.isVisible(messageSession: $0.session, to: session) }
        persistLocked()
        return drained
    }

    /// Must be called on `queue`.
    private func persistLocked() {
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
