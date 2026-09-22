import Foundation

/// Public MCP has the same ownership boundary as the embedded overlay bridge.
/// An unowned/user or system document is never an agent's mutable overlay.
enum MCPOverlayScope {
    private static let lock = NSLock()
    static let toolNames: Set<String> = ["show_guide", "update_guide", "show_panel", "annotate_screen", "clear_annotations", "remove_overlay", "list_overlays"]
    /// Serialize ownership check plus mutation across concurrent external calls.
    static func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    static func owns(_ document: [String: Any]?, sessionID: String?) -> Bool {
        guard let document, let sessionID, document["system"] as? Bool != true else { return false }
        return document["session"] as? String == sessionID
    }
}
