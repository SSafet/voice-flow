import Foundation
import GRDB

/// The word that stands in for the home's id on disk (06 §3.2, decision 23).
///
/// The store never writes a real home id into a row or into a payload: it
/// writes `marker`, and the current id is put in place when a record leaves the
/// store. Before sign-in the current id is the installation id kept in
/// `store_meta`, so a home id that arrives only at sign-in re-keys nothing.
enum StoreHome {
    static let marker = "self"
    static let installationIDKey = "installation_id"

    /// The value of `store_meta` key `installation_id`, minting a UUID string
    /// the first time it is asked and writing it, so the same value comes back
    /// afterwards. It is never `marker`.
    static func installationID(_ db: Database) throws -> String {
        if let existing = try String.fetchOne(
            db,
            sql: "SELECT value FROM store_meta WHERE key = ?",
            arguments: [installationIDKey]) {
            return existing
        }
        let minted = UUID().uuidString
        try db.execute(
            sql: "INSERT INTO store_meta (key, value) VALUES (?, ?)",
            arguments: [installationIDKey, minted])
        return minted
    }

    /// `marker` becomes the current home id; any other origin — an adopted
    /// event's, for instance — is returned as it arrived.
    static func resolve(_ origin: String, homeID: String) -> String {
        origin == marker ? homeID : origin
    }
}
