import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Watcher lines into spans and frames
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  A span is a run of consecutive lines with the same application, window
//  title and address. It ends on a change of any of them, on a pause, resume
//  or watcher_stop line, at the day boundary, and on a gap of more than 120
//  seconds between consecutive lines. The cursor of a line file records the
//  byte offset of the start of the span that is still open, so a replay
//  re-reads that span and upserts the same id.

/// One span while it is being read. The id and start byte are fixed when its
/// first line arrives; the end, the line count and the summed input grow as
/// more lines join it.
private struct OpenSpan {
    let id: String
    let startByte: Int
    let app: String?
    let bundleID: String?
    let rawTitle: String?
    let rawURL: String?
    let title: String?
    let url: String?
    let display: String?
    var tStart: Int
    var tEnd: Int
    var lines = 0
    var input: [String: Int] = [:]
    var pauses: [[String: Any]] = []
    var paused = false

    init(day: String, time: String, startByte: Int, app: String?, bundleID: String?,
         rawTitle: String?, rawURL: String?, title: String?, url: String?,
         display: String?, tStart: Int, tEnd: Int) {
        id = CapturedItemID.activity(day: day, time: time)
        self.startByte = startByte
        self.app = app
        self.bundleID = bundleID
        self.rawTitle = rawTitle
        self.rawURL = rawURL
        self.title = title
        self.url = url
        self.display = display
        self.tStart = tStart
        self.tEnd = tEnd
    }

    mutating func mergeInput(_ value: Any?) {
        IngestFile.merge(into: &input, from: value)
    }

    func row() -> CapturedItemRow {
        var row = CapturedItemRow(id: id, kind: .activity, source: .watcher,
                                  tStart: tStart, tEnd: tEnd)
        row.app = app
        row.bundleID = bundleID
        row.title = title
        row.url = url
        row.display = display
        row.imageState = .none
        row.ocrState = .na
        let extra: [String: Any] = ["input": input, "lines": lines, "pauses": pauses]
        row.extraJSON = IngestFile.json(extra)
        return row
    }
}

struct WatcherIngester {
    let index: CapturedIndex
    let root: URL

    @discardableResult
    func ingestDay(_ day: String) throws -> CapturedIngestResult {
        let relative = "watcher/\(day)/activity.jsonl"
        let url = root.appendingPathComponent(relative)
        guard let state = IngestFile.state(url) else {
            throw IngestError.unreadableFile(relative)
        }
        let cursor = try index.cursor(sourcePath: relative)
        let start = cursor?.byteOffset ?? 0
        let data = try Data(contentsOf: url)

        let reader = WatcherSpanReader(index: index, root: root, day: day)
        for line in IngestFile.lines(data, from: start) {
            try reader.consume(line.bytes, offset: line.offset)
        }
        let offset = try reader.finish(data.count)
        let final = IngestFile.state(url) ?? state
        try index.saveCursor(CapturedCursor(sourcePath: relative, byteOffset: offset,
                                            mtime: final.mtime, size: final.size))
        return reader.result
    }

