import Foundation

enum WatcherTickDecision: Equatable {
    case capture
    case pause(String)
}

/// Deterministic privacy and retention predicates used by the ambient watcher.
/// Keeping these independent from macOS probes lets the signed app own the
/// probes while tests exercise every boundary without recording the real user.
enum WatcherPolicy {
    static func tickDecision(screenLocked: Bool, secondsSinceLastInput: TimeInterval,
                             idleCutoff: TimeInterval) -> WatcherTickDecision {
        if screenLocked { return .pause("locked") }
        if secondsSinceLastInput >= idleCutoff { return .pause("idle") }
        return .capture
    }

    static func shouldSaveScreen(previousChangedBlocks: Int?, threshold: Int,
                                 denseApp: Bool, secondsSinceLastFrame: TimeInterval?,
                                 denseFloor: TimeInterval) -> Bool {
        guard let previousChangedBlocks else { return true }
        if previousChangedBlocks >= max(1, threshold) { return true }
        guard denseApp, denseFloor > 0, let secondsSinceLastFrame else { return false }
        return secondsSinceLastFrame >= denseFloor
    }

    static func shouldSaveCamera(previousDifference: Double?, threshold: Double) -> Bool {
        guard let previousDifference else { return true }
        return previousDifference >= threshold
    }
}
