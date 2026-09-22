import Foundation
import GRDB

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  The six ingesters — catch-up and live
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Every captured stream reaches the one index, reading the files where they
//  already are. Each reader runs in two modes: catch-up, which reads what it
//  has not read yet, newest day first, tracked per file by byte offset; and
//  live, which the recorder calls the moment it writes. Both write through one
//  upsert, and the ids are derived from where the thing lives, so reading the
//  same bytes twice can only ever produce the same rows.

/// How far the derived index has got. `building` until the plan is empty, then
/// `ready`; `rebuilding` is what a caller shows while a moved schema version
/// drops the tables and reads the sources again.
enum CapturedIndexState: String, Equatable {
    case building, ready, rebuilding
}

/// The status line the Captures area shows: how many watcher day folders have
/// been read, out of how many there are.
struct CapturedProgress: Equatable {
    var state: CapturedIndexState
    var daysDone: Int
    var daysTotal: Int
}

/// One unit of catch-up work: which reader, and which file or folder it owns.
/// Every `key` is relative to the data folder (a day folder name for the
/// watcher) and every path behind it is derived from `root`.
struct CapturedIngestStep: Equatable {
    let source: String
    let key: String
}

/// What one reader did, so a caller can tell progress without a second query.
struct CapturedIngestResult: Equatable {
    let inserted: Int
    let updated: Int

    func adding(_ outcome: CapturedUpsert) -> CapturedIngestResult {
        switch outcome {
        case .inserted: return CapturedIngestResult(inserted: inserted + 1, updated: updated)
        case .updated: return CapturedIngestResult(inserted: inserted, updated: updated + 1)
        }
    }

    func merging(_ other: CapturedIngestResult) -> CapturedIngestResult {
        CapturedIngestResult(inserted: inserted + other.inserted, updated: updated + other.updated)
    }
}

/// Every refusal a reader makes by name, so a caller can report it instead of
/// reading a filesystem or decoder message.
enum IngestError: Error, Equatable {
    case unknownSource(String)
    case unreadableFile(String)
    case malformedLine(String)
}

/// The context a picture takes from the activity span it was taken inside
/// (07 §3.4). A day with no watcher data simply has no join.
struct WatcherJoin: Equatable {
    let app: String?
    let bundleID: String?
    let title: String?
    let url: String?
    let isPrivate: Bool
}

/// Shared file work for the six readers: paths relative to the data folder, a
/// file's size and modification time, and the complete lines of a byte range.
/// A last line without its newline is never returned, so a half-written line is
/// never consumed.
enum IngestFile {
    static func relativePath(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path != base else { return "" }
        guard path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }

    static func resolve(_ relative: String, root: URL) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !parts.contains(".."), !parts.contains("."), !parts.contains("")
        else { throw IngestError.unreadableFile(relative) }
        let url = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else { throw IngestError.unreadableFile(relative) }
        return url
    }

    static func state(_ url: URL) -> (size: Int, mtime: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attributes[.modificationDate] as? Date)
            .map { Int($0.timeIntervalSince1970 * 1_000_000) } ?? 0
        return (size, mtime)
    }

    /// Every line that ends with a newline, with the byte offset of its first
    /// byte. A trailing fragment without a newline is left for a later read.
    static func lines(_ data: Data, from start: Int) -> [(offset: Int, bytes: Data)] {
        var result: [(offset: Int, bytes: Data)] = []
        var lineStart = start
        var index = start
        while index < data.count {
            if data[index] == 0x0A {
                result.append((lineStart, data.subdata(in: lineStart..<index)))
                lineStart = index + 1
            }
            index += 1
        }
        return result
    }

    static func int(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        return nil
    }

    static func double(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? NSNumber { return value.doubleValue }
        return nil
    }

    static func merge(into input: inout [String: Int], from value: Any?) {
        guard let dictionary = value as? [String: Any] else { return }
        for (key, raw) in dictionary {
            if let number = int(raw) { input[key, default: 0] += number }
        }
    }

    static func jsonObject(_ json: String?) -> [String: Any] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The `activity:<day>T<time>` tail of an id, from the line's own clock
    /// field or, when it has none, from its moment in local time.
    static func timeKey(_ fields: [String: Any], _ epoch: Int) -> String {
        if let clock = fields["t"] as? String, !clock.isEmpty {
            return clock.replacingOccurrences(of: ":", with: "-")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH-mm-ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func epoch(_ day: String, _ time: String) -> Int? {
        let days = day.split(separator: "-").compactMap { Int($0) }
        let clock = time.split(separator: "-").compactMap { Int($0) }
        guard days.count == 3, clock.count >= 3 else { return nil }
        var components = DateComponents()
        components.year = days[0]; components.month = days[1]; components.day = days[2]
        components.hour = clock[0]; components.minute = clock[1]; components.second = clock[2]
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return nil }
        return Int(date.timeIntervalSince1970)
    }

    static func isoEpoch(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return Int(date.timeIntervalSince1970) }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return Int(date.timeIntervalSince1970) }
        return nil
    }
}

