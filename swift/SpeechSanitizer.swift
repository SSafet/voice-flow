import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Speech cleanup before read-aloud (ticket VF-43)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Agent output is written for a screen: URLs, code blocks, commit hashes,
// file paths and markdown are noise or nonsense when voiced verbatim.
// Everything read aloud passes through this step first. Two layers:
//
// - `SpeechSanitizer` — deterministic, instant, pure. The only layer for
//   streaming replies (chunks arrive every few hundred ms) and the
//   always-on fallback everywhere else.
// - `SpeechCleanupLLM` — a chip-model rewrite via the Codex CLI (same
//   mechanics as AssistantContinuityClassifier) for manual read-aloud of
//   heavy content, with a short timeout; any failure falls back to the
//   deterministic layer.
//
// Cleanup affects SPEECH ONLY — the original text stays untouched in the
// panel, the push stacks, and history.

/// Stateful variant for streaming: a code fence opened in one chunk stays
/// closed-over in the next, so later chunks of the same block are never
/// spoken as prose.
struct SpeechSanitizerStream {
    var inCodeFence = false

    mutating func sanitize(_ chunk: String) -> String {
        var lines: [String] = []
        for rawLine in chunk.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    inCodeFence = false
                } else {
                    inCodeFence = true
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    lines.append(language.isEmpty
                        ? "There's a code block."
                        : "There's a \(language) code block.")
                }
                continue
            }
            if inCodeFence { continue }
            if let line = SpeechSanitizer.sanitizeLine(trimmed) { lines.append(line) }
        }
        let joined = lines.joined(separator: "\n")
        return SpeechSanitizer.sanitizeInline(joined)
    }
}

enum SpeechSanitizer {
    /// One-shot cleanup for complete texts.
    static func sanitize(_ text: String) -> String {
        var stream = SpeechSanitizerStream()
        return stream.sanitize(text)
    }

    /// True when the text carries content worth a chip-model rewrite:
    /// URLs, code fences, tables, hashes, or identifiers.
    static func hasHeavyContent(_ text: String) -> Bool {
        if text.contains("```") { return true }
        if firstMatch(urlRegex, in: text) { return true }
        if firstMatch(uuidRegex, in: text) { return true }
        if firstMatch(hashRegex, in: text) { return true }
        for line in text.components(separatedBy: "\n")
        where line.components(separatedBy: "|").count >= 3 { return true }
        return false
    }

    // ── line-level markdown structure ──

