import Foundation

/// The four git and history operations the files interface serves for a
/// Mac-homed project (06 §3.16 "Operations served through the files interface",
/// "History"). `folder` is the root's absolute folder and `path` is relative to
/// it; L4 has already confined both. The answers are the contract's own shapes,
/// so the Changes and history views cannot tell a Mac from the Atika machine.
struct GitFilesOperations: Sendable {
    private let program: Result<GitProgram, GitUnavailable>
    private let scratchFolder: URL
    private let timeout: Double

    init(program: Result<GitProgram, GitUnavailable>, scratchFolder: URL,
         timeout: Double = GitRunner.defaultTimeout) {
        self.program = program
        self.scratchFolder = scratchFolder
        self.timeout = timeout
    }

    /// The message of `GitUnavailable` when there is no git program, and `nil`
    /// otherwise; native Settings shows it beside the runtimes. The files
    /// contract has no field for it, so it is read from here.
    var unavailableReason: String? {
        switch program {
        case .success: return nil
        case .failure(let unavailable): return unavailable.message
        }
    }

    // MARK: status

    /// A folder that is not a repository, and any folder at all when there is
    /// no git program, is answered as not a repository rather than as an error.
    func status(folder: URL) -> Result<TPFilesGitStatusResult, GitOperationError> {
        guard let runner = runner() else { return .success(emptyStatus) }
        switch runner.run(["status", "--porcelain=v2", "--branch", "-z"],
                          in: folder, query: true) {
        case .success(let output):
            return .success(parseStatus(output))
        case .failure:
            return .success(emptyStatus)
        }
    }

    private var emptyStatus: TPFilesGitStatusResult {
        TPFilesGitStatusResult(ahead: 0, behind: 0, branch: nil, entries: [],
                               isRepo: false, upstream: nil)
    }

    private func parseStatus(_ output: GitOutput) -> TPFilesGitStatusResult {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var entries: [TPGitStatusEntry] = []

        let tokens = nulSeparated(output.standardOutput)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token.hasPrefix("# branch.head ") {
                let value = String(token.dropFirst("# branch.head ".count))
                if value != "(detached)" && !value.isEmpty { branch = value }
            } else if token.hasPrefix("# branch.upstream ") {
                upstream = String(token.dropFirst("# branch.upstream ".count))
            } else if token.hasPrefix("# branch.ab ") {
                let parts = token.split(separator: " ")
                if parts.count == 4 {
                    ahead = Int(parts[2].dropFirst()) ?? 0
                    behind = Int(parts[3].dropFirst()) ?? 0
                }
            } else if token.hasPrefix("1 ") {
                if let entry = trackedEntry(token, fieldsBeforePath: 8) { entries.append(entry) }
            } else if token.hasPrefix("2 ") {
                if let entry = trackedEntry(token, fieldsBeforePath: 9) { entries.append(entry) }
                // A rename record's source path follows as its own NUL token and
                // is not listed separately.
                if index < tokens.count { index += 1 }
            } else if token.hasPrefix("u ") {
                if let entry = trackedEntry(token, fieldsBeforePath: 10) { entries.append(entry) }
            } else if token.hasPrefix("? ") {
                entries.append(TPGitStatusEntry(index: "?", path: String(token.dropFirst(2)),
                                                 worktree: "?"))
            }
        }

