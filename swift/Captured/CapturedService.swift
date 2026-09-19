import Foundation

/// The one call the app makes (07 §3.1, §3.4): it opens the derived index in the
/// data folder, installs the live hooks, runs catch-up off the main thread and
/// reports how far it has got. Nothing else in the app opens the index.
final class CapturedService {
    static let shared: CapturedService = {
        do {
            return try CapturedService(root: VoiceFlowPaths.shared.configRoot)
        } catch {
            fatalError("captured index: cannot open \(VoiceFlowPaths.shared.configRoot.path) — \(error)")
        }
    }()

    let index: CapturedIndex
    let ingest: CapturedIngest

    private let queue = DispatchQueue(label: "voiceflow.captured.index", qos: .utility)
    private let lock = NSLock()
    private var hooksInstalled = false

    /// Opens the index and builds the ingest; it reads nothing.
    init(root: URL) throws {
        let pool = try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root))
        index = CapturedIndex(pool: pool)
        ingest = CapturedIngest(index: index, root: root)
    }

    /// The status line the Captures area shows, read without a second query.
    var progress: CapturedProgress { ingest.progress }

    /// Runs every step to the end on the calling thread. This is what the tests
    /// use; `start` calls it on the service's own queue.
    func catchUpNow() throws {
        while try ingest.catchUpStep() {}
    }

    /// Installs the live hooks and catches up in the background at low priority.
    func start() {
        installLiveHooks()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.catchUpNow()
            } catch {
                vflog("captured index: catch-up stopped — \(error)")
            }
        }
    }

    /// The live watcher hook. The bus belongs to `WorkflowWatcher`, which feeds
    /// every appended line through its existing append observer.
    func observe(stream: String, fields: [String: Any], at date: Date) {
        guard stream == "activity" else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.ingest.ingestWatcherLine(fields, at: date)
            } catch {
                vflog("captured index: live watcher line failed — \(error)")
            }
        }
    }

    private func installLiveHooks() {
        lock.lock()
        defer { lock.unlock() }
        guard !hooksInstalled else { return }
        hooksInstalled = true
        DictationStore.shared.addPersistObserver { [weak self] entries in
            guard let self else { return }
            self.queue.async {
                for entry in entries {
                    do {
                        try self.ingest.ingestDictation(entry)
                    } catch {
                        vflog("captured index: live dictation failed — \(error)")
                    }
                }
            }
        }
    }
}
