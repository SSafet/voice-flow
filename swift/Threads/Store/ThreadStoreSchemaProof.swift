import Foundation
import GRDB

/// Recovery uses GRDB's own migration/schema comparison. A recovered ledger
/// is evidence only when the complete schema agrees with that migration prefix.
enum ThreadStoreSchemaProof {
    /// Only these migrations contain exclusively schema creation. A future
    /// data migration must never be inferred from schema shape alone.
    static let reconstructiblePrefix = ["0001 store meta", "0002 thread store"]

    @discardableResult
    static func validate(_ db: Database, migrator: DatabaseMigrator = StoreMigrations.migrator()) throws -> [String] {
        let applied = try migrator.appliedIdentifiers(db)
        let completed = try migrator.completedMigrations(db)
        guard applied == Set(completed) else {
            throw failure("The database has unknown or incomplete migration history. Use a compatible app or a verified backup.")
        }
        if completed.isEmpty {
            let objects = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                """) ?? 0
            guard objects == 0 else {
                throw failure("The database contains records without a verified migration history. Repair or restore it before continuing.")
            }
        } else if try migrator.hasSchemaChanges(db) {
            throw failure("The database schema does not match its migration history. Repair or restore it before continuing.")
        }
        return completed
    }

    /// Only a staged repair candidate may call this. A matching schema prefix
    /// proves the corresponding DDL completed; remaining migrations still run.
    static func reconstructRecoveredLedger(_ queue: DatabaseQueue) throws {
        let migrator = StoreMigrations.migrator()
        try queue.write { db in
            let applied = try migrator.appliedIdentifiers(db)
            guard applied.isSubset(of: Set(migrator.migrations)) else {
                throw failure("Recovered data belongs to a newer or unknown schema. Its migration history was preserved.")
            }
            if (try? validate(db, migrator: migrator)) != nil, !applied.isEmpty { return }
            let candidates = Array(migrator.migrations.prefix { reconstructiblePrefix.contains($0) })
            for count in stride(from: candidates.count, through: 1, by: -1) {
                var matches = false
                try db.inSavepoint {
                    try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                    try db.execute(sql: "DELETE FROM grdb_migrations")
                    for identifier in candidates.prefix(count) {
                        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
                    }
                    matches = try !migrator.hasSchemaChanges(db)
                    return matches ? .commit : .rollback
                }
                if matches { return }
            }
            throw failure("The recovered schema is incomplete or cannot be proved. The damaged database has been kept; restore a backup or inspect the files.")
        }
    }

    static func verifyIntegrity(_ db: Database) throws {
        let answers = try String.fetchAll(db, sql: "PRAGMA integrity_check")
        guard answers == ["ok"] else {
            throw failure("Database integrity verification failed: \(answers.joined(separator: "; "))")
        }
        guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw failure("Recovered records contain broken references. The candidate was not activated.")
        }
    }

    private static func failure(_ message: String) -> ThreadStoreError {
        ThreadStoreError(code: .notSupported, message: message)
    }
}
