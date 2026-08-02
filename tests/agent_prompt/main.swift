import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let root = VoiceFlowPaths.shared.directory("assistants/prompt-test")
try FileManager.default.createDirectory(
    at: root.appendingPathComponent("memory"), withIntermediateDirectories: true)
try "2026-08-02: memory marker".write(
    to: root.appendingPathComponent("memory/core.md"), atomically: true, encoding: .utf8)
let skillDir = root.appendingPathComponent("skills/example")
try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
try "---\nname: example\ndescription: Example skill\n---\nSKILL_MARKER".write(
    to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
let assistant = AssistantDefinition(
    slug: "prompt-test", name: "Prompt Test", description: "",
    voice: nil, instructions: "PERSONA_MARKER", directory: root,
    selectedSkills: ["example"])
let history = [
    AssistantHistoryMessage(role: .user, text: "HANDOFF_MARKER"),
    AssistantHistoryMessage(role: .assistant, text: "prior answer"),
]
let layers = AgentPromptComposer.layers(
    assistant: assistant, priorMessages: history, task: "TASK_MARKER",
    includeHandoff: true, includeSkillBodies: true)
let prompt = AgentPromptComposer.compose(layers, includeIdentity: true)
for marker in ["PERSONA_MARKER", "memory marker", "SKILL_MARKER", "HANDOFF_MARKER", "TASK_MARKER"] {
    expect(prompt.contains(marker), "missing prompt layer \(marker)")
}
expect(prompt.range(of: "PERSONA_MARKER")!.lowerBound < prompt.range(of: "memory marker")!.lowerBound,
       "persona/memory order changed")
expect(prompt.range(of: "HANDOFF_MARKER")!.lowerBound < prompt.range(of: "TASK_MARKER")!.lowerBound,
       "handoff/task order changed")
let resumed = AgentPromptComposer.compose(layers, includeIdentity: false)
expect(!resumed.contains("PERSONA_MARKER") && !resumed.contains("HANDOFF_MARKER"),
       "resumed prompt repeated identity or handoff")
expect(resumed.contains("memory marker") && resumed.contains("TASK_MARKER"),
       "resumed prompt omitted dynamic context")
print("agent prompt tests passed")
