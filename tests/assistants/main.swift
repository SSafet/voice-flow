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

// ── folder lifecycle and rollback-safe editing ───────────

let lifecycleRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("voice-flow-assistants-tests-\(UUID().uuidString)")
let store = AssistantsStore(rootURL: lifecycleRoot)
let initial = store.reload()
expect(initial.assistants.map(\.slug) == ["flora"],
       "truly empty root did not scaffold exactly one base Assistant")
expect(initial.issues.isEmpty, "fresh scaffold reported a load issue")

let research = try store.create(AssistantDraft(
    name: "Rësearch / Helper",
    description: "Collects and compares evidence.",
    voice: "shimmer",
    instructions: "Work from sources."))
expect(research.slug == "research-helper",
       "generated slug did not fold diacritics and path punctuation")
expect(FileManager.default.fileExists(atPath: research.coreMemoryURL.path)
       && FileManager.default.fileExists(atPath: research.ledgerURL.path)
       && FileManager.default.fileExists(atPath: research.workspaceDirectory.path),
       "create did not establish the Assistant folder contract")

do {
    _ = try store.create(AssistantDraft(name: "research / helper"))
    expect(false, "ambiguous duplicate wake name was accepted")
} catch AssistantStoreError.duplicateWakeName { }
catch { expect(false, "duplicate wake name produced the wrong error: \(error)") }

let alpha = try store.create(AssistantDraft(name: "Alpha Beta"))
let alphaCollision = try store.create(AssistantDraft(name: "Alpha-Beta"))
expect(alpha.slug == "alpha-beta" && alphaCollision.slug == "alpha-beta-2",
       "slug collision did not receive a deterministic suffix")

// Unknown frontmatter survives revision-checked edits; an external mutation
// is never overwritten by a stale UI draft.
let researchFile = research.directory.appendingPathComponent("assistant.md")
var researchText = try String(contentsOf: researchFile, encoding: .utf8)
researchText = researchText.replacingOccurrences(
    of: "description:", with: "custom-policy: preserve-me\ndescription:")
try researchText.write(to: researchFile, atomically: true, encoding: .utf8)
let externalDocument = try store.document(slug: research.slug)
expect(externalDocument.fields["custom-policy"] == "preserve-me",
       "unknown frontmatter fixture did not load")

try "\n# external edit\n".appendLine(to: researchFile)
do {
    _ = try store.update(
        slug: research.slug,
        draft: AssistantDraft(
            name: research.name, description: "Changed", voice: research.voice,
            instructions: research.instructions),
        expectedRevision: externalDocument.revision)
    expect(false, "stale revision overwrote an external Assistant edit")
} catch AssistantStoreError.revisionConflict { }
catch { expect(false, "revision conflict produced the wrong error: \(error)") }

let latestDocument = try store.document(slug: research.slug)
let skillDirectory = research.directory
    .appendingPathComponent("skills/tool", isDirectory: true)
try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
try "---\nname: tool\ndescription: test\n---\nUse it.\n".write(
    to: skillDirectory.appendingPathComponent("SKILL.md"),
    atomically: true, encoding: .utf8)
let updatedResearch = try store.update(
    slug: research.slug,
    draft: AssistantDraft(
        name: "Research Helper", description: "Updated safely.",
        voice: "shimmer", instructions: "Work from verified sources.",
        selectedSkills: ["tool"]),
    expectedRevision: latestDocument.revision)
let savedText = try String(contentsOf: researchFile, encoding: .utf8)
expect(savedText.contains("custom-policy: preserve-me"),
       "revisioned save discarded unknown frontmatter")
expect(updatedResearch.selectedSkills == ["tool"],
       "selected skills did not persist")

try "private memory\n".write(
    to: updatedResearch.coreMemoryURL, atomically: true, encoding: .utf8)
try "workspace secret\n".write(
    to: updatedResearch.workspaceDirectory.appendingPathComponent("private.txt"),
    atomically: true, encoding: .utf8)
let duplicated = try store.duplicate(
    slug: updatedResearch.slug, name: "Research Helper Copy")
expect(FileManager.default.fileExists(atPath: duplicated.directory
    .appendingPathComponent("skills/tool/SKILL.md").path),
       "template duplicate omitted selected skill source")
let duplicatedMemory = try String(contentsOf: duplicated.coreMemoryURL, encoding: .utf8)
expect(!duplicatedMemory.contains("private memory"),
       "template duplicate copied durable memory")
expect(!FileManager.default.fileExists(atPath: duplicated.workspaceDirectory
    .appendingPathComponent("private.txt").path),
       "template duplicate copied workspace data")

do {
    _ = try store.document(slug: "../outside")
    expect(false, "path traversal escaped the Assistants root")
} catch AssistantStoreError.boundaryViolation { }
catch { expect(false, "path traversal produced the wrong error: \(error)") }

// A malformed existing FLORA folder is evidence, not an invitation to
// overwrite it with a scaffold.
let malformedRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("voice-flow-assistants-malformed-\(UUID().uuidString)")
let malformedFlora = malformedRoot.appendingPathComponent("flora", isDirectory: true)
try FileManager.default.createDirectory(at: malformedFlora, withIntermediateDirectories: true)
let malformedFile = malformedFlora.appendingPathComponent("assistant.md")
let malformedBytes = Data("---\ndescription: missing name\n---\nKeep me byte-for-byte.\n".utf8)
try malformedBytes.write(to: malformedFile, options: .atomic)
let malformedStore = AssistantsStore(rootURL: malformedRoot)
let malformedSnapshot = malformedStore.reload()
expect(malformedSnapshot.assistants.isEmpty && malformedSnapshot.issues.count == 1,
       "malformed folder was presented as a healthy or empty store")
let malformedAfterReload = try Data(contentsOf: malformedFile)
expect(malformedAfterReload == malformedBytes,
       "reload overwrote a malformed existing Assistant")

let onlyStoreRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("voice-flow-assistants-last-\(UUID().uuidString)")
let onlyStore = AssistantsStore(rootURL: onlyStoreRoot)
_ = onlyStore.reload()
do {
    try onlyStore.moveToTrash(slug: "flora")
    expect(false, "final remaining Assistant was moved to Trash")
} catch AssistantStoreError.cannotDeleteLast { }
catch { expect(false, "final-delete guard produced the wrong error: \(error)") }

print("assistants tests passed")

private extension String {
    func appendLine(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
