import Foundation

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
        let relative = "dictations/\(fileName)"
        let url = root.appendingPathComponent(relative)
        guard let state = IngestFile.state(url) else {
            throw IngestError.unreadableFile(relative)
        }
        let data = try Data(contentsOf: url)
        var result = CapturedIngestResult(inserted: 0, updated: 0)
        for line in IngestFile.lines(data, from: 0) {
            guard let object = try? JSONSerialization.jsonObject(with: line.bytes) as? [String: Any]
            else {
                throw IngestError.malformedLine("\(relative)@\(line.offset)")
            }
            if object["deleted"] as? Bool == true, let id = object["id"] as? String {
                try index.remove(id: CapturedItemID.dictation(id))
                result = result.adding(.updated)
                continue
            }
            guard let entry = try? JSONDecoder().decode(HistoryEntry.self, from: line.bytes) else {
                throw IngestError.malformedLine("\(relative)@\(line.offset)")
            }
            result = result.merging(try ingest(entry))
        }
        try index.saveCursor(CapturedCursor(sourcePath: relative, byteOffset: data.count,
                                            mtime: state.mtime, size: state.size))
        return result
    }

    /// The live path: the archive already stored the entry, so only its row is
    /// written or refreshed here.
    @discardableResult
    func ingest(_ entry: HistoryEntry) throws -> CapturedIngestResult {
        guard let id = entry.id, !id.isEmpty else {
            throw IngestError.malformedLine("a dictation without an id")
        }
        guard let at = IngestFile.isoEpoch(entry.timestamp) else {
            throw IngestError.malformedLine("dictation \(id) has no readable time")
        }
        var row = CapturedItemRow(id: CapturedItemID.dictation(id), kind: .dictation,
                                  source: .dictation, tStart: at, tEnd: at)
        row.body = entry.text
        row.originDevice = entry.originDevice
        row.imageState = .none
        row.ocrState = .na
        var extra: [String: Any] = ["destination": entry.effectiveDestination.rawValue]
        if let capability = entry.capability { extra["capability"] = capability.rawValue }
        row.extraJSON = IngestFile.json(extra)
        return CapturedIngestResult(inserted: 0, updated: 0)
            .adding(try index.upsert(row))
    }
}
