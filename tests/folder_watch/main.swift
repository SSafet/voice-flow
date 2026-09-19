import Foundation

// Work package V4, task 5: the one folder watcher on this Mac (06 §3.16
// "Watch"). It is the single place File System Events are read, it turns them
// into the files contract's `changed` and `root_missing` messages for the
// directories a client asked for, and the same events are what branch 09's
// `file.changed` and the persona store read.

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { return }
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    failures += 1
}
func expectEqual<T: Equatable>(_ actual: T, _ wanted: T, _ message: String) {
    expect(actual == wanted, "\(message) — wanted \(wanted), got \(actual)")
}

let fileManager = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("vf-folder-watch-\(UUID().uuidString)", isDirectory: true)
    .resolvingSymlinksInPath()
try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: scratch) }

func write(_ text: String, to url: URL) {
    try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FolderWatchEvent] = []
    func record(_ event: FolderWatchEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }
    var all: [FolderWatchEvent] {
        lock.lock(); defer { lock.unlock() }; return events
    }
    /// Waits for an event the test is looking for, and fails rather than
    /// passing because something happened to arrive in time.
    func wait(seconds: Double, until matches: @escaping ([FolderWatchEvent]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if matches(all) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return matches(all)
    }
}

// ───────────────────── merging what the system reports ─────────────────────

let projectRoot = scratch.appendingPathComponent("project", isDirectory: true)
try fileManager.createDirectory(at: projectRoot.appendingPathComponent("src", isDirectory: true),
                                withIntermediateDirectories: true)

var coalescer = FolderChangeCoalescer(root: projectRoot)
expect(coalescer.isEmpty, "a fresh coalescer holds nothing")
coalescer.add([
    projectRoot.appendingPathComponent("src/b.swift").path,
    projectRoot.appendingPathComponent("src/a.swift").path,
    projectRoot.appendingPathComponent("src/a.swift").path + "/",
    projectRoot.path,
    "/somewhere/else/x.swift",
])
expect(!coalescer.isEmpty, "it holds what was added")
expectEqual(coalescer.drain(), ["", "src/a.swift", "src/b.swift"],
            "paths come back relative to the root, in order, once each, with the root itself as \"\"")
expectEqual(coalescer.drain(), [], "draining twice gives nothing the second time")
expect(coalescer.isEmpty, "and it is empty again")

// ─────────────── which client hears about which directory ───────────────

let personasRoot = scratch.appendingPathComponent("personas", isDirectory: true)
try fileManager.createDirectory(at: personasRoot, withIntermediateDirectories: true)

let watcher = FolderWatcher()
let deliveries = Collector()
let registry = FolderWatchRegistry(watcher: watcher, rootPath: { rootId in
    switch rootId {
    case "pr_1": return projectRoot
    case "personas-home_1": return personasRoot
    default: return nil
    }
})

func watch(_ client: String, _ rootId: String, _ dir: String) -> GitOperationError? {
    let request = TPWatchRequest(dir: dir, op: .watch, rootID: rootId)
    if case .failure(let error) = registry.apply(request, client: client) { return error }
    return nil
}
func unwatch(_ client: String, _ rootId: String, _ dir: String) {
    let request = TPWatchRequest(dir: dir, op: .unwatch, rootID: rootId)
    _ = registry.apply(request, client: client)
}

expect(watch("web", "pr_1", "") == nil, "a client may watch the top of a root")
expect(watch("web", "pr_1", "src") == nil, "and a directory inside it")
expect(watch("phone", "pr_1", "src") == nil, "and so may a second client")

if let error = watch("web", "no_such_root", "") {
    expectEqual(error.code, "files.not_found", "an unknown root is refused by name")
} else {
    expect(false, "watching a root that does not exist must be refused")
}

func delivered(_ paths: [String]) -> [WatchDelivery] {
    registry.deliveries(for: .changed(FolderChange(root: projectRoot, paths: paths)))
}

