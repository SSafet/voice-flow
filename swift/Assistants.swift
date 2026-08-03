import CryptoKit
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

struct AssistantDocument {
    let definition: AssistantDefinition
    let fields: [String: String]
    let fieldOrder: [String]
    let revision: String
}

struct AssistantDraft {
    let name: String
    let description: String
    let voice: String?
    let instructions: String
    let selectedSkills: [String]

    init(name: String, description: String = "", voice: String? = nil,
         instructions: String = "", selectedSkills: [String] = []) {
        self.name = name
        self.description = description
        self.voice = voice
        self.instructions = instructions
        self.selectedSkills = selectedSkills
    }
}

struct AssistantLoadIssue: Equatable {
    let slug: String
    let message: String
}

struct AssistantsLoadSnapshot {
    let assistants: [AssistantDefinition]
    let issues: [AssistantLoadIssue]
}

enum AssistantStoreError: LocalizedError, Equatable {
    case notFound(String)
    case invalidName(String)
    case invalidDescription(String)
    case invalidInstructions(String)
    case invalidSkill(String)
    case duplicateWakeName(String)
    case revisionConflict
    case cannotDeleteLast
    case boundaryViolation
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let slug): return "Assistant \(slug) was not found."
        case .invalidName(let detail): return "Assistant name is invalid: \(detail)"
        case .invalidDescription(let detail): return "Assistant description is invalid: \(detail)"
        case .invalidInstructions(let detail): return "Assistant instructions are invalid: \(detail)"
        case .invalidSkill(let detail): return "Assistant skill selection is invalid: \(detail)"
        case .duplicateWakeName(let name): return "Another Assistant already uses the wake name \(name)."
        case .revisionConflict: return "Assistant changed on disk. Reload before saving."
        case .cannotDeleteLast: return "Create another Assistant first."
        case .boundaryViolation: return "Assistant folder is outside the configured Assistants directory."
        case .io(let detail): return "Assistant files could not be updated: \(detail)"
        }
    }
}

enum AssistantFrontmatter {
    struct Document {
        let fields: [String: String]
        let fieldOrder: [String]
        let body: String
    }

    /// Parse "---\nkey: value\n---\nbody". A line indented by two or more
    /// spaces continues the previous value (matching how the fields are
    /// written by hand). Without a frontmatter block the whole text is body.
    static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let document = parseDocument(text)
        return (document.fields, document.body)
    }

    static func parseDocument(_ text: String) -> Document {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return Document(
                fields: [:], fieldOrder: [],
                body: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var fields: [String: String] = [:]
        var fieldOrder: [String] = []
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
                if fields[key] == nil { fieldOrder.append(key) }
                fields[key] = value
                lastKey = key
            }
            index += 1
        }
        let body = lines[index...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Document(fields: fields, fieldOrder: fieldOrder, body: body)
    }
}

final class AssistantsStore {
    static let shared = AssistantsStore()

    static var rootURL: URL {
        VoiceFlowPaths.shared.directory("assistants")
    }

    private let root: URL
    private let lock = NSRecursiveLock()
    private var loadedAssistants: [AssistantDefinition] = []
    private var loadIssues: [AssistantLoadIssue] = []

    init(rootURL: URL = AssistantsStore.rootURL) {
        root = rootURL.standardizedFileURL
    }

    var assistants: [AssistantDefinition] {
        lock.withLock { loadedAssistants }
    }

    var issues: [AssistantLoadIssue] {
        lock.withLock { loadIssues }
    }

    /// The base assistant the Settings wake word addresses — "flora" if that
    /// folder exists, else the first loaded one.
    var base: AssistantDefinition? {
        lock.withLock {
            loadedAssistants.first { $0.slug == "flora" } ?? loadedAssistants.first
        }
    }

    func assistant(slug: String) -> AssistantDefinition? {
        lock.withLock { loadedAssistants.first { $0.slug == slug } }
    }

    func load() {
        _ = reload()
    }

    @discardableResult
    func reload() -> AssistantsLoadSnapshot {
        lock.withLock { reloadLocked() }
    }

    func snapshot() -> AssistantsLoadSnapshot {
        lock.withLock {
            AssistantsLoadSnapshot(assistants: loadedAssistants, issues: loadIssues)
        }
    }

    func document(slug: String) throws -> AssistantDocument {
        try lock.withLock {
            let directory = try directoryLocked(slug: slug)
            return try loadDocumentLocked(directory: directory)
        }
    }

    @discardableResult
    func create(_ draft: AssistantDraft) throws -> AssistantDefinition {
        try lock.withLock {
            try createLocked(draft, copiedSkillsFrom: nil)
        }
    }

    @discardableResult
    func duplicate(slug: String, name: String) throws -> AssistantDefinition {
        try lock.withLock {
            let source = try loadDocumentLocked(directory: directoryLocked(slug: slug))
            let draft = AssistantDraft(
                name: name,
                description: source.definition.description,
                voice: source.definition.voice,
                instructions: source.definition.instructions,
                selectedSkills: source.definition.selectedSkills)
            return try createLocked(draft, copiedSkillsFrom: source.definition)
        }
    }

