import Foundation
import GRDB

/// The four ways out of a damaged store that the recovery window offers
/// (06 §3.2 "Damage is surfaced and recoverable"): restore the newest backup,
/// try a repair, start empty, or show the files in Finder.
///
/// In every case the `.damaged-` file stays where it is, so no choice discards
/// what the user had.
enum ThreadStoreRecovery {
    enum Choice: Equatable {
        case restoreBackup(URL)
        case repair
        case startEmpty
        case showInFinder
    }

    /// Always `.repair`, `.startEmpty` and `.showInFinder`, with
    /// `.restoreBackup(url)` first when a backup is there. With no backup it is
    /// not offered at all.
    static func choices(for report: DamageReport, configRoot: URL) throws -> [Choice] {
        let backupsFolder = configRoot.appendingPathComponent("backups", isDirectory: true)
        let listed = try ThreadStoreHealth.backups(in: backupsFolder)
        var result: [Choice] = []
        if let newest = listed.first ?? report.newestBackup {
            result.append(.restoreBackup(newest))
        }
        result.append(.repair)
        result.append(.startEmpty)
        result.append(.showInFinder)
        return result
    }

    /// Carries out one choice and answers the pool to work in, or `nil` for the
    /// choice that only shows files. The damaged file is never moved.
    static func apply(_ choice: Choice, report: DamageReport, configRoot: URL,
                      now: Date) throws -> DatabasePool? {
        let storeURL = ThreadDatabase.url(configRoot: configRoot)
        switch choice {
        case .restoreBackup(let backup):
            try ThreadStoreHealth.restore(backup, to: storeURL, now: now)
            return try ThreadDatabase.open(at: storeURL)

        case .repair:
            _ = try ThreadStoreHealth.repair(from: report.setAside, to: storeURL)
            return try ThreadDatabase.open(at: storeURL)

        case .startEmpty:
            return try ThreadDatabase.open(at: storeURL)

        case .showInFinder:
            ThreadStoreRecoveryWindow.revealInFinder(report.setAside)
            return nil
        }
    }
}
