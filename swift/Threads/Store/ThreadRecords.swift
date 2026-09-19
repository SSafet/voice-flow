import Foundation

/// The one refusal type of the thread store. Its `code` is one of the master
/// plan's stable error strings — `not_found`, `invalid_params`, `not_supported`
/// and `snapshot_required` live here; no other code is invented.
struct ThreadStoreError: Error, Equatable {
    let code: TPErrorCode
    let message: String
}

/// Contract records to and from the `record` column (06 §3.2).
///
/// A record is written exactly as the generated types write it, with sorted
/// keys, except that every `homeId` anywhere in the tree becomes the word
/// `self`; nothing else is touched. The two decoders that carry a home id put
/// the current one back before decoding, so no stored payload and no stored row
/// ever contains a real home id.
enum ThreadRecords {
    static func encode<T: Encodable>(_ record: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThreadStoreError(code: .invalidParams,
                                   message: "a contract record must encode to a JSON object")
        }
        let replaced = replacingHomeID(object, with: StoreHome.marker)
        let out = try JSONSerialization.data(withJSONObject: replaced, options: [.sortedKeys])
        return String(decoding: out, as: UTF8.self)
    }

    static func decodeProject(_ json: String, homeID: String) throws -> TPProject {
        try JSONDecoder().decode(TPProject.self, from: substitutingHomeID(json, homeID))
    }

    static func decodeThread(_ json: String, homeID: String) throws -> TPThread {
        try JSONDecoder().decode(TPThread.self, from: substitutingHomeID(json, homeID))
    }

    static func decodeTurn(_ json: String) throws -> TPTurn {
        try JSONDecoder().decode(TPTurn.self, from: Data(json.utf8))
    }

    static func decodeItem(_ json: String) throws -> TPItem {
        try JSONDecoder().decode(TPItem.self, from: Data(json.utf8))
    }

    /// Every `homeId` key in the object tree becomes `replacement`, without
    /// disturbing key order or any other value; arrays are walked too.
    private static func replacingHomeID(_ value: Any, with replacement: String) -> Any {
        if var object = value as? [String: Any] {
            for (key, nested) in object {
                if key == "homeId" {
                    object[key] = replacement
                } else {
                    object[key] = replacingHomeID(nested, with: replacement)
                }
            }
            return object
        }
        if let array = value as? [Any] {
            return array.map { replacingHomeID($0, with: replacement) }
        }
        return value
    }

    private static func substitutingHomeID(_ json: String, _ homeID: String) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ThreadStoreError(code: .invalidParams,
                                   message: "the stored record is not a JSON object")
        }
        let replaced = replacingHomeID(object, with: homeID)
        return try JSONSerialization.data(withJSONObject: replaced)
    }
}