extension CapturedIndex {
    /// True when the stored cursor already describes this file's bytes, so the
    /// plan can leave a file that did not move alone.
    func covers(sourcePath: String, size: Int, mtime: Int) throws -> Bool {
        guard let cursor = try cursor(sourcePath: sourcePath) else { return false }
        return cursor.size == size && cursor.mtime == mtime
    }

    /// The activity span a picture was taken inside, if the watcher was
    /// running then. The reader applies this after the watcher days are in, so
    /// a join always sees the spans it belongs to.
    func watcherContext(at time: Int) throws -> WatcherJoin? {
        let id = try read { db in
            try String.fetchOne(db, sql: """
                SELECT id FROM item
                WHERE kind = 'activity' AND t_start <= ? AND t_end >= ?
                ORDER BY t_start DESC LIMIT 1
                """, arguments: [time, time])
        }
        guard let id, let row = try item(id: id) else { return nil }
        return WatcherJoin(app: row.app, bundleID: row.bundleID, title: row.title, url: row.url,
                           isPrivate: IngestFile.jsonObject(row.extraJSON)["private"] as? Bool ?? false)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  The plan and its cursors
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class CapturedIngest {
    private let index: CapturedIndex
    private let root: URL
    private let lock = NSRecursiveLock()
    private var cached = CapturedProgress(state: .building, daysDone: 0, daysTotal: 0)

    init(index: CapturedIndex, root: URL) {
        self.index = index
        self.root = root
    }

    var progress: CapturedProgress { lock.withLock { cached } }

    /// The watcher's day folders newest first, then the bundle, shot,
    /// dictation, review and recording steps. A file whose cursor covers it
    /// unchanged is not planned; a file that grew or changed is planned again
    /// from its cursor.
    func plan() throws -> [CapturedIngestStep] {
        lock.lock(); defer { lock.unlock() }
        var steps: [CapturedIngestStep] = []
        let files = FileManager.default

        let watcherDir = root.appendingPathComponent("watcher", isDirectory: true)
        let days = watcherDays()
        for day in days {
            let url = watcherDir.appendingPathComponent(day).appendingPathComponent("activity.jsonl")
            if try shouldRead(url) {
                steps.append(CapturedIngestStep(source: "watcher", key: day))
            }
        }

        let capturesDir = root.appendingPathComponent("captures", isDirectory: true)
        for bundle in names(in: capturesDir).sorted() where bundle != "shots" {
            let url = capturesDir.appendingPathComponent(bundle).appendingPathComponent("meta.json")
            guard files.fileExists(atPath: url.path) else { continue }
            if try shouldRead(url) {
                steps.append(CapturedIngestStep(source: "bundle", key: bundle))
            }
        }

        let shotsDir = capturesDir.appendingPathComponent("shots", isDirectory: true)
        for shot in names(in: shotsDir).filter(isShotFile).sorted() {
            if try shouldRead(shotsDir.appendingPathComponent(shot)) {
                steps.append(CapturedIngestStep(source: "shot", key: shot))
            }
        }

        let recentDictations = root.appendingPathComponent("dictations.json")
        if FileManager.default.fileExists(atPath: recentDictations.path), try shouldRead(recentDictations) {
            steps.append(CapturedIngestStep(source: "dictation", key: "dictations.json"))
        }
        let dictationsDir = root.appendingPathComponent("dictations", isDirectory: true)
        for archive in names(in: dictationsDir).filter({ $0.hasSuffix(".jsonl") }).sorted() {
            if try shouldRead(dictationsDir.appendingPathComponent(archive)) {
                steps.append(CapturedIngestStep(source: "dictation", key: archive))
            }
        }

        let reviewsDir = watcherDir.appendingPathComponent("reviews", isDirectory: true)
        for review in names(in: reviewsDir).filter({ $0.hasSuffix(".md") }).sorted() {
            if try shouldRead(reviewsDir.appendingPathComponent(review)) {
                steps.append(CapturedIngestStep(source: "review", key: review))
            }
        }
        let ledger = watcherDir.appendingPathComponent("ledger.md")
        if files.fileExists(atPath: ledger.path), try shouldRead(ledger) {
            steps.append(CapturedIngestStep(source: "review", key: "ledger.md"))
        }

        let audioDir = root.appendingPathComponent("pending-audio", isDirectory: true)
        for recording in names(in: audioDir).filter({ $0.hasSuffix(".wav") }).sorted() {
            if try shouldRead(audioDir.appendingPathComponent(recording)) {
                steps.append(CapturedIngestStep(source: "recording", key: recording))
            }
        }

        let remainingDays = steps.filter { $0.source == "watcher" }.count
        cached = CapturedProgress(
            state: steps.isEmpty ? .ready : .building,
            daysDone: max(0, days.count - remainingDays),
            daysTotal: days.count)
        return steps
    }

    /// Runs the next step and answers whether anything is left. Progress rises
    /// one watcher day at a time, and the state turns ready only when the plan
    /// is empty.
    @discardableResult
    func catchUpStep() throws -> Bool {
        let steps = try plan()
        guard let next = steps.first else { return false }
        _ = try run(next)
        return try !plan().isEmpty
    }

    @discardableResult
    func run(_ step: CapturedIngestStep) throws -> CapturedIngestResult {
        try index.transaction { transaction in
            try CapturedIngest(index: transaction, root: root).runInTransaction(step)
        }
    }

    private func runInTransaction(_ step: CapturedIngestStep) throws -> CapturedIngestResult {
        switch step.source {
        case "watcher":
            return try WatcherIngester(index: index, root: root).ingestDay(step.key)
        case "bundle":
            return try BundleIngester(index: index, root: root).ingest(id: step.key)
        case "shot":
            return try ShotIngester(index: index, root: root).ingest(fileName: step.key)
        case "dictation":
            return try DictationIngester(index: index, root: root).ingest(fileName: step.key)
        case "review":
            return try ReviewIngester(index: index, root: root).ingest(fileName: step.key)
        case "recording":
            return try RecordingIngester(index: index, root: root).ingest(fileName: step.key)
        default:
            throw IngestError.unknownSource(step.source)
        }
    }

    func ingestWatcherLine(_ fields: [String: Any], at date: Date) throws {
        _ = try run(CapturedIngestStep(source: "watcher", key: IngestFile.dayString(date)))
    }

    func ingestBundle(id: String) throws {
        _ = try run(CapturedIngestStep(source: "bundle", key: id))
    }

    func ingestShot(fileName: String) throws {
        _ = try run(CapturedIngestStep(source: "shot", key: fileName))
    }

    func ingestDictation(_ entry: HistoryEntry) throws {
        _ = try DictationIngester(index: index, root: root).ingest(entry)
    }

    // MARK: - Filesystem helpers

    /// Day folders carry a `yyyy-MM-dd` name and an `activity.jsonl`; that is
    /// what the progress line counts.
    private func watcherDays() -> [String] {
        let watcherDir = root.appendingPathComponent("watcher", isDirectory: true)
        return names(in: watcherDir).filter { name in
            guard name.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil
            else { return false }
            let line = watcherDir.appendingPathComponent(name).appendingPathComponent("activity.jsonl")
            return FileManager.default.fileExists(atPath: line.path)
        }.sorted { $0 > $1 }
    }

    private func names(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
    }

    private func isShotFile(_ name: String) -> Bool {
        guard name.hasSuffix(".jpg"), !name.hasSuffix(".clean.jpg") else { return false }
        return name.hasPrefix("shot-") || name.hasPrefix("pasted-")
    }

    private func shouldRead(_ url: URL) throws -> Bool {
        guard let state = IngestFile.state(url) else { return false }
        return try !index.covers(sourcePath: IngestFile.relativePath(url, root: root),
                                 size: state.size, mtime: state.mtime)
    }
}