    @discardableResult
    func update(slug: String, draft: AssistantDraft,
                expectedRevision: String) throws -> AssistantDefinition {
        try lock.withLock {
            let validated = try validatedDraftLocked(draft, excludingSlug: slug)
            let current = try loadDocumentLocked(directory: directoryLocked(slug: slug))
            guard current.revision == expectedRevision else {
                throw AssistantStoreError.revisionConflict
            }
            var fields = current.fields
            fields["name"] = validated.name
            fields["description"] = validated.description
            fields["voice"] = validated.voice ?? ""
            fields["skills"] = validated.selectedSkills.joined(separator: ", ")
            let text = Self.render(
                fields: fields, fieldOrder: current.fieldOrder,
                body: validated.instructions)
            do {
                try Data(text.utf8).write(
                    to: current.definition.directory.appendingPathComponent("assistant.md"),
                    options: .atomic)
            } catch {
                throw AssistantStoreError.io(error.localizedDescription)
            }
            let snapshot = reloadLocked()
            guard let result = snapshot.assistants.first(where: { $0.slug == slug }) else {
                throw AssistantStoreError.io("saved definition could not be reloaded")
            }
            return result
        }
    }

    func moveToTrash(slug: String) throws {
        try lock.withLock {
            guard loadedAssistants.count > 1 else { throw AssistantStoreError.cannotDeleteLast }
            let directory = try directoryLocked(slug: slug)
            do {
                try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
            } catch {
                throw AssistantStoreError.io(error.localizedDescription)
            }
            _ = reloadLocked()
        }
    }

    private func reloadLocked() -> AssistantsLoadSnapshot {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            loadIssues = [AssistantLoadIssue(slug: "", message: error.localizedDescription)]
            return AssistantsLoadSnapshot(assistants: loadedAssistants, issues: loadIssues)
        }

