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
struct DamageReport: Equatable {
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
        let backupsFolder = configRoot.appendingPathComponent("backups", isDirectory: true)
        switch ThreadStoreHealth.check(at: storeURL) {
        case .absent:
            let pool = try ThreadDatabase.open(at: storeURL)
            let swept = try sweepAttachmentFolders(configRoot: configRoot, pool: pool)
            return .ready(pool, LaunchReport(created: true, backup: nil, sweptFolders: swept))

        case .damaged(let reason):
            let setAside = try ThreadStoreHealth.setAside(at: storeURL, now: now)
            let newest = try ThreadStoreHealth.backups(in: backupsFolder).first
            return .damaged(DamageReport(reason: reason, setAside: setAside,
                                         newestBackup: newest))

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
            let backup = try ThreadStoreHealth.backupIfDue(pool: existing, into: folder, now: now)
            try existing.close()
            return backup
        } catch {
            try? existing.close()
            throw error
        }
    }

    /// The launch sweep: attachment folders whose thread is gone are removed
    /// after the fact, which is what catches a crash between a delete's commit
    /// and its file removal (06 §3.2, decision 11).
    private static func sweepAttachmentFolders(configRoot: URL, pool: DatabasePool) throws -> [URL] {
        let paths = VoiceFlowPaths(
            environment: [VoiceFlowPaths.configRootEnvironmentKey: configRoot.path])
        let store = ThreadStore(pool: pool, paths: paths, homeID: { StoreHome.marker })
        return try store.sweepAttachmentFolders()
    }
}
