import Foundation

/// Edits the same file consumed by NextQueue. Each action checks the bytes
/// the user saw; malformed or externally changed data is never replaced.
final class QueueEditorStore {
    struct Item: Equatable { let text: String; let done: Bool }
    enum EditError: LocalizedError {
        case malformed, changed, empty
        var errorDescription: String? {
            switch self {
            case .malformed: return "The queue file could not be read. Fix its format, then reload."
            case .changed: return "The queue changed elsewhere. The list has been refreshed; try again."
            case .empty: return "Enter an item first."
            }
        }
    }
    let url: URL
    private var revision: Data?
    private var loaded = false
    private var root: [String: Any] = [:]
    private var rows: [[String: Any]] = []
    var items: [Item] { rows.map { Item(text: $0["text"] as! String, done: $0["done"] as? Bool ?? false) } }

    init(url: URL) { self.url = url }

    private func read() throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    @discardableResult
    func reload() throws -> Bool {
        let bytes = try read()
        if loaded, bytes == revision { return false }
        var document: [String: Any] = [:]
        var parsedRows: [[String: Any]] = []
        if let bytes {
            let parsed = try JSONSerialization.jsonObject(with: bytes)
            document = parsed as? [String: Any] ?? [:]
            guard let raw = (document["items"] as? [Any]) ?? (parsed as? [Any]) else { throw EditError.malformed }
            for value in raw {
                var row = (value as? [String: Any]) ?? [:]
                if let text = value as? String { row["text"] = text }
                guard let text = row["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditError.malformed }
                parsedRows.append(row)
            }
        }
        root = document; rows = parsedRows; revision = bytes; loaded = true
        return true
    }

    func add(_ text: String) throws {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw EditError.empty }
        try mutate { $0.append(["id": UUID().uuidString.lowercased(), "text": cleaned, "done": false]) }
    }

    func remove(at index: Int) throws {
        try mutate {
            guard $0.indices.contains(index) else { throw EditError.changed }
            $0.remove(at: index)
        }
    }

    /// Destination is an insertion gap in the original list (0...count).
    func move(from source: Int, to destination: Int) throws {
        try mutate {
            guard $0.indices.contains(source), (0...$0.count).contains(destination) else {
                throw EditError.changed
            }
            let item = $0.remove(at: source)
            $0.insert(item, at: destination > source ? destination - 1 : destination)
        }
    }

    private func mutate(_ edit: (inout [[String: Any]]) throws -> Void) throws {
        guard loaded, try read() == revision else { throw EditError.changed }
        var updated = rows
        try edit(&updated)
        var document = root
        document["items"] = updated
        let bytes = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        root = document; rows = updated; revision = bytes
    }
}
