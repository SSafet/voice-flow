import Foundation
import CryptoKit

enum AgentCapabilityError: LocalizedError, Equatable {
    case invalidPath
    case pathOutsideRoot
    case invalidRevision
    case oversized(Int)
    case secretDetected
    case invalidSkill(String)
    case missingSkill(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath: return "The requested path is invalid."
        case .pathOutsideRoot: return "The requested path is outside the assistant boundary."
        case .invalidRevision: return "The file changed since it was read; read it again before writing."
        case .oversized(let limit): return "The content exceeds the \(limit)-character limit."
        case .secretDetected: return "The content looks like a credential or secret and was not stored."
        case .invalidSkill(let detail): return "Invalid skill: \(detail)"
        case .missingSkill(let name): return "Selected skill '\(name)' does not exist."
        }
    }
}

enum AgentDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }
}

enum AgentPathBoundary {
    /// Resolves a relative path without permitting `..`, absolute paths, or a
    /// symlinked parent to escape the canonical root.
    static func resolve(_ relativePath: String, within root: URL,
                        fileManager: FileManager = .default) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains("..") else {
            throw AgentCapabilityError.invalidPath
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        let existingParent = nearestExistingParent(of: candidate, fileManager: fileManager)
        let resolvedParent = existingParent.resolvingSymlinksInPath()
        guard contains(resolvedParent, root: canonicalRoot) else {
            throw AgentCapabilityError.pathOutsideRoot
        }
        let resolved = candidate.resolvingSymlinksInPath()
        guard contains(resolved, root: canonicalRoot) else {
            throw AgentCapabilityError.pathOutsideRoot
        }
        return candidate
    }

    static func contains(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func nearestExistingParent(of url: URL, fileManager: FileManager) -> URL {
        var current = url
        while !fileManager.fileExists(atPath: current.path), current.path != "/" {
            current.deleteLastPathComponent()
        }
        return current
    }
}

enum AgentSecretPolicy {
    private static let expressions: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        try! NSRegularExpression(pattern: #"(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[:=]\s*['\"]?[A-Za-z0-9_./+=-]{12,}"#),
        try! NSRegularExpression(pattern: #"\b(?:sk|pk|rk)-(?:live-)?[A-Za-z0-9_-]{16,}"#),
        try! NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#),
    ]

    static func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    static func redacted(_ text: String) -> String {
        var result = text
        for expression in expressions.reversed() {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: "[REDACTED]")
        }
        return result
    }
}

struct AgentMemoryDocument: Equatable {
    let kind: String
    let content: String
    let revision: String
    let clipped: Bool
}

final class AgentMemoryStore {
    static let coreLimit = 12_000
    static let ledgerLimit = 24_000

    private let assistant: AssistantDefinition
    private let lock = NSLock()

    init(assistant: AssistantDefinition) {
        self.assistant = assistant
    }

    func read(kind: String) throws -> AgentMemoryDocument {
        try lock.withLock { try readUnlocked(kind: kind) }
    }

    func update(kind: String, content: String, expectedRevision: String) throws -> AgentMemoryDocument {
        try lock.withLock {
            let current = try readUnlocked(kind: kind)
            guard current.revision == expectedRevision else {
                throw AgentCapabilityError.invalidRevision
            }
            let limit = try limit(for: kind)
            guard content.count <= limit else { throw AgentCapabilityError.oversized(limit) }
            guard !AgentSecretPolicy.containsSecret(content) else {
                throw AgentCapabilityError.secretDetected
            }
            let url = try url(for: kind)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(content.utf8)
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return AgentMemoryDocument(
                kind: kind, content: content,
                revision: AgentDigest.sha256(data), clipped: false)
        }
    }

    private func readUnlocked(kind: String) throws -> AgentMemoryDocument {
        let url = try url(for: kind)
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let limit = try limit(for: kind)
        let clipped = raw.count > limit
        let visible = clipped ? String(raw.prefix(limit)) : raw
        return AgentMemoryDocument(
            kind: kind, content: visible,
            revision: AgentDigest.sha256(raw), clipped: clipped)
    }

    private func url(for kind: String) throws -> URL {
        switch kind {
        case "core": return assistant.coreMemoryURL
        case "ledger": return assistant.ledgerURL
        default: throw AgentCapabilityError.invalidPath
        }
    }

