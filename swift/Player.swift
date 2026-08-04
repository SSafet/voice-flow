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

/// Which pushes a session read-aloud plays (ticket VF-53). Fresh = active
/// (not retired to done history) and neither spoken nor answered — matching
/// what the pill actually shows. Fully caught up, an explicit press replays
/// only the NEWEST push, never the whole retained archive from the top.
enum PushSpeechSelection {
    struct Item {
        let spoken: Bool
        let answered: Bool
        let done: Bool
    }

    static func selection(for items: [Item]) -> (indices: [Int], replay: Bool) {
        let active = items.indices.filter { !items[$0].done }
        let fresh = active.filter { !items[$0].spoken && !items[$0].answered }
        if !fresh.isEmpty { return (fresh, false) }
        if let newestActive = active.last { return ([newestActive], true) }
        if let newest = items.indices.last { return ([newest], true) }
        return ([], true)
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

/// One player, many inputs (VF-48 unification): whatever is being read —
/// a session's push stack, the assistant's reply, selected text, pasted
/// text — feeds the SAME band/waveform/karaoke/transport. The context
/// only says where the sentences came from, so consumption and karaoke
/// land on the right surface; playback itself is source-blind.
final class PlayerContext {
    enum Source {
        /// A session push stack — the one source with consumption
        /// bookkeeping (spoken cursor, resume points, done history).
        case sessionStack(id: String, indices: [Int])
        /// The in-app assistant's reply; sentences grow while it streams.
        case assistantReply(title: String)
        /// Everything else: selected text, the Speech drawer, the HTTP API.
        case text(title: String)
    }

    let source: Source
    /// Sentences per item, in play order. Fixed for session stacks;
    /// refreshed from the live TTS queue for still-growing replies.
    var sentences: [[String]]
    /// This run has actually been heard generating/playing — the settle
    /// guard against status transitions from before it started.
    var playbackSeen = false
    /// Reply text still streaming in: karaoke waits for the full text so
    /// it never fights the delta renderer for the same text view.
    var streaming = false

    var map: PlaybackQueueMap { PlaybackQueueMap(counts: sentences.map { $0.count }) }

    var sessionId: String? {
        if case .sessionStack(let id, _) = source { return id }
        return nil
    }
    var sessionIndices: [Int]? {
        if case .sessionStack(_, let indices) = source { return indices }
        return nil
    }

    init(source: Source, sentences: [[String]]) {
        self.source = source
        self.sentences = sentences
    }
}

/// Generation runs well ahead of playback (each sentence streams in faster
/// than it plays), so anything the user SEES must follow the playhead, not
/// the fetcher (VF-48 QA: "text and audio are out of sync"). Boundaries are
/// (chunk, first frame of that chunk in the accumulated PCM stream).
enum QueuedPlayback {
    static func chunk(atFrame playhead: Int64,
                      boundaries: [(chunk: Int, frame: Int64)]) -> Int? {
        guard let first = boundaries.first else { return nil }
        var current = first.chunk
        for boundary in boundaries where boundary.frame <= playhead {
            current = boundary.chunk
        }
        return current
    }
}
