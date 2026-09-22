import Foundation

/// Every item id VoiceFlow knows, built and checked in one place (07 §3.2).
///
/// An id is readable and derived from where the thing already lives, so it is
/// the same on every rebuild and any tool, the interface and a thread
/// attachment can all accept it. The pattern is the one the design fixes; the
/// check beside it refuses a tail that would walk out of the data folder.
enum CapturedItemID {
    static let pattern = "^(frame|activity|capture|shot|dictation|review|recording):[A-Za-z0-9._/-]{1,100}$"

    static func isValid(_ id: String) -> Bool {
        guard id.range(of: pattern, options: .regularExpression) != nil else { return false }
        guard let colon = id.firstIndex(of: ":") else { return false }
        let tail = id[id.index(after: colon)...]
        for component in tail.split(separator: "/", omittingEmptySubsequences: false) {
            if component == ".." || component == "." { return false }
        }
        return true
    }

    static func frame(day: String, time: String) -> String { "frame:\(day)T\(time)" }

    static func activity(day: String, time: String) -> String { "activity:\(day)T\(time)" }

    static func capture(bundle: String) -> String { "capture:\(bundle)" }

    static func bundleFrame(bundle: String, index: Int) -> String {
        String(format: "capture:%@/%02d", bundle, index)
    }

    static func shot(name: String) -> String { "shot:\(name)" }

    static func dictation(_ id: String) -> String { "dictation:\(id)" }

    static func review(day: String) -> String { "review:\(day)" }

    static let ledger = "review:ledger"

    static func recording(_ id: String) -> String { "recording:\(id)" }
}
