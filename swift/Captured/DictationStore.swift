import Foundation
import CryptoKit


/// Where a capture went. Stored as data only — the Inbox filter chips are the
/// one place it surfaces; rows never label it (panel redesign, ticket #15).
enum CaptureDestination: String, Codable {
    case pasted      // landed in the frontmost app (classic dictation)
    case kept        // brain dump — recorded into Voice Flow only (ticket #2)
    case assistant   // routed to the in-app assistant
    case session     // routed to a Claude session
}

struct HistoryEntry: Codable {
    var text: String
    var time: String
    /// Full creation date-time for processing cursors. Optional so existing
    /// history continues to decode without rewriting or dropping any fields.
    var timestamp: String?
    /// Stable identity for Continue-append and cross-device sync upserts
    /// (ticket #36). Optional so existing entries keep decoding; assigned
    /// lazily the first time identity is needed.
    var id: String?
    // Optional so pre-redesign dictations.json entries still decode:
    // nil destination = pasted, nil seen = already revisited.
    var destination: CaptureDestination?
    var seen: Bool?
    /// Optional so existing dictations.json and mobile records keep decoding.
    /// Local paths are intentionally not synced to Android.
    var capability: CaptureCapability?
    var attachments: [String]?
    var captureId: String?
    /// The device that made this dictation; nil means this Mac.
    var originDevice: String?

    var archiveIdentity: String {
        if let id, !id.isEmpty { return id }
        // Stable across rebuilds and backup imports; never rewrite a source
        // solely so the derived index can identify a legacy dictation.
        let bytes = Data(((timestamp ?? time) + "\u{1}" + text).utf8)
        return "legacy-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    var effectiveDestination: CaptureDestination { destination ?? .pasted }
    /// Only kept items carry unread semantics.
    var isUnrevisited: Bool { effectiveDestination == .kept && seen == false }
}

/// Where dictation history lives: the newest 200 entries in `dictations.json`
/// and every dictation ever stored in the append-only month archive.
///
/// `dictations.json` keeps its historical shape so the record sync keeps
/// reading it; the archive is what the file forgets.
final class DictationStore {
    static let shared = DictationStore(root: VoiceFlowPaths.shared.configRoot)
    static let keepInFile = 200

    private let root: URL
    private let fileURL: URL
    private let lock = NSRecursiveLock()
    private(set) var lastPersistenceError: String?
    private var observers: [([HistoryEntry]) -> Void] = []

    init(root: URL) {
        self.root = root
        fileURL = root.appendingPathComponent("dictations.json")
    }

    /// Newest first, exactly as `dictations.json` stores it.
    func all() -> [HistoryEntry] {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL),
                  var list = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
            // One-time compatibility migration for pre-Continue history. IDs
            // must be durable before sync exports an entry; otherwise Android
            // invents an identity the Mac cannot recognize when the continued
            // text returns.
            var migrated = false
            for index in list.indices where list[index].id?.isEmpty ?? true {
                list[index].id = list[index].archiveIdentity
                migrated = true
            }
            if migrated { _ = save(list) }
            return list
        }
    }

    func recent(limit: Int) -> [HistoryEntry] {
        Array(all().prefix(max(0, limit)))
    }

    /// The one write path: the file, then every observer, then the archive.
    @discardableResult
    func save(_ entries: [HistoryEntry]) -> Bool {
        lock.withLock {
            do {
                // Archive first: failure cannot evict the only remaining copy.
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let prior = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: fileURL))
                    try DictationArchive.append(prior, root: root)
                }
                try DictationArchive.append(entries, root: root)
                try persist(entries)
                lastPersistenceError = nil
                for observer in observers { observer(entries) }
                return true
            } catch {
                lastPersistenceError = String(describing: error)
                return false
            }
        }
    }

    /// Merge one entry into the file and the archive, telling the observers.
    func upsert(_ entry: HistoryEntry) {
        lock.withLock {
            var list = all()
            if let index = list.firstIndex(where: { $0.id != nil && $0.id == entry.id }) {
                list.remove(at: index)
            }
            list.insert(entry, at: 0)
            save(list)
        }
    }

    /// Take the entry out of the file, leaving an append-only tombstone.
    func remove(id: String) {
        lock.withLock {
            let list = all()
            guard list.contains(where: { $0.id == id }) || DictationArchive.load(root: root).contains(where: { $0.id == id }) else { return }
            do {
                try DictationArchive.appendDeletion(id: id, at: Date(), root: root)
                let remaining = list.filter { $0.id != id }
                try persist(remaining)
                lastPersistenceError = nil
                for observer in observers { observer(remaining) }
            } catch { lastPersistenceError = String(describing: error) }
        }
    }

    /// A list: a second observer never unsubscribes the first, so every path
    /// that stores a dictation reaches each of them.
    func addPersistObserver(_ observer: @escaping ([HistoryEntry]) -> Void) {
        lock.withLock { observers.append(observer) }
    }

    private func persist(_ entries: [HistoryEntry]) throws {
        let trimmed = Array(entries.prefix(Self.keepInFile))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(trimmed)
        try data.write(to: fileURL, options: .atomic)
    }
}
