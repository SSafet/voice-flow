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
        registerDeviceIdentity(&migrator)
        // Later Mac packages add their own registrations here, one line each.
        return migrator
    }

    /// The one device identity row (05 §3.2, L1M): one row, `id = 1`, no token
    /// and no private key — only the small non-secret facts the app needs to
    /// resume being a signed-in device.
    private static func registerDeviceIdentity(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("0002 device identity") { db in
            try db.create(table: "device_identity") { table in
                table.column("id", .integer).primaryKey().check { $0 == 1 }
                table.column("origin", .text).notNull()
                table.column("user_id", .text).notNull()
                table.column("email", .text).notNull()
                table.column("device_id", .text).notNull()
                table.column("label", .text).notNull()
                table.column("home_id", .text)
                table.column("signed_in_at", .text).notNull()
                table.column("refresh_material_removed", .integer).notNull().defaults(to: 0)
            }
        }
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
