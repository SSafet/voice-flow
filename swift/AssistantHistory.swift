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
    /// One-time bridge for conversations created before this store shipped.
    var legacyImportCompleted: Bool?
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

    static var defaultLegacySessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    init(url: URL = AssistantHistoryStore.defaultURL,
         legacySessionsRoot: URL? = AssistantHistoryStore.defaultLegacySessionsRoot) {
        self.url = url
        let fileExisted = FileManager.default.fileExists(atPath: url.path)
        var canPersist = !fileExisted
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(AssistantHistoryEnvelope.self, from: data),
           loaded.version == 1, !loaded.sessions.isEmpty {
            envelope = loaded
            canPersist = true
            repairActiveSessionLocked()
            recoverInterruptedTurnsLocked()
        } else {
            let fresh = AssistantConversation()
            envelope = AssistantHistoryEnvelope(
                version: 1, activeSessionId: fresh.id, sessions: [fresh],
                legacyImportCompleted: nil)
            // A corrupt existing file is left untouched until the user makes
            // a deliberate mutation; a missing file gets its initial snapshot.
            if fileExisted {
                vflog("assistant history: could not decode \(url.path); keeping it untouched")
            }
        }
        if canPersist, envelope.legacyImportCompleted != true {
            importLegacyConversationsLocked(from: legacySessionsRoot)
            envelope.legacyImportCompleted = true
            persistLocked()
        } else if canPersist, !fileExisted {
            persistLocked()
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
            // Repeated presses on "new assistant" must not manufacture empty
            // history. Reuse the active blank draft until the user writes.
            if let current = conversationLocked(envelope.activeSessionId),
               current.messages.isEmpty, current.codexThreadId == nil,
               current.turnState == .idle {
                return current
            }
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

    private func importLegacyConversationsLocked(from root: URL?) {
        guard let root else { return }
        let imported = LegacyAssistantConversationImporter.load(from: root)
        guard !imported.isEmpty else { return }
        let existingThreads = Set(envelope.sessions.compactMap(\.codexThreadId))
        let additions = imported.filter { conversation in
            guard let thread = conversation.codexThreadId else { return false }
            return !existingThreads.contains(thread)
        }
        guard !additions.isEmpty else { return }

        // Empty drafts are implementation scaffolding, not history. The
        // imported conversation becomes the active session the user sees.
        envelope.sessions.removeAll {
            $0.messages.isEmpty && $0.codexThreadId == nil && $0.turnState == .idle
        }
        envelope.sessions.append(contentsOf: additions)
        envelope.activeSessionId = additions.max { $0.updatedAt < $1.updatedAt }!.id
        pruneLocked()
        vflog("assistant history: imported \(additions.count) pre-store Codex session(s)")
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

/// Imports only rollout files whose first user message carries Voice Flow's
/// exact Assistant preamble. Working directory and timestamps are deliberately
/// not identity signals: unrelated Codex Desktop sessions often share both.
private enum LegacyAssistantConversationImporter {
    private static let marker = "You are the assistant inside Voice Flow, a macOS companion app"
    private static let preambleTerminator = "write the finished content into your reply instead of trying to create files or call external services.\n\n"

    static func load(from root: URL) -> [AssistantConversation] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var conversations: [AssistantConversation] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            if let conversation = parse(file) { conversations.append(conversation) }
        }
        return conversations.sorted { $0.updatedAt < $1.updatedAt }
    }

    private static func parse(_ url: URL) -> AssistantConversation? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var threadId: String?
        var recognized = false
        var messages: [AssistantHistoryMessage] = []
        var assistantParts: [String] = []
        var turnInFlight = false

        for rawLine in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { continue }
            let at = date(object["timestamp"] as? String) ?? Date()
            if type == "session_meta" {
                threadId = payload["id"] as? String
                continue
            }
            guard type == "event_msg", let eventType = payload["type"] as? String else { continue }
            switch eventType {
            case "user_message":
                guard let raw = payload["message"] as? String else { continue }
                if !recognized {
                    guard raw.contains(marker) else { return nil }
                    recognized = true
                }
                flushAssistant(&assistantParts, at: at, into: &messages)
                let text = stripPreamble(from: raw)
                if !text.isEmpty {
                    messages.append(AssistantHistoryMessage(at: at, role: .user, text: text))
                    turnInFlight = true
                }
            case "agent_message":
                if recognized, let text = payload["message"] as? String, !text.isEmpty {
                    assistantParts.append(text)
                }
            case "task_complete":
                guard recognized else { continue }
                if assistantParts.isEmpty,
                   let final = payload["last_agent_message"] as? String, !final.isEmpty {
                    assistantParts.append(final)
                }
                flushAssistant(&assistantParts, at: at, into: &messages)
                turnInFlight = false
            default:
                continue
            }
        }

        guard recognized, let threadId, messages.contains(where: { $0.role == .user }) else { return nil }
        flushAssistant(&assistantParts, at: messages.last?.at ?? Date(), into: &messages)
        if turnInFlight {
            messages.append(AssistantHistoryMessage(
                role: .note,
                text: "Interrupted before Assistant history was enabled — send another message to continue this session."))
        }
        let createdAt = messages.first?.at ?? Date()
        let updatedAt = messages.last?.at ?? createdAt
        let firstUser = messages.first(where: { $0.role == .user })?.text ?? "Recovered assistant"
        return AssistantConversation(
            codexThreadId: threadId,
            createdAt: createdAt,
            updatedAt: updatedAt,
            title: title(from: firstUser),
            turnState: turnInFlight ? .interrupted : .idle,
            messages: messages)
    }

    private static func flushAssistant(_ parts: inout [String], at: Date,
                                       into messages: inout [AssistantHistoryMessage]) {
        guard !parts.isEmpty else { return }
        messages.append(AssistantHistoryMessage(
            at: at, role: .assistant, text: parts.joined(separator: "\n\n")))
        parts.removeAll(keepingCapacity: true)
    }

    private static func stripPreamble(from text: String) -> String {
        guard text.contains(marker) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: preambleTerminator) {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let separator = text.range(of: "\n\n", options: .backwards) else { return "" }
        return String(text[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func title(from text: String) -> String {
        let compact = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return compact.count > 54 ? String(compact.prefix(54)) + "…" : compact
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
