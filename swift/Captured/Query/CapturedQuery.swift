import Foundation
import GRDB

/// One read implementation for the shared client and the tool host. The host
/// supplies its existing observe decision; the default refuses access.
struct CapturedQuery {
    let index: CapturedIndex
    let root: URL
    var timeZone: TimeZone
    var indexProgress: () -> CapturedProgress
    var mayRead: () -> Bool

    init(index: CapturedIndex, root: URL, timeZone: TimeZone = .current,
         indexProgress: @escaping () -> CapturedProgress = { .init(state: .ready, daysDone: 0, daysTotal: 0) },
         mayRead: @escaping () -> Bool = { false }) {
        self.index = index; self.root = root; self.timeZone = timeZone
        self.indexProgress = indexProgress; self.mayRead = mayRead
    }
    func checkReady() throws {
        try Task.checkCancellation()
        guard mayRead() else { throw CapturedQueryFailure(.permissionDenied, "Captured data requires observe access on this device.") }
        let progress = indexProgress()
        guard progress.state == .ready else {
            throw CapturedQueryFailure(.indexBuilding, "The captured index is being prepared.", progress: progress)
        }
    }
    func stamp(_ value: Int) -> String { CapturedTime.localString(Date(timeIntervalSince1970: Double(value)), in: timeZone) }
    func epoch(_ text: String) throws -> Int { Int(try CapturedTime.parse(text, in: timeZone).timeIntervalSince1970) }
    func range(_ from: String, _ to: String, maxSeconds: Int) throws -> (Int, Int) {
        let a = try epoch(from), b = try epoch(to)
        guard b > a else { throw CapturedQueryFailure(.invalidArguments, "The end must be later than the start.") }
        guard b - a <= maxSeconds else { throw CapturedQueryFailure(.rangeTooLong, "Choose a narrower time range.") }
        return (a, b)
    }
    func rows(_ db: Database, where condition: String = "1", args: [DatabaseValue] = [],
              order: String = "item.t_start, item.id", limit: Int? = nil) throws -> [CapturedItemRow] {
        try Row.fetchAll(db, sql: CapturedReadPolicy.visibleCTE + " SELECT item.* FROM visible item WHERE \(condition) ORDER BY \(order)" + (limit.map { " LIMIT \($0)" } ?? ""),
                         arguments: StatementArguments(args)).map(CapturedIndex.makeRow)
    }
    func row(_ db: Database, id: String) throws -> CapturedItemRow {
        guard CapturedItemID.isValid(id), let row = try rows(db, where: "id = ?", args: [id.databaseValue], limit: 1).first else {
            // Private rows are indistinguishable from absent ones, including for direct ids.
            throw CapturedQueryFailure(.notFound, "The captured item was not found.")
        }
        return row
    }
    func duration(_ row: CapturedItemRow) -> Int? {
        if row.kind == .activity { return row.tEnd - row.tStart }
        if row.kind == .capture { return (CapturedReadPolicy.object(row.extraJSON)["durationSeconds"] as? NSNumber)?.intValue ?? (row.tEnd - row.tStart) }
        return nil
    }
    func children(_ db: Database, _ row: CapturedItemRow, limit: Int) throws -> [CapturedItemRow] {
        try rows(db, where: "parent_id = ?", args: [row.id.databaseValue], limit: limit)
    }
    func links(_ db: Database, _ id: String, limit: Int = 100) throws -> [TPCapturedLink] {
        try Row.fetchAll(db, sql: "SELECT DISTINCT thread_id, turn_id, role FROM link WHERE item_id = ? ORDER BY at, thread_id, turn_id LIMIT ?",
                        arguments: [id, limit]).compactMap { link in
            guard let role = TPLinkRole(rawValue: link["role"]) else { return nil }
            return TPCapturedLink(role: role, threadID: CapturedReadPolicy.text(link["thread_id"])!, turnID: CapturedReadPolicy.text(link["turn_id"])!)
        }
    }
    func hit(_ db: Database, _ row: CapturedItemRow, words: String? = nil, sameSpan: Int? = nil) throws -> TPCapturedHit {
        let container = row.kind == .activity || row.kind == .capture
        let total = container ? (try Int.fetchOne(db, sql: CapturedReadPolicy.visibleCTE + " SELECT count(*) FROM visible WHERE parent_id = ? AND kind = 'frame'", arguments: [row.id]) ?? 0) : 0
        let previews: [String]
        if row.kind == .frame || row.kind == .shot { previews = [row.id] }
        else if row.kind == .capture && total > 0 {
            previews = try Array(Set([0, total / 2, total - 1])).sorted().compactMap { offset in
                try String.fetchOne(db, sql: CapturedReadPolicy.visibleCTE + " SELECT id FROM visible WHERE parent_id = ? AND kind = 'frame' ORDER BY t_start, id LIMIT 1 OFFSET ?", arguments: [row.id, offset])
            }
        } else {
            previews = try rows(db, where: "parent_id = ? AND kind = 'frame'", args: [row.id.databaseValue], limit: 3).map(\.id)
        }
        let extra = CapturedReadPolicy.object(row.extraJSON)
        let marks = decode([TPMark].self, row.marksJSON) ?? []
        return TPCapturedHit(app: CapturedReadPolicy.text(row.app), at: stamp(row.tStart),
            destination: (extra["destination"] as? String).flatMap(TPDictationDestination.init(rawValue:)),
            durationSeconds: duration(row), frameCount: total > 0 ? total : nil, hasPicture: row.path != nil,
            id: row.id, kind: TPCapturedKind(rawValue: row.kind.rawValue)!, markCount: marks.isEmpty ? nil : marks.count,
            originDevice: CapturedReadPolicy.text(row.originDevice), parent: row.parentID, previewIDS: previews,
            sameSpanMatches: sameSpan, snippet: snippet(row.body ?? row.ocr ?? row.title ?? "", words: words),
            threadIDS: Array(Set(try links(db, row.id).map(\.threadID))).sorted().prefix(3).map { $0 },
            title: CapturedReadPolicy.title(row.title), url: CapturedReadPolicy.url(row.url))
    }
    func search(_ input: TPCapturedSearchInput, limits: CapturedLimits) throws -> TPCapturedSearchOutput {
        try checkReady()
        let count = try CapturedReadPolicy.positive(input.limit, default: 10, maximum: limits.searchHits)
        let offset: Int
        if let cursor = input.cursor {
            guard cursor.range(of: #"^c_[0-9]{1,9}$"#, options: .regularExpression) != nil,
                  let value = Int(cursor.dropFirst(2)) else { throw CapturedQueryFailure(.invalidArguments, "The search cursor is invalid.") }
            offset = value
        } else { offset = 0 }
        let apps = try CapturedReadPolicy.appFilter(input.apps)
        var terms = ["(\(apps.0))"]; var args = apps.1
        let from = try input.from.map(epoch), to = try input.to.map(epoch)
        if let from, let to, to <= from { throw CapturedQueryFailure(.invalidArguments, "The end must be later than the start.") }
        if let from { terms.append("item.t_start >= ?"); args.append(from.databaseValue) }
        if let to { terms.append("item.t_start < ?"); args.append(to.databaseValue) }
        if let kinds = input.kinds {
            guard !kinds.isEmpty else { throw CapturedQueryFailure(.invalidArguments, "Specify at least one captured kind.") }
            terms.append("item.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))")
            args += kinds.map { $0.rawValue.databaseValue }
        }
        if let thread = input.threadID {
            guard !thread.isEmpty && thread.count <= 256 else { throw CapturedQueryFailure(.invalidArguments, "The thread id is invalid.") }
            terms.append("EXISTS (SELECT 1 FROM link WHERE link.item_id = item.id AND link.thread_id = ?)"); args.append(thread.databaseValue)
        }
        let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text?.count ?? 0 <= 2_000 else { throw CapturedQueryFailure(.invalidArguments, "Search text is limited to 2,000 characters.") }
        let words = text.flatMap { $0.isEmpty ? nil : $0 }
        return try index.read { db in
            var sql: String
            if let words {
                guard let pattern = FTS5Pattern(matchingAllPrefixesIn: words) else {
                    return TPCapturedSearchOutput(hits: [], nextCursor: nil, notice: CapturedReadPolicy.notice, ok: true, truncated: false)
                }
                terms.append("item_fts MATCH ?"); args.append(pattern.rawPattern.databaseValue)
                sql = CapturedReadPolicy.visibleCTE + """
                , matched AS MATERIALIZED (
                  SELECT item.*, bm25(item_fts, 1, 1, 2, 1, 1) AS relevance,
                    CASE WHEN item.kind = 'frame' AND item.parent_id LIKE 'activity:%' THEN item.parent_id ELSE item.id END AS bucket
                  FROM item_fts JOIN visible item ON item.rowid = item_fts.rowid
                  WHERE \(terms.joined(separator: " AND "))
                ), ranked AS (
                  SELECT *, row_number() OVER (PARTITION BY bucket ORDER BY relevance, t_start DESC, id) AS ordinal,
                    count(*) OVER (PARTITION BY bucket) AS siblings FROM matched
                ) SELECT * FROM ranked WHERE ordinal = 1 ORDER BY relevance, t_start DESC, id LIMIT ? OFFSET ?
                """
            } else {
                sql = CapturedReadPolicy.visibleCTE + " SELECT item.*, 1 AS siblings FROM visible item WHERE \(terms.joined(separator: " AND ")) ORDER BY t_start DESC, id LIMIT ? OFFSET ?"
            }
            let fetched = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args + [(count + 1).databaseValue, offset.databaseValue]))
            var hits = try fetched.prefix(count).map { try hit(db, CapturedIndex.makeRow($0), words: words, sameSpan: words == nil ? nil : $0["siblings"]) }
            var more = fetched.count > hits.count
            while true {
                let result = TPCapturedSearchOutput(hits: hits, nextCursor: more ? "c_\(offset + hits.count)" : nil, notice: CapturedReadPolicy.notice, ok: true, truncated: more)
                if try CapturedReadPolicy.fits(result, limits) { return result }
                guard !hits.isEmpty else { throw CapturedQueryFailure(.invalidArguments, "The result byte limit is too small.") }
                hits.removeLast(); more = true
                if hits.isEmpty { throw CapturedQueryFailure(.invalidArguments, "A hit cannot fit the result byte limit.") }
            }
        }
    }
    func get(_ input: TPCapturedGetInput, limits: CapturedLimits, includePath: Bool) throws -> TPCapturedGetOutput {
        try checkReady()
        guard (input.textOffset ?? 0) >= 0 else { throw CapturedQueryFailure(.invalidArguments, "textOffset must be zero or greater.") }
        try CapturedFiles.validateRegion(input.region)
        return try index.read { db in
            let source = try row(db, id: input.id)
            let kids = try children(db, source, limit: limits.children + 1)
            var childValues = kids.prefix(limits.children).map { child in
                TPCapturedChild(app: CapturedReadPolicy.text(child.app), at: stamp(child.tStart), elapsedSeconds: child.tStart - (kids.first?.tStart ?? child.tStart), id: child.id, title: CapturedReadPolicy.title(child.title))
            }
            var markValues = (decode([TPMark].self, source.marksJSON) ?? []).map { mark in
                TPMark(box: mark.box, center: mark.center, color: mark.color, from: mark.from, kind: mark.kind, label: mark.label, n: mark.n,
                    note: CapturedReadPolicy.text(mark.note, max: 2_000), origin: mark.origin, points: mark.points, stroke: mark.stroke, to: mark.to,
                    underText: CapturedReadPolicy.text(mark.underText, max: 2_000))
            }
            let whole = (source.body ?? source.ocr).map(AgentSecretPolicy.redacted)
            let offset = min(input.textOffset ?? 0, whole?.count ?? 0)
            var window = whole.map { String($0.dropFirst(offset).prefix(8_000)) }
            var linkValues = try links(db, source.id, limit: 101)
            var truncated = kids.count > limits.children || linkValues.count > 100 || (whole?.count ?? 0) > offset + (window?.count ?? 0)
            linkValues = Array(linkValues.prefix(100))
            let pictureRequested = input.picture != false && source.path != nil
            let relative = input.variant == .clean ? source.pathClean : source.path
            var available = false
            var fileFailure: CapturedQueryFailure?
            if source.imageState == .present, let relative {
                do { available = try CapturedFiles.withFile(relative, root: root) { _, _ in true } }
                catch let failure as CapturedQueryFailure { fileFailure = failure }
            }
            let state = source.imageState == .present && !available ? TPPictureState.missing : TPPictureState(rawValue: source.imageState.rawValue)!
            let picture = source.path.map { _ in TPCapturedPictureInfo(height: source.imgH ?? 0,
                path: includePath && pictureRequested && available && input.region == nil ? root.appendingPathComponent(relative!).path : nil,
                state: state, width: source.imgW ?? 0) }
            var context = context(source)
            while true {
                let item = TPCapturedItem(at: stamp(source.tStart), children: childValues, context: context, durationSeconds: duration(source),
                    id: source.id, kind: TPCapturedKind(rawValue: source.kind.rawValue)!, links: linkValues, marks: markValues,
                    picture: picture, text: window, textTotal: whole?.count)
                let output = TPCapturedGetOutput(item: item, notice: CapturedReadPolicy.notice, ok: true, truncated: truncated)
                // Leave room for the picture_gone error envelope as well.
                let byteCount = try JSONEncoder().encode(output).count
                if byteCount <= max(0, limits.resultBytes - (pictureRequested && !available ? 256 : 0)) {
                    if pictureRequested && !available {
                        if fileFailure?.error.code == .permissionDenied {
                            throw CapturedQueryFailure(.permissionDenied, "macOS denied access to the captured file.", item: item)
                        }
                        throw CapturedQueryFailure(.pictureGone, "The requested picture is no longer available; its indexed text is retained.", item: item)
                    }
                    return output
                }
                truncated = true
                if !markValues.isEmpty { markValues.removeLast() }
                else if !childValues.isEmpty { childValues.removeLast() }
                else if !linkValues.isEmpty { linkValues.removeLast() }
                else if let value = window, !value.isEmpty { window = String(value.prefix(value.count / 2)) }
                else if context != nil { context = nil }
                else { throw CapturedQueryFailure(.invalidArguments, "The result byte limit is too small.") }
            }
        }
    }
    func decode<T: Decodable>(_ type: T.Type, _ string: String?) -> T? {
        string?.data(using: .utf8).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    func context(_ row: CapturedItemRow) -> TPContext? {
        guard let object = CapturedReadPolicy.object(row.extraJSON)["context"],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let c = try? JSONDecoder().decode(TPContext.self, from: data) else { return nil }
        let display = TPContextDisplay(heightPt: c.display.heightPt, index: c.display.index, scale: c.display.scale,
                                       uuid: CapturedReadPolicy.text(c.display.uuid)!, widthPt: c.display.widthPt)
        return TPContext(app: CapturedReadPolicy.text(c.app)!, bundleID: CapturedReadPolicy.text(c.bundleID), display: display,
                         pointer: c.pointer, contextPrivate: c.contextPrivate, url: CapturedReadPolicy.url(c.url), windowBox: c.windowBox,
                         windowTitle: CapturedReadPolicy.title(c.windowTitle))
    }
    func snippet(_ raw: String, words: String?) -> String {
        let text = AgentSecretPolicy.redacted(raw)
        guard let words else { return String(text.prefix(240)) }
        let tokens = words.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
        guard !tokens.isEmpty else { return String(text.prefix(240)) }
        let pattern = #"(?i)(?<![\p{L}\p{N}_])(?:"# + tokens.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")[\p{L}\p{N}_]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return String(text.prefix(240)) }
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let window = String(text[start...].prefix(220))
        return String(regex.stringByReplacingMatches(in: window, range: NSRange(window.startIndex..., in: window), withTemplate: "«$0»").prefix(240))
    }
}
