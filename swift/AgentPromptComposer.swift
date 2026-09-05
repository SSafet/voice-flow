import Foundation

struct AgentPromptLayers: Equatable {
    let systemRole: String
    let persona: String
    let memory: String
    let skills: String
    let handoff: String
    let task: String
    var sources: String = ""
}

enum AgentPromptComposer {
    static let systemRole = """
    You are the Assistant inside Voice Flow, a macOS companion for voice dictation, speech, and screen-aware work. Complete the user's current request and return the finished result to the current Voice Flow conversation.

    Keep replies concise and direct because they appear in a compact panel. Treat attached screenshots and the user's annotations as evidence. Ask one focused question only when a consequential ambiguity cannot be resolved safely. Never take a destructive, irreversible, paid, or externally communicative action unless the user explicitly requested that exact effect.

    Assistant memory is durable user-owned context. Use it when relevant, keep durable facts current, preserve superseded facts, and never retain credentials or secrets. Return plain conversational text unless the task itself requires structured output.
    """

    static func layers(assistant: AssistantDefinition?,
                       priorMessages: [AssistantHistoryMessage],
                       task: String,
                       includeHandoff: Bool,
                       includeSkillBodies: Bool,
                       sourceContext: String = "") -> AgentPromptLayers {
        let persona: String
        let memory: String
        let skills: String
        if let assistant {
            persona = assistant.instructions.isEmpty
                ? "You are \(assistant.name)."
                : "You are \(assistant.name).\n\n\(assistant.instructions)"
            let current = assistant.coreMemory()
            memory = current.isEmpty
                ? "# Current durable memory\n(empty)"
                : "# Current durable memory\n\(current)"
            if includeSkillBodies {
                skills = (try? AgentSkillStore.promptBlock(for: assistant)) ?? ""
            } else {
                let selected = (try? AgentSkillStore.loadSelected(for: assistant)) ?? []
                skills = selected.isEmpty ? "" : "# Selected skills\n" + selected
                    .map { "- \($0.name): \($0.description)" }
                    .joined(separator: "\n")
            }
        } else {
            persona = ""
            memory = ""
            skills = ""
        }
        return AgentPromptLayers(
            systemRole: systemRole,
            persona: persona,
            memory: memory,
            skills: skills,
            handoff: includeHandoff ? canonicalHandoff(priorMessages) : "",
            task: task, sources: sourceContext)
    }

    static func compose(_ layers: AgentPromptLayers, includeIdentity: Bool) -> String {
        var sections: [String] = []
        if includeIdentity {
            sections.append(layers.systemRole)
            if !layers.persona.isEmpty { sections.append("# Assistant identity\n\(layers.persona)") }
            if !layers.handoff.isEmpty { sections.append(layers.handoff) }
        }
        if !layers.memory.isEmpty { sections.append(layers.memory) }
        if !layers.skills.isEmpty { sections.append(layers.skills) }
        if !layers.sources.isEmpty { sections.append(layers.sources) }
        sections.append("# Current task\n\(layers.task)")
        return sections.joined(separator: "\n\n")
    }

    static func canonicalHandoff(_ messages: [AssistantHistoryMessage],
                                 maxMessages: Int = 24,
                                 maxCharacters: Int = 16_000) -> String {
        let context = messages
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(maxMessages)
            .map { message in
                let role = message.role == .user ? "USER" : "ASSISTANT"
                return "[\(message.id.uuidString)] \(role): \(message.text)"
            }
            .joined(separator: "\n\n")
        guard !context.isEmpty else { return "" }
        let clipped = context.count > maxCharacters
            ? String(context.suffix(maxCharacters)) : context
        return """
        # Canonical conversation handoff
        This runtime session is being rebuilt from Voice Flow's durable transcript. Continue from this context and do not repeat its answers in your reply.

        \(clipped)
        """
    }
}
