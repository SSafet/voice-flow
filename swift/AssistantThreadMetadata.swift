import CryptoKit
import Foundation

struct AssistantThreadMetadata: Codable, Equatable {
    let version: Int
    let conversationID: String
    var assistantSlug: String?
    var assistantNameSnapshot: String?
    var assistantOwnerWasInferred: Bool?
    /// Retention mirror for the durable job-to-conversation reference. The
    /// job database remains authoritative; this prevents an older app build
    /// from making an automation conversation eligible for history pruning.
    var automationJobID: String?
    var completedAt: Date?
    var metadataUpdatedAt: Date
    var historyUpdatedAtAtWrite: Date

    init(conversationID: String, assistantSlug: String?,
         assistantNameSnapshot: String?, assistantOwnerWasInferred: Bool? = nil,
         automationJobID: String? = nil,
         completedAt: Date?,
         metadataUpdatedAt: Date = Date(), historyUpdatedAtAtWrite: Date) {
        self.version = 1
        self.conversationID = conversationID
        self.assistantSlug = assistantSlug
        self.assistantNameSnapshot = assistantNameSnapshot
        self.assistantOwnerWasInferred = assistantOwnerWasInferred
        self.automationJobID = automationJobID
        self.completedAt = completedAt
        self.metadataUpdatedAt = metadataUpdatedAt
        self.historyUpdatedAtAtWrite = historyUpdatedAtAtWrite
    }
}

enum AssistantThreadMetadataError: LocalizedError {
    case invalidDocument(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument(let detail): return "Assistant thread metadata is invalid: \(detail)"
        case .write(let detail): return "Assistant thread metadata could not be saved: \(detail)"
        }
    }
}

/// Rollback-surviving owner/archive metadata. An older app build can rewrite
/// assistant-sessions.json without unknown fields, but it does not know or
/// rewrite these versioned per-conversation sidecars.
final class AssistantThreadMetadataStore {
    private let rootURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func metadata(for conversationID: String) -> AssistantThreadMetadata? {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL(for: conversationID)),
                  let document = try? JSONDecoder().decode(AssistantThreadMetadata.self, from: data),
                  document.version == 1,
                  document.conversationID == conversationID else { return nil }
            return document
        }
    }

    func write(_ document: AssistantThreadMetadata) throws {
        try lock.withLock {
            guard document.version == 1, !document.conversationID.isEmpty else {
                throw AssistantThreadMetadataError.invalidDocument("missing conversation identity")
            }
            do {
                try FileManager.default.createDirectory(
                    at: rootURL, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let data = try encoder.encode(document)
                let url = fileURL(for: document.conversationID)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch let error as AssistantThreadMetadataError {
                throw error
            } catch {
                throw AssistantThreadMetadataError.write(error.localizedDescription)
            }
        }
    }

    func remove(_ conversationID: String) {
        lock.withLock {
            try? FileManager.default.removeItem(at: fileURL(for: conversationID))
        }
    }

    func all() -> [AssistantThreadMetadata] {
        lock.withLock {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            return urls.compactMap { url in
                guard url.pathExtension == "json",
                      let data = try? Data(contentsOf: url),
                      let document = try? JSONDecoder().decode(
                        AssistantThreadMetadata.self, from: data),
                      document.version == 1 else { return nil }
                return document
            }
        }
    }

    private func fileURL(for conversationID: String) -> URL {
        let digest = SHA256.hash(data: Data(conversationID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return rootURL.appendingPathComponent("\(digest).json")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
