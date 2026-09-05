import Foundation

/// Captured data and authority are separate choices. Standard mode retains the
/// normal runtime permissions; reviewCopies is app-owned text-only inference.
enum AgentSourceAccessMode: String, Codable, CaseIterable {
    case standard
    case reviewCopies

    static func persisted(_ raw: String?) -> AgentSourceAccessMode {
        guard let raw, !raw.isEmpty else { return .standard }
        // Unknown future/corrupt modes must never restore general tool access.
        return AgentSourceAccessMode(rawValue: raw) ?? .reviewCopies
    }

    var label: String {
        switch self {
        case .standard: return "Normal assistant access"
        case .reviewCopies: return "Review copies only"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "Selected copies are context. Existing runtime permissions still apply."
        case .reviewCopies: return "Uses the OpenRouter model to review captured text. No commands, browser, or mailbox actions. Requires an OpenRouter key in Settings."
        }
    }
}

enum AgentSourceSelection {
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
    }

    static func normalized(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }
}

struct AgentSourceChoice {
    let id: String
    let label: String
}
