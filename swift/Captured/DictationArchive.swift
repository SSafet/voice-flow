import Foundation

struct DictationImport: Equatable {
    var added: Int
    var skipped: Int
}

/// The append-only `dictations/<yyyy-mm>.jsonl`: one line per stored dictation,
/// one tombstone per removal. Reading folds the lines so the later line for an
/// id wins; the files are only ever appended to.
enum DictationArchive {
    static let directoryName = "dictations"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    private struct Tombstone: Codable {
        var id: String?
        var deleted: Bool?
    }

    static func url(root: URL, month: String) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(month).jsonl")
    }

    /// A dictation's own month, from its `timestamp`, falling back to `time`
    /// and then to the current month.
    static func month(for entry: HistoryEntry) -> String {
        for candidate in [entry.timestamp, entry.time] {
            if let candidate, let month = monthPrefix(candidate) { return month }
        }
        return currentMonth()
    }

    static func append(_ entries: [HistoryEntry], root: URL) throws {
        guard !entries.isEmpty else { return }
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var last: [URL: [String: Data]] = [:]
        for entry in entries {
            let fileURL = url(root: root, month: month(for: entry))
            let key = archiveKey(entry)
            let line = try encoder.encode(entry)
            if last[fileURL] == nil { last[fileURL] = lastLines(at: fileURL) }
            // A line is appended only for an entry that is new or differs from
            // the last line archived for that id.
            if last[fileURL]?[key] == line { continue }
            try appendLine(line, to: fileURL)
            last[fileURL]?[key] = line
        }
    }

    static func appendDeletion(id: String, at: Date, root: URL) throws {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = url(root: root, month: currentMonth(for: at))
        let line = try encoder.encode(Tombstone(id: id, deleted: true))
        if lastLines(at: fileURL)["id:" + id] == line { return }
        try appendLine(line, to: fileURL)
    }

    /// Folded across every month file, newest month first; the later line for
    /// an id wins and a tombstone removes it.
    static func load(root: URL) -> [HistoryEntry] {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let monthFiles = files.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var order: [String] = []
        var folded: [String: HistoryEntry] = [:]
        for fileURL in monthFiles {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                let line = Data(raw.utf8)
                if let tombstone = try? decoder.decode(Tombstone.self, from: line),
                   tombstone.deleted == true, let id = tombstone.id {
                    let key = "id:" + id
                    folded[key] = nil
                    if let index = order.firstIndex(of: key) { order.remove(at: index) }
                    continue
                }
                guard let entry = try? decoder.decode(HistoryEntry.self, from: line) else { continue }
                let key = archiveKey(entry)
                if folded[key] == nil { order.append(key) }
                folded[key] = entry
            }
        }
        return order.compactMap { folded[$0] }
    }

    /// Reads each file once, remembering it in a marker beside the archive, and
    /// adds only what is not already there — by id, or by time and text where
    /// an entry has no id.
    @discardableResult
    static func importOnce(from files: [URL], root: URL) -> DictationImport {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        let markerURL = directory.appendingPathComponent(".imported.json")
        var imported = (try? decoder.decode([String].self, from: Data(contentsOf: markerURL))) ?? []
        let importedSet = Set(imported)
        var keys = Set(load(root: root).map(archiveKey))
        var added = 0
        var skipped = 0
        var processed: [String] = []
        for fileURL in files {
            let path = fileURL.standardizedFileURL.path
            guard !importedSet.contains(path) else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let entries = try? decoder.decode([HistoryEntry].self, from: data) else { continue }
            var fresh: [HistoryEntry] = []
            for entry in entries {
                let key = archiveKey(entry)
                if keys.contains(key) { skipped += 1; continue }
                keys.insert(key)
                fresh.append(entry)
                added += 1
            }
            if !fresh.isEmpty { try? append(fresh, root: root) }
            processed.append(path)
        }
        if !processed.isEmpty {
            imported.append(contentsOf: processed)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? encoder.encode(imported) {
                try? data.write(to: markerURL, options: .atomic)
            }
        }
        return DictationImport(added: added, skipped: skipped)
    }

    private static func archiveKey(_ entry: HistoryEntry) -> String {
        if let id = entry.id, !id.isEmpty { return "id:" + id }
        return "text:" + entry.time + "\u{1}" + entry.text
    }

    private static func monthPrefix(_ value: String) -> String? {
        guard value.count >= 7 else { return nil }
        let prefix = String(value.prefix(7))
        guard prefix.range(of: "^\\d{4}-\\d{2}$", options: .regularExpression) != nil else { return nil }
        return prefix
    }

    private static func currentMonth(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private static func lastLines(at fileURL: URL) -> [String: Data] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        var result: [String: Data] = [:]
        for raw in text.split(separator: "\n") {
            let line = Data(raw.utf8)
            if let tombstone = try? decoder.decode(Tombstone.self, from: line),
               tombstone.deleted == true, let id = tombstone.id {
                result["id:" + id] = line
            } else if let entry = try? decoder.decode(HistoryEntry.self, from: line) {
                result[archiveKey(entry)] = line
            }
        }
        return result
    }

    private static func appendLine(_ line: Data, to fileURL: URL) throws {
        var payload = line
        payload.append(contentsOf: Data("\n".utf8))
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(to: fileURL, options: .atomic)
        }
    }
}
