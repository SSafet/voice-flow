import Foundation
import GRDB

/// The one writer of the captured index and the small readers the store owes
/// (07 §3.1, §3.4). Every ingester writes through `upsert`, so the same thing
/// written twice is one row and the search table stays pointed at it: the write
/// is `INSERT … ON CONFLICT(id) DO UPDATE`, which keeps the row number.
final class CapturedIndex {
    let pool: DatabasePool

    private let transactionDatabase: Database?

    init(pool: DatabasePool) {
        self.pool = pool
        transactionDatabase = nil
    }

    private init(pool: DatabasePool, database: Database) {
        self.pool = pool
        transactionDatabase = database
    }

    // The transaction-bound index never escapes this synchronous closure.
    // Items, search triggers and the source cursor commit together.
    func transaction<T>(_ body: (CapturedIndex) throws -> T) throws -> T {
        if transactionDatabase != nil { return try body(self) }
        return try pool.write { db in
            try body(CapturedIndex(pool: pool, database: db))
        }
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        if let db = transactionDatabase { return try body(db) }
        return try pool.read(body)
    }

    private func write<T>(_ body: (Database) throws -> T) throws -> T {
        if let db = transactionDatabase { return try body(db) }
        return try pool.write(body)
    }

    @discardableResult
    func upsert(_ row: CapturedItemRow) throws -> CapturedUpsert {
        guard CapturedItemID.isValid(row.id) else {
            throw CapturedStoreError.invalidItemID(row.id)
        }
        guard row.tEnd >= row.tStart else {
            throw CapturedStoreError.invalidTimeRange(
                "\(row.id): t_end \(row.tEnd) is before t_start \(row.tStart)")
        }
        return try write { db in
            let existed = try Int64.fetchOne(
                db, sql: "SELECT rowid FROM item WHERE id = ?", arguments: [row.id]) != nil
            try db.execute(sql: Self.upsertSQL, arguments: Self.arguments(for: row))
            return existed ? .updated : .inserted
        }
    }

