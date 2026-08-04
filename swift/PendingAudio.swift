import Foundation

/// Recoverable raw-audio safety net (VF-44). A completed dictation's PCM is
/// written here as a playable WAV *before* transcription begins and removed
/// only after the transcript is delivered, so a transcription failure, crash,
/// or mid-processing quit never loses recorded speech. Files are pruned to
/// the newest `keepLimit` on each save; anything left behind is openable in
/// any audio player.
enum PendingAudioStore {
    static let keepLimit = 20

    static func directory(root: VoiceFlowPaths = .shared) -> URL {
        root.directory("pending-audio")
    }

    /// Writes 16-bit mono PCM as a WAV. Returns the file URL, or nil when the
    /// write fails (the capture proceeds regardless — persistence is a net,
    /// not a gate).
    @discardableResult
    static func save(pcm: Data, runId: UUID, sampleRate: Int,
                     root: VoiceFlowPaths = .shared) -> URL? {
        let url = directory(root: root).appendingPathComponent("\(runId.uuidString).wav")
        do {
            try wavData(pcm: pcm, sampleRate: sampleRate).write(to: url, options: .atomic)
        } catch {
            vflog("pending-audio: save failed for \(runId): \(error)")
            return nil
        }
        prune(root: root)
        return url
    }

    static func remove(runId: UUID, root: VoiceFlowPaths = .shared) {
        let url = directory(root: root).appendingPathComponent("\(runId.uuidString).wav")
        try? FileManager.default.removeItem(at: url)
    }

    /// Pending WAVs, newest first.
    static func pendingFiles(root: VoiceFlowPaths = .shared) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory(root: root), includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension == "wav" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da > db
        }
    }

    private static func prune(root: VoiceFlowPaths) {
        for stale in pendingFiles(root: root).dropFirst(keepLimit) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// Minimal RIFF/WAVE wrapper for 16-bit mono little-endian PCM.
    static func wavData(pcm: Data, sampleRate: Int) -> Data {
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteRate = UInt32(sampleRate * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))            // fmt chunk size
        append(UInt16(1))             // PCM
        append(UInt16(1))             // mono
        append(UInt32(sampleRate))
        append(byteRate)
        append(UInt16(2))             // block align
        append(UInt16(16))            // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