    private func limit(for kind: String) throws -> Int {
        switch kind {
        case "core": return Self.coreLimit
        case "ledger": return Self.ledgerLimit
        default: throw AgentCapabilityError.invalidPath
        }
    }
}

struct AgentSkill: Equatable {
    let name: String
    let description: String
    let sourceURL: URL
    let contents: String
    let digest: String
}

struct AgentSkillProjectionEntry: Codable, Equatable {
    let skill: String
    let sourceDigest: String
    let projectedPath: String
}

struct AgentSkillProjectionManifest: Codable, Equatable {
    let version: Int
    let entries: [AgentSkillProjectionEntry]
}

enum AgentSkillStore {
    private static let projectionLock = NSLock()
    private static let namePattern = try! NSRegularExpression(
        pattern: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#)

    static func loadSelected(for assistant: AssistantDefinition) throws -> [AgentSkill] {
        try assistant.selectedSkills.map { try load(name: $0, assistant: assistant) }
    }

    static func load(name: String, assistant: AssistantDefinition) throws -> AgentSkill {
        let fullRange = NSRange(name.startIndex..<name.endIndex, in: name)
        guard name.count <= 64,
              namePattern.firstMatch(in: name, range: fullRange)?.range == fullRange else {
            throw AgentCapabilityError.invalidSkill("name must match ^[a-z0-9]+(-[a-z0-9]+)*$")
        }
        let relative = "skills/\(name)/SKILL.md"
        let url = try AgentPathBoundary.resolve(relative, within: assistant.directory)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw AgentCapabilityError.missingSkill(name)
        }
        let parsed = AssistantFrontmatter.parse(text)
        guard parsed.fields["name"] == name else {
            throw AgentCapabilityError.invalidSkill("frontmatter name must equal its directory")
        }
        guard let description = parsed.fields["description"],
              (1...1_024).contains(description.count) else {
            throw AgentCapabilityError.invalidSkill("description must be 1-1024 characters")
        }
        guard !parsed.body.isEmpty else {
            throw AgentCapabilityError.invalidSkill("body is empty")
        }
        return AgentSkill(
            name: name, description: description, sourceURL: url,
            contents: text, digest: AgentDigest.sha256(text))
    }

    @discardableResult
    static func project(for assistant: AssistantDefinition) throws -> AgentSkillProjectionManifest {
        // Skills and tools are assistant-scoped projections, not
        // conversation-scoped state. Concurrent runs may refresh the exact
        // same target and therefore must share one filesystem transaction.
        projectionLock.lock()
        defer { projectionLock.unlock() }
        let skills = try loadSelected(for: assistant)
        let opencodeRoot = assistant.directory.appendingPathComponent(".opencode")
        let target = opencodeRoot.appendingPathComponent("skills")
        let staging = opencodeRoot.appendingPathComponent(".skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var entries: [AgentSkillProjectionEntry] = []
            for skill in skills {
                let directory = staging.appendingPathComponent(skill.name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let projected = directory.appendingPathComponent("SKILL.md")
                try Data(skill.contents.utf8).write(to: projected, options: [.atomic])
                entries.append(AgentSkillProjectionEntry(
                    skill: skill.name, sourceDigest: skill.digest,
                    projectedPath: ".opencode/skills/\(skill.name)/SKILL.md"))
            }
            let manifest = AgentSkillProjectionManifest(version: 1, entries: entries)
            let data = try JSONEncoder.sorted.encode(manifest)
            try data.write(to: staging.appendingPathComponent("manifest.json"), options: [.atomic])
            if FileManager.default.fileExists(atPath: target.path) {
                let old = opencodeRoot.appendingPathComponent(".skills-old-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: target, to: old)
                do {
                    try FileManager.default.moveItem(at: staging, to: target)
                    try? FileManager.default.removeItem(at: old)
                } catch {
                    try? FileManager.default.moveItem(at: old, to: target)
                    throw error
                }
            } else {
                try FileManager.default.moveItem(at: staging, to: target)
            }
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func promptBlock(for assistant: AssistantDefinition,
                            maxCharacters: Int = 16_000) throws -> String {
        let blocks = try loadSelected(for: assistant).map { skill in
            "## Skill: \(skill.name)\n\(skill.contents)"
        }.joined(separator: "\n\n")
        guard !blocks.isEmpty else { return "" }
        return blocks.count <= maxCharacters
            ? "\n\n# Selected Voice Flow skills\n\(blocks)"
            : "\n\n# Selected Voice Flow skills\n\(String(blocks.prefix(maxCharacters)))\n…(skills clipped)"
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
