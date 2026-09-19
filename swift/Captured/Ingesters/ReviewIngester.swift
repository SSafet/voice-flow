import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Reviews — watcher/reviews/*.md and watcher/ledger.md
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Each review file is one review item with the file's text in the body. A
//  dated review covers its day from local midnight to its last second; the
//  ledger is timed at the file's modification time.

struct ReviewIngester {
    let index: CapturedIndex
    let root: URL

    @discardableResult
    func ingest(fileName: String) throws -> CapturedIngestResult {
        let relative: String
        let id: String
        let dated: String?
        if fileName == "ledger.md" {
            relative = "watcher/ledger.md"
            id = CapturedItemID.ledger
            dated = nil
        } else {
            relative = "watcher/reviews/\(fileName)"
            let day = String(fileName.dropLast(3))
            id = CapturedItemID.review(day: day)
            dated = day
        }
        let url = root.appendingPathComponent(relative)
        guard let state = IngestFile.state(url) else {
            throw IngestError.unreadableFile(relative)
        }
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            throw IngestError.unreadableFile(relative)
        }
        var row = CapturedItemRow(id: id, kind: .review, source: .review,
                                  tStart: state.mtime, tEnd: state.mtime)
        if let dated, let start = IngestFile.epoch(dated, "00-00-00") {
            row.tStart = start
            row.tEnd = start + 86_399
        }
        row.body = body
        row.imageState = .none
        row.ocrState = .na
        let result = try index.upsert(row)
        try index.saveCursor(CapturedCursor(sourcePath: relative, byteOffset: state.size,
                                            mtime: state.mtime, size: state.size))
        return CapturedIngestResult(inserted: 0, updated: 0).adding(result)
    }
}
