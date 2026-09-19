import Foundation
import CoreServices
import Darwin

/// One directory's worth of changes: the root that was watched and the changed
/// paths relative to it, the root itself being the empty string.
struct FolderChange: Equatable, Sendable {
    let root: URL
    let paths: [String]
}

/// What the one File System Events reader on this Mac reports. `rootMissing`
/// says the watched folder itself is gone, so the stream has stopped.
enum FolderWatchEvent: Equatable, Sendable {
    case changed(FolderChange)
    case rootMissing(URL)
}

/// Merges the paths of one callback into the set a client hears about: each
/// absolute path becomes relative to its root, the root itself becomes the
/// empty string, anything outside the root is dropped, a trailing slash is
/// ignored and each path is kept once.
struct FolderChangeCoalescer: Equatable, Sendable {
    let root: URL
    private var paths: Set<String> = []

    init(root: URL) {
        self.root = root
    }

    var isEmpty: Bool { paths.isEmpty }

    mutating func add(_ absolutePaths: [String]) {
        let rootPath = FolderChangeCoalescer.canonical(root.path)
        for absolute in absolutePaths {
            let candidate = FolderChangeCoalescer.canonical(absolute)
            guard !candidate.isEmpty else { continue }
            if candidate == rootPath {
                paths.insert("")
            } else if candidate.hasPrefix(rootPath + "/") {
                paths.insert(String(candidate.dropFirst(rootPath.count + 1)))
            }
        }
    }

    /// The merged paths in order, once each, and the coalescer is empty again.
    /// A second drain answers nothing.
    mutating func drain() -> [String] {
        let answer = paths.sorted()
        paths.removeAll()
        return answer
    }

    private static func canonical(_ path: String) -> String {
        var value = path
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        guard !value.isEmpty else { return value }
        // File System Events reports the canonical path, so a watch of `/var`
        // or `/tmp` hears about `/private/var` and `/private/tmp`. The longest
        // existing ancestor is resolved the same way and the rest, which may
        // not exist yet, is put back, so root and path always agree.
        var existing = value
        var suffix: [String] = []
        while !existing.isEmpty && !FileManager.default.fileExists(atPath: existing) {
            let url = URL(fileURLWithPath: existing)
            suffix.insert(url.lastPathComponent, at: 0)
            existing = url.deletingLastPathComponent().path
            if existing == "/" { break }
        }
        var result = FolderChangeCoalescer.realPath(existing) ?? existing
        for component in suffix {
            result += "/" + component
        }
        return result
    }

    private static func realPath(_ path: String) -> String? {
        path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }
}

/// Why a File System Events stream could not be started.
struct FolderWatcherError: Error, Equatable {
    let message: String
}

/// The one File System Events reader on this Mac (06 §3.16 "Watch"). One stream
/// per watched root, driven by a dispatch queue of this class, coalesced into
/// one change per root per callback and handed to every subscriber.
final class FolderWatcher {
    static let latency: Double = 0.3

    private final class StreamBox {
        let root: URL
        weak var watcher: FolderWatcher?
        var handle: FSEventStreamRef?

        init(root: URL, watcher: FolderWatcher) {
            self.root = root
            self.watcher = watcher
        }

