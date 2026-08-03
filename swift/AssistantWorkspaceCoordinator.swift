import Foundation

struct AssistantWorkspaceSkill {
    let name: String
    let description: String
    let selected: Bool
    let error: String?
}

struct AssistantWorkspaceSnapshot {
    let document: AssistantDocument
    let coreMemory: AgentMemoryDocument
    let ledger: AgentMemoryDocument
    let skills: [AssistantWorkspaceSkill]
    let conversations: [AssistantConversation]
    let jobs: [AgentJob]
}

enum AssistantWorkspaceError: LocalizedError {
    case busy
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Wait for this Assistant turn to finish."
        case .unavailable(let detail): return detail
        }
    }
}

/// The UI-facing join across Assistant folders, canonical history, and jobs.
/// Views never coordinate these stores independently.
final class AssistantWorkspaceCoordinator {
    private let assistants: AssistantsStore
    private unowned let agent: AgentSession
    private let jobStore: () -> AgentJobStore?

    init(assistants: AssistantsStore = .shared,
         agent: AgentSession,
         jobStore: @escaping () -> AgentJobStore?) {
        self.assistants = assistants
        self.agent = agent
        self.jobStore = jobStore
    }

    func snapshot(slug: String) throws -> AssistantWorkspaceSnapshot {
        let document = try assistants.document(slug: slug)
        let memory = AgentMemoryStore(assistant: document.definition)
        let core = try memory.read(kind: "core")
        let ledger = try memory.read(kind: "ledger")
        let conversations = agent.conversations
            .filter { $0.assistantSlug == slug }
            .sorted { $0.updatedAt > $1.updatedAt }
        let jobs = (try jobStore()?.jobs(limit: 500) ?? [])
            .filter { $0.assistantSlug == slug }
        return AssistantWorkspaceSnapshot(
            document: document, coreMemory: core, ledger: ledger,
            skills: discoverSkills(for: document.definition),
            conversations: conversations, jobs: jobs)
    }

    @discardableResult
    func createAssistant(_ draft: AssistantDraft) throws -> String {
        try assistants.create(draft).slug
    }

    @discardableResult
    func duplicateAssistant(slug: String, name: String) throws -> String {
        try assistants.duplicate(slug: slug, name: name).slug
    }

    func updateAssistant(slug: String, draft: AssistantDraft,
                         expectedRevision: String) throws {
        guard !agent.isRunning || agent.activeAssistant?.slug != slug else {
            throw AssistantWorkspaceError.busy
        }
        let updated = try assistants.update(
            slug: slug, draft: draft, expectedRevision: expectedRevision)
        agent.refreshAssistantDefinition(updated)
    }

    @discardableResult
    func createConversation(assistantSlug: String) throws -> String {
        guard !agent.isRunning else { throw AssistantWorkspaceError.busy }
        guard let assistant = assistants.assistant(slug: assistantSlug) else {
            throw AssistantWorkspaceError.unavailable("Assistant is unavailable.")
        }
        return agent.createConversation(for: assistant).id
    }

    func moveConversation(id: String, to assistantSlug: String) throws {
        guard !agent.isRunning else { throw AssistantWorkspaceError.busy }
        guard let assistant = assistants.assistant(slug: assistantSlug),
              agent.moveConversation(id, to: assistant) != nil else {
            throw AssistantWorkspaceError.unavailable("Conversation could not be moved.")
        }
    }

    @discardableResult
    func updateMemory(slug: String, kind: String, content: String,
                      expectedRevision: String) throws -> AgentMemoryDocument {
        guard !agent.isRunning || agent.activeAssistant?.slug != slug else {
            throw AssistantWorkspaceError.busy
        }
        guard let assistant = assistants.assistant(slug: slug) else {
            throw AssistantWorkspaceError.unavailable("Assistant is unavailable.")
        }
        return try AgentMemoryStore(assistant: assistant).update(
            kind: kind, content: content, expectedRevision: expectedRevision)
    }

    private func discoverSkills(for assistant: AssistantDefinition) -> [AssistantWorkspaceSkill] {
        let root = assistant.directory.appendingPathComponent("skills", isDirectory: true)
        let disk = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]))?.compactMap { url -> String? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { return nil }
                return url.lastPathComponent
            } ?? []
        let names = Set(disk).union(assistant.selectedSkills).sorted()
        return names.map { name in
            do {
                let skill = try AgentSkillStore.load(name: name, assistant: assistant)
                return AssistantWorkspaceSkill(
                    name: name, description: skill.description,
                    selected: assistant.selectedSkills.contains(name), error: nil)
            } catch {
                return AssistantWorkspaceSkill(
                    name: name, description: "",
                    selected: assistant.selectedSkills.contains(name),
                    error: error.localizedDescription)
            }
        }
    }
}