    func item(id: String) throws -> CapturedItemRow? {
        try read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM item WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try Self.makeRow(row)
        }
    }

    func rowID(of id: String) throws -> Int64? {
        try read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM item WHERE id = ?", arguments: [id])
        }
    }

    func removeWatcherDay(_ day: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM item WHERE source = 'watcher' AND (id LIKE ? OR id LIKE ?)",
                           arguments: ["activity:" + day + "T%", "frame:" + day + "T%"])
        }
    }

    func remove(id: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [id])
        }
    }

    func search(_ text: String, limit: Int) throws -> [String] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT item.id FROM item_fts
                JOIN item ON item.rowid = item_fts.rowid
                WHERE item_fts MATCH ?
                ORDER BY item.t_start DESC
                LIMIT ?
                """,
                arguments: [pattern.rawPattern, limit])
        }
    }

    func countsByKindAndImageState() throws -> [CapturedCount] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT kind, image_state, count(*) AS n FROM item
                GROUP BY kind, image_state
                ORDER BY kind, image_state
                """).map { row in
                CapturedCount(
                    kind: try Self.kind(row["kind"]),
                    imageState: try Self.imageState(row["image_state"]),
                    count: row["n"])
            }
        }
    }

    func cursor(sourcePath: String) throws -> CapturedCursor? {
        try read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM ingest_cursor WHERE source_path = ?",
                arguments: [sourcePath]) else { return nil }
            return CapturedCursor(
                sourcePath: row["source_path"],
                byteOffset: row["byte_offset"],
                mtime: row["mtime"],
                size: row["size"])
        }
    }

    func saveCursor(_ cursor: CapturedCursor) throws {
        try write { db in
            try db.execute(
                sql: """
                INSERT INTO ingest_cursor(source_path, byte_offset, mtime, size)
                VALUES (:sourcePath, :byteOffset, :mtime, :size)
                ON CONFLICT(source_path) DO UPDATE SET
                  byte_offset = excluded.byte_offset,
                  mtime = excluded.mtime,
                  size = excluded.size
                """,
                arguments: [
                    "sourcePath": cursor.sourcePath,
                    "byteOffset": cursor.byteOffset,
                    "mtime": cursor.mtime,
                    "size": cursor.size,
                ])
        }
    }

    func meta(_ key: String) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    func setMeta(_ key: String, _ value: String) throws {
        try write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)",
                arguments: [key, value])
        }
    }

    // MARK: - Row mapping

    static func makeRow(_ row: Row) throws -> CapturedItemRow {
        CapturedItemRow(
            id: row["id"],
            kind: try kind(row["kind"]),
            source: try source(row["source"]),
            tStart: row["t_start"],
            tEnd: row["t_end"],
            parentID: row["parent_id"],
            app: row["app"],
            bundleID: row["bundle_id"],
            title: row["title"],
            url: row["url"],
            display: row["display"],
            imgW: row["img_w"],
            imgH: row["img_h"],
            path: row["path"],
            pathClean: row["path_clean"],
            bytes: row["bytes"],
            imageState: try imageState(row["image_state"]),
            body: row["body"],
            ocr: row["ocr"],
            ocrState: try ocrState(row["ocr_state"]),
            marksJSON: row["marks_json"],
            extraJSON: row["extra_json"],
            originDevice: row["origin_device"])
    }

    private static func kind(_ raw: String) throws -> CapturedKind {
        guard let value = CapturedKind(rawValue: raw) else {
            throw CapturedStoreError.databaseUnusable("unknown item kind \(raw)")
        }
        return value
    }

    private static func source(_ raw: String) throws -> CapturedSource {
        guard let value = CapturedSource(rawValue: raw) else {
            throw CapturedStoreError.databaseUnusable("unknown item source \(raw)")
        }
        return value
    }

    private static func imageState(_ raw: String) throws -> CapturedImageState {
        guard let value = CapturedImageState(rawValue: raw) else {
            throw CapturedStoreError.databaseUnusable("unknown image state \(raw)")
        }
        return value
    }

    private static func ocrState(_ raw: String) throws -> CapturedOCRState {
        guard let value = CapturedOCRState(rawValue: raw) else {
            throw CapturedStoreError.databaseUnusable("unknown text-recognition state \(raw)")
        }
        return value
    }

    private static func arguments(for row: CapturedItemRow) -> StatementArguments {
        [
            "id": row.id,
            "kind": row.kind.rawValue,
            "source": row.source.rawValue,
            "tStart": row.tStart,
            "tEnd": row.tEnd,
            "parentID": row.parentID,
            "app": row.app,
            "bundleID": row.bundleID,
            "title": row.title,
            "url": row.url,
            "display": row.display,
            "imgW": row.imgW,
            "imgH": row.imgH,
            "path": row.path,
            "pathClean": row.pathClean,
            "bytes": row.bytes,
            "imageState": row.imageState.rawValue,
            "body": row.body,
            "ocr": row.ocr,
            "ocrState": row.ocrState.rawValue,
            "marksJSON": row.marksJSON,
            "extraJSON": row.extraJSON,
            "originDevice": row.originDevice,
        ]
    }

    private static let upsertSQL = """
    INSERT INTO item (
      id, kind, source, t_start, t_end, parent_id, app, bundle_id, title,
      url, display, img_w, img_h, path, path_clean, bytes, image_state,
      body, ocr, ocr_state, marks_json, extra_json, origin_device)
    VALUES (
      :id, :kind, :source, :tStart, :tEnd, :parentID, :app, :bundleID, :title,
      :url, :display, :imgW, :imgH, :path, :pathClean, :bytes, :imageState,
      :body, :ocr, :ocrState, :marksJSON, :extraJSON, :originDevice)
    ON CONFLICT(id) DO UPDATE SET
      kind = excluded.kind,
      source = excluded.source,
      t_start = excluded.t_start,
      t_end = excluded.t_end,
      parent_id = excluded.parent_id,
      app = excluded.app,
      bundle_id = excluded.bundle_id,
      title = excluded.title,
      url = excluded.url,
      display = excluded.display,
      img_w = excluded.img_w,
      img_h = excluded.img_h,
      path = excluded.path,
      path_clean = excluded.path_clean,
      bytes = excluded.bytes,
      image_state = excluded.image_state,
      body = excluded.body,
      ocr = excluded.ocr,
      ocr_state = excluded.ocr_state,
      marks_json = excluded.marks_json,
      extra_json = excluded.extra_json,
      origin_device = excluded.origin_device
    """
}
