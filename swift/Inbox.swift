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
}

final class MessageInbox {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voice-flow/inbox.json")
    private static let maxQueued = 100

    private let queue = DispatchQueue(label: "voiceflow.inbox")
    private var messages: [InboxMessage] = []
    private var waiters: [DispatchSemaphore] = []

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let stored = try? JSONDecoder().decode([InboxMessage].self, from: data) {
            messages = stored
        }
    }

    /// True while an MCP wait_for_message call is parked — the user's
    /// message will be delivered instantly rather than queued.
    var hasWaiter: Bool {
        queue.sync { !waiters.isEmpty }
    }

    var pendingCount: Int {
        queue.sync { messages.count }
    }

    func add(text: String, attachments: [String]) {
        let message = InboxMessage(
            time: ISO8601DateFormatter().string(from: Date()),
            text: text,
            attachments: attachments
        )
        queue.sync {
            messages.append(message)
            if messages.count > Self.maxQueued {
                messages.removeFirst(messages.count - Self.maxQueued)
            }
            persistLocked()
            for waiter in waiters {
                waiter.signal()
            }
            waiters.removeAll()
        }
        vflog("inbox: queued message (\(text.prefix(60))…)")
    }

    /// Return all queued messages and clear the queue.
    func drain() -> [InboxMessage] {
        queue.sync {
            let drained = messages
            messages = []
            if !drained.isEmpty {
                persistLocked()
            }
            return drained
        }
    }

    /// Block until at least one message exists (or the timeout passes),
    /// then drain. Returns [] on timeout.
    func wait(timeout: TimeInterval) -> [InboxMessage] {
        let semaphore = DispatchSemaphore(value: 0)
        let immediate: [InboxMessage] = queue.sync {
            if !messages.isEmpty {
                let drained = messages
                messages = []
                persistLocked()
                return drained
            }
            waiters.append(semaphore)
            return []
        }
        if !immediate.isEmpty {
            return immediate
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return queue.sync {
            waiters.removeAll { $0 === semaphore }
            let drained = messages
            messages = []
            if !drained.isEmpty {
                persistLocked()
            }
            return drained
        }
    }

    /// Must be called on `queue`.
    private func persistLocked() {
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
