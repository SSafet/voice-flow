import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  The observation bus — shared plumbing for every source
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Collection is a list of interchangeable *sources*. A source decides only
//  what it observes and how — its thresholds, its coalescing rules, its
//  fields, and a SOURCE.md saying what its data means. Everything that
//  applies to all of them lives here and is written once: which day folder
//  is current, how streams are appended, how artifacts are named, how long
//  anything is kept, and what the health of the whole set looks like.
//
//  ~/.config/voice-flow/watcher/
//      2026-07-28/
//          activity.jsonl      desktop source — one line per tick
//          actions.jsonl       desktop source — one line per coalesced action
//          frame-HH-mm-ss.jpg  artifacts, named <source-scoped>-HH-mm-ss.<ext>
//      sources-status.json     health of every source, for the UI and the review

final class DayBus {

    static let baseDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/voice-flow/watcher")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Called on the main thread when the date changes, so sources can drop
    /// per-day state (a cached previous frame belongs to yesterday's folder).
    /// A list, not one slot: a second source registering must not silently
    /// unsubscribe the first.
    private var dayRollObservers: [() -> Void] = []

    func onDayRoll(_ observer: @escaping () -> Void) {
        dayRollObservers.append(observer)
    }

    private let writeQueue = DispatchQueue(label: "voiceflow.watcher.bus", qos: .utility)
    private var currentDay = ""

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static let fileTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH-mm-ss"; return f
    }()
    static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Resolve (and roll into) the folder for `date`.
    ///
    /// Main thread only — it mutates `currentDay` and fans out to observers.
    /// Every caller (the scheduler's timers, the coalescer's NSEvent handlers,
    /// each source's tick completion) is already on the main thread; file IO
    /// is what gets handed to the write queue, not this.
    @discardableResult
    func dayDir(at date: Date = Date()) -> URL {
        let day = Self.dayFormatter.string(from: date)
        if day != currentDay {
            currentDay = day
            prune()
            for observer in dayRollObservers { observer() }
        }
        let dir = Self.baseDir.appendingPathComponent(day)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Append one JSON line to `<day>/<stream>.jsonl`, stamping the clock and
    /// epoch fields every consumer merges on. Sources never format time.
    func append(_ fields: [String: Any], to stream: String, at date: Date = Date()) {
        var line = fields
        line["t"] = Self.clockFormatter.string(from: date)
        line["e"] = Int(date.timeIntervalSince1970)
        let url = dayDir(at: date).appendingPathComponent("\(stream).jsonl")
        guard let json = try? JSONSerialization.data(withJSONObject: line) else { return }
        writeQueue.async {
            let entry = json + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entry)
            } else {
                try? entry.write(to: url)
            }
        }
    }

    /// Write a timestamped artifact and return the filename the stream should
    /// reference. `encode` runs off the main thread — hand it the cheapest
    /// representation you have and let it do the expensive part.
    @discardableResult
    func artifact(prefix: String, ext: String, at date: Date = Date(),
                  encode: @escaping () -> Data?) -> String {
        let name = "\(prefix)-\(Self.fileTimeFormatter.string(from: date)).\(ext)"
        let url = dayDir(at: date).appendingPathComponent(name)
        writeQueue.async {
            guard let data = encode() else { return }
            try? data.write(to: url, options: .atomic)
        }
        return name
    }

    /// Retention is the bus's job, not any one source's: every source writes
    /// into the same folder, so a per-source policy could never delete it.
    func prune() {
        let keep = max(3, UserSettings.shared.watcherKeepDays)
        // Off the main thread: a day folder holds thousands of JPEGs, and
        // shortening retention can delete twenty of them at once. Nothing here
        // needs main-thread ordering.
        writeQueue.async {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: Self.baseDir, includingPropertiesForKeys: nil) else { return }
            let dayDirs = entries
                .filter { $0.hasDirectoryPath && $0.lastPathComponent.first?.isNumber == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for stale in dayDirs.dropFirst(keep) {
                try? FileManager.default.removeItem(at: stale)
            }
        }
    }

    /// Last computed day-folder tally. Read freely; it is refreshed off the
    /// main thread. Scanning is NOT done on demand — a day folder can hold
    /// thousands of files and this is read from the menu-bar update path.
    private(set) var volume: (frames: Int, bytes: Int) = (0, 0)

    func refreshVolume(_ done: (() -> Void)? = nil) {
        let dir = Self.baseDir.appendingPathComponent(Self.dayFormatter.string(from: Date()))
        writeQueue.async { [weak self] in
            var frames = 0, bytes = 0
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            if let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys) {
                for item in items {
                    let values = try? item.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }
                    if item.pathExtension == "jpg" { frames += 1 }
                    bytes += values?.fileSize ?? 0
                }
            }
            DispatchQueue.main.async {
                self?.volume = (frames, bytes)
                done?()
            }
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Source contract
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

