import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Undelivered recordings — pending-audio/*.wav
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Each waiting recording is one item, marked undelivered in its extra and
//  timed at the file's modification time. It has no picture.

struct RecordingIngester {
    let index: CapturedIndex
    let root: URL

    @discardableResult
    func ingest(fileName: String) throws -> CapturedIngestResult {
        let relative = "pending-audio/\(fileName)"
        let url = root.appendingPathComponent(relative)
        guard let state = IngestFile.state(url) else {
            throw IngestError.unreadableFile(relative)
        }
        guard fileName.hasSuffix(".wav") else {
            throw IngestError.malformedLine(relative)
        }
        let recordingID = String(fileName.dropLast(4))
        var row = CapturedItemRow(id: CapturedItemID.recording(recordingID), kind: .recording,
                                  source: .recording, tStart: state.mtime, tEnd: state.mtime)
        row.imageState = .none
        row.ocrState = .na
        row.extraJSON = IngestFile.json(["state": "undelivered"])
        let result = try index.upsert(row)
        try index.saveCursor(CapturedCursor(sourcePath: relative, byteOffset: state.size,
                                            mtime: state.mtime, size: state.size))
        return CapturedIngestResult(inserted: 0, updated: 0).adding(result)
    }
}
