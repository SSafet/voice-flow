import Foundation
import GRDB

/// The one registration point for schema steps in `threads.sqlite`
/// (06 §3.2, ruling C32). Every store that needs a transaction together with
/// the threads lives in this one file, so every store registers its steps here:
/// the thread records and their events, the channel outbox and the command
/// ledger, the triggers, the persona records and the captured index each add
/// one call at the end of `migrator()`.
///
/// Two rules keep old files openable: a step's name is never changed and a step
/// is never removed, because GRDB records the names it has applied; and a new
/// step is added after the ones already there, because they run in the order
/// they were registered.
enum StoreMigrations {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerStoreMeta(&migrator)
        // Later Mac packages add their own registrations here, one line each.
        return migrator
    }

    /// The store's key-and-value table (06 §3.2): the outcome of the legacy
    /// import and this installation's own id live in it.
    private static func registerStoreMeta(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("0001 store meta") { db in
            try db.create(table: "store_meta") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
        }
    }
}
