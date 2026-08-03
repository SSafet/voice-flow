import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Next queue — the persistent "what's next" list.
//
//  The whole feature lives in this file as a side-attachment: the store
//  (~/.config/voice-flow/queue/queue.json — the file IS the API: FLORA,
//  Claude sessions, and the user edit it directly; _schema.md in the same
//  directory documents the format), the voiceflow_queue tool handler, the
//  overlay projection (overlays/next-queue.json, no session field so it
//  renders regardless of the active session), and the resurfacing policy.
//  Deleting this file plus its ~20 wiring lines removes the feature.
//
//  Resurfacing is deliberately not a static widget: the panel stays hidden
//  while a queue exists and comes back briefly at transition moments — an
//  app-switch burst (the wander signature), returning from idle, a slow
//  fallback clock, or the queue's content changing — each time at a
//  different top-of-screen position so it never becomes wallpaper. An
//  empty queue during active hours is the one persistent state: it stays
//  up until the user gives it a next step. Closing the panel (✕ deletes
//  the overlay file) is respected with a cooldown. Tunables can be
//  overridden by queue/config.json.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct QueueItem: Equatable {
    var id: String
    var text: String
    var done: Bool

    static func freshID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

final class NextQueue {
    private(set) static var shared: NextQueue?

    private let dirURL = VoiceFlowPaths.shared.directory("queue")
    private var fileURL: URL { dirURL.appendingPathComponent("queue.json") }
    private var configURL: URL { dirURL.appendingPathComponent("config.json") }
    private var schemaURL: URL { dirURL.appendingPathComponent("_schema.md") }
    private let overlayURL = VoiceFlowPaths.shared
        .directory("overlays").appendingPathComponent("next-queue.json")

    private let isBusy: () -> Bool
    private var timer: Timer?
    private var appSwitchObserver: NSObjectProtocol?

    // ── Store state (main thread) ──
    private(set) var items: [QueueItem] = []
    private var lastFileMtime: Date?
    private var lastConfigMtime: Date?

    // ── Surfacing state (main thread) ──
    private enum Surface { case hidden, brief(until: Date), persistentEmpty }
    private var surface: Surface = .hidden
    private var anchorIndex = 0
    private var lastTriggerShow = Date.distantPast
    private var lastClockShow = Date()          // don't clock-fire right at launch
    private var dismissCooldownUntil = Date.distantPast
    private var emptySince: Date?
    private var wasIdleSince: Date?
    private var recentActivations: [Date] = []
    private var shownContentKey: String?

    // ── Tunables (config.json overrides) ──
    private var showSeconds: TimeInterval = 45
    private var clockMinutes: Double = 30
    private var idleResumeMinutes: Double = 5
    private var switchBurstCount = 3
    private var switchBurstWindow: TimeInterval = 45
    private var minGapMinutes: Double = 6
    private var activeIdleCutoff: TimeInterval = 90
    private var emptyGraceSeconds: TimeInterval = 25

    init(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
        NextQueue.shared = self
    }

    // ── Lifecycle ──

    /// Start or stop to match the settings toggle. Safe to call repeatedly.
    func applySettings() {
        let enabled = UserSettings.shared.queueEnabled
        if enabled, timer == nil { start() }
        if !enabled, timer != nil { stop() }
    }

