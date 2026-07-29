import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// ── frontmatter parsing ──────────────────────────────────

let basic = AssistantFrontmatter.parse("""
---
name: FLORA
description: the assistant — organizing thoughts,
  filing work, recalling decisions.
voice: shimmer
---
You are FLORA. Answer from memory first.
""")
expect(basic.fields["name"] == "FLORA", "name parses")
expect(basic.fields["voice"] == "shimmer", "voice parses")
expect(basic.fields["description"] == "the assistant — organizing thoughts, filing work, recalling decisions.",
       "two-space continuation lines extend the previous value")
expect(basic.body == "You are FLORA. Answer from memory first.", "body is everything after the closing ---")

let bare = AssistantFrontmatter.parse("Just instructions, no frontmatter.")
expect(bare.fields.isEmpty, "no frontmatter → no fields")
expect(bare.body == "Just instructions, no frontmatter.", "no frontmatter → whole text is body")

let emptyBody = AssistantFrontmatter.parse("---\nname: X\n---\n")
expect(emptyBody.fields["name"] == "X" && emptyBody.body.isEmpty, "empty body is allowed")

// ── longest-match wake resolution ────────────────────────

let candidates = [
    AssistantWakeCandidate(slug: "flora", keyword: "FLORA"),
    AssistantWakeCandidate(slug: "flora-watcher", keyword: "FLORA watcher"),
]

let variant = AssistantWakeMatcher.resolve(in: "FLORA watcher, how was my morning?", candidates: candidates)
expect(variant?.slug == "flora-watcher", "compound name routes to the variant, not the base")
expect(variant?.prompt == "how was my morning?", "variant prompt strips the compound name")

let base = AssistantWakeMatcher.resolve(in: "FLORA, hello there", candidates: candidates)
expect(base?.slug == "flora", "bare name routes to the base")
expect(base?.prompt == "hello there", "base prompt strips the name")

let lower = AssistantWakeMatcher.resolve(in: "flora watcher: check the log", candidates: candidates)
expect(lower?.slug == "flora-watcher", "matching is case-insensitive")

expect(AssistantWakeMatcher.resolve(in: "FLORAL arrangement ideas", candidates: candidates) == nil,
       "FLORAL must not wake FLORA")
expect(AssistantWakeMatcher.resolve(in: "nothing to see", candidates: candidates) == nil,
       "no name, no match")

let cyrillic = AssistantWakeMatcher.resolve(in: "ФЛОРА, здравей", candidates: candidates)
expect(cyrillic?.slug == "flora", "Cyrillic fallback still reaches the default-named base")

print("assistants tests passed")
