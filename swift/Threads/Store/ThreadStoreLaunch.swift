import Foundation
import GRDB

/// What a ready launch made, took or swept: whether the store was new, the
/// day's backup when one was due, and the attachment folders the sweep removed.
struct LaunchReport: Equatable {
    let created: Bool
    let backup: URL?
    let sweptFolders: [URL]
}

/// Why the store could not be opened: the reason the check gave, the file that
/// was set aside untouched, and the newest backup the window may offer.
struct DamageReport: Codable, Equatable {
    let reason: String
    let setAside: URL
    let newestBackup: URL?
}

/// The one launch entry point (06 §3.2, decision 10): check, set aside on
/// damage, back up when due, open and migrate, sweep — or report damage.
///
/// Doing the whole order here is what keeps "before every schema change" and
/// "at launch" from being two callers that can drift apart.
enum ThreadStoreLaunch {
    enum Outcome {
        case ready(DatabasePool, LaunchReport)
        case damaged(DamageReport)
    }

    static func open(configRoot: URL, now: Date) throws -> Outcome {
        let storeURL = ThreadDatabase.url(configRoot: configRoot)
        if var pending = try readPending(configRoot: configRoot) {
            if !pending.preserved {
                try ThreadStoreHealth.finishPreserving(at: storeURL, to: pending.report.setAside)
                pending.preserved = true
                try writePending(pending, configRoot: configRoot)
            }
            return .damaged(pending.report)
        }
        let backupsFolder = configRoot.appendingPathComponent("backups", isDirectory: true)
        switch ThreadStoreHealth.check(at: storeURL) {
        case .absent:
            let pool = try ThreadDatabase.open(at: storeURL)
            let swept = try sweepAttachmentFolders(configRoot: configRoot, pool: pool)
            return .ready(pool, LaunchReport(created: true, backup: nil, sweptFolders: swept))

        case .damaged(let reason):
            let report = DamageReport(reason: reason,
                                      setAside: ThreadStoreHealth.preservationURL(for: storeURL, now: now),
                                      newestBackup: try ThreadStoreHealth.backups(in: backupsFolder).first)
            // Record intent before the first rename. Restarting at any point
            // cannot mistake an absent active file for a fresh installation.
            try writePending(PendingRecovery(report: report, preserved: false), configRoot: configRoot)
            try ThreadStoreHealth.finishPreserving(at: storeURL, to: report.setAside)
            try writePending(PendingRecovery(report: report, preserved: true), configRoot: configRoot)
            return .damaged(report)

        case .ok:
            let backup = try backupBeforeMigrating(at: storeURL, into: backupsFolder, now: now)
            let pool = try ThreadDatabase.open(at: storeURL)
            let swept = try sweepAttachmentFolders(configRoot: configRoot, pool: pool)
            return .ready(pool, LaunchReport(created: false, backup: backup,
                                             sweptFolders: swept))
        }
    }

    /// Backs the file up before `ThreadDatabase.open` migrates it, so a day's
    /// backup holds the store as it was, not as the new schema leaves it. The
    /// temporary pool is closed before the store proper is opened.
    private static func backupBeforeMigrating(at url: URL, into folder: URL,
                                              now: Date) throws -> URL? {
        let existing = try DatabasePool(path: url.path)
        do {
            let needsMigration = try existing.read { db in
                try ThreadStoreSchemaProof.validate(db)
                return try !StoreMigrations.migrator().hasCompletedMigrations(db)
            }
            let backup = needsMigration
                ? try ThreadStoreHealth.backup(pool: existing, into: folder, now: now, beforeSchemaUpgrade: true)
                : try ThreadStoreHealth.backupIfDue(pool: existing, into: folder, now: now)
            try existing.close()
            return backup
        } catch {
            try? existing.close()
            throw error
        }
    }

    struct PendingRecovery: Codable {
        let report: DamageReport
        var preserved: Bool
    }

    static func pendingURL(configRoot: URL) -> URL {
        configRoot.appendingPathComponent("threads-recovery.json")
    }

    static func readPending(configRoot: URL) throws -> PendingRecovery? {
        let url = pendingURL(configRoot: configRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let pending = try JSONDecoder().decode(PendingRecovery.self, from: Data(contentsOf: url))
        guard pending.report.setAside.deletingLastPathComponent().standardizedFileURL == configRoot.standardizedFileURL,
              pending.report.setAside.lastPathComponent.hasPrefix("threads.sqlite.damaged-") else {
            throw ThreadStoreError(code: .notSupported, message: "The recovery record refers to a different configuration folder. No files were moved.")
        }
        return pending
    }

    static func writePending(_ pending: PendingRecovery, configRoot: URL) throws {
        let url = pendingURL(configRoot: configRoot)
        try JSONEncoder().encode(pending).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try ThreadStoreHealth.synchronizeDirectory(configRoot)
    }

    static func completeRecovery(configRoot: URL) throws {
        let url = pendingURL(configRoot: configRoot)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            try ThreadStoreHealth.synchronizeDirectory(configRoot)
        }
    }

    /// The launch sweep: attachment folders whose thread is gone are removed
    /// after the fact, which is what catches a crash between a delete's commit
    /// and its file removal (06 §3.2, decision 11).
    private static func sweepAttachmentFolders(configRoot: URL, pool: DatabasePool) throws -> [URL] {
        // A preserved database can still refer to any attachment folder.
        // Starting empty/restoring history must not erase those recovery bytes.
        if try FileManager.default.contentsOfDirectory(atPath: configRoot.path)
            .contains(where: { $0.hasPrefix("threads.sqlite.damaged-") }) { return [] }
        let paths = VoiceFlowPaths(
            environment: [VoiceFlowPaths.configRootEnvironmentKey: configRoot.path])
        let store = ThreadStore(pool: pool, paths: paths, homeID: { StoreHome.marker })
        return try store.sweepAttachmentFolders()
    }
}