    private func start() {
        writeSchemaDoc()
        loadConfig()
        loadStore(initial: true)
        // A previous run may have died with the panel up; never let a stale
        // overlay render unmanaged. The state machine re-surfaces per policy.
        hideOverlay()
        let open = items.filter { !$0.done }
        shownContentKey = open.isEmpty ? nil : Self.contentKey(open)
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.recentActivations.append(Date()) }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        vflog("queue: started (\(items.filter { !$0.done }.count) open items)")
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
        hideOverlay()
        surface = .hidden
        vflog("queue: stopped")
    }

    // ── Tick — external edits, then the surfacing state machine ──

    private func tick() {
        reloadIfChanged()

        let open = items.filter { !$0.done }
        let now = Date()
        let idle = Self.secondsSinceLastInput()
        let active = !Self.screenIsLocked() && idle < activeIdleCutoff
        if !open.isEmpty { emptySince = nil }

        // Track idle stretches for the idle-return trigger.
        if idle >= idleResumeMinutes * 60 {
            if wasIdleSince == nil { wasIdleSince = now.addingTimeInterval(-idle) }
        }
        recentActivations.removeAll { now.timeIntervalSince($0) > switchBurstWindow }

        // The user closed the panel (✕ deletes the overlay file): back off.
        if case .hidden = surface {} else if !FileManager.default.fileExists(atPath: overlayURL.path) {
            let minutes: Double
            if case .persistentEmpty = surface { minutes = 30 } else { minutes = 10 }
            dismissCooldownUntil = now.addingTimeInterval(minutes * 60)
            surface = .hidden
            vflog("queue: dismissed by user, quiet for \(Int(minutes))m")
        }

        switch surface {
        case .brief(let until):
            if open.isEmpty || now >= until {
                hideOverlay()
                surface = .hidden
            } else {
                refreshOverlayIfContentChanged(open: open)
            }
        case .persistentEmpty:
            if !open.isEmpty {
                // The queue just got its next step. Show it only if the user
                // is actually there; otherwise drop the stale Empty panel and
                // let the .hidden branch surface the fill on their return.
                if active && !isBusy() {
                    showBrief(open: open, reason: "filled")
                } else {
                    hideOverlay()
                    surface = .hidden
                }
            } else if !active {
                hideOverlay()
                surface = .hidden
            }
        case .hidden:
            guard active, !isBusy(), now >= dismissCooldownUntil else { break }
            if open.isEmpty {
                if emptySince == nil { emptySince = now }
                if now.timeIntervalSince(emptySince!) >= emptyGraceSeconds {
                    showPersistentEmpty()
                }
                break
            }
            let contentKey = Self.contentKey(open)
            let gapOK = now.timeIntervalSince(lastTriggerShow) >= minGapMinutes * 60
            // A changed queue is the strongest signal. A fresh fill after
            // empty (shownContentKey == nil) is the designed first look and
            // skips the minimum-gap throttle.
            if contentKey != shownContentKey, shownContentKey == nil || gapOK {
                showBrief(open: open, reason: shownContentKey == nil ? "filled" : "updated")
            } else if let idleStart = wasIdleSince, idle < activeIdleCutoff,
                      now.timeIntervalSince(idleStart) >= idleResumeMinutes * 60, gapOK {
                showBrief(open: open, reason: "idle-return")
            } else if recentActivations.count >= switchBurstCount, gapOK {
                showBrief(open: open, reason: "app-switch burst")
            } else if now.timeIntervalSince(lastClockShow) >= clockMinutes * 60, gapOK {
                showBrief(open: open, reason: "clock")
            }
        }

        if idle < activeIdleCutoff { wasIdleSince = nil }
        if open.isEmpty { shownContentKey = nil }
    }

    // ── Surfacing actions ──

    /// Explicit "show me the queue now" (menu bar / pill context menu).
    /// Bypasses the dismiss cooldown — a direct request always wins.
    func showNow() {
        guard timer != nil else { return }   // feature disabled in settings
        reloadIfChanged()
        dismissCooldownUntil = .distantPast
        let open = items.filter { !$0.done }
        if open.isEmpty {
            showPersistentEmpty()
        } else {
            showBrief(open: open, reason: "manual")
        }
    }

    private func showBrief(open: [QueueItem], reason: String) {
        let now = Date()
        anchorIndex = (anchorIndex + 1) % 3
        writeOverlay(open: open, empty: false)
        surface = .brief(until: now.addingTimeInterval(showSeconds))
        lastTriggerShow = now
        lastClockShow = now
        shownContentKey = Self.contentKey(open)
        recentActivations.removeAll()
        vflog("queue: surfaced (\(reason))")
    }

    private func showPersistentEmpty() {
        writeOverlay(open: [], empty: true)
        surface = .persistentEmpty
        vflog("queue: empty panel up")
    }

    private func refreshOverlayIfContentChanged(open: [QueueItem]) {
        let key = Self.contentKey(open)
        guard key != shownContentKey else { return }
        shownContentKey = key
        writeOverlay(open: open, empty: false)
    }

    private static func contentKey(_ open: [QueueItem]) -> String {
        open.map { $0.text }.joined(separator: "\u{1}")
    }

    // ── Overlay projection ──

    private func writeOverlay(open: [QueueItem], empty: Bool) {
        // "system": bulk remove_overlay("all") from agent sessions must not
        // silence the queue (only the user's ✕ or the queue itself may).
        var doc: [String: Any] = ["type": "panel", "title": "Next queue",
                                  "width": 320, "system": true]
        if empty {
            doc["note"] = "Empty — what's next?"
            doc["blocks"] = [["kind": "text", "text": "Say “FLORA, add … to my queue”, or just start planning out loud."]]
            doc["position"] = "top-right"
        } else {
            doc["note"] = "→ " + open[0].text
            var blocks: [[String: Any]] = []
            if open.count > 1 {
                blocks.append(["kind": "bullets", "items": open.dropFirst().map { $0.text }])
            }
            let doneCount = items.count - open.count
            if doneCount > 0 {
                blocks.append(["kind": "text", "text": "✓ \(doneCount) done"])
            }
            doc["blocks"] = blocks
            doc["position"] = ["top-right", "top-center", "top-left"][anchorIndex]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted]) else { return }
        try? data.write(to: overlayURL, options: .atomic)
    }

    private func hideOverlay() {
        try? FileManager.default.removeItem(at: overlayURL)
    }

    // ── Store — queue.json is the API; parse tolerantly ──

    private func reloadIfChanged() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if mtime != lastFileMtime { loadStore(initial: false) }
        let configMtime = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
        if configMtime != lastConfigMtime { loadConfig() }
    }

    private func loadStore(initial: Bool) {
        lastFileMtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let rawItems = (parsed as? [String: Any])?["items"] as? [Any] ?? parsed as? [Any] ?? []
        items = rawItems.compactMap { raw in
            if let text = raw as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : QueueItem(id: Self.derivedID(trimmed), text: trimmed, done: false)
            }
            guard let dict = raw as? [String: Any],
                  let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let id = (dict["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return QueueItem(id: id?.isEmpty == false ? id! : Self.derivedID(text),
                             text: text, done: dict["done"] as? Bool ?? false)
        }
        if !initial { vflog("queue: reloaded from disk (\(items.filter { !$0.done }.count) open)") }
    }

    /// Stable id for hand-written entries that omit one, so `done <id>`
    /// keeps working across reloads and app restarts (FNV-1a — Swift's
    /// own hashValue is seeded per process and would drift).
    private static func derivedID(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "t%07x", hash % 0xFFFFFFF)
    }

    private func saveStore() {
        // Keep done history bounded (newest 20); open items always survive.
        let doneIDs = items.filter { $0.done }.map { $0.id }
        if doneIDs.count > 20 {
            let drop = Set(doneIDs.prefix(doneIDs.count - 20))
            items.removeAll { drop.contains($0.id) }
        }
        let payload: [String: Any] = ["items": items.map { item in
            ["id": item.id, "text": item.text, "done": item.done] as [String: Any]
        }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
        lastFileMtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    // ── voiceflow_queue tool (OpenCode runtime; codex edits the file) ──

    /// The dispatcher validates `operation` and permissions before this runs.
    static func toolExecute(_ arguments: [String: Any]) async throws -> AgentToolOutput {
        try await MainActor.run {
            guard let queue = NextQueue.shared, UserSettings.shared.queueEnabled else {
                throw AgentToolError.unavailable("the next queue is disabled in Voice Flow settings")
            }
            let operation = arguments["operation"] as? String ?? ""
            return try queue.execute(operation: operation, arguments: arguments)
        }
    }

    private func execute(operation: String, arguments: [String: Any]) throws -> AgentToolOutput {
        // The file is the API: another writer (codex FLORA, a Claude session,
        // the user's editor) may have changed it since the last 1s tick —
        // mutate the fresh state, never a stale snapshot.
        reloadIfChanged()
        switch operation {
        case "list":
            return AgentToolOutput(data: [
                "items": items.map { ["id": $0.id, "text": $0.text, "done": $0.done] },
                "open_count": items.filter { !$0.done }.count,
            ])
        case "add":
            var texts = arguments["texts"] as? [String] ?? []
            if let single = arguments["text"] as? String { texts.append(single) }
            let cleaned = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else {
                throw AgentToolError.invalidArguments("`texts` must contain at least one non-empty string")
            }
            for text in cleaned {
                items.append(QueueItem(id: QueueItem.freshID(), text: String(text.prefix(200)), done: false))
            }
            saveStore()
            return AgentToolOutput(data: [
                "added": cleaned.count,
                "open_count": items.filter { !$0.done }.count,
                "message": "Added. Only queue what the user explicitly asked for.",
            ])
        case "done", "remove":
            guard let id = (arguments["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                throw AgentToolError.invalidArguments("`id` is required — call list first to get item ids")
            }
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw AgentToolError.invalidArguments("no queue item has id \(id); call list for current ids")
            }
            if operation == "done" { items[index].done = true } else { items.remove(at: index) }
            saveStore()
            return AgentToolOutput(data: [
                "open_count": items.filter { !$0.done }.count,
                "message": operation == "done" ? "Marked done." : "Removed.",
            ])
        default:
            throw AgentToolError.invalidArguments("unknown queue operation \(operation)")
        }
    }

    // ── Config overrides (queue/config.json, all keys optional) ──

    private func loadConfig() {
        lastConfigMtime = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
        let dict = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: configURL))) as? [String: Any] ?? [:]
        func number(_ key: String, _ fallback: Double) -> Double {
            (dict[key] as? NSNumber)?.doubleValue ?? fallback
        }
        showSeconds = number("show_seconds", 45)
        clockMinutes = number("clock_minutes", 30)
        idleResumeMinutes = number("idle_resume_minutes", 5)
        switchBurstCount = Int(number("switch_burst_count", 3))
        switchBurstWindow = number("switch_burst_window_seconds", 45)
        minGapMinutes = number("min_gap_minutes", 6)
        activeIdleCutoff = number("active_idle_cutoff_seconds", 90)
        emptyGraceSeconds = number("empty_grace_seconds", 25)
    }

    // ── Activity probes (duplicated from the watcher on purpose: this
    //    feature must stay removable without touching other subsystems) ──

    private static func screenIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return dict["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    // ── Schema doc for agents and humans ──

    private func writeSchemaDoc() {
        let text = """
        # Voice Flow next queue

        `queue.json` in this directory is the user's small "what's next" list —
        Voice Flow shows it on screen and re-reads the file within ~1s of any
        change. Editing this file and using the `voiceflow_queue` tool are
        equivalent. The queue is the user's deliberate plan: only ever add
        items the user explicitly asked to queue — never auto-populate it.

        ```json
        {
          "items": [
            {"id": "a1b2c3d4", "text": "fix the speaker QA test", "done": false},
            {"id": "e5f6a7b8", "text": "Pantrella retention email", "done": true}
          ]
        }
        ```

        - Order is the queue order; the first open item is what the user does next.
        - `id`: any short unique string (omit it and Voice Flow derives one).
        - `done`: flip to true instead of deleting, so the user sees progress.
          Voice Flow prunes done items beyond the newest 20.
        - Reorder by rewriting the array. Keep texts short — one line each.

        `config.json` (optional) overrides surfacing tunables: show_seconds,
        clock_minutes, idle_resume_minutes, switch_burst_count,
        switch_burst_window_seconds, min_gap_minutes,
        active_idle_cutoff_seconds, empty_grace_seconds.
        """
        try? text.data(using: .utf8)?.write(to: schemaURL, options: .atomic)
    }
}
