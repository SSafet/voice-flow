import Foundation

let DefaultAssistantWakeWord = "FLORA"

/// Pure transcript parser for the Assistant wake-word path. Capture capability
/// and the enabled setting are intentionally enforced by the delivery caller,
/// so this type only answers whether a complete transcript contains a command.
enum AssistantWakeMatcher {
    private static let delimiterCharacters = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)

    static func prompt(in transcript: String, keyword: String) -> String? {
        let candidate = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !normalizedKeyword.isEmpty,
              let match = candidate.range(
                of: normalizedKeyword,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        let remainder = candidate[match.upperBound...]
        guard let first = remainder.first,
              first.unicodeScalars.allSatisfy({ delimiterCharacters.contains($0) }) else {
            // A boundary is required: “FLORAL” must not wake “FLORA”.
            return nil
        }

        var promptStart = remainder.startIndex
        while promptStart < remainder.endIndex {
            let character = remainder[promptStart]
            guard character.unicodeScalars.allSatisfy({ delimiterCharacters.contains($0) }) else {
                break
            }
            promptStart = remainder.index(after: promptStart)
        }

        let prompt = String(remainder[promptStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }
}