        func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
            for flag in flags
            where flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                watcher?.rootMissing(box: self)
                return
            }
            if !FileManager.default.fileExists(atPath: root.path) {
                watcher?.rootMissing(box: self)
                return
            }
            var coalescer = FolderChangeCoalescer(root: root)
            coalescer.add(paths)
            let changed = coalescer.drain()
            guard !changed.isEmpty else { return }
            watcher?.deliver(.changed(FolderChange(root: root, paths: changed)))
        }
    }

    private static let callback: FSEventStreamCallback = {
        _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let box = Unmanaged<StreamBox>.fromOpaque(info).takeUnretainedValue()
        // The stream's flags ask for C-string paths rather than CF types, so
        // File System Events hands back a C array of C strings.
        let list = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
        var paths: [String] = []
        paths.reserveCapacity(numEvents)
        for index in 0..<numEvents {
            if let value = list[index] {
                paths.append(String(cString: value))
            }
        }
        var flags: [FSEventStreamEventFlags] = []
        flags.reserveCapacity(numEvents)
        for index in 0..<numEvents {
            flags.append(eventFlags[index])
        }
        box.handleEvents(paths: paths, flags: flags)
    }

    private let latency: Double
    private let queue = DispatchQueue(label: "com.voiceflow.folder-watcher")
    private let lock = NSLock()
    private var holders: [String: Int] = [:]
    private var streams: [String: StreamBox] = [:]
    private var nextToken = 1
    private var handlers: [Int: (FolderWatchEvent) -> Void] = [:]

    init(latency: Double = FolderWatcher.latency) {
        self.latency = latency
    }

    /// The roots that currently have a stream.
    var watchedRoots: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return streams.values.map(\.root)
    }

    /// Starts one stream for a root that is not yet watched; a second holder is
    /// counted without starting a second stream.
    func retain(root: URL) throws {
        lock.lock()
        let key = root.path
        if let count = holders[key] {
            holders[key] = count + 1
            lock.unlock()
            return
        }
        holders[key] = 1
        lock.unlock()
        do {
            try startStream(root: root)
        } catch {
            lock.lock()
            holders.removeValue(forKey: key)
            lock.unlock()
            throw error
        }
    }

    /// Stops the stream only when the last holder is gone.
    func release(root: URL) {
        lock.lock()
        let key = root.path
        guard let count = holders[key] else {
            lock.unlock()
            return
        }
        if count > 1 {
            holders[key] = count - 1
            lock.unlock()
            return
        }
        holders.removeValue(forKey: key)
        lock.unlock()
        stopStream(root: root)
    }

    @discardableResult
    func subscribe(_ handler: @escaping (FolderWatchEvent) -> Void) -> Int {
        lock.lock()
        let token = nextToken
        nextToken += 1
        handlers[token] = handler
        lock.unlock()
        return token
    }

    func unsubscribe(_ token: Int) {
        lock.lock()
        handlers.removeValue(forKey: token)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let boxes = streams
        streams.removeAll()
        holders.removeAll()
        handlers.removeAll()
        lock.unlock()
        for box in boxes.values { stop(box) }
    }

    // MARK: streams

    private func startStream(root: URL) throws {
        let box = StreamBox(root: root, watcher: self)
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(box).toOpaque()
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer)
        let paths = [root.path] as CFArray
        guard let handle = FSEventStreamCreate(
            kCFAllocatorDefault, FolderWatcher.callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            throw FolderWatcherError(message: "could not watch \(root.path)")
        }
        box.handle = handle
        FSEventStreamSetDispatchQueue(handle, queue)
        lock.lock()
        streams[root.path] = box
        lock.unlock()
        guard FSEventStreamStart(handle) else {
            lock.lock()
            streams.removeValue(forKey: root.path)
            lock.unlock()
            FSEventStreamInvalidate(handle)
            FSEventStreamRelease(handle)
            throw FolderWatcherError(message: "could not start watching \(root.path)")
        }
    }

    private func stopStream(root: URL) {
        lock.lock()
        let box = streams.removeValue(forKey: root.path)
        lock.unlock()
        if let box { stop(box) }
    }

    private func stop(_ box: StreamBox) {
        guard let handle = box.handle else { return }
        FSEventStreamStop(handle)
        FSEventStreamInvalidate(handle)
        FSEventStreamRelease(handle)
        box.handle = nil
    }

    /// A root that no longer exists: its stream is stopped and every subscriber
    /// hears about it once.
    private func rootMissing(box: StreamBox) {
        lock.lock()
        let stored = streams.removeValue(forKey: box.root.path)
        holders.removeValue(forKey: box.root.path)
        lock.unlock()
        guard stored != nil else { return }
        stop(box)
        deliver(.rootMissing(box.root))
    }

    private func deliver(_ event: FolderWatchEvent) {
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        for handler in current { handler(event) }
    }
}

/// One client hearing about one directory (or about a root going missing).
struct WatchDelivery: Equatable, Sendable {
    let client: String
    let event: TPWatchEvent
}

/// Decides which client hears about which directory, in the files contract's
/// own `changed` and `root_missing` messages (06 §3.16 "Watch").
final class FolderWatchRegistry {
    private struct Watch: Equatable {
        let client: String
        let rootId: String
        let dir: String
    }

    private let watcher: FolderWatcher
    private let rootPath: (String) -> URL?
    private let lock = NSLock()
    private var watches: [Watch] = []
    private var rootURLs: [String: URL] = [:]

    init(watcher: FolderWatcher, rootPath: @escaping (String) -> URL?) {
        self.watcher = watcher
        self.rootPath = rootPath
    }

    func apply(_ request: TPWatchRequest, client: String) -> Result<Void, GitOperationError> {
        switch request.op {
        case .watch:
            return watch(request, client: client)
        case .unwatch:
            return unwatch(request, client: client)
        }
    }

