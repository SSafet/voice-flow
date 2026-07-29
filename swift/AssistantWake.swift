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
        guard !candidate.isEmpty, !normalizedKeyword.isEmpty else { return nil }

        var acceptedKeywords = [normalizedKeyword]
        if normalizedKeyword.compare(
            DefaultAssistantWakeWord,
            options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            // Bulgarian-language STT may render the proper name in Cyrillic
            // despite the cloud hint. Keep this fallback prefix-only so the
            // ordinary noun “флора” elsewhere in a dictation is untouched.
            acceptedKeywords.append("ФЛОРА")
        }

        guard let match = acceptedKeywords.lazy.compactMap({ accepted in
            candidate.range(
                of: accepted,
                options: [.anchored, .caseInsensitive, .diacriticInsensitive])
        }).first else { return nil }

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

/// One wake name an assistant answers to (ticket VF-49). The base assistant's
/// keyword stays the Settings wake word; folder variants use their own name.
struct AssistantWakeCandidate {
    let slug: String
    let keyword: String
}

extension AssistantWakeMatcher {
    /// Match a transcript against every loaded assistant, longest wake name
    /// first, so "FLORA watcher, …" routes to the variant while "FLORA, …"
    /// stays with the base.
    static func resolve(in transcript: String,
                        candidates: [AssistantWakeCandidate]) -> (slug: String, prompt: String)? {
        for candidate in candidates.sorted(by: { $0.keyword.count > $1.keyword.count }) {
            if let prompt = prompt(in: transcript, keyword: candidate.keyword) {
                return (candidate.slug, prompt)
            }
        }
        return nil
    }
}