protocol WatcherSource: AnyObject {
    /// Folder name under `~/.config/voice-flow/sources/` holding this source's
    /// SOURCE.md. Deliberately outside the watcher archive: that directory is
    /// written by the nightly review, and a source folder will eventually hold
    /// an executable this app runs with its own permissions.
    var name: String { get }
    /// Seconds between ticks; 0 for sources that write on their own events.
    var interval: TimeInterval { get }
    var isEnabled: Bool { get }

    func start(bus: DayBus)
    func stop()
    /// Settings changed while this source is running. Reconcile anything the
    /// scheduler cannot see — the scheduler only knows about `isEnabled` and
    /// `interval`, so every other knob a source owns must be picked up here.
    func applySettings()
    /// Do one unit of work. Call `done` exactly once, on the main thread,
    /// with nil or a short error string.
    func tick(bus: DayBus, done: @escaping (String?) -> Void)
    /// Source-owned health fields merged into sources-status.json.
    func status() -> [String: Any]
}

extension WatcherSource {
    func status() -> [String: Any] { [:] }
    func applySettings() {}
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Scheduler
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  One timer per source, each firing independently, each isolated: a source
//  that throws, hangs, or is switched off cannot stop any other. Work runs
//  off the main thread and lands back on it, so a slow source never blocks
//  dictation, the panel, or the agent.

final class SourceScheduler {

    let bus = DayBus()
    private(set) var isRunning = false

    private struct Slot {
        let source: WatcherSource
        var timer: Timer?
        var started = false
        /// The source's own declared interval as of the last start — compared
        /// against `source.interval` to decide whether a restart is needed.
        /// Not the timer's period, which is floored to 1 s.
        var appliedInterval: TimeInterval = 0
        var inFlightSince: Date?
        var lastRun: Date?
        var lastDurationMs: Int?
        var lastError: String?
        var runs = 0
        var stalls = 0
    }

    private var slots: [String: Slot] = [:]
    private var order: [String] = []

    func register(_ source: WatcherSource) {
        guard slots[source.name] == nil else { return }
        slots[source.name] = Slot(source: source)
        order.append(source.name)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        bus.prune()
        for name in order { startSlot(name) }
        writeStatus()
        vflog("sources: started — \(order.filter { slots[$0]?.source.isEnabled == true }.joined(separator: ", "))")
    }

    func stop() {
        guard isRunning else { return }
        for name in order { stopSlot(name) }
        isRunning = false
        writeStatus()
        vflog("sources: stopped")
    }

    /// Settings changed: bring every source into line without disturbing the
    /// ones whose configuration did not move.
    func applySettings() {
        guard isRunning else { return }
        for name in order {
            guard let slot = slots[name] else { continue }
            let wanted = slot.source.isEnabled
            if !wanted, slot.started {
                stopSlot(name)
            } else if wanted, !slot.started {
                startSlot(name)
            } else if wanted, slot.source.interval != slot.appliedInterval {
                stopSlot(name); startSlot(name)
            } else if wanted {
                slot.source.applySettings()
            }
        }
        writeStatus()
    }