let inSource = delivered(["src/a.swift"])
expectEqual(inSource, [
    WatchDelivery(client: "phone", event: TPWatchEvent(dir: "src", rootID: "pr_1", type: .changed)),
    WatchDelivery(client: "web", event: TPWatchEvent(dir: "src", rootID: "pr_1", type: .changed)),
], "a changed file tells the clients watching the directory it is in, and nobody else")

expectEqual(delivered(["src/deep/b.swift"]), [],
            "a change deeper down does not redraw a directory that does not list it")
expectEqual(delivered(["top.txt"]), [
    WatchDelivery(client: "web", event: TPWatchEvent(dir: "", rootID: "pr_1", type: .changed)),
], "a change at the top of the root tells the client watching the top")
expectEqual(delivered(["src/a.swift", "src/b.swift"]).count, 2,
            "two changes in one directory are one message per client, not one per file")
expectEqual(delivered([""]), [
    WatchDelivery(client: "web", event: TPWatchEvent(dir: "", rootID: "pr_1", type: .changed)),
], "the root folder itself changing tells the client watching the top")

unwatch("web", "pr_1", "src")
expectEqual(delivered(["src/a.swift"]), [
    WatchDelivery(client: "phone", event: TPWatchEvent(dir: "src", rootID: "pr_1", type: .changed)),
], "unwatching stops that one directory for that one client")
expectEqual(delivered(["top.txt"]).count, 1, "and leaves the client's other watch alone")

registry.removeClient("web")
expectEqual(delivered(["top.txt"]), [], "a client that is gone hears nothing")

expectEqual(registry.deliveries(for: .rootMissing(projectRoot)), [
    WatchDelivery(client: "phone", event: TPWatchEvent(dir: nil, rootID: "pr_1", type: .rootMissing)),
], "a root that disappears is announced once per client, with no directory")

// ───────────────────── one stream per root, and no more ─────────────────────

expectEqual(registry.watchedRootIds().sorted(), ["pr_1"],
            "only a root somebody is watching is watched")
expectEqual(watcher.watchedRoots.count, 1, "one File System Events stream for it")
expect(watch("phone", "personas-home_1", "") == nil, "the personas root is watched like any other")
expectEqual(watcher.watchedRoots.count, 2, "one stream each, never one per client")
registry.removeClient("phone")
expectEqual(watcher.watchedRoots.count, 0, "and the streams stop when nobody is listening")

// ───────────────────── against the real file system ─────────────────────

let live = Collector()
let token = watcher.subscribe { event in live.record(event) }
defer { watcher.unsubscribe(token) }

let watched = scratch.appendingPathComponent("watched", isDirectory: true)
try fileManager.createDirectory(at: watched, withIntermediateDirectories: true)
try watcher.retain(root: watched)
expectEqual(watcher.watchedRoots.count, 1, "the live root is watched")

func changedPaths(_ events: [FolderWatchEvent]) -> [String] {
    events.flatMap { event -> [String] in
        if case .changed(let change) = event, change.root == watched { return change.paths }
        return []
    }
}

write("hello\n", to: watched.appendingPathComponent("note.txt"))
expect(live.wait(seconds: 15) { changedPaths($0).contains("note.txt") },
       "a file written into a watched folder is reported: \(changedPaths(live.all))")

write("deeper\n", to: watched.appendingPathComponent("sub/inner.txt"))
expect(live.wait(seconds: 15) { changedPaths($0).contains("sub/inner.txt") },
       "and so is one written further down: \(changedPaths(live.all))")

try fileManager.removeItem(at: watched)
expect(live.wait(seconds: 20) { events in
    events.contains { if case .rootMissing(let root) = $0 { return root == watched }; return false }
}, "a root folder that is deleted is reported as missing")

watcher.release(root: watched)
expectEqual(watcher.watchedRoots.count, 0, "releasing the last holder stops the stream")

if failures > 0 {
    FileHandle.standardError.write(Data("folder_watch: \(failures) failure(s)\n".utf8))
    exit(1)
}
print("folder_watch: one stream per root, coalesced, delivered only to the directories clients asked for")
