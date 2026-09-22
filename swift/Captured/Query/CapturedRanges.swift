import Foundation
import GRDB

extension CapturedQuery {
    func activity(_ db: Database, from: Int, to: Int, apps: [String]? = nil) throws -> [CapturedItemRow] {
        let filter = try CapturedReadPolicy.appFilter(apps)
        return try rows(db, where: "kind = 'activity' AND t_start < ? AND t_end > ? AND (\(filter.0))",
                        args: [to.databaseValue, from.databaseValue] + filter.1).map {
            var clipped = $0; clipped.tStart = max(from, clipped.tStart); clipped.tEnd = min(to, clipped.tEnd); return clipped
        }
    }
    func timeline(_ spans: [CapturedItemRow]) -> (lines: [TPTimelineLine], truncated: Bool) {
        var lines = spans.map { TPTimelineLine(app: CapturedReadPolicy.text($0.app) ?? "Unknown application", from: stamp($0.tStart),
                         title: CapturedReadPolicy.title($0.title), to: stamp($0.tEnd), url: CapturedReadPolicy.url($0.url)) }
        if lines.count > 40 {
            var merged: [TPTimelineLine] = []
            for line in lines {
                if let last = merged.last, last.app == line.app, last.to == line.from {
                    merged[merged.count - 1] = TPTimelineLine(app: line.app, from: last.from, title: last.title == line.title ? last.title : nil,
                                                             to: line.to, url: last.url == line.url ? last.url : nil)
                } else { merged.append(line) }
            }
            lines = merged
        }
        return (Array(lines.prefix(40)), lines.count > 40)
    }
    func frames(_ input: TPCapturedFramesInput, limits: CapturedLimits, includePath: Bool) throws -> TPCapturedFramesOutput {
        try checkReady()
        let (from, to) = try range(input.from, input.to, maxSeconds: 86_400)
        let maximum = try CapturedReadPolicy.positive(input.maxPictures, default: 6, maximum: limits.maxPictures)
        let filter = try CapturedReadPolicy.appFilter(input.apps)
        return try index.read { db in
            let spans = try activity(db, from: from, to: to, apps: input.apps)
            let all = try rows(db, where: "kind = 'frame' AND source = 'watcher' AND t_start >= ? AND t_start < ? AND (\(filter.0))",
                               args: [from.databaseValue, to.databaseValue] + filter.1)
            // A stale `present` bit cannot turn a removed/unsafe path into a picture.
            let available = all.filter { $0.imageState == .present && $0.path.map { CapturedFiles.isAvailable($0, root: root) } == true }
            let chosen: [CapturedItemRow]
            if available.count <= maximum { chosen = available }
            else {
                // Compute the first visible frame of each span in the entire index,
                // not merely the first frame after the caller's range boundary.
                let first = try Row.fetchAll(db, sql: CapturedReadPolicy.visibleCTE + " SELECT parent_id, min(t_start) AS first_at FROM visible WHERE kind = 'frame' AND source = 'watcher' GROUP BY parent_id")
                var firstTimes: [String: Int] = [:]
                for row in first { if let parent: String = row["parent_id"] { firstTimes[parent] = row["first_at"] } }
                func area(_ row: CapturedItemRow) -> Double {
                    guard let box = CapturedReadPolicy.object(row.extraJSON)["chg"] as? [Double], box.count == 4,
                          box[2] > 0, box[3] > 0 else { return 0 }
                    return box[2] * box[3]
                }
                chosen = (0..<maximum).compactMap { n in
                    let start = Double(from) + Double(to - from) * Double(n) / Double(maximum)
                    let end = Double(from) + Double(to - from) * Double(n + 1) / Double(maximum)
                    let bucket = available.filter { Double($0.tStart) >= start && Double($0.tStart) < end }
                    let starts = bucket.filter { $0.parentID.flatMap { firstTimes[$0] } == $0.tStart }
                    return starts.sorted { a, b in area(a) == area(b) ? (a.tStart, a.id) < (b.tStart, b.id) : area(a) > area(b) }.first ?? bucket.first
                }
            }
            var pictures = chosen.map { TPFramePicture(app: CapturedReadPolicy.text($0.app), at: stamp($0.tStart), id: $0.id,
                path: includePath ? root.appendingPathComponent($0.path!).path : nil, title: CapturedReadPolicy.title($0.title), url: CapturedReadPolicy.url($0.url)) }
            let timelineResult = timeline(spans)
            var lines = timelineResult.lines
            var truncated = timelineResult.truncated || pictures.count < all.count
            while true {
                let output = TPCapturedFramesOutput(hint: "Use captured_get for a selected id, or choose a narrower range for more detail.",
                    notice: CapturedReadPolicy.notice, ok: true, omitted: all.count - pictures.count, pictures: pictures, timeline: lines, truncated: truncated)
                if try CapturedReadPolicy.fits(output, limits) { return output }
                truncated = true
                if !lines.isEmpty { lines.removeLast() } else if !pictures.isEmpty { pictures.removeLast() }
                else { throw CapturedQueryFailure(.invalidArguments, "The result byte limit is too small.") }
            }
        }
    }
    func around(_ input: TPCapturedAroundInput, limits: CapturedLimits) throws -> TPCapturedAroundOutput {
        try checkReady()
        guard (input.at == nil) != (input.id == nil), (1...60).contains(input.windowMinutes ?? 5) else {
            throw CapturedQueryFailure(.invalidArguments, "Specify exactly one of at or id, and a window of 1 to 60 minutes.")
        }
        return try index.read { db in
            let at = try input.at.map(epoch) ?? row(db, id: input.id!).tStart
            let window = (input.windowMinutes ?? 5) * 60
            let a = at - window, b = at + window
            let spans = try activity(db, from: a, to: b)
            let other = try rows(db, where: "kind != 'activity' AND t_start >= ? AND t_start < ?", args: [a.databaseValue, b.databaseValue], limit: 31)
            var hits = try other.prefix(30).map { try hit(db, $0) }
            let pictures = try rows(db, where: "kind = 'frame' AND image_state = 'present' AND t_start >= ? AND t_start < ?",
                                    args: [a.databaseValue, b.databaseValue]).filter { $0.path.map { CapturedFiles.isAvailable($0, root: root) } == true }
            let before = pictures.last { $0.tStart <= at }?.id, after = pictures.first { $0.tStart >= at }?.id
            let timelineResult = timeline(spans); var lines = timelineResult.lines
            var truncated = timelineResult.truncated || other.count > 30
            while true {
                let output = TPCapturedAroundOutput(activity: lines, frameAfter: after, frameBefore: before, items: hits,
                    notice: CapturedReadPolicy.notice, ok: true, truncated: truncated)
                if try CapturedReadPolicy.fits(output, limits) { return output }
                truncated = true
                if !hits.isEmpty { hits.removeLast() } else if !lines.isEmpty { lines.removeLast() }
                else { throw CapturedQueryFailure(.invalidArguments, "The result byte limit is too small.") }
            }
        }
    }
    func summary(_ input: TPCapturedSummaryInput, limits: CapturedLimits) throws -> TPCapturedSummaryOutput {
        try checkReady()
        let (from, to) = try range(input.from, input.to, maxSeconds: 31 * 86_400)
        let grouping = input.groupBy ?? .app
        return try index.read { db in
            // Range clipping happens before grouping. Calendar splitting below is
            // needed for DST days/hours; grouping a span by t_start loses midnight.
            let originals = try rows(db, where: "kind = 'activity' AND t_start < ? AND t_end > ?", args: [to.databaseValue, from.databaseValue])
            let spans = originals.map { source -> CapturedItemRow in
                var span = source; span.tStart = max(from, span.tStart); span.tEnd = min(to, span.tEnd); return span
            }
            let counts = try Row.fetchAll(db, sql: CapturedReadPolicy.visibleCTE + " SELECT kind, count(*) AS n FROM visible WHERE t_start >= ? AND t_start < ? GROUP BY kind", arguments: [from, to])
            var byKind: [String: Int] = [:]
            for row in counts { byKind[row["kind"]] = row["n"] }
            let frameTimes = (grouping == .day || grouping == .hour) ? try Int.fetchAll(db, sql: CapturedReadPolicy.visibleCTE + " SELECT t_start FROM visible WHERE kind = 'frame' AND t_start >= ? AND t_start < ?", arguments: [from, to]) : []
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            func bucket(_ at: Int) -> String {
                let date = Date(timeIntervalSince1970: Double(at))
                if grouping == .day { return CapturedTime.formatter("yyyy-MM-dd", timeZone).string(from: date) }
                let start = calendar.dateInterval(of: .hour, for: date)!.start
                return CapturedTime.localString(start, in: timeZone)
            }
            struct Group { var seconds = 0; var ids = Set<String>(); var apps: [String: Int] = [:] }
            var groups: [String: Group] = [:], pauses: [String: Int] = [:]
            var switches = 0; var previous: CapturedItemRow?
            var longest: CapturedItemRow?
            for (original, span) in zip(originals, spans) {
                if let p = previous, p.app != span.app || p.title != span.title || p.url != span.url { switches += 1 }
                previous = span
                if span.tEnd - span.tStart > (longest.map { $0.tEnd - $0.tStart } ?? -1) { longest = span }
                // Old watcher pause records lack timestamps. Count a recorded pause
                // only when its owning span is fully inside the requested interval.
                if original.tStart >= from && original.tEnd <= to {
                    for pause in CapturedReadPolicy.object(span.extraJSON)["pauses"] as? [[String: Any]] ?? [] {
                        if let reason = pause["reason"] as? String, let seconds = pause["seconds"] as? Int, seconds > 0 {
                            pauses[CapturedReadPolicy.text(reason) ?? "Unknown", default: 0] += seconds
                        }
                    }
                }
                var cursor = span.tStart
                while cursor < span.tEnd {
                    let key: String, end: Int
                    switch grouping {
                    case .hour, .day:
                        key = bucket(cursor)
                        let interval = calendar.dateInterval(of: grouping == .day ? .day : .hour, for: Date(timeIntervalSince1970: Double(cursor)))!
                        end = min(span.tEnd, Int(interval.end.timeIntervalSince1970))
                    case .app: key = CapturedReadPolicy.text(span.app) ?? "Unknown application"; end = span.tEnd
                    case .title: key = CapturedReadPolicy.title(span.title) ?? "Untitled"; end = span.tEnd
                    case .urlHost: key = CapturedReadPolicy.url(span.url)?.split(separator: "/").first.map(String.init) ?? "No website"; end = span.tEnd
                    }
                    guard end > cursor else { break }
                    var group = groups[key] ?? Group()
                    group.seconds += end - cursor; group.ids.insert(span.id)
                    group.apps[CapturedReadPolicy.text(span.app) ?? "Unknown application", default: 0] += end - cursor
                    groups[key] = group; cursor = end
                }
            }
            let active = groups.values.reduce(0) { $0 + $1.seconds }
            let framesByBucket = Dictionary(grouping: frameTimes, by: bucket).mapValues(\.count)
            let temporal = grouping == .day || grouping == .hour
            var values: [TPSummaryGroup] = []
            for (key, group) in groups {
                let orderedApps = group.apps.sorted { a, b in
                    a.value == b.value ? a.key < b.key : a.value > b.value
                }
                let top: [TPSummaryTopApp]? = temporal ? orderedApps.prefix(3).map {
                    TPSummaryTopApp(app: $0.key, seconds: $0.value)
                } : nil
                let frameCount: Int? = temporal ? framesByBucket[key, default: 0] : nil
                let share = active == 0 ? 0.0 : Double(group.seconds) / Double(active)
                values.append(TPSummaryGroup(frames: frameCount, key: key, seconds: group.seconds,
                                              share: share, spans: group.ids.count, top: top))
            }
            values.sort { a, b in a.seconds == b.seconds ? a.key < b.key : a.seconds > b.seconds }
            var paused: [TPSummaryPause] = []
            for (reason, seconds) in pauses { paused.append(TPSummaryPause(reason: reason, seconds: seconds)) }
            paused.sort { a, b in
                if a.seconds != b.seconds { return a.seconds > b.seconds }
                return a.reason < b.reason
            }
            var truncated = values.count > limits.summaryGroups || paused.count > 25
            values = Array(values.prefix(limits.summaryGroups)); paused = Array(paused.prefix(25))
            let focus = longest.map { TPLongestFocus(app: CapturedReadPolicy.text($0.app) ?? "Unknown application", from: stamp($0.tStart), seconds: $0.tEnd - $0.tStart, title: CapturedReadPolicy.title($0.title), to: stamp($0.tEnd)) }
            while true {
                let output = TPCapturedSummaryOutput(activeSeconds: active,
                    counts: TPSummaryCounts(bundles: byKind["capture", default: 0], dictations: byKind["dictation", default: 0], frames: byKind["frame", default: 0], shots: byKind["shot", default: 0]),
                    groups: values, longestFocus: focus, notice: CapturedReadPolicy.notice, ok: true, paused: paused, switches: switches, truncated: truncated)
                if try CapturedReadPolicy.fits(output, limits) { return output }
                truncated = true
                if !values.isEmpty { values.removeLast() } else if !paused.isEmpty { paused.removeLast() }
                else { throw CapturedQueryFailure(.invalidArguments, "The result byte limit is too small.") }
            }
        }
    }
    /// A calendar day can be 23 or 25 hours; do not add a fixed 86,400 seconds.
    func day(_ day: String, limits: CapturedLimits = .interface) throws -> TPCapturedSummaryOutput {
        let start = try CapturedTime.parse(day + " 00:00", in: timeZone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard day.count == 10, let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw CapturedQueryFailure(.invalidArguments, "Use a calendar day in YYYY-MM-DD form.")
        }
        return try summary(.init(from: CapturedTime.localString(start, in: timeZone), groupBy: .hour,
                                 to: CapturedTime.localString(end, in: timeZone)), limits: limits)
    }
}
