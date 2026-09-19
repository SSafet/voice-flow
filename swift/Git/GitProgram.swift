import Foundation

/// The one place the `git` program is found (06 §3.16 "Running git"). Every
/// other type in this package is handed a `GitProgram`; none of them looks for
/// git or names it by path.
struct GitProgram: Equatable, Sendable {
    let url: URL
    let version: String
}

/// Why no `git` program could be used, in a sentence a person can read.
struct GitUnavailable: Error, Equatable {
    let message: String
}

enum GitProgramLocator {
    /// When this key is present in the environment, only its value is tried.
    static let overrideEnvironmentKey = "VOICE_FLOW_GIT_PATH"

    /// The places macOS keeps git, tried after every `PATH` directory.
    static let fallbackPaths: [String] = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
    ]

    private static let lock = NSLock()
    private static var cached: Result<GitProgram, GitUnavailable>?

    /// Finds git exactly the way the brief says: the override when the
    /// environment carries one, otherwise every `PATH` directory in order and
    /// then the fallback paths. A candidate is only accepted when it runs and
    /// prints a `git version …` line of its own.
    static func find(environment: [String: String]) -> Result<GitProgram, GitUnavailable> {
        if let override = environment[overrideEnvironmentKey] {
            return probe(override)
        }

        var candidates: [String] = []
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") {
                let trimmed = String(directory)
                guard !trimmed.isEmpty else { continue }
                candidates.append(trimmed.hasSuffix("/") ? trimmed + "git" : trimmed + "/git")
            }
        }
        candidates.append(contentsOf: fallbackPaths)

        var reasons: [String] = []
        for candidate in candidates {
            switch probe(candidate) {
            case .success(let program):
                return .success(program)
            case .failure(let unavailable):
                reasons.append(unavailable.message)
            }
        }
        return .failure(GitUnavailable(message: reasons.joined(separator: "; ")))
    }

    /// Finds git once for the life of the process and gives the same answer
    /// afterwards, whatever the environment does later.
    static func shared() -> Result<GitProgram, GitUnavailable> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let result = find(environment: ProcessInfo.processInfo.environment)
        cached = result
        return result
    }

    private static func probe(_ path: String) -> Result<GitProgram, GitUnavailable> {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .failure(GitUnavailable(message: "git was not found at \(path)"))
        }
        let url = URL(fileURLWithPath: path)
        let runner = GitRunner(program: GitProgram(url: url, version: ""), timeout: 5)
        let folder = url.deletingLastPathComponent()
        switch runner.run(["--version"], in: folder) {
        case .failure(let failure):
            return .failure(GitUnavailable(
                message: "\(path) could not be run to read its git version: \(describe(failure))"))
        case .success(let output):
            let printed = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = printed.split(separator: "\n").first.map(String.init) ?? ""
            guard firstLine.hasPrefix("git version ") else {
                return .failure(GitUnavailable(
                    message: "\(path) did not print a git version; it printed \(printed)"))
            }
            let rest = firstLine.dropFirst("git version ".count)
            guard let version = rest.split(separator: " ").first, !version.isEmpty else {
                return .failure(GitUnavailable(
                    message: "\(path) printed a git version line with no version in it: \(firstLine)"))
            }
            return .success(GitProgram(url: url, version: String(version)))
        }
    }

    private static func describe(_ failure: GitFailure) -> String {
        switch failure {
        case .unavailable(let message):
            return message
        case .timedOut(let seconds):
            return "it did not answer within \(seconds) seconds"
        case .failed(let exitCode, let message):
            return "it exited with \(exitCode): \(message)"
        }
    }
}
