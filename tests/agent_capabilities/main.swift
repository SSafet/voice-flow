import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func expectThrows(_ expected: AgentCapabilityError, _ message: String,
                          _ work: () throws -> Void) {
    do {
        try work()
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    } catch let error as AgentCapabilityError {
        expect(error == expected, "\(message): got \(error)")
    } catch {
        fputs("FAIL: \(message): unexpected \(error)\n", stderr)
        exit(1)
    }
}

let root = VoiceFlowPaths.shared.configRoot
let assistantDirectory = root.appendingPathComponent("assistants/test")
try FileManager.default.createDirectory(
    at: assistantDirectory.appendingPathComponent("memory"), withIntermediateDirectories: true)
let assistant = AssistantDefinition(
    slug: "test", name: "TEST", description: "test", voice: nil,
    instructions: "Be precise.", directory: assistantDirectory,
    selectedSkills: ["sample-skill"])

let memory = AgentMemoryStore(assistant: assistant)
let initial = try memory.read(kind: "core")
expect(initial.content.isEmpty, "missing memory must read as empty")
let first = try memory.update(
    kind: "core", content: "2026-08-02: durable fact", expectedRevision: initial.revision)
expect(first.content.contains("durable fact"), "memory update was lost")
let reread = try memory.read(kind: "core")
expect(reread == first, "memory read/revision mismatch")
expectThrows(.invalidRevision, "stale memory write was accepted") {
    _ = try memory.update(kind: "core", content: "stale", expectedRevision: initial.revision)
}
expectThrows(.secretDetected, "secret-looking memory was accepted") {
    _ = try memory.update(
        kind: "core", content: "api_key = sk-live-abcdefghijklmnop",
        expectedRevision: first.revision)
}

let inside = try AgentPathBoundary.resolve("memory/new.md", within: assistantDirectory)
expect(inside.path.hasPrefix(assistantDirectory.path), "inside path escaped")
expectThrows(.invalidPath, "parent traversal was accepted") {
    _ = try AgentPathBoundary.resolve("../outside", within: assistantDirectory)
}
let outside = root.appendingPathComponent("outside")
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
let link = assistantDirectory.appendingPathComponent("link")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
expectThrows(.pathOutsideRoot, "symlink escape was accepted") {
    _ = try AgentPathBoundary.resolve("link/secret", within: assistantDirectory)
}

let skillDirectory = assistantDirectory.appendingPathComponent("skills/sample-skill")
try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
let skillText = """
---
name: sample-skill
description: A deterministic selected skill
---
Use the exact marker SKILL_NONCE_8421.
"""
try skillText.write(
    to: skillDirectory.appendingPathComponent("SKILL.md"),
    atomically: true, encoding: .utf8)
let loaded = try AgentSkillStore.loadSelected(for: assistant)
expect(loaded.count == 1 && loaded[0].name == "sample-skill", "selected skill did not validate")
let direct = try AgentSkillStore.load(name: "sample-skill", assistant: assistant)
expect(direct.description == "A deterministic selected skill"
       && direct.contents.contains("SKILL_NONCE_8421"),
       "a skill's own file must still load whole")
let listed = RuntimeSkills.promptList(skills: loaded)
expect(listed.contains("sample-skill") && listed.contains("A deterministic selected skill")
       && listed.contains(skillDirectory.appendingPathComponent("SKILL.md").path)
       && !listed.contains("SKILL_NONCE_8421"),
       "a skill reaches the model as name, description and path, never its body")

let unselected = assistantDirectory.appendingPathComponent("skills/not-selected")
try FileManager.default.createDirectory(at: unselected, withIntermediateDirectories: true)
try skillText.replacingOccurrences(of: "sample-skill", with: "not-selected")
    .write(to: unselected.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
_ = try AgentSkillStore.load(name: "not-selected", assistant: assistant)
let stillSelected = try AgentSkillStore.loadSelected(for: assistant)
expect(stillSelected.count == 1,
       "an unselected skill must never join the selected list")
expect(RuntimeSkills.promptList(skills: []) == "",
       "no skills must be the empty string")

print("agent capabilities tests passed")