    /// Returns the speakable form of a (non-code) line, or nil to drop it.
    static func sanitizeLine(_ line: String) -> String? {
        var text = line
        // Horizontal rules and table separator rows carry no speech.
        if !text.isEmpty,
           text.unicodeScalars.allSatisfy({ "-*_|: ".unicodeScalars.contains($0) }),
           text.contains("-") || text.contains("*") || text.contains("_") {
            return nil
        }
        // Table row → comma-joined cells.
        if text.components(separatedBy: "|").count >= 3 {
            let cells = text.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return cells.isEmpty ? nil : cells.joined(separator: ", ")
        }
        text = replace(text, #"^#{1,6}\s+"#, "")        // headings
        text = replace(text, #"^>\s?"#, "")              // blockquotes
        text = replace(text, #"^[-*+]\s+"#, "")          // bullets
        text = replace(text, #"^\d{1,3}[.)]\s+"#, "")    // numbered lists
        return text
    }

    // ── inline tokens ──

    static func sanitizeInline(_ input: String) -> String {
        var text = input
        // Images and links keep their human label.
        text = replace(text, #"!\[([^\]]*)\]\(([^)]*)\)"#, "$1")
        text = replace(text, #"\[([^\]]+)\]\(([^)]*)\)"#, "$1")
        // Bare URLs → "a link to <host>".
        text = replaceMatches(urlRegex, in: text) { match in
            "a link to \(host(of: match))"
        }
        // Inline code: short snippets are spoken bare, long ones described.
        text = replaceMatches(#"`([^`\n]+)`"#, in: text) { match in
            let inner = String(match.dropFirst().dropLast())
            return inner.count <= 60 ? inner : "a code snippet"
        }
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "~~", with: "")
        // Machine identifiers: UUIDs vanish, commit hashes become words.
        text = replace(text, uuidRegex, "")
        // "Commit <hash> landed the fix" → "A commit landed the fix".
        // Keeping only the lead-in read as a bare "Commit landed the fix".
        // Sentence-initial matches take the capital; the rest stay lowercase.
        text = replace(text, #"(?i)(^|(?<=[.!?]\s))commit\s+"# + hashBody, "A commit")
        text = replace(text, #"(?i)\bcommit\s+"# + hashBody, "a commit")
        text = replace(text, hashRegex, "a commit hash")
        // Deep paths → the last component ("swift/App.swift" survives as
        // "App.swift"; "either/or" has one slash and is untouched).
        text = replaceMatches(#"(?:~|\.)?(?:/[\w.@+-]+){2,}|[\w.@+-]+(?:/[\w.@+-]+){2,}"#, in: text) { match in
            match.components(separatedBy: "/").last(where: { !$0.isEmpty }) ?? ""
        }
        // Tidy what the removals left behind.
        text = replace(text, #"[ \t]+([.,!?;:])"#, "$1")
        text = replace(text, #"[ \t]{2,}"#, " ")
        text = replace(text, #"\n{2,}"#, "\n")
        text = dropEmptyScaffolding(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ── post-removal repair ──

    /// Removing an identifier can strand the words that introduced it:
    /// "The session id is <uuid>." becomes "The session id is." A sentence
    /// that is nothing but a lead-in to something we deleted carries no
    /// speech at all, so it goes with it. Deliberately narrow — the sentence
    /// must END on a linking word and must not be a question, so "Do you
    /// want me to roll this to production?" and "The build is ok." both stay.
    static func dropEmptyScaffolding(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            sentences(in: line)
                .filter { !isScaffolding($0) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static let scaffoldingPattern =
        #"(?i)^[\w\s,'’-]{0,60}\b(?:is|are|was|were|at|to|from|of|see|via)\s*\.?$"#

    private static func isScaffolding(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return firstMatch(scaffoldingPattern, in: trimmed)
    }

    /// Splits on sentence terminators only when whitespace (or the end of the
    /// line) follows, so "github.com" and "CaptureRouting.swift" stay whole.
    private static func sentences(in line: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(line)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?".contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            if next.isWhitespace {
                result.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        return result
    }


    // ── regex plumbing ──

    private static let urlRegex = #"https?://[^\s)\]>,"']+"#
    private static let uuidRegex =
        #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#
    /// Hex run 7–40 chars containing both a digit and a letter — a bare
    /// number ("1234567", a year, a count) never matches.
    private static let hashBody = #"\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}\b"#
    private static var hashRegex: String { hashBody }

    private static func host(of url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return "a page" }
        let rest = url[schemeEnd.upperBound...]
        let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let cleaned = host.hasPrefix("www.") ? host.dropFirst(4) : host[...]
        return cleaned.isEmpty ? "a page" : String(cleaned)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replaceMatches(_ pattern: String, in text: String,
                                       _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in regex.matches(in: text, range: range).reversed() {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let replacement = transform(String(text[swiftRange]))
            let resultRange = Range(match.range, in: result)!
            result.replaceSubrange(resultRange, with: replacement)
        }
        return result
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Chip-model rewrite (deterministic fallback on any failure)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

private enum SpeechCleanupError: LocalizedError {
    case codexUnavailable
    case timedOut
    case processFailed(String)
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .codexUnavailable: return "Codex CLI is unavailable or not signed in"
        case .timedOut: return "speech cleanup timed out"
        case .processFailed(let message): return message
        case .missingOutput: return "speech cleanup produced no output"
        }
    }
}

private struct SpeechCleanupResponse: Decodable {
    let speech: String
}

final class SpeechCleanupLLM {
    typealias Runner = @Sendable (String) async throws -> String

    static let shared = SpeechCleanupLLM()
    /// Resolved per run so a retune from the Agents panel lands on the very
    /// next read-aloud without a restart.
    static var config: SystemAgentConfig { SystemAgentStore.shared.config(for: .speechCleanup) }
    static let defaultTimeoutSeconds: TimeInterval = 6
    static let maxInputCharacters = 4_000

    private let runner: Runner
    private let timeoutNanoseconds: UInt64

    init(timeoutSeconds: TimeInterval = SpeechCleanupLLM.defaultTimeoutSeconds,
         runner: Runner? = nil) {
        self.timeoutNanoseconds = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
        self.runner = runner ?? { prompt in try await Self.runCodex(prompt) }
    }

    /// Speech-ready rewrite of `text`, or nil when the model is
    /// unavailable, slow, or produced something unusable — callers then
    /// use `SpeechSanitizer.sanitize` instead.
    func cleanup(_ text: String) async -> String? {
        let input = String(text.prefix(Self.maxInputCharacters))
        do {
            let raw = try await runWithTimeout(Self.prompt(for: input))
            let data = Data(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            let response = try JSONDecoder().decode(SpeechCleanupResponse.self, from: data)
            let speech = response.speech.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speech.isEmpty, speech.count <= max(400, input.count * 3) else { return nil }
            return speech
        } catch {
            return nil
        }
    }

    static func prompt(for text: String) -> String {
        // Editable brief, fixed data block — the schema decode depends on the
        // delimiters, so they are appended here and never in the user's text.
        """
        \(config.instructions.trimmingCharacters(in: .whitespacesAndNewlines))

        <MESSAGE>
        \(text)
        </MESSAGE>
        """
    }

    private func runWithTimeout(_ prompt: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.runner(prompt) }
            group.addTask {
                try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                throw SpeechCleanupError.timedOut
            }
            guard let first = try await group.next() else { throw SpeechCleanupError.missingOutput }
            group.cancelAll()
            return first
        }
    }

    private static func findCodexBinary() -> String? {
        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { String($0) + "/codex" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runCodex(_ prompt: String) async throws -> String {
        guard let binary = findCodexBinary(),
              FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/auth.json") else {
            throw SpeechCleanupError.codexUnavailable
        }

        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("vf-speech-cleanup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let schemaURL = directory.appendingPathComponent("schema.json")
        let outputURL = directory.appendingPathComponent("output.json")
        let errorURL = directory.appendingPathComponent("stderr.txt")
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "speech": ["type": "string"],
            ],
            "required": ["speech"],
            "additionalProperties": false,
        ]
        try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted])
            .write(to: schemaURL, options: .atomic)
        fm.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }

        let resolved = config
        vflog("speech cleanup: model=\(resolved.model) effort=\(resolved.effort ?? "provider default") brief=\(resolved.instructions.prefix(48))…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var arguments = [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-m", resolved.model,
        ]
        if let effort = resolved.effort {
            arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""])
        }
        arguments.append(contentsOf: [
            "-c", "mcp_servers={}",
            "--output-schema", schemaURL.path,
            "-o", outputURL.path,
            prompt,
        ])
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle

        try Task.checkCancellation()
        let status: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completed in
                    continuation.resume(returning: completed.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            if process.isRunning { process.terminate() }
        })

        guard status == 0 else {
            let message = (try? String(contentsOf: errorURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SpeechCleanupError.processFailed(
                message.isEmpty ? "speech cleanup exited with status \(status)" : String(message.prefix(1_000)))
        }
        guard let output = try? String(contentsOf: outputURL, encoding: .utf8),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechCleanupError.missingOutput
        }
        return output
    }
}
