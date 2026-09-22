import Foundation
import GRDB

/// The schema of the captured index (07 §3.1) and the one version number.
///
/// The index is derived: every row can be rebuilt from the files on disk plus
/// the thread store, so there are no migrations. When the version below differs
/// from `meta.schema_version`, `CapturedDatabase` drops every table here and
/// creates them again, and the sources are read from the beginning. The FTS
/// table is kept in step by triggers, not by the writer, so an update cannot
/// leave the old words findable.
enum CapturedSchema {
    static let version = 1

    static func apply(to db: Database) throws {
        for statement in creates {
            try db.execute(sql: statement)
        }
    }

    /// Drops every table of this schema and the triggers that shadow them. A
    /// rebuild calls it before `apply`, so nothing of an older version survives
    /// and the cursors go with it.
    static func dropAll(_ db: Database) throws {
        for statement in drops {
            try db.execute(sql: statement)
        }
    }

    private static let creates: [String] = [
        """
        CREATE TABLE item (
          rowid         INTEGER PRIMARY KEY,
          id            TEXT NOT NULL UNIQUE,
          kind          TEXT NOT NULL,
          source        TEXT NOT NULL,
          t_start       INTEGER NOT NULL,
          t_end         INTEGER NOT NULL,
          parent_id     TEXT,
          app           TEXT, bundle_id TEXT, title TEXT,
          url           TEXT,
          display       TEXT, img_w INTEGER, img_h INTEGER,
          path          TEXT,
          path_clean    TEXT,
          bytes         INTEGER,
          image_state   TEXT NOT NULL,
          body          TEXT,
          ocr           TEXT,
          ocr_state     TEXT NOT NULL,
          marks_json    TEXT,
          extra_json    TEXT,
          origin_device TEXT
        )
        """,
        "CREATE INDEX item_time ON item(t_start)",
        "CREATE INDEX item_kind_time ON item(kind, t_start)",
        "CREATE INDEX item_app_time ON item(app, t_start)",
        "CREATE INDEX item_parent ON item(parent_id)",
        """
        CREATE VIRTUAL TABLE item_fts USING fts5(
          body, ocr, title, url, app,
          content='item', content_rowid='rowid',
          tokenize='unicode61 remove_diacritics 2', prefix='2 3 4')
        """,
        """
        CREATE TABLE link (item_id TEXT, thread_id TEXT, turn_id TEXT, role TEXT, at INTEGER,
                           PRIMARY KEY (item_id, thread_id, turn_id, role))
        """,
        """
        CREATE TABLE ingest_cursor (source_path TEXT PRIMARY KEY, byte_offset INTEGER, mtime INTEGER, size INTEGER)
        """,
        """
        CREATE TABLE cleanup_log (at INTEGER, stage TEXT, day TEXT, files INTEGER, bytes INTEGER, reason TEXT)
        """,
        """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)
        """,
        """
        CREATE TRIGGER item_ai AFTER INSERT ON item BEGIN
          INSERT INTO item_fts(rowid, body, ocr, title, url, app)
          VALUES (new.rowid, new.body, new.ocr, new.title, new.url, new.app);
        END
        """,
        """
        CREATE TRIGGER item_ad AFTER DELETE ON item BEGIN
          INSERT INTO item_fts(item_fts, rowid, body, ocr, title, url, app)
          VALUES ('delete', old.rowid, old.body, old.ocr, old.title, old.url, old.app);
        END
        """,
        """
        CREATE TRIGGER item_au AFTER UPDATE ON item BEGIN
          INSERT INTO item_fts(item_fts, rowid, body, ocr, title, url, app)
          VALUES ('delete', old.rowid, old.body, old.ocr, old.title, old.url, old.app);
          INSERT INTO item_fts(rowid, body, ocr, title, url, app)
          VALUES (new.rowid, new.body, new.ocr, new.title, new.url, new.app);
        END
        """,
    ]

    private static let drops: [String] = [
        "DROP TRIGGER IF EXISTS item_ai",
        "DROP TRIGGER IF EXISTS item_ad",
        "DROP TRIGGER IF EXISTS item_au",
        "DROP TABLE IF EXISTS item_fts",
        "DROP TABLE IF EXISTS item",
        "DROP TABLE IF EXISTS link",
        "DROP TABLE IF EXISTS ingest_cursor",
        "DROP TABLE IF EXISTS cleanup_log",
        "DROP TABLE IF EXISTS meta",
    ]
}
