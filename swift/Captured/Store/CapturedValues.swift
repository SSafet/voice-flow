import Foundation

/// The storage vocabulary of the captured index (07 §3.1). The raw values are
/// the column values written to SQLite, exactly the strings 07 §3.1 names, so a
/// later work package can map them to the home contract's generated types
/// without the file having to change.
enum CapturedKind: String, Codable, Equatable {
    case dictation, capture, frame, shot, activity, review, recording
}

enum CapturedSource: String, Codable, Equatable {
    case watcher, bundle, shot, paste, dictation, review, recording
}

enum CapturedImageState: String, Codable, Equatable {
    case none, present, missing, thinned, deleted
}

enum CapturedOCRState: String, Codable, Equatable {
    case na, pending, done, skippedPrivate = "skipped_private", failed
}

/// What one `CapturedIndex.upsert` did, so a caller can tell a catch-up replay
/// from a first reading without a second query.
enum CapturedUpsert: Equatable {
    case inserted, updated
}

/// Every refusal the store makes by name, so a caller can report it instead of
/// reading a database message.
enum CapturedStoreError: Error, Equatable {
    case invalidItemID(String)
    case invalidTimeRange(String)
    case databaseUnusable(String)
}

/// One row of the index. The field order follows the columns of `item`, so
/// `item(id:)` can return exactly what was written, every optional included.
struct CapturedItemRow: Equatable {
    var id: String; var kind: CapturedKind; var source: CapturedSource
    var tStart: Int; var tEnd: Int
    var parentID: String? = nil
    var app: String? = nil; var bundleID: String? = nil; var title: String? = nil; var url: String? = nil
    var display: String? = nil; var imgW: Int? = nil; var imgH: Int? = nil
    var path: String? = nil; var pathClean: String? = nil; var bytes: Int? = nil
    var imageState: CapturedImageState = .none
    var body: String? = nil; var ocr: String? = nil
    var ocrState: CapturedOCRState = .na
    var marksJSON: String? = nil; var extraJSON: String? = nil; var originDevice: String? = nil
}

/// One cell of the validation's totals table (07 §3.1): how many items of one
/// kind are in one image state.
struct CapturedCount: Equatable {
    let kind: CapturedKind
    let imageState: CapturedImageState
    let count: Int
}

/// How far one ingest source has been read. The byte offset is the start of the
/// span that is still open, never the end of the file (07 §3.4), so a replay
/// re-reads that span and upserts the same id.
struct CapturedCursor: Equatable {
    var sourcePath: String
    var byteOffset: Int
    var mtime: Int
    var size: Int
}
