import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Session player — pure pieces (ticket VF-48)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Read-aloud of a push stack plays a queue of SENTENCES, so skips are
// exact (skip = another queue index) and the karaoke highlight is always
// in sync. These types are pure so the boundary rules are testable.

/// Splits speakable text into the sentences the player queues — the same
/// boundary rules the live reply speaker uses: cut after . ! ? or at a
/// newline once a chunk is long enough to not sound choppy, force-cut
/// overlong runs at a space.
enum SpeechSentencer {
    static let minLength = 25
    static let maxLength = 360

    static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character = " "
        for character in text {
            if character == "\n" {
                if current.count >= minLength { flush(&current, into: &result) }
                else if !current.isEmpty { current.append(" ") }
                previous = " "
                continue
            }
            current.append(character)
            if current.count >= minLength,
               ".!?".contains(previous),
               character == " " {
                // The boundary sits after sentence-ending punctuation, at
                // the following space — "v1.2" or "3.14" never split.
                current.removeLast()
                flush(&current, into: &result)
            } else if current.count >= maxLength, character == " " {
                current.removeLast()
                flush(&current, into: &result)
            }
            previous = character
        }
        flush(&current, into: &result)
        return result
    }

    private static func flush(_ chunk: inout String, into result: inout [String]) {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        chunk = ""
        guard !trimmed.isEmpty else { return }
        result.append(trimmed)
    }
}

/// Maps the player's flat sentence queue back onto the stack's messages:
/// chunk index → (message ordinal, sentence within it) — the "2/3" label
/// and the per-push consumption cursor both read from here.
struct PlaybackQueueMap {
    /// Sentence count per queued message, in play order.
    let counts: [Int]

    var totalChunks: Int { counts.reduce(0, +) }
    var itemCount: Int { counts.count }

    func position(ofChunk chunk: Int) -> (item: Int, sentence: Int) {
        var remaining = chunk
        for (item, count) in counts.enumerated() {
            if remaining < count { return (item, remaining) }
            remaining -= count
        }
        return (max(0, counts.count - 1), max(0, (counts.last ?? 1) - 1))
    }

    func firstChunk(ofItem item: Int) -> Int {
        counts.prefix(max(0, item)).reduce(0, +)
    }

    /// Messages fully BEFORE this chunk — everything the listener has heard
    /// (or deliberately skipped past).
    func completedItems(beforeChunk chunk: Int) -> Int {
        position(ofChunk: chunk).item
    }
}
