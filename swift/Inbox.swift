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
    let time: String            // ISO8601
    let text: String
    let attachments: [String]   // absolute screenshot paths
    // Target MCP session id; nil = any session may take it (also what
    // pre-session inbox.json files decode to).
    let session: String?
}

final class MessageInbox {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voice-flow/inbox.json")
    private static let maxQueued = 100

    private let queue = DispatchQueue(label: "voiceflow.inbox")
    private var messages: [InboxMessage] = []
    private var waiters: [(session: String?, semaphore: DispatchSemaphore)] = []
    /// Session ids the user dismissed (pill trash / remove / panel ✓) while
    /// an agent was listening. Consumed by the next wait() for that exact id
    /// so the parked — or next — wait_for_message returns a terminal
    /// "user closed" notice instead of silently resurrecting the session.
    private var userClosed: Set<String> = []
    /// Waiters released because a newer wait() for the same session replaced
    /// them: a session keeps exactly one live listener — the latest — so
    /// stale background `vf listen` tasks finish instead of accumulating.
    private var superseded: Set<ObjectIdentifier> = []

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let stored = try? JSONDecoder().decode([InboxMessage].self, from: data) {
            messages = stored
        }
    }

    /// A message for `session` matches a waiter/drainer of `candidate` when
    /// either side is unscoped (nil) or the ids agree.
    private static func matches(_ session: String?, _ candidate: String?) -> Bool {
        session == nil || candidate == nil || session == candidate
    }

    /// True while an MCP wait_for_message call that would receive a message
    /// for `session` is parked — it will be delivered instantly, not queued.
    func hasWaiter(for session: String?) -> Bool {
        queue.sync { waiters.contains { Self.matches(session, $0.session) } }
    }

    var pendingCount: Int {
        queue.sync { messages.count }
    }

    /// How many messages a given session would receive right now.
    func pendingCount(for session: String?) -> Int {
        queue.sync { messages.filter { Self.matches($0.session, session) }.count }
    }

    func add(text: String, attachments: [String], session: String? = nil) {
        let message = InboxMessage(
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
            for waiter in waiters where Self.matches(session, waiter.session) {
                waiter.semaphore.signal()
            }
            waiters.removeAll { Self.matches(session, $0.session) }
        }
        vflog("inbox: queued message (\(text.prefix(60))…)")
    }

    /// Return the messages visible to `session` and remove them from the
    /// queue (other sessions' messages stay).
    func drain(session: String?) -> [InboxMessage] {
        queue.sync { drainLocked(session: session) }
    }

    /// The user closed `session` (trash / remove / ✓): release its parked
    /// waiters with a terminal notice and remember the closure for a poll
    /// that isn't currently parked. Exact id match — unscoped (nil) waiters
    /// and other sessions are untouched.
    func cancelWait(for session: String) {
        queue.sync {
            userClosed.insert(session)
            for waiter in waiters where waiter.session == session {
                waiter.semaphore.signal()
            }
            waiters.removeAll { $0.session == session }
        }
    }

    /// The session re-engaged the user (a fresh push) — a closure recorded
    /// before that is stale and must not end its next listen.
    func clearUserClosed(_ session: String) {
        queue.sync { _ = userClosed.remove(session) }
    }

    /// Block until a message for `session` exists (or the timeout passes),
    /// then drain. Returns ([], false, false) on timeout; userClosed is true
    /// when the user dismissed the session — the caller must tell the agent
    /// to stop listening. superseded is true when a newer wait() for the
    /// same session replaced this one — the caller must tell the agent this
    /// listener is obsolete (the newer one holds the session).
    func wait(timeout: TimeInterval, session: String?) -> (messages: [InboxMessage], userClosed: Bool, superseded: Bool) {
        enum Immediate { case closed, messages([InboxMessage]), parked }
        let semaphore = DispatchSemaphore(value: 0)
        let immediate: Immediate = queue.sync {
            if let session, userClosed.remove(session) != nil { return .closed }
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
        case .closed: return ([], true, false)
        case .messages(let drained): return (drained, false, false)
        case .parked: break
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return queue.sync {
            waiters.removeAll { $0.semaphore === semaphore }
            // Checked before draining: a superseded waiter must not steal
            // messages that now belong to its replacement.
            if superseded.remove(ObjectIdentifier(semaphore)) != nil { return ([], false, true) }
            if let session, userClosed.remove(session) != nil { return ([], true, false) }
            return (drainLocked(session: session), false, false)
        }
    }

    /// Must be called on `queue`.
    private func drainLocked(session: String?) -> [InboxMessage] {
        let drained = messages.filter { Self.matches($0.session, session) }
        guard !drained.isEmpty else { return [] }
        messages.removeAll { Self.matches($0.session, session) }
        persistLocked()
        return drained
    }

    /// Must be called on `queue`.
    private func persistLocked() {
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
