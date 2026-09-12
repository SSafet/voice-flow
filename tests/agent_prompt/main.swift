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
    includeHandoff: true, includeSkillBodies: true, sourceContext: "SOURCE_COPY_MARKER",
    sourceInstructions: "SOURCE_GUIDANCE_MARKER")
let instructions = AgentPromptComposer.instructions(layers, additional: "APP_COMMUNICATION_MARKER")
let prompt = AgentPromptComposer.userMessage(layers)
for marker in ["PERSONA_MARKER", "SKILL_MARKER", "SOURCE_GUIDANCE_MARKER", "APP_COMMUNICATION_MARKER"] {
    expect(instructions.contains(marker) && !prompt.contains(marker), "instruction leaked or disappeared: \(marker)")
}
for marker in ["memory marker", "HANDOFF_MARKER", "TASK_MARKER", "SOURCE_COPY_MARKER"] {
    expect(prompt.contains(marker) && !instructions.contains(marker), "context promoted or lost: \(marker)")
}
let resumedLayers = AgentPromptComposer.layers(
    assistant: assistant, priorMessages: history, task: "NEXT_TASK",
    includeHandoff: false, includeSkillBodies: true, sourceContext: "NEW_COPY",
    sourceInstructions: "NEW_GUIDANCE")
let resumedInstructions = AgentPromptComposer.instructions(resumedLayers)
let resumed = AgentPromptComposer.userMessage(resumedLayers)
expect(resumedInstructions.contains("PERSONA_MARKER") && resumedInstructions.contains("SKILL_MARKER")
       && resumedInstructions.contains("NEW_GUIDANCE") && !resumedInstructions.contains("SOURCE_GUIDANCE_MARKER"),
       "resume must supply current instructions, including selected skills and source guidance")
expect(!resumed.contains("PERSONA_MARKER") && !resumed.contains("HANDOFF_MARKER")
       && resumed.contains("memory marker") && resumed.contains("NEXT_TASK") && resumed.contains("NEW_COPY"),
       "resume must contain only current task/context without reintroducing the handoff")
let noBodies = AgentPromptComposer.layers(assistant: assistant, priorMessages: [], task: "T",
    includeHandoff: false, includeSkillBodies: false)
expect(AgentPromptComposer.instructions(noBodies).contains("Example skill")
       && !AgentPromptComposer.instructions(noBodies).contains("SKILL_MARKER"),
       "OpenCode/review skill descriptions must remain separate from user input")
let beforeFocus = try DailyFocus.read()
try DailyFocus.replace("CURRENT_FOCUS_MARKER", expected: beforeFocus)
let focusedLayers = AgentPromptComposer.layers(assistant: assistant, priorMessages: history,
    task: "Follow up", includeHandoff: false, includeSkillBodies: false)
expect(focusedLayers.dailyContext.contains("CURRENT_FOCUS_MARKER"),
       "every resumed assistant must receive the current shared briefing")
let firstFocus = try DailyFocus.read()
try DailyFocus.replace("REPLACED_FOCUS_MARKER", expected: firstFocus)
let updatedFocusLayers = AgentPromptComposer.layers(assistant: assistant, priorMessages: history,
    task: "Follow up", includeHandoff: false, includeSkillBodies: false)
expect(updatedFocusLayers.dailyContext.contains("REPLACED_FOCUS_MARKER")
       && !updatedFocusLayers.dailyContext.contains("CURRENT_FOCUS_MARKER"),
       "focus replacement must reach the next turn without a restart")
if let bytes = beforeFocus.bytes { try bytes.write(to: DailyFocus.url, options: .atomic) }
else { try FileManager.default.removeItem(at: DailyFocus.url) }
print("agent prompt tests passed")
