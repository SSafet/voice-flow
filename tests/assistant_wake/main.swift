import Foundation

private func expectEqual(_ actual: String?, _ expected: String?, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message) (actual=\(actual ?? "nil"), expected=\(expected ?? "nil"))\n", stderr)
        exit(1)
    }
}

expectEqual(
    AssistantWakeMatcher.prompt(in: "FLORA, organize these thoughts.", keyword: "FLORA"),
    "organize these thoughts.",
    "comma-delimited FLORA must return only the Assistant prompt")
expectEqual(
    AssistantWakeMatcher.prompt(in: "  flora: what is on my board?  ", keyword: "FLORA"),
    "what is on my board?",
    "matching must ignore case and surrounding whitespace")
expectEqual(
    AssistantWakeMatcher.prompt(in: "FLORA — structure this", keyword: "FLORA"),
    "structure this",
    "punctuation delimiters must be stripped before the prompt")
expectEqual(
    AssistantWakeMatcher.prompt(in: "Флора, подреди тези мисли", keyword: "FLORA"),
    "подреди тези мисли",
    "Bulgarian STT spelling must wake the default FLORA name")
expectEqual(
    AssistantWakeMatcher.prompt(in: "Hey Flora, help me", keyword: "Hey Flora"),
    "help me",
    "configurable wake phrases must match as one prefix")
expectEqual(
    AssistantWakeMatcher.prompt(in: "FLORAL arrangement", keyword: "FLORA"), nil,
    "a longer word sharing the prefix must not wake the Assistant")
expectEqual(
    AssistantWakeMatcher.prompt(in: "I asked FLORA to help", keyword: "FLORA"), nil,
    "the wake word must occur at the start")
expectEqual(
    AssistantWakeMatcher.prompt(in: "Обичам местната флора", keyword: "FLORA"), nil,
    "the Bulgarian noun away from the prefix must remain ordinary dictation")
expectEqual(
    AssistantWakeMatcher.prompt(in: "FLORA", keyword: "FLORA"), nil,
    "a wake word without a prompt must not override delivery")
expectEqual(
    AssistantWakeMatcher.prompt(in: "FLORA...", keyword: "FLORA"), nil,
    "delimiter-only text must not create an empty Assistant turn")
expectEqual(
    AssistantWakeMatcher.prompt(in: "FLORA, keep the ending?", keyword: ""), nil,
    "an empty configured keyword must never match")

print("assistant wake tests passed")
