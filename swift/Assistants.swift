import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Persistent assistants — a folder of markdown (ticket VF-49)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// An assistant IS its folder under ~/.config/voice-flow/assistants/<slug>/:
//   assistant.md   — frontmatter (name, description, voice) + instructions body
//   memory/core.md — her memory: dated facts, superseded not deleted; she
//                    tends it herself and it is injected into every turn
//   memory/ledger.md — her scratch notes
//   workspace/     — her working directory; sessions run inside her folder
// Replication = copy the folder, rename, change the wake name. The loader
// discovers every folder; wake routing picks the longest matching name, so
// "FLORA watcher" wins over "FLORA" when both exist.

struct AssistantDefinition {
    let slug: String          // folder name, e.g. "flora"
    let name: String          // display + wake name, e.g. "FLORA watcher"
    let description: String
    let voice: String?        // optional TTS voice for her replies
    let instructions: String  // assistant.md body — the user-authored persona
    let directory: URL
    let selectedSkills: [String]

    var memoryDirectory: URL { directory.appendingPathComponent("memory") }
    var coreMemoryURL: URL { memoryDirectory.appendingPathComponent("core.md") }
    var ledgerURL: URL { memoryDirectory.appendingPathComponent("ledger.md") }
    var workspaceDirectory: URL { directory.appendingPathComponent("workspace") }

    /// core.md as injected into the prompt — clipped so a bloated file can
    /// never eat the context. The cap is generous next to the documented
    /// ~200-line convention.
    func coreMemory(maxCharacters: Int = 12_000) -> String {
        guard let raw = try? String(contentsOf: coreMemoryURL, encoding: .utf8) else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "\n…(clipped — core.md is over the injection cap; tidy it)"
    }
}

enum AssistantFrontmatter {
    /// Parse "---\nkey: value\n---\nbody". A line indented by two or more
    /// spaces continues the previous value (matching how the fields are
    /// written by hand). Without a frontmatter block the whole text is body.
    static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var fields: [String: String] = [:]
        var lastKey: String?
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                index += 1
                break
            }
            if line.hasPrefix("  "), let key = lastKey {
                fields[key] = (fields[key] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                fields[key] = value
                lastKey = key
            }
            index += 1
        }
        let body = lines[index...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, body)
    }
}

final class AssistantsStore {
    static let shared = AssistantsStore()

    static var rootURL: URL {
        VoiceFlowPaths.shared.directory("assistants")
    }

    private(set) var assistants: [AssistantDefinition] = []

    /// The base assistant the Settings wake word addresses — "flora" if that
    /// folder exists, else the first loaded one.
    var base: AssistantDefinition? {
        assistants.first { $0.slug == "flora" } ?? assistants.first
    }

    func assistant(slug: String) -> AssistantDefinition? {
        assistants.first { $0.slug == slug }
    }

    /// Scan the folders; scaffold FLORA's on first run so the structure is
    /// visible and editable from day one.
    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.rootURL, withIntermediateDirectories: true)
        var found: [AssistantDefinition] = []
        let folders = (try? fm.contentsOfDirectory(at: Self.rootURL, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if let definition = Self.loadDefinition(directory: folder) { found.append(definition) }
        }
        if found.isEmpty {
            scaffoldFlora()
            if let flora = Self.loadDefinition(directory: Self.rootURL.appendingPathComponent("flora")) {
                found = [flora]
            }
        }
        // Every assistant keeps its memory and workspace dirs present.
        for definition in found {
            try? fm.createDirectory(at: definition.memoryDirectory, withIntermediateDirectories: true)
            try? fm.createDirectory(at: definition.workspaceDirectory, withIntermediateDirectories: true)
        }
        assistants = found.sorted { $0.slug < $1.slug }
        vflog("assistants loaded: \(assistants.map(\.name).joined(separator: ", "))")
    }

    private static func loadDefinition(directory: URL) -> AssistantDefinition? {
        let file = directory.appendingPathComponent("assistant.md")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let (fields, body) = AssistantFrontmatter.parse(text)
        let slug = directory.lastPathComponent
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? slug.uppercased()
        let voice = fields["voice"].flatMap { $0.isEmpty ? nil : $0 }
        let selectedSkills = (fields["skills"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return AssistantDefinition(slug: slug, name: name,
                                   description: fields["description"] ?? "",
                                   voice: voice, instructions: body, directory: directory,
                                   selectedSkills: selectedSkills)
    }

    private func scaffoldFlora() {
        let fm = FileManager.default
        let dir = Self.rootURL.appendingPathComponent("flora")
        try? fm.createDirectory(at: dir.appendingPathComponent("memory"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        let assistantMD = """
        ---
        name: \(DefaultAssistantWakeWord)
        description: the assistant — organizing thoughts, filing work, recalling decisions.
        ---
        You are \(DefaultAssistantWakeWord). Answer from your memory and the user's data before \
        reasoning from scratch, and when you recall a decision, say when you learned it. File \
        things where they belong; on genuine ambiguity ask instead of guessing. Never invent \
        facts your files don't back.
        """
        let coreMD = """
        # \(DefaultAssistantWakeWord) — core memory

        Durable facts, decisions, and standing rules. \(DefaultAssistantWakeWord) tends this \
        file herself: every fact is dated (YYYY-MM-DD), changes supersede (~~old~~ → new) \
        instead of deleting, and it stays under ~200 lines. Edit it freely — the files are \
        the assistant.

        ## Decisions

        ## Standing rules

        ## Superseded
        """
        let ledgerMD = """
        # \(DefaultAssistantWakeWord) — ledger

        Scratch notes between conversations. Nothing here is promised to survive; durable \
        things belong in core.md.
        """
        try? assistantMD.write(to: dir.appendingPathComponent("assistant.md"), atomically: true, encoding: .utf8)
        try? coreMD.write(to: dir.appendingPathComponent("memory/core.md"), atomically: true, encoding: .utf8)
        try? ledgerMD.write(to: dir.appendingPathComponent("memory/ledger.md"), atomically: true, encoding: .utf8)
        vflog("assistants: scaffolded \(dir.path)")
    }
}