        var folders = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []
        folders = folders.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey])).flatMap(\.isDirectory) == true
        }
        if folders.isEmpty {
            do { try scaffoldFloraLocked() }
            catch { loadIssues = [AssistantLoadIssue(slug: "flora", message: error.localizedDescription)] }
            folders = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        }

        var found: [AssistantDefinition] = []
        var issues: [AssistantLoadIssue] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            do {
                let document = try loadDocumentLocked(directory: folder)
                found.append(document.definition)
                try fm.createDirectory(
                    at: document.definition.memoryDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try fm.createDirectory(
                    at: document.definition.workspaceDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                issues.append(AssistantLoadIssue(
                    slug: folder.lastPathComponent,
                    message: error.localizedDescription))
            }
        }
        loadedAssistants = found.sorted { $0.slug < $1.slug }
        loadIssues = issues.sorted { $0.slug < $1.slug }
        vflog("assistants loaded: \(loadedAssistants.map(\.name).joined(separator: ", "))")
        return AssistantsLoadSnapshot(assistants: loadedAssistants, issues: loadIssues)
    }

    private func loadDocumentLocked(directory: URL) throws -> AssistantDocument {
        try ensureDirectChildLocked(directory)
        let file = directory.appendingPathComponent("assistant.md")
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch { throw AssistantStoreError.io(error.localizedDescription) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AssistantStoreError.io("assistant.md is not UTF-8")
        }
        let parsed = AssistantFrontmatter.parseDocument(text)
        let slug = directory.lastPathComponent
        let name = parsed.fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else {
            throw AssistantStoreError.invalidName("assistant.md needs a name")
        }
        let voice = parsed.fields["voice"].flatMap { $0.isEmpty ? nil : $0 }
        let selectedSkills = (parsed.fields["skills"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let definition = AssistantDefinition(
            slug: slug, name: name,
            description: parsed.fields["description"] ?? "",
            voice: voice, instructions: parsed.body, directory: directory,
            selectedSkills: selectedSkills)
        return AssistantDocument(
            definition: definition, fields: parsed.fields,
            fieldOrder: parsed.fieldOrder,
            revision: Self.revision(data))
    }

    private func createLocked(_ draft: AssistantDraft,
                              copiedSkillsFrom source: AssistantDefinition?) throws -> AssistantDefinition {
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw AssistantStoreError.io(error.localizedDescription)
        }
        let validated = try validatedDraftLocked(draft, excludingSlug: nil)
        let slug = nextSlugLocked(name: validated.name)
        let staging = root.appendingPathComponent(".creating-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent(slug, isDirectory: true)
        try ensureDirectChildLocked(staging)
        try ensureDirectChildLocked(target)
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: staging, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(
                at: staging.appendingPathComponent("memory"),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(
                at: staging.appendingPathComponent("workspace"),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(
                at: staging.appendingPathComponent("skills"),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])

            let fields = [
                "name": validated.name,
                "description": validated.description,
                "voice": validated.voice ?? "",
                "skills": validated.selectedSkills.joined(separator: ", "),
            ]
            let assistantText = Self.render(
                fields: fields,
                fieldOrder: ["name", "description", "voice", "skills"],
                body: validated.instructions)
            try Data(assistantText.utf8).write(
                to: staging.appendingPathComponent("assistant.md"), options: .atomic)
            try Data("# \(validated.name) — core memory\n".utf8).write(
                to: staging.appendingPathComponent("memory/core.md"), options: .atomic)
            try Data("# \(validated.name) — ledger\n".utf8).write(
                to: staging.appendingPathComponent("memory/ledger.md"), options: .atomic)

            if let source {
                for skill in validated.selectedSkills {
                    let from = source.directory
                        .appendingPathComponent("skills", isDirectory: true)
                        .appendingPathComponent(skill, isDirectory: true)
                    guard fm.fileExists(atPath: from.path) else {
                        throw AssistantStoreError.invalidSkill("selected package \(skill) is missing")
                    }
                    try fm.copyItem(
                        at: from,
                        to: staging.appendingPathComponent("skills", isDirectory: true)
                            .appendingPathComponent(skill, isDirectory: true))
                }
            }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            if let typed = error as? AssistantStoreError { throw typed }
            throw AssistantStoreError.io(error.localizedDescription)
        }
        let snapshot = reloadLocked()
        guard let result = snapshot.assistants.first(where: { $0.slug == slug }) else {
            throw AssistantStoreError.io("created definition could not be reloaded")
        }
        return result
    }

    private func validatedDraftLocked(_ draft: AssistantDraft,
                                      excludingSlug: String?) throws -> AssistantDraft {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, !name.contains("\n") else {
            throw AssistantStoreError.invalidName("use 1–64 characters on one line")
        }
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard description.count <= 240, !description.contains("\n") else {
            throw AssistantStoreError.invalidDescription("use at most 240 characters on one line")
        }
        guard draft.instructions.count <= 12_000 else {
            throw AssistantStoreError.invalidInstructions("use at most 12,000 characters")
        }
        if loadedAssistants.contains(where: {
            $0.slug != excludingSlug
                && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            throw AssistantStoreError.duplicateWakeName(name)
        }
        var skills: [String] = []
        for raw in draft.selectedSkills {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value != ".", value != "..",
                  !value.contains("/"), !value.contains("\\") else {
                throw AssistantStoreError.invalidSkill(raw)
            }
            if !skills.contains(value) { skills.append(value) }
        }
        let voice = draft.voice?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantDraft(
            name: name, description: description,
            voice: voice?.isEmpty == true ? nil : voice,
            instructions: draft.instructions,
            selectedSkills: skills)
    }

    private func nextSlugLocked(name: String) -> String {
        let folded = name.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = folded.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "assistant" }
        slug = String(slug.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let diskNames = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?.map(\.lastPathComponent) ?? []
        let occupied = Set(loadedAssistants.map(\.slug)).union(diskNames)
        if !occupied.contains(slug) { return slug }
        var suffix = 2
        while true {
            let tail = "-\(suffix)"
            let prefix = String(slug.prefix(max(1, 64 - tail.count)))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let candidate = prefix + tail
            if !occupied.contains(candidate) { return candidate }
            suffix += 1
        }
    }

    private func directoryLocked(slug: String) throws -> URL {
        guard !slug.isEmpty, slug != ".", slug != "..",
              !slug.contains("/"), !slug.contains("\\") else {
            throw AssistantStoreError.boundaryViolation
        }
        let directory = root.appendingPathComponent(slug, isDirectory: true)
        try ensureDirectChildLocked(directory)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw AssistantStoreError.notFound(slug)
        }
        return directory
    }

    private func ensureDirectChildLocked(_ candidate: URL) throws {
        let parent = candidate.deletingLastPathComponent().standardizedFileURL
        guard parent.path == root.standardizedFileURL.path,
              candidate.lastPathComponent != ".",
              candidate.lastPathComponent != ".." else {
            throw AssistantStoreError.boundaryViolation
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(resolvedRoot + "/") else {
                throw AssistantStoreError.boundaryViolation
            }
        }
    }

    private func scaffoldFloraLocked() throws {
        let directory = root.appendingPathComponent("flora", isDirectory: true)
        let file = directory.appendingPathComponent("assistant.md")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let draft = AssistantDraft(
            name: DefaultAssistantWakeWord,
            description: "the assistant — organizing thoughts, filing work, recalling decisions.",
            instructions: "You are \(DefaultAssistantWakeWord). Answer from your memory and the user's data before reasoning from scratch, and when you recall a decision, say when you learned it. File things where they belong; on genuine ambiguity ask instead of guessing. Never invent facts your files don't back.")
        _ = try createLocked(draft, copiedSkillsFrom: nil)
    }

    private static func render(fields: [String: String], fieldOrder: [String],
                               body: String) -> String {
        var order = fieldOrder
        for key in ["name", "description", "voice", "skills"] where !order.contains(key) {
            order.append(key)
        }
        var lines = ["---"]
        for key in order {
            guard let value = fields[key] else { continue }
            let parts = value.components(separatedBy: "\n")
            lines.append("\(key): \(parts.first ?? "")")
            lines.append(contentsOf: parts.dropFirst().map { "  \($0)" })
        }
        lines.append("---")
        if !body.isEmpty { lines.append(body) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
