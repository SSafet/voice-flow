import Foundation

/// The skills layer given to a runtime (06 §3.6): name, description and the
/// absolute path of the `SKILL.md`, one line per skill. A skill's body is never
/// pasted into the prompt — the runtime reads it from the path.
enum RuntimeSkills {
    static func promptList(skills: [AgentSkill]) -> String {
        guard !skills.isEmpty else { return "" }
        return skills.map { skill in
            "\(skill.name) — \(skill.description) — \(skill.sourceURL.path)"
        }.joined(separator: "\n")
    }
}
