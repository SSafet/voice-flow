import Foundation

/// The working copy a thread gets of its own (06 §3.3 "Own working copy"): where
/// it lives, the branch the contract names, creating it once, pruning what git
/// no longer has, and removing it only when git says the work is safe.
struct GitWorktree: Equatable, Sendable {
    let path: URL
    let branch: String
    let baseCommit: String
    let created: Bool
}

enum WorktreeRemoval: Equatable, Sendable {
    case removed
    case kept(reason: String)
}

struct GitWorktrees: Sendable {
    private let runner: GitRunner

    init(runner: GitRunner) {
        self.runner = runner
    }

    /// `<configRoot>/worktrees/<projectId>/<threadId>` (06 §3.3).
    static func path(configRoot: URL, projectId: String, threadId: String) -> URL {
        configRoot
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent(threadId, isDirectory: true)
    }

    /// The branch is the contract's one rule and nothing else; this package has
    /// no fallback of its own.
    private static func branch(title: String, threadId: String) -> String {
        ContractBranchName.threadBranchName(title: title, threadId: threadId)
    }

    /// Creates the working copy once. Asking again for the same project and
    /// thread creates nothing and answers the same folder and branch.
    func ensure(projectFolder: URL, projectId: String, threadId: String,
                title: String, configRoot: URL) -> Result<GitWorktree, GitFailure> {
        let folder = GitWorktrees.path(configRoot: configRoot, projectId: projectId, threadId: threadId)
        let branch = GitWorktrees.branch(title: title, threadId: threadId)

        if case .success(let existing) = list(projectFolder: projectFolder),
           existing.contains(where: { GitWorktrees.sameLocation($0, folder) }) {
            return head(of: projectFolder).map {
                GitWorktree(path: folder, branch: branch, baseCommit: $0, created: false)
            }
        }

        let parent = folder.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            return .failure(.unavailable(
                "could not create \(parent.path): \(error.localizedDescription)"))
        }

        let base: String
        switch head(of: projectFolder) {
        case .success(let commit):
            base = commit
        case .failure(let failure):
            return .failure(failure)
        }

        switch runner.run(["worktree", "add", "-b", branch, folder.path], in: projectFolder) {
        case .success:
            return .success(GitWorktree(path: folder, branch: branch,
                                        baseCommit: base, created: true))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// `git worktree list --porcelain`, the project folder first as git lists
    /// it. The main worktree is answered in the caller's own spelling, because
    /// git resolves the path it prints and the caller may not have.
    func list(projectFolder: URL) -> Result<[URL], GitFailure> {
        switch runner.run(["worktree", "list", "--porcelain"], in: projectFolder, query: true) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let output):
            var paths: [URL] = []
            for line in output.text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.hasPrefix("worktree ") else { continue }
                let value = String(line.dropFirst("worktree ".count))
                guard !value.isEmpty else { continue }
                var url = URL(fileURLWithPath: value)
                if GitWorktrees.sameLocation(url, projectFolder) {
                    url = projectFolder
                }
                paths.append(url)
            }
            return .success(paths)
        }
    }

    /// Forgets the worktrees whose folders are gone; run for each git project
    /// at launch.
    func prune(projectFolder: URL) -> Result<Void, GitFailure> {
        switch runner.run(["worktree", "prune"], in: projectFolder) {
        case .success:
            return .success(())
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Removes the working copy only when git says the work is safe: nothing is
    /// uncommitted, and the branch is an ancestor of the default branch or has
    /// an upstream with nothing unpushed.
    func remove(projectFolder: URL, worktree: URL, branch: String, defaultBranch: String)
        -> Result<WorktreeRemoval, GitFailure> {
        switch uncommittedChanges(in: worktree) {
        case .success(true):
            return .success(.kept(
                reason: "the working copy at \(worktree.path) has uncommitted changes"))
        case .success(false):
            break
        case .failure(let failure):
            return .failure(failure)
        }

        switch branchIsSafe(projectFolder: projectFolder, worktree: worktree,
                            branch: branch, defaultBranch: defaultBranch) {
        case .success(true):
            break
        case .success(false):
            return .success(.kept(
                reason: "the branch \(branch) is neither merged into \(defaultBranch) nor pushed"))
        case .failure(let failure):
            return .failure(failure)
        }

        switch runner.run(["worktree", "remove", worktree.path], in: projectFolder) {
        case .success:
            return .success(.removed)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    // MARK: Asking git

    private func head(of folder: URL) -> Result<String, GitFailure> {
        switch runner.run(["rev-parse", "HEAD"], in: folder, query: true) {
        case .success(let output):
            return .success(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func uncommittedChanges(in worktree: URL) -> Result<Bool, GitFailure> {
        switch runner.run(["status", "--porcelain"], in: worktree, query: true) {
        case .success(let output):
            return .success(!output.standardOutput.isEmpty)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func branchIsSafe(projectFolder: URL, worktree: URL,
                              branch: String, defaultBranch: String) -> Result<Bool, GitFailure> {
        switch runner.run(["merge-base", "--is-ancestor", branch, defaultBranch],
                          in: projectFolder, query: true) {
        case .success:
            return .success(true)
        case .failure:
            return upstreamHasNothingUnpushed(in: worktree, branch: branch)
        }
    }

    private func upstreamHasNothingUnpushed(in worktree: URL, branch: String)
        -> Result<Bool, GitFailure> {
        let upstream: String
        switch runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name",
                           "\(branch)@{upstream}"], in: worktree, query: true) {
        case .success(let output):
            upstream = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure:
            return .success(false)
        }
        guard !upstream.isEmpty else { return .success(false) }
        switch runner.run(["rev-list", "--count", "\(upstream)..\(branch)"],
                          in: worktree, query: true) {
        case .success(let output):
            let count = Int(output.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return .success(count == 0)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private static func sameLocation(_ first: URL, _ second: URL) -> Bool {
        first.resolvingSymlinksInPath().standardizedFileURL
            == second.resolvingSymlinksInPath().standardizedFileURL
    }
}
