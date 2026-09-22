import Foundation

struct DictationImport: Equatable {
    var added: Int
    var skipped: Int
    var failures: [String] = []
}

/// The append-only `dictations/<yyyy-mm>.jsonl`: one line per stored dictation,
/// one tombstone per removal. Reading folds the lines so the later line for an
/// id wins; the files are only ever appended to.
enum DictationArchive {
    static let directoryName = "dictations"
    private static let lock = NSRecursiveLock()

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
        lock.lock(); defer { lock.unlock() }
        guard !entries.isEmpty else { return }
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var last: [URL: [String: Data]] = [:]
        let locations = archiveLocations(root: root)
        for entry in entries {
            let fileURL = locations[archiveKey(entry)] ?? url(root: root, month: month(for: entry))
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
        lock.lock(); defer { lock.unlock() }
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = archiveLocations(root: root)["id:" + id] ?? url(root: root, month: currentMonth(for: at))
        let line = try encoder.encode(Tombstone(id: id, deleted: true))
        if lastLines(at: fileURL)["id:" + id] == line { return }
        try appendLine(line, to: fileURL)
    }

    /// Folded across every month file, newest month first; the later line for
    /// an id wins and a tombstone removes it.
    static func load(root: URL) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let monthFiles = files.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
        return order.compactMap { folded[$0] }.sorted { ($0.timestamp ?? $0.time) > ($1.timestamp ?? $1.time) }
    }

    /// Reads each file once, remembering it in a marker beside the archive, and
    /// adds only what is not already there — by id, or by time and text where
    /// an entry has no id.
    @discardableResult
    static func importOnce(from files: [URL], root: URL) -> DictationImport {
        lock.lock(); defer { lock.unlock() }
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        let markerURL = directory.appendingPathComponent(".imported.json")
        var imported = (try? decoder.decode([String].self, from: Data(contentsOf: markerURL))) ?? []
        let importedSet = Set(imported)
        let existing = load(root: root)
        var keys = Set(existing.map(archiveKey))
        // Historical IDs include tombstones: finding another old backup is
        // not permission to recreate something the user already removed.
        keys.formUnion(archiveLocations(root: root).keys)
        var semanticKeys = Set(historicalEntries(root: root).map { ($0.timestamp ?? $0.time) + "\u{1}" + $0.text })
        var added = 0
        var skipped = 0
        var processed: [String] = []
        var failures: [String] = []
        for fileURL in files {
            let path = fileURL.standardizedFileURL.path
            guard !importedSet.contains(path) else { continue }
            let entries: [HistoryEntry]
            do { entries = try importEntries(fileURL) }
            catch { failures.append("\(path): \(error)"); continue }
            var fresh: [HistoryEntry] = []
            var candidateKeys = keys
            for entry in entries {
                let key = archiveKey(entry)
                let semanticKey = (entry.timestamp ?? entry.time) + "\u{1}" + entry.text
                if candidateKeys.contains(key) || ((entry.id?.isEmpty ?? true) && semanticKeys.contains(semanticKey)) { skipped += 1; continue }
                candidateKeys.insert(key)
                fresh.append(entry)
            }
            do {
                try append(fresh, root: root)
                added += fresh.count
                keys = candidateKeys
                semanticKeys.formUnion(fresh.map { ($0.timestamp ?? $0.time) + "\u{1}" + $0.text })
                processed.append(path)
            } catch {
                failures.append("\(path): \(error)")
            }
        }
        if !processed.isEmpty {
            imported.append(contentsOf: processed)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? encoder.encode(imported) {
                try? data.write(to: markerURL, options: .atomic)
            }
        }
        return DictationImport(added: added, skipped: skipped, failures: failures)
    }

    private static func archiveKey(_ entry: HistoryEntry) -> String {
        "id:" + entry.archiveIdentity
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

    // Minimal read-only adapter for SourceCollector's actual snapshot format.
    // Whole files are read; the short preview is never substituted for speech.
    private struct Snapshot: Decodable {
        var sourceID: String
        var items: [Item]
        struct Item: Decodable { var title: String; var relativePath: String }
    }
    private static func importEntries(_ file: URL) throws -> [HistoryEntry] {
        let data = try Data(contentsOf: file)
        if let entries = try? decoder.decode([HistoryEntry].self, from: data) { return entries }
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.sourceID == "builtin-dictations" else { throw CocoaError(.fileReadCorruptFile) }
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath()
        return try snapshot.items.map { item in
            let path = folder.appendingPathComponent(item.relativePath).resolvingSymlinksInPath()
            guard path.path.hasPrefix(folder.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let text = try String(contentsOf: path, encoding: .utf8)
            let stamp = item.title.hasPrefix("Dictation · ") ? String(item.title.dropFirst("Dictation · ".count)) : "Date unavailable"
            let dated = stamp.range(of: "^\\d{4}-\\d{2}-\\d{2}T", options: .regularExpression) != nil
            return HistoryEntry(text: text, time: stamp, timestamp: dated ? stamp : nil)
        }
    }

    private static func historicalEntries(root: URL) -> [HistoryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(directoryName), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.flatMap { file -> [HistoryEntry] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                try? decoder.decode(HistoryEntry.self, from: Data($0.utf8))
            }
        }
    }

    private static func archiveLocations(root: URL) -> [String: URL] {
        let directory = root.appendingPathComponent(directoryName)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: URL] = [:]
        for file in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.path < $1.path }) {
            for key in lastLines(at: file).keys { result[key] = file }
        }
        return result
    }

    private static func appendLine(_ line: Data, to fileURL: URL) throws {
        var payload = line
        payload.append(contentsOf: Data("\n".utf8))
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            // Never append into an incomplete record or silently mark its import
            // finished. Preserve the bytes for recovery and report the failure.
            guard try handle.read(upToCount: 1) == Data([0x0A]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        try handle.synchronize()
    }
}
