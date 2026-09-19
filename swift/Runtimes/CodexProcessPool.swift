import Foundation
import Darwin

/// One Codex process per thread (06 §3.6).
///
/// The pool owns process lifetime only; the app-server handshake stays in the
/// adapter. A thread's process is reused while it lives, stopped ten minutes
/// after its last turn, and terminated with its descendants at quit.
final class CodexProcessPool {
    private final class Entry {
        let process: Process
        /// Held open so a runtime waiting on stdin keeps running rather than
        /// seeing end-of-file.
        let input: Pipe
        var idleSince: Date?

        init(process: Process, input: Pipe) {
            self.process = process
            self.input = input
        }
    }

    private let idleTimeout: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(idleTimeout: TimeInterval = 600, now: @escaping () -> Date = Date.init) {
        self.idleTimeout = idleTimeout
        self.now = now
    }

    /// The same `Process` for a thread while it is alive, a new one otherwise.
    func process(forThread threadID: String, plan: RuntimeProcessPlan) throws -> Process {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[threadID], entry.process.isRunning {
            entry.idleSince = nil
            return entry.process
        }
        if let stale = entries.removeValue(forKey: threadID) {
            Self.terminate(stale.process)
        }
        let input = Pipe()
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.currentDirectory
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        entries[threadID] = Entry(process: process, input: input)
        return process
    }

    func markBusy(threadID: String) {
        lock.lock()
        entries[threadID]?.idleSince = nil
        lock.unlock()
    }

    func markIdle(threadID: String) {
        let timestamp = now()
        lock.lock()
        entries[threadID]?.idleSince = timestamp
        lock.unlock()
    }

    /// Stops every thread that has been idle for longer than the limit and
    /// leaves busy threads alone.
    func sweepIdle() {
        let deadline = now()
        lock.lock()
        var expired: [Entry] = []
        for (threadID, entry) in entries {
            guard let idleSince = entry.idleSince else { continue }
            if deadline.timeIntervalSince(idleSince) > idleTimeout {
                expired.append(entry)
                entries.removeValue(forKey: threadID)
            }
        }
        lock.unlock()
        expired.forEach { Self.terminate($0.process) }
    }

    func stop(threadID: String) {
        lock.lock()
        let entry = entries.removeValue(forKey: threadID)
        lock.unlock()
        entry.map { Self.terminate($0.process) }
    }

    func stopAll() {
        lock.lock()
        let all = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        all.forEach { Self.terminate($0.process) }
    }

    var liveThreadIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.value.process.isRunning }.map(\.key).sorted()
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        for child in descendants(of: pid).reversed() where child > 0 {
            kill(child, SIGTERM)
        }
        kill(pid, SIGTERM)
        process.waitUntilExit()
    }

    /// Descendants of a process, so a runtime and everything it spawned is
    /// terminated rather than orphaned.
    private static func descendants(of parent: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [parent]
        var seen: Set<pid_t> = [parent]
        while let current = queue.first {
            queue.removeFirst()
            var children = [pid_t](repeating: 0, count: 128)
            let bytes = proc_listchildpids(
                current, &children,
                Int32(children.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { continue }
            let count = min(Int(bytes) / MemoryLayout<pid_t>.size, children.count)
            for child in children.prefix(count) where child > 0 && !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }
}