        return TPFilesGitStatusResult(ahead: ahead, behind: behind, branch: branch,
                                      entries: entries, isRepo: true, upstream: upstream)
    }

    /// One `1`, `2` or `u` record: the two status characters are the second
    /// field, and the path is everything after the fixed fields, so a path with
    /// a space or a line break stays one path.
    private func trackedEntry(_ token: String, fieldsBeforePath: Int) -> TPGitStatusEntry? {
        let fields = token.split(separator: " ", maxSplits: fieldsBeforePath,
                                 omittingEmptySubsequences: false)
        guard fields.count == fieldsBeforePath + 1 else { return nil }
        let xy = fields[1]
        guard xy.count == 2 else { return nil }
        return TPGitStatusEntry(index: String(xy.first!), path: String(fields[fieldsBeforePath]),
                                worktree: String(xy.last!))
    }

    // MARK: diff

    /// Unified diff text as bytes. `from` absent means `HEAD`, and the empty
    /// tree when the repository has no commit; `to` absent means the working
    /// copy, compared against a throw-away tree so a file that was never added
    /// appears. Both client-named revisions pass through `GitRevision.accept`
    /// before anything runs; `path` is passed as a path, never as an option.
    func diff(folder: URL, from: String?, to: String?, path: String?)
        -> Result<Data, GitOperationError> {
        guard let runner = runner() else {
            return .failure(noHistory("there is no git program: \(unavailableReason ?? "")"))
        }

        var fromValue: String?
        if let from {
            switch GitRevision.accept(from, folder: folder, runner: runner) {
            case .success(let value): fromValue = value
            case .failure(let error): return .failure(error)
            }
        }
        var toValue: String?
        if let to {
            switch GitRevision.accept(to, folder: folder, runner: runner) {
            case .success(let value): toValue = value
            case .failure(let error): return .failure(error)
            }
        }

        let checkpoints = GitCheckpoints(runner: runner, scratchFolder: scratchFolder)
        guard checkpoints.isInsideWorkTree(folder: folder) else {
            return .failure(noHistory("the folder \(folder.path) is not a git repository"))
        }

        let left: String
        if let fromValue {
            left = fromValue
        } else {
            switch headCommit(folder: folder, runner: runner) {
            case .success(let head) where !head.isEmpty:
                left = head
            default:
                switch emptyTree(folder: folder, runner: runner) {
                case .success(let tree): left = tree
                case .failure(let error): return .failure(error)
                }
            }
        }

        let right: String
        if let toValue {
            right = toValue
        } else {
            switch checkpoints.workingCopyTree(folder: folder, threadId: "files-operations",
                                               turnId: UUID().uuidString) {
            case .success(let tree): right = tree
            case .failure(let warning): return .failure(unsupported(warning.message))
            }
        }

        switch runner.run(["diff", "--no-color"], in: folder, query: true,
                          clientValues: [left, right], paths: path.map { [$0] } ?? []) {
        case .success(let output):
            return .success(output.standardOutput)
        case .failure(let failure):
            return .failure(unsupported(message(of: failure)))
        }
    }

    private func headCommit(folder: URL, runner: GitRunner) -> Result<String, GitFailure> {
        runner.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: folder, query: true)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The empty tree of this repository's own object format, built with a
    /// throw-away index so nothing depends on a hard-coded hash.
    private func emptyTree(folder: URL, runner: GitRunner) -> Result<String, GitOperationError> {
        let index = scratchFolder.appendingPathComponent("files-operations-empty-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: index.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            return .failure(unsupported(error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: index) }
        switch runner.run(["write-tree"], in: folder, indexFile: index) {
        case .success(let output):
            let tree = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tree.isEmpty else {
                return .failure(unsupported("git write-tree printed no tree"))
            }
            return .success(tree)
        case .failure(let failure):
            return .failure(unsupported(message(of: failure)))
        }
    }

    // MARK: init

    /// VoiceFlow itself never calls this; only a person's Changes view does. It
    /// creates nothing inside a repository that already exists.
    func initRepository(folder: URL) -> Result<TPFilesGitInitResult, GitOperationError> {
        guard let runner = runner() else {
            return .failure(unsupported(unavailableReason ?? "there is no git program"))
        }
        switch runner.run(["init"], in: folder) {
        case .success:
            return .success(TPFilesGitInitResult(isRepo: true))
        case .failure(let failure):
            return .failure(unsupported(message(of: failure)))
        }
    }

    // MARK: history

    /// A repository's history comes from git even when the one path has no
    /// commits; a folder that is not a repository, or a Mac with no git, says
    /// its history is none. It never answers a checkpoint version.
    func history(folder: URL, path: String) -> Result<TPFilesHistoryResult, GitOperationError> {
        guard let runner = runner() else {
            return .success(TPFilesHistoryResult(entries: [], source: .none))
        }
        let checkpoints = GitCheckpoints(runner: runner, scratchFolder: scratchFolder)
        guard checkpoints.isInsideWorkTree(folder: folder) else {
            return .success(TPFilesHistoryResult(entries: [], source: .none))
        }
        switch runner.run(["log", "-z", "--follow",
                           "--date=format-local:%Y-%m-%dT%H:%M:%SZ",
                           "--format=%H%x1f%an%x1f%ad%x1f%s"],
                          in: folder, query: true, paths: [path], environment: ["TZ": "UTC"]) {
        case .success(let output):
            return .success(TPFilesHistoryResult(entries: parseHistory(output), source: .git))
        case .failure:
            // A repository with no commit yet has no log to read; it is still a
            // repository, so the view is told the source is git.
            return .success(TPFilesHistoryResult(entries: [], source: .git))
        }
    }

    private func parseHistory(_ output: GitOutput) -> [TPHistoryEntry] {
        var entries: [TPHistoryEntry] = []
        for record in nulSeparated(output.standardOutput) where !record.isEmpty {
            let fields = record.split(separator: "\u{1f}", maxSplits: 3,
                                      omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty else { continue }
            entries.append(TPHistoryEntry(
                at: String(fields[2]),
                author: String(fields[1]),
                size: nil,
                subject: String(fields[3]),
                version: TPVersionRef(id: String(fields[0]), kind: .commit)))
        }
        return entries
    }

    // MARK: reading a version

    /// `git show <id>:<path>` for a commit id `isCommitId` accepts and for a
    /// checkpoint reference `CheckpointRefs.isCheckpointRef` accepts. A
    /// snapshot is refused by name; a path that is not in the version is the
    /// contract's `files.not_found`.
    func historyRead(folder: URL, path: String, version: TPVersionRef)
        -> Result<Data, GitOperationError> {
        switch version.kind {
        case .snapshot:
            return .failure(GitOperationError(
                code: "not_supported",
                message: "snapshots exist only on the Atika machine, so a Mac cannot read one"))
        case .commit:
            guard GitRevision.isCommitId(version.id) else {
                return .failure(invalidParams(version.id, kind: "commit"))
            }
        case .checkpoint:
            guard CheckpointRefs.isCheckpointRef(version.id) else {
                return .failure(invalidParams(version.id, kind: "checkpoint"))
            }
        }

        guard let runner = runner() else {
            return .failure(unsupported(unavailableReason ?? "there is no git program"))
        }
        switch runner.run(["show"], in: folder, query: true,
                          clientValues: ["\(version.id):\(path)"]) {
        case .success(let output):
            return .success(output.standardOutput)
        case .failure(let failure):
            let text = message(of: failure)
            if text.contains("does not exist in") || text.contains("exists on disk, but not in") {
                return .failure(GitOperationError(code: "files.not_found", message: text))
            }
            return .failure(invalidParams(version.id, kind: version.kind.rawValue))
        }
    }

    // MARK: Shared

    private func runner() -> GitRunner? {
        switch program {
        case .success(let git): return GitRunner(program: git, timeout: timeout)
        case .failure: return nil
        }
    }

    private func noHistory(_ message: String) -> GitOperationError {
        GitOperationError(code: "files.no_history", message: message)
    }

    private func unsupported(_ message: String) -> GitOperationError {
        GitOperationError(code: "not_supported", message: message)
    }

    private func invalidParams(_ id: String, kind: String) -> GitOperationError {
        GitOperationError(code: "invalid_params",
                          message: "\(id) is not a \(kind) version this project can read")
    }

    private func message(of failure: GitFailure) -> String {
        switch failure {
        case .unavailable(let message): return message
        case .timedOut(let seconds): return "git did not answer within \(seconds) seconds"
        case .failed(_, let message): return message
        }
    }

    /// Splits bytes on their zero values; the terminator is dropped rather than
    /// answered as an empty trailing token.
    private func nulSeparated(_ data: Data) -> [String] {
        var tokens: [String] = []
        var current: [UInt8] = []
        for byte in data {
            if byte == 0 {
                tokens.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            tokens.append(String(decoding: current, as: UTF8.self))
        }
        return tokens
    }
}
