import Foundation

/// Dedicated cloud DTOs. Local HistoryEntry/runtime/settings encoders and the
/// LAN SyncPayload must never be used as the body of a cloud request.
enum CloudCollection: String, Codable, CaseIterable { case dictations, threads, messages, preferences }
struct CloudExportSelection: Codable, Equatable {
    var dictations = true
    var conversations = true
    var preferences = true
    func includes(_ collection: CloudCollection) -> Bool {
        switch collection { case .dictations: return dictations
        case .threads, .messages: return conversations
        case .preferences: return preferences }
    }
}
enum CloudPreference: Codable, Equatable {
    case text(String), words([String]), enabled(Bool)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .enabled(flag) }
        else if let words = try? value.decode([String].self) { self = .words(words) }
        else { self = .text(try value.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .text(let text): try value.encode(text)
        case .words(let words): try value.encode(words)
        case .enabled(let flag): try value.encode(flag) }
    }
}
struct CloudPayload: Codable, Equatable {
    var text: String?
    var destination: String?
    var createdAt: String?
    var modifiedAt: String?
    var legacyTimestamp: String?
    var captureKind: String?
    var title: String?
    var completedAt: String?
    var assistantName: String?
    var threadId: String?
    var role: String?
    var parentMessageId: String?
    var turnId: String?
    var value: CloudPreference?

    func validate(for collection: CloudCollection, id: String) throws {
        func bounded(_ text: String, _ max: Int) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf16.count <= max, !text.contains("\0") else { throw CloudSyncError.invalidRecord }
        }
        let fields: Set<String>
        switch collection {
        case .dictations:
            fields = ["text", "destination", "createdAt", "modifiedAt", "legacyTimestamp", "captureKind"]
            guard let text, ["pasted", "kept"].contains(destination ?? "") else { throw CloudSyncError.invalidRecord }
            try bounded(text, 60_000)
            if let captureKind, !["dictate", "dictateSnapshot", "continuousCapture", "typed"].contains(captureKind) { throw CloudSyncError.invalidRecord }
        case .threads:
            fields = ["title", "createdAt", "completedAt", "assistantName"]
            guard let title else { throw CloudSyncError.invalidRecord }
            try bounded(title, 500)
        case .messages:
            fields = ["text", "threadId", "role", "parentMessageId", "turnId", "createdAt"]
            guard let text, ["user", "assistant", "note"].contains(role ?? ""),
                  let threadId, CloudWire.validID(threadId) else { throw CloudSyncError.invalidRecord }
            try bounded(text, 60_000)
        case .preferences:
            fields = ["value"]
            switch (id, value) {
            case ("vocabulary", .words(let words)):
                guard words.count <= 512 else { throw CloudSyncError.invalidRecord }
                for word in words { try bounded(word, 200) }
            case ("agent_model", .text(let model)):
                guard model.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,199}$", options: .regularExpression) == model.startIndex..<model.endIndex else { throw CloudSyncError.invalidRecord }
            case ("cleanup_enabled", .enabled): break
            default: throw CloudSyncError.invalidRecord
            }
        }
        let bytes = try JSONEncoder().encode(self)
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        guard Set(object.keys).isSubset(of: fields), bytes.count <= 65_536 else { throw CloudSyncError.invalidRecord }
        for date in [createdAt, modifiedAt, completedAt].compactMap({ $0 }) {
            guard date.utf16.count <= 40, date.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,9})?(?:Z|[+-]\\d{2}:\\d{2})$", options: .regularExpression) == date.startIndex..<date.endIndex,
                  CloudWire.date(date) != nil else { throw CloudSyncError.invalidRecord }
        }
        if let legacyTimestamp { try bounded(legacyTimestamp, 64) }
        if let assistantName { try bounded(assistantName, 200) }
        for reference in [parentMessageId, turnId].compactMap({ $0 }) {
            guard CloudWire.validID(reference) else { throw CloudSyncError.invalidRecord }
        }
    }
}
struct CloudOperation: Codable, Equatable {
    var operationId: String = UUID().uuidString
    var collection: CloudCollection
    var recordId: String
    var baseVersion: String
    var schemaVersion: Int = 1
    var op: String
    var payload: CloudPayload?
    var resolvesConflictId: String?
}
struct CloudRecord: Codable, Equatable {
    var collection: CloudCollection
    var recordId: String
    var version: String
    var schemaVersion: Int
    var payload: CloudPayload?
    var deletedAt: String?
    var seq: String
}
struct CloudConflict: Codable, Equatable {
    var conflictId: String
    var collection: CloudCollection
    var recordId: String
    var baseVersion: String
    var currentVersion: String
    var proposed: CloudOperation
    var reason: String
    var createdAt: String
    var resolvedAt: String?
}
struct CloudChange: Codable {
    var seq: String
    var kind: String
    var record: CloudRecord?
    var conflict: CloudConflict?
    var resolvedConflictId: String?
}
struct CloudReceipt: Codable {
    var operationId: String
    var status: String
    var seq: String
    var record: CloudRecord?
    var conflict: CloudConflict?
}
struct CloudPage: Codable {
    var changes: [CloudChange]
    var nextCursor: String
    var hasMore: Bool
    var highWatermark: String
    var epoch: String
    var serverTime: String
}
struct CloudLocalEdit: Codable {
    var collection: CloudCollection
    var recordId: String
    var payload: CloudPayload?
    var restore: Bool = false
}
enum CloudSyncError: LocalizedError {
    case invalidRecord, storage(String), invalidResponse, signInRequired, updateRequired, insecureOrigin, historyChanged
    case server(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidRecord: return "This record needs review before cloud sync. Your local copy is retained."
        case .storage: return "Cloud sync could not save locally. Your existing files are retained."
        case .invalidResponse: return "The cloud response could not be verified. Changes remain queued."
        case .signInRequired: return "Sign in again. Your changes are saved here."
        case .updateRequired: return "Update required. Your changes are saved here."
        case .insecureOrigin: return "Use an HTTPS Atika address with no path or credentials."
        case .historyChanged: return "Cloud history was restored. Review and reload its baseline; local changes are retained."
        case .server(let status, _): return status == 501 ? "Cloud sync is not enabled for this account yet. Changes are saved here." : "Cloud sync is unavailable (\(status)). Changes are saved here."
        }
    }
}
enum CloudWire {
    static func validID(_ id: String) -> Bool {
        id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$", options: .regularExpression) == id.startIndex..<id.endIndex
    }
    static func version(_ value: String) throws -> Int64 {
        guard value.range(of: "^(0|[1-9][0-9]{0,18})$", options: .regularExpression) != nil,
              let number = Int64(value), number >= 0, number < Int64.max else { throw CloudSyncError.invalidResponse }
        return number
    }
    static func timestamp(_ value: Date = Date()) -> String { ISO8601DateFormatter().string(from: value) }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    static func origin(_ input: String, allowLoopback: Bool = false) throws -> String {
        guard let url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (allowLoopback && url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { throw CloudSyncError.insecureOrigin }
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host.lowercased())]" : host.lowercased()
        let port = (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) ? nil : url.port
        return "\(url.scheme!)://\(authority)\(port.map { ":\($0)" } ?? "")"
    }
}
