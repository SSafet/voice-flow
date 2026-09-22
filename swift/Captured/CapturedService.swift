import Foundation

/// The one call the app makes (07 §3.1, §3.4): it opens the derived index in the
/// data folder, installs the live hooks, runs catch-up off the main thread and
/// reports how far it has got. Nothing else in the app opens the index.
final class CapturedService {
    private static let defaultService: Result<CapturedService, Error> = Result {
        try CapturedService(root: VoiceFlowPaths.shared.configRoot, dictations: .shared)
    }
    static var shared: CapturedService? { try? defaultService.get() }
    static var startupError: String? {
        if case .failure(let error) = defaultService { return String(describing: error) }
        return nil
    }

    let index: CapturedIndex
    let ingest: CapturedIngest

    private let queue = DispatchQueue(label: "voiceflow.captured.index", qos: .utility)
    private let lock = NSLock()
    private var hooksInstalled = false
    private let dictations: DictationStore
    private let root: URL
    private var sourceCommitObserver: NSObjectProtocol?
    private var storedError: String?
    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return storedError
    }

    private func report(_ error: String?) {
        lock.lock(); defer { lock.unlock() }
        storedError = error
    }

    deinit {
        if let sourceCommitObserver { NotificationCenter.default.removeObserver(sourceCommitObserver) }
    }

    /// Opens the index and builds the ingest; it reads nothing.
    init(root: URL, dictations: DictationStore? = nil) throws {
        self.root = root.standardizedFileURL
        self.dictations = dictations ?? DictationStore(root: root)
        let pool = try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root))
        index = CapturedIndex(pool: pool)
        ingest = CapturedIngest(index: index, root: root)
    }

    /// The status line the Captures area shows, read without a second query.
    var progress: CapturedProgress { ingest.progress }

    /// Runs every step to the end on the calling thread. This is what the tests
    /// use; `start` calls it on the service's own queue.
    func catchUpNow() throws {
        // A damaged stream must not starve every other stream. Snapshot the
        // work once, commit each source independently, report every failure.
        var failures: [String] = []
        for step in try ingest.plan() {
            do { _ = try ingest.run(step) }
            catch { failures.append("\(step.source)/\(step.key): \(error)") }
        }
        _ = try ingest.plan()
        if !failures.isEmpty {
            throw IngestError.malformedLine(failures.joined(separator: "\n"))
        }
    }

    /// Installs the live hooks and catches up in the background at low priority.
    func start() {
        installLiveHooks()
        catchUpSoon()
    }

    /// Called after a bundle, shot, review or recording has been committed.
    func catchUpSoon() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.catchUpNow()
                self.report(nil)
            } catch {
                self.report(String(describing: error))
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
        sourceCommitObserver = NotificationCenter.default.addObserver(
            forName: CapturedSourceEvents.committed, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let sourceRoot = notification.object as? URL,
                  sourceRoot.standardizedFileURL == self.root else { return }
            self.catchUpSoon()
        }
        dictations.addPersistObserver { [weak self] entries in
            guard let self else { return }
            self.queue.async {
                do {
                    // Includes tombstones and folded edits, so live removals
                    // agree with a rebuild rather than lingering in search.
                    try self.catchUpNow()
                    self.report(nil)
                } catch {
                    self.report(String(describing: error))
                    vflog("captured index: live dictation failed — \(error)")
                }
            }
        }
    }
}
