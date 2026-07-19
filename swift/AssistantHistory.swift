import Foundation

enum AssistantMessageRole: String, Codable {
    case user
    case assistant
    case note
}

enum AssistantTurnState: String, Codable {
    case idle
    case running
    case interrupted
}

struct AssistantHistoryMessage: Codable, Equatable {
    let id: UUID
    let at: Date
    let role: AssistantMessageRole
    let text: String
    let attachmentNote: String?

    init(id: UUID = UUID(), at: Date = Date(), role: AssistantMessageRole,
         text: String, attachmentNote: String? = nil) {
        self.id = id
        self.at = at
        self.role = role
        self.text = text
        self.attachmentNote = attachmentNote
    }
}

struct AssistantConversation: Codable, Equatable {
    let id: String
    var codexThreadId: String?
    let createdAt: Date
    var updatedAt: Date
    var title: String
    var turnState: AssistantTurnState
    var messages: [AssistantHistoryMessage]

    init(id: String = UUID().uuidString, codexThreadId: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date(),
         title: String = "New assistant", turnState: AssistantTurnState = .idle,
         messages: [AssistantHistoryMessage] = []) {
        self.id = id
        self.codexThreadId = codexThreadId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.turnState = turnState
        self.messages = messages
    }

    var preview: String {
        let value = messages.last(where: { $0.role != .note })?.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "talk · type · snap — the in-app agent" : value
    }
}

private struct AssistantHistoryEnvelope: Codable {
    var version: Int
    var activeSessionId: String
    var sessions: [AssistantConversation]
}

/// The durable source of truth for in-app Assistant conversations. Callers
/// receive value copies; all mutations and atomic snapshots are serialized.
final class AssistantHistoryStore {
    static let maxSessions = 100
    static let maxMessagesPerSession = 200

    private let url: URL
    private let lock = NSLock()
    private var envelope: AssistantHistoryEnvelope

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice-flow/assistant-sessions.json")
    }

    init(url: URL = AssistantHistoryStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(AssistantHistoryEnvelope.self, from: data),
           loaded.version == 1, !loaded.sessions.isEmpty {
            envelope = loaded
            repairActiveSessionLocked()
            recoverInterruptedTurnsLocked()
        } else {
            let fresh = AssistantConversation()
            envelope = AssistantHistoryEnvelope(version: 1, activeSessionId: fresh.id, sessions: [fresh])
            // A corrupt existing file is left untouched until the user makes
            // a deliberate mutation; a missing file gets its initial snapshot.
            if !FileManager.default.fileExists(atPath: url.path) {
                persistLocked()
            } else {
                vflog("assistant history: could not decode \(url.path); keeping it untouched")
            }
        }
    }

    var activeSessionId: String {
        lock.withLock { envelope.activeSessionId }
    }

    func activeConversation() -> AssistantConversation {
        lock.withLock {
            conversationLocked(envelope.activeSessionId) ?? envelope.sessions[0]
        }
    }

    func conversation(_ id: String) -> AssistantConversation? {
        lock.withLock { conversationLocked(id) }
    }

    func conversations() -> [AssistantConversation] {
        lock.withLock { envelope.sessions.sorted { $0.updatedAt > $1.updatedAt } }
    }

    @discardableResult
    func createConversation() -> AssistantConversation {
        lock.withLock {
            let conversation = AssistantConversation()
            envelope.sessions.append(conversation)
            envelope.activeSessionId = conversation.id
            pruneLocked()
            persistLocked()
            return conversation
        }
    }

    @discardableResult
    func activate(_ id: String) -> AssistantConversation? {
        lock.withLock {
            guard let conversation = conversationLocked(id) else { return nil }
            envelope.activeSessionId = id
            persistLocked()
            return conversation
        }
    }

    /// Removes one conversation. The Assistant always retains one valid empty
    /// target, so deleting the final row creates a fresh replacement.
    @discardableResult
    func delete(_ id: String) -> AssistantConversation {
        lock.withLock {
            envelope.sessions.removeAll { $0.id == id }
            if envelope.sessions.isEmpty {
                let fresh = AssistantConversation()
                envelope.sessions = [fresh]
                envelope.activeSessionId = fresh.id
            } else if envelope.activeSessionId == id {
                envelope.activeSessionId = envelope.sessions.max { $0.updatedAt < $1.updatedAt }!.id
            }
            persistLocked()
            return conversationLocked(envelope.activeSessionId)!
        }
    }

    func appendMessage(sessionId: String, role: AssistantMessageRole,
                       text: String, attachmentNote: String? = nil) {
        lock.withLock {
            guard let index = envelope.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || attachmentNote != nil else { return }
            let now = Date()
            envelope.sessions[index].messages.append(AssistantHistoryMessage(
                at: now, role: role, text: text, attachmentNote: attachmentNote))
            if envelope.sessions[index].messages.count > Self.maxMessagesPerSession {
                envelope.sessions[index].messages.removeFirst(
                    envelope.sessions[index].messages.count - Self.maxMessagesPerSession)
            }
            if role == .user, envelope.sessions[index].title == "New assistant" {
                envelope.sessions[index].title = Self.title(from: trimmed, attachmentNote: attachmentNote)
            }
            envelope.sessions[index].updatedAt = now
            persistLocked()
        }
    }

    func setCodexThreadId(_ threadId: String, for sessionId: String) {
        mutateConversation(sessionId) { conversation in
            conversation.codexThreadId = threadId
        }
    }

    func setTurnState(_ state: AssistantTurnState, for sessionId: String) {
        mutateConversation(sessionId) { conversation in
            conversation.turnState = state
        }
    }

    private func mutateConversation(_ id: String, _ body: (inout AssistantConversation) -> Void) {
        lock.withLock {
            guard let index = envelope.sessions.firstIndex(where: { $0.id == id }) else { return }
            body(&envelope.sessions[index])
            envelope.sessions[index].updatedAt = Date()
            persistLocked()
        }
    }

    private func conversationLocked(_ id: String) -> AssistantConversation? {
        envelope.sessions.first { $0.id == id }
    }

    private func repairActiveSessionLocked() {
        guard !envelope.sessions.contains(where: { $0.id == envelope.activeSessionId }) else { return }
        envelope.activeSessionId = envelope.sessions.max { $0.updatedAt < $1.updatedAt }!.id
        persistLocked()
    }

    private func recoverInterruptedTurnsLocked() {
        var changed = false
        for index in envelope.sessions.indices where envelope.sessions[index].turnState == .running {
            envelope.sessions[index].turnState = .interrupted
            envelope.sessions[index].messages.append(AssistantHistoryMessage(
                role: .note,
                text: "Interrupted by an app restart — send another message to continue this session."))
            envelope.sessions[index].updatedAt = Date()
            changed = true
        }
        if changed { persistLocked() }
    }

    private func pruneLocked() {
        guard envelope.sessions.count > Self.maxSessions else { return }
        let active = envelope.activeSessionId
        let removable = envelope.sessions
            .filter { $0.id != active }
            .sorted { $0.updatedAt < $1.updatedAt }
        let count = envelope.sessions.count - Self.maxSessions
        let ids = Set(removable.prefix(count).map(\.id))
        envelope.sessions.removeAll { ids.contains($0.id) }
    }

    private func persistLocked() {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: url, options: .atomic)
        } catch {
            vflog("assistant history: save failed: \(error.localizedDescription)")
        }
    }

    private static func title(from text: String, attachmentNote: String?) -> String {
        let compact = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let source = compact.isEmpty ? (attachmentNote ?? "Screenshot") : compact
        return source.count > 54 ? String(source.prefix(54)) + "…" : source
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