    private func watch(_ request: TPWatchRequest, client: String)
        -> Result<Void, GitOperationError> {
        guard let root = rootPath(request.rootID) else {
            return .failure(GitOperationError(
                code: "files.not_found",
                message: "no watched root is named \"\(request.rootID)\""))
        }
        lock.lock()
        let alreadyRoot = watches.contains {
            $0.client == client && $0.rootId == request.rootID
        }
        let alreadyDir = watches.contains {
            $0.client == client && $0.rootId == request.rootID && $0.dir == request.dir
        }
        rootURLs[request.rootID] = root
        if !alreadyDir {
            watches.append(Watch(client: client, rootId: request.rootID, dir: request.dir))
        }
        lock.unlock()
        guard !alreadyRoot else { return .success(()) }
        do {
            try watcher.retain(root: root)
        } catch {
            lock.lock()
            watches.removeAll {
                $0.client == client && $0.rootId == request.rootID && $0.dir == request.dir
            }
            lock.unlock()
            return .failure(GitOperationError(
                code: "not_supported",
                message: "\(request.rootID) could not be watched: \(error)"))
        }
        return .success(())
    }

    private func unwatch(_ request: TPWatchRequest, client: String)
        -> Result<Void, GitOperationError> {
        var release: URL?
        lock.lock()
        let hadTriple = watches.contains {
            $0.client == client && $0.rootId == request.rootID && $0.dir == request.dir
        }
        watches.removeAll {
            $0.client == client && $0.rootId == request.rootID && $0.dir == request.dir
        }
        let stillWatching = watches.contains {
            $0.client == client && $0.rootId == request.rootID
        }
        if hadTriple && !stillWatching {
            release = rootURLs[request.rootID]
            let anyClient = watches.contains { $0.rootId == request.rootID }
            if !anyClient { rootURLs.removeValue(forKey: request.rootID) }
        }
        lock.unlock()
        if let release { watcher.release(root: release) }
        return .success(())
    }

    /// Forgets every triple of that client and releases what it held.
    func removeClient(_ client: String) {
        lock.lock()
        let removed = watches.filter { $0.client == client }
        watches.removeAll { $0.client == client }
        var releases: [URL] = []
        for rootId in Set(removed.map(\.rootId)) {
            if let root = rootURLs[rootId] { releases.append(root) }
            let anyClient = watches.contains { $0.rootId == rootId }
            if !anyClient { rootURLs.removeValue(forKey: rootId) }
        }
        lock.unlock()
        for root in releases { watcher.release(root: root) }
    }

    func watchedRootIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(Set(watches.map(\.rootId))).sorted()
    }

    func deliveries(for event: FolderWatchEvent) -> [WatchDelivery] {
        switch event {
        case .changed(let change):
            return changedDeliveries(change)
        case .rootMissing(let root):
            return missingDeliveries(root)
        }
    }

    private func changedDeliveries(_ change: FolderChange) -> [WatchDelivery] {
        lock.lock()
        defer { lock.unlock() }
        let changedRoot = change.root.path
        var seen = Set<String>()
        var answer: [WatchDelivery] = []
        for watch in watches {
            guard let root = rootURLs[watch.rootId], root.path == changedRoot else { continue }
            guard change.paths.contains(where: {
                FolderWatchRegistry.parentDirectory(of: $0) == watch.dir
            }) else { continue }
            let key = "\(watch.client)\u{0}\(watch.dir)"
            guard seen.insert(key).inserted else { continue }
            answer.append(WatchDelivery(
                client: watch.client,
                event: TPWatchEvent(dir: watch.dir, rootID: watch.rootId, type: .changed)))
        }
        return answer.sorted(by: FolderWatchRegistry.ordered)
    }

    private func missingDeliveries(_ root: URL) -> [WatchDelivery] {
        lock.lock()
        defer { lock.unlock() }
        let missingRoot = root.path
        var seen = Set<String>()
        var answer: [WatchDelivery] = []
        for watch in watches {
            guard let watched = rootURLs[watch.rootId], watched.path == missingRoot else {
                continue
            }
            guard seen.insert(watch.client).inserted else { continue }
            answer.append(WatchDelivery(
                client: watch.client,
                event: TPWatchEvent(dir: nil, rootID: watch.rootId, type: .rootMissing)))
        }
        return answer.sorted(by: FolderWatchRegistry.ordered)
    }

    private static func parentDirectory(of relativePath: String) -> String {
        guard let index = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[relativePath.startIndex..<index])
    }

    private static func ordered(_ left: WatchDelivery, _ right: WatchDelivery) -> Bool {
        if left.client != right.client { return left.client < right.client }
        return (left.event.dir ?? "") < (right.event.dir ?? "")
    }
}