    /// The bus observer's path: one line becomes or extends a span at once,
    /// without a catch-up cursor.
    @discardableResult
    func ingestLive(_ fields: [String: Any], at date: Date) throws -> CapturedIngestResult {
        let epoch = IngestFile.int(fields["e"]) ?? Int(date.timeIntervalSince1970)
        let day = IngestFile.dayString(date)
        let app = fields["app"] as? String
        let bundleID = fields["bundle"] as? String
        let rawTitle = fields["title"] as? String
        let rawURL = fields["url"] as? String
        let secure = fields["secure"] as? Bool ?? false
        let privateFlag = fields["private"] as? Bool ?? false
        let hidden = privateFlag || ContextRules.isPrivate(
            bundleID: bundleID, appName: app, secureInput: secure, incognito: false)
        let title = hidden ? nil : ContextRules.cutWindowTitle(rawTitle)
        let url = hidden ? nil : ContextRules.cleanURL(rawURL)

        var result = CapturedIngestResult(inserted: 0, updated: 0)
        let parent: String
        if let last = try newestActivity(day: day), let app,
           last.app == app, last.title == title, last.url == url,
           epoch >= last.tEnd, epoch - last.tEnd <= 120 {
            var row = last
            row.tEnd = max(last.tEnd, epoch)
            var extra = IngestFile.jsonObject(last.extraJSON)
            extra["lines"] = (IngestFile.int(extra["lines"]) ?? 0) + 1
            var input: [String: Int] = [:]
            IngestFile.merge(into: &input, from: extra["input"])
            IngestFile.merge(into: &input, from: fields["input"])
            extra["input"] = input
            row.extraJSON = IngestFile.json(extra)
            parent = last.id
            result = result.adding(try index.upsert(row))
        } else {
            var span = OpenSpan(day: day, time: IngestFile.timeKey(fields, epoch), startByte: 0,
                                app: app, bundleID: bundleID, rawTitle: rawTitle, rawURL: rawURL,
                                title: title, url: url,
                                display: fields["display"].map { "\($0)" },
                                tStart: epoch, tEnd: epoch)
            span.lines = 1
            span.mergeInput(fields["input"])
            parent = span.id
            result = result.adding(try index.upsert(span.row()))
        }
        if let frame = fields["frame"] as? String {
            result = result.adding(try index.upsert(frameRow(
                day: day, fields: fields, frame: frame, epoch: epoch, parent: parent,
                app: app, bundleID: bundleID, title: title, url: url, hidden: hidden)))
        }
        return result
    }

    // MARK: - Rows and lookups

    private func frameRow(day: String, fields: [String: Any], frame: String, epoch: Int,
                          parent: String, app: String?, bundleID: String?, title: String?,
                          url: String?, hidden: Bool) throws -> CapturedItemRow {
        let path = "watcher/\(day)/\(frame)"
        let exists = FileManager.default.fileExists(
            atPath: root.appendingPathComponent(path).path)
        var row = CapturedItemRow(
            id: CapturedItemID.frame(day: day, time: IngestFile.timeKey(fields, epoch)),
            kind: .frame, source: .watcher, tStart: epoch, tEnd: epoch, parentID: parent)
        row.app = app
        row.bundleID = bundleID
        row.title = title
        row.url = url
        row.display = fields["display"].map { "\($0)" }
        if let geom = fields["geom"] as? [String: Any] {
            row.imgW = IngestFile.int(geom["w"])
            row.imgH = IngestFile.int(geom["h"])
        }
        row.path = path
        row.imageState = exists ? .present : .missing
        row.ocrState = hidden ? .skippedPrivate : .pending
        var extra: [String: Any] = [:]
        if let box = fields["chg"] as? [Int] { extra["chg"] = box }
        if let of = fields["chg_of"] as? [Int] { extra["chg_of"] = of }
        if let blocks = IngestFile.int(fields["chg_blocks"]) { extra["chg_blocks"] = blocks }
        if let percent = IngestFile.int(fields["chg_pct"]) { extra["chg_pct"] = percent }
        row.extraJSON = extra.isEmpty ? nil : IngestFile.json(extra)
        return row
    }

