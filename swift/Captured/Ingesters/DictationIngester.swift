import Foundation
import GRDB

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Dictations — dictations/<yyyy-mm>.jsonl
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  The archive is append-only and folds so the later line for an id wins, so
//  reading it in order and upserting is enough. A tombstone removes the item.
//  The destination and the capture kind live in the extra; `origin_device`
//  names the device that made the dictation, and stays empty for this Mac.

struct DictationIngester {
    let index: CapturedIndex
    let root: URL

    @discardableResult
    func ingest(fileName: String) throws -> CapturedIngestResult {
        // A deletion or continuation can live in a different month from its
        // original record. Fold the archive as one source; reading only the
        // changed month could resurrect a later tombstone from another file.
        let directory = root.appendingPathComponent("dictations")
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        var folded: [String: (HistoryEntry, String)] = [:]
        var cursors: [CapturedCursor] = []
        let recent = root.appendingPathComponent("dictations.json")
        if FileManager.default.fileExists(atPath: recent.path) {
            let data = try Data(contentsOf: recent)
            let entries = try JSONDecoder().decode([HistoryEntry].self, from: data)
            for entry in entries { folded[entry.archiveIdentity] = (entry, DictationArchive.month(for: entry)) }
            if let state = IngestFile.state(recent) {
                cursors.append(CapturedCursor(sourcePath: "dictations.json", byteOffset: data.count, mtime: state.mtime, size: data.count))
            }
        }
        for file in files {
            let relative = "dictations/" + file.lastPathComponent
            guard let state = IngestFile.state(file) else { throw IngestError.unreadableFile(relative) }
            let data = try Data(contentsOf: file)
            for line in IngestFile.lines(data, from: 0) {
                guard let object = try JSONSerialization.jsonObject(with: line.bytes) as? [String: Any]
                else { throw IngestError.malformedLine("\(relative)@\(line.offset)") }
                if object["deleted"] as? Bool == true, let id = object["id"] as? String {
                    folded[id] = nil
                } else {
                    let entry = try JSONDecoder().decode(HistoryEntry.self, from: line.bytes)
                    folded[entry.archiveIdentity] = (entry, String(file.lastPathComponent.prefix(7)))
                }
            }
            cursors.append(CapturedCursor(sourcePath: relative,
                byteOffset: data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0,
                mtime: state.mtime, size: data.count))
        }
        let previous = try index.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM item WHERE kind = 'dictation'")
        }
        for id in previous where folded[String(id.dropFirst("dictation:".count))] == nil {
            try index.remove(id: id)
        }
        var result = CapturedIngestResult(inserted: 0, updated: 0)
        for (entry, month) in folded.values {
            result = result.merging(try ingest(entry, archiveMonth: month))
        }
        for cursor in cursors { try index.saveCursor(cursor) }
        return result
    }

    /// The live path: the archive already stored the entry, so only its row is
    /// written or refreshed here.
    @discardableResult
    func ingest(_ entry: HistoryEntry, archiveMonth: String? = nil) throws -> CapturedIngestResult {
        let id = entry.archiveIdentity
        let exactTime = IngestFile.isoEpoch(entry.timestamp) ?? IngestFile.isoEpoch(entry.time)
        let monthTime = archiveMonth.flatMap { IngestFile.epoch($0 + "-01", "00-00-00") }
        guard let at = exactTime ?? monthTime else {
            throw IngestError.malformedLine("dictation \(id) has no readable time")
        }
        var row = CapturedItemRow(id: CapturedItemID.dictation(id), kind: .dictation,
                                  source: .dictation, tStart: at, tEnd: at)
        row.body = entry.text
        row.originDevice = entry.originDevice
        row.imageState = .none
        row.ocrState = .na
        var extra: [String: Any] = ["destination": entry.effectiveDestination.rawValue]
        if exactTime == nil { extra["timePrecision"] = "month" }
        if let capability = entry.capability { extra["capability"] = capability.rawValue }
        row.extraJSON = IngestFile.json(extra)
        return CapturedIngestResult(inserted: 0, updated: 0)
            .adding(try index.upsert(row))
    }
}