    private func startSlot(_ name: String) {
        guard var slot = slots[name], !slot.started, slot.source.isEnabled else { return }
        slot.source.start(bus: bus)
        slot.started = true
        slot.appliedInterval = slot.source.interval
        slot.inFlightSince = nil
        if slot.source.interval > 0 {
            slot.timer = Timer.scheduledTimer(withTimeInterval: max(1, slot.source.interval), repeats: true) {
                [weak self] _ in self?.fire(name)
            }
        }
        slots[name] = slot
    }

    private func stopSlot(_ name: String) {
        guard var slot = slots[name], slot.started else { return }
        slot.timer?.invalidate()
        slot.timer = nil
        slot.started = false
        slot.appliedInterval = 0
        slot.inFlightSince = nil
        slot.source.stop()
        slots[name] = slot
    }

    private func fire(_ name: String) {
        guard var slot = slots[name] else { return }

        // A capture with no timeout used to latch this source off for good:
        // one hung call and every later tick returned at the guard, silently,
        // until the app restarted. Now the guard expires and says so.
        if let since = slot.inFlightSince {
            let limit = max(20, slot.appliedInterval * 4)
            guard Date().timeIntervalSince(since) >= limit else { return }
            slot.stalls += 1
            slot.lastError = "stalled"
            slot.inFlightSince = nil
            slots[name] = slot
            bus.append(["kind": "stall", "source": name,
                        "held_s": Int(Date().timeIntervalSince(since))], to: "watcher")
            vflog("sources: \(name) stalled — guard force-cleared")
        }

        let started = Date()
        slot.inFlightSince = started
        slots[name] = slot
        let source = slot.source

        source.tick(bus: bus) { [weak self] error in
            guard let self, var slot = self.slots[name] else { return }
            // A stall already cleared this run; do not let it land late.
            guard slot.inFlightSince == started else { return }
            slot.inFlightSince = nil
            slot.lastRun = Date()
            slot.lastDurationMs = Int(Date().timeIntervalSince(started) * 1000)
            slot.lastError = error
            slot.runs += 1
            self.slots[name] = slot
            if let error { vflog("sources: \(name) — \(error)") }
        }
    }

    // ── observability ──────────────────────────────────────────────────

    /// One line for the menu bar.
    func statusLine() -> String {
        guard isRunning else { return "Off" }
        let volume = bus.volume
        let mb = volume.bytes / 1_048_576
        var line = "Watching — \(volume.frames) frames today"
        if mb > 0 { line += " (\(mb) MB)" }
        let broken = order.filter { slots[$0]?.lastError != nil }
        if !broken.isEmpty { line += " · \(broken.joined(separator: ", ")) failing" }
        return line
    }

    /// Written after every settings change and on a slow cadence while
    /// running, so both the Settings UI and the nightly review can see which
    /// sources actually produced anything today.
    func writeStatus() {
        bus.refreshVolume { [weak self] in self?.renderStatus() }
        renderStatus()
    }

    private func renderStatus() {
        let volume = bus.volume
        var sources: [[String: Any]] = []
        for name in order {
            guard let slot = slots[name] else { continue }
            var entry: [String: Any] = [
                "name": name,
                "enabled": slot.source.isEnabled,
                "interval_s": slot.source.interval,
                "runs_today": slot.runs,
                "stalls": slot.stalls,
            ]
            if let last = slot.lastRun {
                entry["last_run"] = ISO8601DateFormatter().string(from: last)
            }
            if let ms = slot.lastDurationMs { entry["last_duration_ms"] = ms }
            if let error = slot.lastError { entry["last_error"] = error }
            entry.merge(slot.source.status()) { _, new in new }
            sources.append(entry)
        }
        let doc: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
            "running": isRunning,
            "keep_days": max(3, UserSettings.shared.watcherKeepDays),
            "frames_today": volume.frames,
            "bytes_today": volume.bytes,
            "sources": sources,
        ]
        let url = DayBus.baseDir.appendingPathComponent("sources-status.json")
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
