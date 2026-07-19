import Foundation
import AppKit

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Capture Store — demonstration bundles for Claude Code
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  A session records the user's narration plus deduped screenshots.
//  Instead of flooding an in-app agent, everything is written to disk as
//  a browsable bundle Claude Code can read:
//
//  ~/.config/voice-flow/captures/<id>/
//      transcript.md      narration + ordered frame index
//      meta.json          machine-readable summary
//      frames/frame-01-t000s.jpg …
//
//  Ad-hoc single screenshots (MCP take_screenshot, snap-answers to
//  ask_user) land in captures/shots/.

struct CaptureFrameMeta: Codable {
    let file: String        // path relative to the bundle directory
    let elapsed: Double     // seconds since the capture started
}

struct CaptureBundleMeta: Codable {
    let id: String
    let startedAt: String
    let endedAt: String
    let durationSeconds: Double
    let transcript: String
    let frames: [CaptureFrameMeta]
}

struct CaptureSummary {
    let id: String
    let directory: URL
    let frameCount: Int
    let durationSeconds: Double
    let transcript: String
    let framePaths: [String]

    var transcriptPath: String { directory.appendingPathComponent("transcript.md").path }

    /// One-liner the user pastes into Claude Code.
    var claudePrompt: String { Self.claudePrompt(transcriptPath: transcriptPath) }

    /// Same prompt for a bundle already on disk (menu bar's copy action).
    static func claudePrompt(transcriptPath: String) -> String {
        "I recorded a Voice Flow capture — my spoken narration plus ordered screenshots of what I was doing. "
        + "Read \(transcriptPath), then look at the frames it lists in order, and act on what I said and showed."
    }
}

