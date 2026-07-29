import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// ── sentence splitting ───────────────────────────────────

let plain = SpeechSentencer.sentences(of:
    "Deployed to staging and everything is green. Migration finished in forty seconds! Ready for review?")
expect(plain.count == 3, "three sentences split at . ! ? (got \(plain.count): \(plain))")
expect(plain[0] == "Deployed to staging and everything is green.", "first sentence keeps its punctuation")
expect(plain[2] == "Ready for review?", "trailing sentence flushes")

let decimals = SpeechSentencer.sentences(of:
    "The build uses version 1.2 of the runtime and pi is 3.14 which is fine. A second sentence follows here.")
expect(decimals.count == 2, "decimals like 1.2 and 3.14 never split a sentence (got \(decimals.count))")

let newlines = SpeechSentencer.sentences(of:
    "First line is long enough to stand alone\nSecond line also long enough to stand alone")
expect(newlines.count == 2, "newlines split once chunks are long enough (got \(newlines.count))")

let tiny = SpeechSentencer.sentences(of: "OK. Sure. Done. That is everything working as intended.")
expect(tiny.joined(separator: " ").contains("everything working"), "no text is lost when merging")

let long = SpeechSentencer.sentences(of:
    String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces))
expect(long.count >= 2, "an unpunctuated run force-splits at the max length")
expect(long.allSatisfy { $0.count <= SpeechSentencer.maxLength }, "no chunk exceeds the max length")

expect(SpeechSentencer.sentences(of: "   \n  ").isEmpty, "whitespace-only input yields nothing")

// ── queue map ────────────────────────────────────────────

let map = PlaybackQueueMap(counts: [2, 3, 1])
expect(map.totalChunks == 6, "total chunks sum")
expect(map.itemCount == 3, "item count")
expect(map.position(ofChunk: 0) == (0, 0), "chunk 0 = first item, first sentence")
expect(map.position(ofChunk: 1) == (0, 1), "chunk 1 = first item, second sentence")
expect(map.position(ofChunk: 2) == (1, 0), "chunk 2 crosses into the second item")
expect(map.position(ofChunk: 5) == (2, 0), "last chunk = third item")
expect(map.position(ofChunk: 99) == (2, 0), "out-of-range clamps to the last position")
expect(map.firstChunk(ofItem: 0) == 0, "first item starts at 0")
expect(map.firstChunk(ofItem: 2) == 5, "third item starts after 2+3")
expect(map.completedItems(beforeChunk: 2) == 1, "one item completed once the voice is in item 2")
expect(map.completedItems(beforeChunk: 0) == 0, "nothing completed at the start")

print("player tests passed")
