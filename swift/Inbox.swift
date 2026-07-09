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

    /// Block until a message for `session` exists (or the timeout passes),
    /// then drain. Returns [] on timeout.
    func wait(timeout: TimeInterval, session: String?) -> [InboxMessage] {
        let semaphore = DispatchSemaphore(value: 0)
        let immediate: [InboxMessage] = queue.sync {
            let drained = drainLocked(session: session)
            if drained.isEmpty {
                waiters.append((session, semaphore))
            }
            return drained
        }
        if !immediate.isEmpty {
            return immediate
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return queue.sync {
            waiters.removeAll { $0.semaphore === semaphore }
            return drainLocked(session: session)
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
