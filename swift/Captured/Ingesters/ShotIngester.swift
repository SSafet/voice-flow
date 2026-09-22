import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Shots — captures/shots/
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  A shot is one item. A file named `pasted-…` is the same id form with the
//  paste source; a file ending `.clean.jpg` is not an item but the
//  `path_clean` of the shot with the same name. A shot taken inside a known
//  activity span copies that span's context.

struct ShotIngester {
    let index: CapturedIndex
    let root: URL

    @discardableResult
    func ingest(fileName: String) throws -> CapturedIngestResult {
        let relative = "captures/shots/\(fileName)"
        guard let state = IngestFile.state(try IngestFile.resolve(relative, root: root)) else {
            throw IngestError.unreadableFile(relative)
        }
        guard let shot = Self.parse(fileName) else {
            throw IngestError.malformedLine(relative)
        }
        var row = CapturedItemRow(id: CapturedItemID.shot(name: shot.stamp),
                                  kind: .shot,
                                  source: shot.pasted ? .paste : .shot,
                                  tStart: shot.epoch, tEnd: shot.epoch)
        row.path = relative
        let clean = try IngestFile.resolve(relative, root: root)
            .deletingPathExtension().appendingPathExtension("clean.jpg")
        if FileManager.default.fileExists(atPath: clean.path) {
            row.pathClean = IngestFile.relativePath(clean, root: root)
        }
        row.imageState = .present
        row.ocrState = .pending
        if let join = try index.watcherContext(at: shot.epoch) {
            row.app = join.app
            row.bundleID = join.bundleID
            row.title = join.title
            row.url = join.url
                row.ocrState = join.isPrivate ? .skippedPrivate : .pending
            row.extraJSON = IngestFile.json(["contextSource": "watcher_join"])
        }
        let result = try index.upsert(row)
        try index.saveCursor(CapturedCursor(sourcePath: relative, byteOffset: state.size,
                                            mtime: state.mtime, size: state.size))
        return CapturedIngestResult(inserted: 0, updated: 0).adding(result)
    }

    /// `shot-<stamp>.jpg` and `pasted-<stamp>.jpg` share one id form; the
    /// stamp is the file name without its prefix and extension.
    static func parse(_ fileName: String) -> (stamp: String, epoch: Int, pasted: Bool)? {
        guard fileName.hasSuffix(".jpg") else { return nil }
        let base = String(fileName.dropLast(4))
        guard !base.hasSuffix(".clean") else { return nil }
        let pasted: Bool
        let prefix: String
        if base.hasPrefix("shot-") {
            pasted = false; prefix = "shot-"
        } else if base.hasPrefix("pasted-") {
            pasted = true; prefix = "pasted-"
        } else {
            return nil
        }
        let stamp = String(base.dropFirst(prefix.count))
        guard let epoch = stampEpoch(stamp) else { return nil }
        return (stamp, epoch, pasted)
    }

    private static func stampEpoch(_ stamp: String) -> Int? {
        let parts = stamp.split(separator: "_")
        guard parts.count == 2 else { return nil }
        return IngestFile.epoch(String(parts[0]), String(parts[1]))
    }
}
