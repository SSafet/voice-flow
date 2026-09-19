import Foundation
import GRDB

/// The thread store's one migration step (06 §3.2). It is registered with the
/// single migrator K8 owns, because a transaction cannot span two database
/// files; the registration line lives in `swift/Store/Migrations.swift` and
/// later Mac packages add theirs after it.
///
/// Each table keeps the whole contract record as JSON in `record` beside the
/// few fields that are queried, so a listing never decodes more than it needs
/// and a record is never re-shaped by a second vocabulary. `home_id` always
/// holds the word `self`; Mac-only facts live in their own columns or their own
/// table and never inside a contract record.
enum ThreadStoreSchema {
    static let migrationID = "0002 thread store"

    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(migrationID) { db in
            try db.create(table: "projects") { t in
                t.primaryKey("id", .text)
                t.column("home_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("path", .text).notNull()
                t.column("git_remote", .text)
                t.column("git_default_branch", .text)
                t.column("is_general", .integer).notNull()
                t.column("remote_access", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("archived_at", .text)
                t.column("deleted_at", .text)
                t.column("version", .integer).notNull()
                t.column("record", .text).notNull()
            }
            try db.create(index: "projects_is_general", on: "projects", columns: ["is_general"])

            try db.create(table: "threads") { t in
                t.primaryKey("id", .text)
                t.column("project_id", .text).notNull().references("projects")
                t.column("home_id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("activity", .text).notNull()
                t.column("runtime", .text).notNull()
                t.column("persona_id", .text)
                t.column("last_activity_at", .text).notNull()
                t.column("last_read_at", .text)
                t.column("archived_at", .text)
                t.column("deleted_at", .text)
                t.column("pinned_slot", .integer)
                t.column("version", .integer).notNull()
                t.column("record", .text).notNull()
                t.column("last_seq", .integer).notNull().defaults(to: 0)
                t.column("last_origin_seq", .integer).notNull().defaults(to: 0)
                t.column("runtime_models", .text)
                t.column("imported_job_ids", .text)
            }
            try db.create(index: "threads_project_activity",
                          on: "threads",
                          columns: ["project_id", "last_activity_at"])

            try db.create(table: "turns") { t in
                t.primaryKey("id", .text)
                t.column("thread_id", .text).notNull().references("threads", onDelete: .cascade)
                t.column("created_at", .text).notNull()
                t.column("status", .text).notNull()
                t.column("record", .text).notNull()
            }
            try db.create(index: "turns_thread_created",
                          on: "turns",
                          columns: ["thread_id", "created_at"])

            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("turn_id", .text).notNull()
                t.column("thread_id", .text).notNull().references("threads", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("status", .text).notNull()
                t.column("text", .text)
                t.column("created_at", .text).notNull()
                t.column("record", .text).notNull()
            }
            try db.create(index: "items_thread_created",
                          on: "items",
                          columns: ["thread_id", "created_at"])
            try db.create(index: "items_turn", on: "items", columns: ["turn_id"])

            try db.create(virtualTable: "items_fts", using: FTS5()) { t in
                t.column("text")
                t.synchronize(withTable: "items")
            }

            try db.create(table: "thread_events") { t in
                t.column("thread_id", .text).notNull().references("threads", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("origin", .text).notNull()
                t.column("origin_seq", .integer).notNull()
                t.column("type", .text).notNull()
                t.column("turn_id", .text)
                t.column("item_id", .text)
                t.column("payload", .text).notNull()
                t.column("created_at", .text).notNull()
                t.primaryKey(["thread_id", "seq"])
                t.uniqueKey(["thread_id", "origin", "origin_seq"])
            }

            try db.create(table: "attachments") { t in
                t.primaryKey("id", .text)
                t.column("thread_id", .text).notNull().references("threads", onDelete: .cascade)
                t.column("item_id", .text)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("mime", .text).notNull()
                t.column("size_bytes", .integer).notNull()
                t.column("sha256", .text).notNull()
                t.column("capture_id", .text)
                t.column("local_path", .text)
                t.column("created_at", .text).notNull()
                t.column("record", .text).notNull()
            }
            try db.create(index: "attachments_thread", on: "attachments", columns: ["thread_id"])
            try db.create(index: "attachments_item", on: "attachments", columns: ["item_id"])
            try db.create(index: "attachments_capture", on: "attachments", columns: ["capture_id"])

            try db.create(table: "thread_commands") { t in
                t.primaryKey("command_id", .text)
                t.column("thread_id", .text)
                t.column("method", .text).notNull()
                t.column("params_hash", .text).notNull()
                t.column("result", .text).notNull()
                t.column("received_at", .text).notNull()
            }

            try db.create(table: "native_consumption") { t in
                t.column("thread_id", .text).notNull().references("threads", onDelete: .cascade)
                t.column("item_id", .text).notNull()
                t.column("spoken", .integer).notNull()
                t.column("resume_sentence", .text)
                t.column("dismissed_from_pill", .integer).notNull()
                t.column("speak_reply", .integer).notNull()
                t.primaryKey(["thread_id", "item_id"])
            }
        }
    }
}
