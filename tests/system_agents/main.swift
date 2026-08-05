import Foundation

// SystemAgents.swift logs through the app helper; the standalone harness
// supplies the same symbol without pulling AppKit into this focused test.
func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("vf-system-agents-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let file = root.appendingPathComponent("system-agents.json")
let store = SystemAgentStore(fileURL: file)

// ── identities are fixed ────────────────────────────────────────────────
expect(SystemAgentStore.specs.count == 3, "three system agents ship")
expect(SystemAgentKind.allCases.allSatisfy { kind in
    SystemAgentStore.specs.contains { $0.kind == kind }
}, "every kind has a spec")

// ── untouched agents resolve to the shipped defaults ────────────────────
for spec in SystemAgentStore.specs {
    let config = store.config(for: spec.kind)
    expect(config.model == spec.defaultModel, "\(spec.kind) starts on its default model")
    expect(config.usesDefaultModel && config.usesDefaultEffort && config.usesDefaultInstructions,
           "\(spec.kind) reports itself untouched")
}
expect(store.config(for: .continuity).effort == "low", "continuity ships pinned to low")
expect(store.config(for: .speech).effort == nil, "speech has no reasoning level")
expect(!FileManager.default.fileExists(atPath: file.path),
       "reading must not create a file — defaults are not written out")

// ── a saved change resolves immediately, through a fresh reader ─────────
try! store.save(kind: .continuity, model: "gpt-5.6-pro", effort: "high", instructions: nil)
expect(store.config(for: .continuity).model == "gpt-5.6-pro", "model applies in place")
expect(store.config(for: .continuity).effort == "high", "effort applies in place")
let reader = SystemAgentStore(fileURL: file)
expect(reader.config(for: .continuity).model == "gpt-5.6-pro",
       "a separate reader sees the change — call sites resolve per call, not at launch")

// "Provider default" is a real choice, distinct from the shipped default.
try! store.save(kind: .continuity, model: "", effort: "", instructions: nil)
let providerDefault = store.config(for: .continuity)
expect(providerDefault.model == "gpt-5.6-luna", "an empty model returns to the default")
expect(providerDefault.effort == nil && !providerDefault.usesDefaultEffort,
       "empty effort is stored as a deliberate provider-default override")

// ── instructions ────────────────────────────────────────────────────────
try! store.save(kind: .speechCleanup, model: "", effort: nil, instructions: "Say it plainly.")
expect(store.config(for: .speechCleanup).instructions == "Say it plainly.",
       "instructions apply in place")
expect(store.config(for: .speechCleanup).effort == "low",
       "a nil effort argument leaves the stored effort alone")

var threw = false
do { try store.save(kind: .speechCleanup, model: "", effort: nil, instructions: "   ") }
catch { threw = true }
expect(threw, "empty instructions are rejected rather than sent as an empty brief")

threw = false
do { try store.save(kind: .speech, model: "", effort: "high", instructions: nil) }
catch { threw = true }
expect(threw, "an agent without reasoning rejects a reasoning value")

threw = false
do { try store.save(kind: .speech, model: "", effort: nil, instructions: "read it") }
catch { threw = true }
expect(threw, "speech instructions are not stored here — they are the tts setting")

threw = false
do { try store.save(kind: .continuity, model: "gpt 5 with spaces", effort: nil, instructions: nil) }
catch { threw = true }
expect(threw, "a model id with whitespace is rejected before it reaches argv")

threw = false
do { try store.save(kind: .continuity, model: "", effort: "turbo", instructions: nil) }
catch { threw = true }
expect(threw, "an unknown reasoning level is rejected")

threw = false
do {
    try store.save(kind: .speechCleanup, model: "", effort: nil,
                   instructions: String(repeating: "x", count: 5_000))
} catch { threw = true }
expect(threw, "oversized instructions are rejected")

// ── reset ───────────────────────────────────────────────────────────────
try! store.reset(kind: .continuity)
try! store.reset(kind: .speechCleanup)
let afterReset = store.config(for: .continuity)
expect(afterReset.model == "gpt-5.6-luna" && afterReset.effort == "low",
       "reset returns the shipped defaults")
expect(afterReset.usesDefaultModel && afterReset.usesDefaultEffort,
       "reset clears the override rather than pinning the current value")
let document = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
let agents = document["agents"] as! [String: Any]
expect(agents.isEmpty, "a fully reset agent leaves nothing behind on disk")

// ── external edits are picked up, unknown identities dropped ────────────
try! Data("""
{"version":1,"agents":{"continuity":{"model":"edited-by-hand"},"bogus":{"model":"x"}}}
""".utf8).write(to: file, options: .atomic)
// The cache keys off mtime; make sure the write is distinguishable.
try! FileManager.default.setAttributes(
    [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
expect(store.config(for: .continuity).model == "edited-by-hand",
       "the file is the API — a hand edit is picked up without a restart")
expect(SystemAgentKind(rawValue: "bogus") == nil, "identities stay fixed")

print("system_agents: ok")