    private func newestActivity(day: String) throws -> CapturedItemRow? {
        let id = try index.pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT id FROM item
                WHERE kind = 'activity' AND id LIKE ?
                ORDER BY t_start DESC LIMIT 1
                """, arguments: ["activity:\(day)%"])
        }
        guard let id else { return nil }
        return try index.item(id: id)
    }
}

/// Reads one day folder's complete lines into spans and frames, keeping the
/// byte offset of the span that is still open.
private final class WatcherSpanReader {
    private let index: CapturedIndex
    private let root: URL
    private let day: String
    private var current: OpenSpan?
    private var pendingPause: String?
    private var openOffset: Int?
    private(set) var result = CapturedIngestResult(inserted: 0, updated: 0)

    init(index: CapturedIndex, root: URL, day: String) {
        self.index = index
        self.root = root
        self.day = day
    }

    func consume(_ bytes: Data, offset: Int) throws {
        currentOffset = offset
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw IngestError.malformedLine("watcher/\(day)/activity.jsonl")
        }
        if let kind = object["kind"] as? String { return try control(kind, object) }
        guard let app = object["app"] as? String else { return }
        try application(object, app: app)
    }

    /// Returns the byte offset the next read must start from: the start of the
    /// span that is still open, or the end of the file when none is.
    func finish(_ end: Int) throws -> Int {
        if let span = current { try finalize(span, open: true) }
        return openOffset ?? end
    }

    private func control(_ kind: String, _ object: [String: Any]) throws {
        switch kind {
        case "pause":
            guard current != nil else { return }
            pendingPause = object["reason"] as? String ?? ""
            current?.paused = true
        case "resume":
            if var span = current, let reason = pendingPause {
                span.pauses.append(["reason": reason,
                                    "seconds": IngestFile.int(object["seconds"]) ?? 0])
                current = span
                try finalize(span, open: false)
            }
            pendingPause = nil
            current = nil
        case "watcher_stop":
            if let span = current { try finalize(span, open: false) }
            pendingPause = nil
            current = nil
        default:
            break
        }
    }

    private func application(_ object: [String: Any], app: String) throws {
        let epoch = IngestFile.int(object["e"]) ?? 0
        let rawTitle = object["title"] as? String
        let rawURL = object["url"] as? String
        let bundleID = object["bundle"] as? String
        let secure = object["secure"] as? Bool ?? false
        let privateFlag = object["private"] as? Bool ?? false
        let hidden = privateFlag || ContextRules.isPrivate(
            bundleID: bundleID, appName: app, secureInput: secure, incognito: false)
        let title = hidden ? nil : ContextRules.cutWindowTitle(rawTitle)
        let url = hidden ? nil : ContextRules.cleanURL(rawURL)

        let startsNew = current.map { span in
            span.paused || span.app != app || span.rawTitle != rawTitle || span.rawURL != rawURL
                || epoch - span.tEnd > 120 || epoch < span.tEnd
        } ?? true
        if startsNew {
            if let span = current { try finalize(span, open: false) }
            current = OpenSpan(day: day, time: IngestFile.timeKey(object, epoch), startByte: currentOffset,
                               app: app, bundleID: bundleID, rawTitle: rawTitle, rawURL: rawURL,
                               title: title, url: url,
                               display: object["display"].map { "\($0)" },
                               tStart: epoch, tEnd: epoch)
        }
        guard var span = current else { return }
        span.tEnd = max(span.tEnd, epoch)
        span.lines += 1
        span.mergeInput(object["input"])
        current = span
        if let frame = object["frame"] as? String {
            result = result.adding(try index.upsert(
                frameRow(object, frame: frame, epoch: epoch, parent: span.id,
                         app: app, bundleID: bundleID, title: title, url: url, hidden: hidden)))
        }
    }

    /// Set by `consume` to the offset of the line being read, so a span that
    /// starts here records where a replay must begin.
    private var currentOffset = 0

    private func finalize(_ span: OpenSpan, open: Bool) throws {
        result = result.adding(try index.upsert(span.row()))
        if open { openOffset = span.startByte }
    }

    private func frameRow(_ fields: [String: Any], frame: String, epoch: Int, parent: String,
                          app: String?, bundleID: String?, title: String?, url: String?,
                          hidden: Bool) throws -> CapturedItemRow {
        let path = "watcher/\(day)/\(frame)"
        let exists = FileManager.default.fileExists(
            atPath: root.appendingPathComponent(path).path)
        var row = CapturedItemRow(
            id: CapturedItemID.frame(day: day, time: IngestFile.timeKey(fields, epoch)),
            kind: .frame, source: .watcher, tStart: epoch, tEnd: epoch, parentID: parent)
        row.app = app
        row.bundleID = bundleID
        row.title = title
        row.url = url
        row.display = fields["display"].map { "\($0)" }
        if let geom = fields["geom"] as? [String: Any] {
            row.imgW = IngestFile.int(geom["w"])
            row.imgH = IngestFile.int(geom["h"])
        }
        row.path = path
        row.imageState = exists ? .present : .missing
        row.ocrState = hidden ? .skippedPrivate : .pending
        var extra: [String: Any] = [:]
        if let box = fields["chg"] as? [Int] { extra["chg"] = box }
        if let of = fields["chg_of"] as? [Int] { extra["chg_of"] = of }
        if let blocks = IngestFile.int(fields["chg_blocks"]) { extra["chg_blocks"] = blocks }
        if let percent = IngestFile.int(fields["chg_pct"]) { extra["chg_pct"] = percent }
        row.extraJSON = extra.isEmpty ? nil : IngestFile.json(extra)
        return row
    }
}