final class CaptureStore {
    static let baseDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice-flow/captures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let shotsDir: URL = {
        let dir = baseDir.appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let maxStoredBundles = 40
    private static let maxStoredShots = 60
    private let writeQueue = DispatchQueue(label: "voiceflow.capture-store", qos: .utility)

    // Active session state (main thread only)
    private var activeDir: URL?
    private var startDate: Date?
    private var frames: [CaptureFrameMeta] = []
    private var frameCounter = 0

    var isCapturing: Bool { activeDir != nil }

    // ── Session lifecycle ───────────────────────────────

    func beginSession(runId: UUID? = nil) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let id = runId.map { "\(timestamp)-\($0.uuidString.prefix(8))" } ?? timestamp
        let dir = Self.baseDir.appendingPathComponent(id)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("frames"), withIntermediateDirectories: true)
        activeDir = dir
        startDate = Date()
        frames = []
        frameCounter = 0
        vflog("capture: began bundle \(id)")
    }

    func addFrame(_ raw: Data) {
        guard let activeDir, let startDate else { return }
        frameCounter += 1
        let elapsed = Date().timeIntervalSince(startDate)
        let name = String(format: "frames/frame-%02d-t%03ds.jpg", frameCounter, Int(elapsed))
        frames.append(CaptureFrameMeta(file: name, elapsed: elapsed))
        let url = activeDir.appendingPathComponent(name)
        writeQueue.async {
            guard let jpeg = ImageUtils.compress(raw) else { return }
            try? jpeg.write(to: url, options: .atomic)
        }
    }

    /// Finalize the active bundle. Returns nil (and removes the directory)
    /// when nothing was captured at all.
    func endSession(transcript: String?, keepEmpty: Bool = false) -> CaptureSummary? {
        guard let activeDir, let startDate else { return nil }
        let collected = frames
        let started = startDate
        self.activeDir = nil
        self.startDate = nil
        self.frames = []

        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard keepEmpty || !collected.isEmpty || !text.isEmpty else {
            try? FileManager.default.removeItem(at: activeDir)
            return nil
        }

        let ended = Date()
        let duration = ended.timeIntervalSince(started)
        let id = activeDir.lastPathComponent
        let iso = ISO8601DateFormatter()

        writeQueue.async { [maxStoredBundles] in
            // The frame writes were queued ahead of us on this serial queue,
            // so every frame that could be written now exists — drop the
            // rare ones whose JPEG encode failed from the index.
            let written = collected.filter {
                FileManager.default.fileExists(atPath: activeDir.appendingPathComponent($0.file).path)
            }
            let meta = CaptureBundleMeta(
                id: id,
                startedAt: iso.string(from: started),
                endedAt: iso.string(from: ended),
                durationSeconds: duration,
                transcript: text,
                frames: written
            )
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: activeDir.appendingPathComponent("meta.json"), options: .atomic)
            }
            let markdown = Self.renderTranscript(meta: meta)
            try? Data(markdown.utf8).write(
                to: activeDir.appendingPathComponent("transcript.md"), options: .atomic)
            Self.pruneBundles(keep: maxStoredBundles)
        }

        vflog("capture: finished bundle \(id) — \(collected.count) frames, \(Int(duration))s")
        return CaptureSummary(
            id: id, directory: activeDir,
            frameCount: collected.count,
            durationSeconds: duration,
            transcript: text,
            framePaths: collected.map { activeDir.appendingPathComponent($0.file).path }
        )
    }

    /// A continuous run closes its frame bundle before transcription returns,
    /// freeing the store for the next run. Update the serialized transcript on
    /// the same queue after the original frame/meta writes, preserving order.
    func updateTranscript(_ transcript: String, in summary: CaptureSummary) -> CaptureSummary {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = summary.directory
        writeQueue.async {
            guard let old = Self.readMeta(in: directory) else { return }
            let updated = CaptureBundleMeta(
                id: old.id,
                startedAt: old.startedAt,
                endedAt: old.endedAt,
                durationSeconds: old.durationSeconds,
                transcript: text,
                frames: old.frames)
            if let data = try? JSONEncoder().encode(updated) {
                try? data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
            }
            try? Data(Self.renderTranscript(meta: updated).utf8).write(
                to: directory.appendingPathComponent("transcript.md"), options: .atomic)
        }
        return CaptureSummary(
            id: summary.id,
            directory: summary.directory,
            frameCount: summary.frameCount,
            durationSeconds: summary.durationSeconds,
            transcript: text,
            framePaths: summary.framePaths)
    }

    private static func renderTranscript(meta: CaptureBundleMeta) -> String {
        var lines: [String] = []
        lines.append("# Voice Flow capture \(meta.id)")
        lines.append("")
        lines.append("- Started: \(meta.startedAt)")
        lines.append("- Duration: \(Int(meta.durationSeconds))s")
        lines.append("- Frames: \(meta.frames.count) (in `frames/`, ordered by time; filenames carry elapsed seconds)")
        lines.append("")
        lines.append("## Spoken narration")
        lines.append("")
        lines.append(meta.transcript.isEmpty ? "(no narration — the frames are the message)" : meta.transcript)
        lines.append("")
        lines.append("## Frames, in order")
        lines.append("")
        if meta.frames.isEmpty {
            lines.append("(no frames captured)")
        }
        for frame in meta.frames {
            lines.append("- \(frame.file) — t+\(Int(frame.elapsed))s")
        }
        lines.append("")
        lines.append("_Read the frames alongside the narration — both are ordered by time, and any circles or notes drawn on screen are part of the message._")
        return lines.joined(separator: "\n")
    }

    // ── Browsing bundles ────────────────────────────────

    static func readMeta(in directory: URL) -> CaptureBundleMeta? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(CaptureBundleMeta.self, from: data)
    }

    /// Completed bundles, newest first.
    static func listBundles(limit: Int) -> [(directory: URL, meta: CaptureBundleMeta)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil) else { return [] }
        let dirs = entries
            .filter { $0.hasDirectoryPath && $0.lastPathComponent != "shots" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var result: [(URL, CaptureBundleMeta)] = []
        for dir in dirs {
            guard result.count < limit else { break }
            if let meta = readMeta(in: dir) {
                result.append((dir, meta))
            }
        }
        return result
    }

    static func latestBundle() -> (directory: URL, meta: CaptureBundleMeta)? {
        listBundles(limit: 1).first
    }

    private static func pruneBundles(keep: Int) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil) else { return }
        let dirs = entries
            .filter { $0.hasDirectoryPath && $0.lastPathComponent != "shots" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in dirs.dropFirst(keep) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    // ── Ad-hoc screenshots ──────────────────────────────

    /// Screenshot geometry shared with annotate_screen: one fixed pixel
    /// space so coordinates in the saved image map deterministically onto
    /// screen points (see `annotationPointScale`).
    static func shotGeometry(for display: DisplayContext? = nil) -> (width: Int, height: Int) {
        (display ?? DisplayTopology.primary)?.shotGeometry ?? (1440, 900)
    }

    /// Multiply image-pixel coordinates by this to get screen points.
    static func annotationPointScale(for display: DisplayContext? = nil) -> CGFloat {
        (display ?? DisplayTopology.primary)?.annotationPointScale ?? 1.0
    }

    /// Resize + save a raw screenshot; returns its path and pixel size.
    static func saveShot(_ raw: Data, on display: DisplayContext? = nil) -> (path: String, width: Int, height: Int)? {
        let (width, height) = shotGeometry(for: display)
        guard let jpeg = ImageUtils.resizeExact(raw, width: width, height: height) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let url = shotsDir.appendingPathComponent("shot-\(formatter.string(from: Date())).jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            vflog("capture: shot write failed: \(error)")
            return nil
        }
        pruneShots()
        return (url.path, width, height)
    }

    private static func pruneShots() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: shotsDir, includingPropertiesForKeys: nil) else { return }
        let sorted = entries.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in sorted.dropFirst(maxStoredShots) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
