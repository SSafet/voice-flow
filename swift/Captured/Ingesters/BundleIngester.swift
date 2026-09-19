import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Capture bundles — captures/<id>/meta.json
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  A bundle is one capture item — its narration in the body, its length and
//  frame count in the extra — plus one frame item per picture, numbered from
//  one and timed from the bundle's start. The bundle itself carries no picture.

struct BundleIngester {
    let index: CapturedIndex
    let root: URL

    @discardableResult
    func ingest(id: String) throws -> CapturedIngestResult {
        let relative = "captures/\(id)/meta.json"
        let url = root.appendingPathComponent(relative)
        guard let state = IngestFile.state(url) else {
            throw IngestError.unreadableFile(relative)
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IngestError.malformedLine(relative)
        }

        let bundle = CapturedItemID.capture(bundle: id)
        guard let start = IngestFile.isoEpoch(object["startedAt"] as? String) else {
            throw IngestError.malformedLine(relative)
        }
        let duration = IngestFile.double(object["durationSeconds"]) ?? 0
        let ended = IngestFile.isoEpoch(object["endedAt"] as? String) ?? (start + Int(duration))
        let frames = object["frames"] as? [[String: Any]] ?? []

        var result = CapturedIngestResult(inserted: 0, updated: 0)
        var row = CapturedItemRow(id: bundle, kind: .capture, source: .bundle,
                                  tStart: start, tEnd: max(start, ended))
        row.body = object["transcript"] as? String
        row.imageState = .none
        row.ocrState = .na
        var extra: [String: Any] = ["frameCount": frames.count]
        extra["durationSeconds"] = duration
        row.extraJSON = IngestFile.json(extra)
        result = result.adding(try index.upsert(row))

        for (position, frame) in frames.enumerated() {
            guard let file = frame["file"] as? String else { continue }
            let at = start + Int(IngestFile.double(frame["elapsed"]) ?? 0)
            let path = "captures/\(id)/\(file)"
            var frameRow = CapturedItemRow(
                id: CapturedItemID.bundleFrame(bundle: id, index: position + 1),
                kind: .frame, source: .bundle, tStart: at, tEnd: at, parentID: bundle)
            frameRow.path = path
            let exists = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path)
            frameRow.imageState = exists ? .present : .missing
            frameRow.ocrState = .pending
            if let join = try index.watcherContext(at: at) {
                frameRow.app = join.app
                frameRow.bundleID = join.bundleID
                frameRow.title = join.title
                frameRow.url = join.url
                frameRow.extraJSON = IngestFile.json(["contextSource": "watcher_join"])
            }
            result = result.adding(try index.upsert(frameRow))
        }

        try index.saveCursor(CapturedCursor(sourcePath: relative, byteOffset: data.count,
                                            mtime: state.mtime, size: state.size))
        return result
    }
}
