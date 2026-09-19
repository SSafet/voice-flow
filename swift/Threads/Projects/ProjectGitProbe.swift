import Foundation

/// The two read-only git questions the project registry asks about a folder
/// (06 §3.3). The registry decides what to record; this is the only thing in
/// V1 that starts a process, and it starts only `git remote get-url origin`
/// and `git symbolic-ref --short HEAD`. Creating and removing worktrees,
/// checkpoints, diffs and history belong to work package V4.
protocol ProjectGitProbe {
    func remote(at folder: URL) -> String?
    func defaultBranch(at folder: URL) -> String?
}

/// The real answers, from the system `git`. Neither method throws: a folder
/// that is not a repository, or a git that is not there, simply answers
/// nothing.
struct SystemGitProbe: ProjectGitProbe {
    let git: URL

    init(git: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.git = git
    }

    func remote(at folder: URL) -> String? {
        run(["remote", "get-url", "origin"], at: folder)
    }

    func defaultBranch(at folder: URL) -> String? {
        run(["symbolic-ref", "--short", "HEAD"], at: folder)
    }

    private func run(_ arguments: [String], at folder: URL) -> String? {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = folder
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
