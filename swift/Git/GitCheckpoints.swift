import Foundation

/// A checkpoint that was taken: an ordinary commit under one of this project's
/// hidden references, and the tree that commit carries.
struct Checkpoint: Equatable, Sendable {
    let ref: String
    let commit: String
    let tree: String
}

/// Why a checkpoint could not be taken, in git's own words wherever git said
/// something. `record` never refuses in a sentence of its own.
struct CheckpointWarning: Error, Equatable {
    let message: String
}

/// What happened to one file between two trees. This is this package's own
/// shape; only `path`, `added` and `removed` travel on the turn record.
enum ChangeKind: String, Equatable, Sendable {
    case added
    case modified
    case deleted
    case renamed
}

struct ChangedFileDetail: Equatable, Sendable {
    let path: String
    let kind: ChangeKind
    let added: Int
    let removed: Int
    let isBinary: Bool
    let renamedFrom: String?
}

struct ChangedFileSet: Equatable, Sendable {
    /// Every change, in path order.
    let files: [ChangedFileDetail]

    var total: Int { files.count }

    /// The first `GitCheckpoints.changedFilesMax`, in the same order, in the
    /// contract's own shape. A binary file carries no line counts.
    func turnChangedFiles() -> [TPChangedFile] {
        files.prefix(GitCheckpoints.changedFilesMax).map {
            TPChangedFile(added: $0.added, path: $0.path, removed: $0.removed)
        }
    }
}

/// The temporary-index technique (06 §3.16 "Checkpoints"): a `GIT_INDEX_FILE`
/// under the thread's scratch folder, `read-tree`, `add -A`, `write-tree`,
/// `commit-tree`, `update-ref`. The repository's own index, HEAD, branches and
/// stash are never written.
struct GitCheckpoints: Sendable {
    static let changedFilesMax = 300
    static let authorName = "VoiceFlow"
    static let authorEmail = "voiceflow@localhost"

    private let runner: GitRunner
    private let scratchFolder: URL

    init(runner: GitRunner, scratchFolder: URL) {
        self.runner = runner
        self.scratchFolder = scratchFolder
    }

    // MARK: Recording

    func record(folder: URL, threadId: String, turnId: String, phase: CheckpointPhase)
        -> Result<Checkpoint, CheckpointWarning> {
        let ref = CheckpointRefs.ref(threadId: threadId, turnId: turnId, phase: phase)
        let index = indexFile(threadId: threadId, turnId: turnId, phase: phase)
        switch prepareIndex(index) {
        case .failure(let warning):
            return .failure(warning)
        case .success:
            break
        }
        defer { try? FileManager.default.removeItem(at: index) }

        switch buildTree(folder: folder, index: index) {
        case .failure(let warning):
            return .failure(warning)
        case .success(let tree):
            switch commitTree(tree: tree, folder: folder, index: index,
                              threadId: threadId, turnId: turnId, phase: phase) {
            case .failure(let warning):
                return .failure(warning)
            case .success(let commit):
                switch step(["update-ref", ref, commit], in: folder, index: index) {
                case .failure(let warning):
                    return .failure(warning)
                case .success:
                    return .success(Checkpoint(ref: ref, commit: commit, tree: tree))
                }
            }
        }
    }

    /// Steps 1 to 3 and `write-tree`: a throw-away tree of the working copy,
    /// with no reference written. A diff against the working copy is made
    /// against it, which is why a file that was never added appears in one.
    func workingCopyTree(folder: URL, threadId: String, turnId: String)
        -> Result<String, CheckpointWarning> {
        let index = scratchFolder.appendingPathComponent(threadId, isDirectory: true)
            .appendingPathComponent("index-\(turnId)-tree")
        switch prepareIndex(index) {
        case .failure(let warning):
            return .failure(warning)
        case .success:
            break
        }
        defer { try? FileManager.default.removeItem(at: index) }
        return buildTree(folder: folder, index: index)
    }

    // MARK: Changed files

    func changedFiles(folder: URL, from: String, to: String)
        -> Result<ChangedFileSet, CheckpointWarning> {
        let numstat: GitOutput
        switch runner.run(["diff", "--numstat", "-z", "-M"], in: folder, query: true,
                          clientValues: [from, to]) {
        case .success(let output):
            numstat = output
        case .failure(let failure):
            return .failure(warning(failure))
        }

        let nameStatus: GitOutput
        switch runner.run(["diff", "--name-status", "-z", "-M"], in: folder, query: true,
                          clientValues: [from, to]) {
        case .success(let output):
            nameStatus = output
        case .failure(let failure):
            return .failure(warning(failure))
        }

        let counts = parseNumstat(numstat)
        let details = parseNameStatus(nameStatus, counts: counts)
        return .success(ChangedFileSet(files: details.sorted { $0.path < $1.path }))
    }

    // MARK: Git state at turn end

    func state(folder: URL) -> Result<TPTurnGit, CheckpointWarning> {
        guard isInsideWorkTree(folder: folder) else {
            return .failure(CheckpointWarning(
                message: "the folder \(folder.path) is not inside a git work tree"))
        }

        let branch: String
        switch runner.run(["symbolic-ref", "--short", "HEAD"], in: folder, query: true) {
        case .success(let output):
            branch = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure:
            branch = "(detached)"
        }

        let headCommit: String
        switch runner.run(["rev-parse", "HEAD"], in: folder, query: true) {
        case .success(let output):
            headCommit = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure:
            headCommit = ""
        }

        let dirty: Bool
        switch runner.run(["status", "--porcelain"], in: folder, query: true) {
        case .success(let output):
            dirty = !output.standardOutput.isEmpty
        case .failure(let failure):
            return .failure(warning(failure))
        }

        var upstreamRef: String?
        switch runner.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
                          in: folder, query: true) {
        case .success(let output):
            let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            upstreamRef = value.isEmpty ? nil : value
        case .failure:
            upstreamRef = nil
        }

        var unpushedCount: Int?
        var pushed: Bool?
        if let upstreamRef {
            switch runner.run(["rev-list", "--count", "\(upstreamRef)..HEAD"],
                              in: folder, query: true) {
            case .success(let output):
                let count = Int(output.text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                unpushedCount = count
                pushed = count == 0
            case .failure(let failure):
                return .failure(warning(failure))
            }
        }

        return .success(TPTurnGit(branch: branch, dirty: dirty, headCommit: headCommit,
                                  pushed: pushed, unpushedCount: unpushedCount,
                                  upstreamRef: upstreamRef))
    }

    // MARK: References

    func deleteThreadCheckpoints(folder: URL, threadId: String) -> Result<Int, CheckpointWarning> {
        let listed: GitOutput
        switch step(["for-each-ref", "--format=%(refname)", CheckpointRefs.threadPrefix(threadId)],
                    in: folder, index: nil, query: true) {
        case .success(let output):
            listed = output
        case .failure(let warning):
            return .failure(warning)
        }

        let refs = listed.text.split(separator: "\n").map(String.init)
            .filter { !$0.isEmpty }
        var removed = 0
        for ref in refs {
            switch step(["update-ref", "-d", ref], in: folder, index: nil) {
            case .success:
                removed += 1
            case .failure(let warning):
                return .failure(warning)
            }
        }
        return .success(removed)
    }

    func isInsideWorkTree(folder: URL) -> Bool {
        switch runner.run(["rev-parse", "--is-inside-work-tree"], in: folder, query: true) {
        case .success(let output):
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        case .failure:
            return false
        }
    }

    // MARK: The temporary-index steps

    /// The index a checkpoint attempt is built in. It lives under the thread's
    /// scratch folder so the repository's own `.git/index` is never named.
    private func indexFile(threadId: String, turnId: String, phase: CheckpointPhase) -> URL {
        scratchFolder.appendingPathComponent(threadId, isDirectory: true)
            .appendingPathComponent("index-\(turnId)-\(phase.rawValue)")
    }

    private func prepareIndex(_ index: URL) -> Result<Void, CheckpointWarning> {
        do {
            try FileManager.default.createDirectory(at: index.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            return .success(())
        } catch {
            return .failure(CheckpointWarning(message: error.localizedDescription))
        }
    }

    /// Steps 1 to 3 and `write-tree`: `read-tree HEAD` when there is a HEAD,
    /// `add -A`, `write-tree`. `HEAD` is never given to git as a value the
    /// caller named; the caller's index is never touched.
    private func buildTree(folder: URL, index: URL) -> Result<String, CheckpointWarning> {
        var parent: String?
        switch step(["rev-parse", "--verify", "--quiet", "HEAD"], in: folder, index: index) {
        case .success(let output):
            let value = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            parent = value.isEmpty ? nil : value
        case .failure:
            parent = nil
        }

        if parent != nil {
            switch step(["read-tree", "HEAD"], in: folder, index: index) {
            case .failure(let warning):
                return .failure(warning)
            case .success:
                break
            }
        }

        switch step(["add", "-A"], in: folder, index: index) {
        case .failure(let warning):
            return .failure(warning)
        case .success:
            break
        }

        switch step(["write-tree"], in: folder, index: index) {
        case .success(let output):
            let tree = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tree.isEmpty else {
                return .failure(CheckpointWarning(message: "git write-tree printed no tree"))
            }
            return .success(tree)
        case .failure(let warning):
            return .failure(warning)
        }
    }

    private func commitTree(tree: String, folder: URL, index: URL,
                            threadId: String, turnId: String, phase: CheckpointPhase)
        -> Result<String, CheckpointWarning> {
        var arguments = ["commit-tree", tree]
        if hasHead(folder: folder, index: index) {
            arguments.append(contentsOf: ["-p", "HEAD"])
        }
        arguments.append(contentsOf: ["-m", "checkpoint \(threadId)/\(turnId) \(phase.rawValue)"])
        switch step(arguments, in: folder, index: index, environment: authorization()) {
        case .success(let output):
            let commit = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commit.isEmpty else {
                return .failure(CheckpointWarning(message: "git commit-tree printed no commit"))
            }
            return .success(commit)
        case .failure(let warning):
            return .failure(warning)
        }
    }

    private func hasHead(folder: URL, index: URL) -> Bool {
        switch step(["rev-parse", "--verify", "--quiet", "HEAD"], in: folder, index: index) {
        case .success(let output):
            return !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .failure:
            return false
        }
    }

    /// A fixed identity in the environment, so a Mac with no git identity
    /// configured still gets checkpoints.
    private func authorization() -> [String: String] {
        [
            "GIT_AUTHOR_NAME": GitCheckpoints.authorName,
            "GIT_AUTHOR_EMAIL": GitCheckpoints.authorEmail,
            "GIT_COMMITTER_NAME": GitCheckpoints.authorName,
            "GIT_COMMITTER_EMAIL": GitCheckpoints.authorEmail,
        ]
    }

    private func step(_ arguments: [String], in folder: URL, index: URL?,
                      query: Bool = false,
                      environment: [String: String] = [:]) -> Result<GitOutput, CheckpointWarning> {
        switch runner.run(arguments, in: folder, query: query, indexFile: index,
                          environment: environment) {
        case .success(let output):
            return .success(output)
        case .failure(let failure):
            return .failure(warning(failure))
        }
    }

    private func warning(_ failure: GitFailure) -> CheckpointWarning {
        switch failure {
        case .unavailable(let message):
            return CheckpointWarning(message: message)
        case .timedOut(let seconds):
            return CheckpointWarning(message: "git did not answer within \(seconds) seconds")
        case .failed(_, let message):
            return CheckpointWarning(message: message)
        }
    }

    // MARK: Parsing git's `-z` output

    private struct Counts {
        let added: Int
        let removed: Int
        let isBinary: Bool
    }

    /// `git diff --numstat -z -M` output: a plain entry is `added\tremoved\t`
    /// then the path then a NUL; a rename entry is `added\tremoved\t` then a
    /// NUL, the old path, a NUL, the new path and a NUL. A path may carry a
    /// space or a line break and is never split on either.
    private func parseNumstat(_ output: GitOutput) -> [String: Counts] {
        let tokens = nulSeparated(output.standardOutput)
        var counts: [String: Counts] = [:]
        var index = 0
        while index < tokens.count {
            let fields = tokens[index].split(separator: "\t", maxSplits: 2,
                                             omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                index += 1
                continue
            }
            let addedText = String(fields[0])
            let removedText = String(fields[1])
            let remainder = String(fields[2])
            let isBinary = addedText == "-" || removedText == "-"
            let added = isBinary ? 0 : (Int(addedText) ?? 0)
            let removed = isBinary ? 0 : (Int(removedText) ?? 0)
            let path: String
            if remainder.isEmpty {
                guard index + 2 < tokens.count else { break }
                path = tokens[index + 2]
                index += 3
            } else {
                path = remainder
                index += 1
            }
            counts[path] = Counts(added: added, removed: removed, isBinary: isBinary)
        }
        return counts
    }

    /// `git diff --name-status -z -M` output: `status` then a NUL then the
    /// path then a NUL, except for a rename where the old path and the new
    /// path follow.
    private func parseNameStatus(_ output: GitOutput,
                                 counts: [String: Counts]) -> [ChangedFileDetail] {
        let tokens = nulSeparated(output.standardOutput)
        var details: [ChangedFileDetail] = []
        var index = 0
        while index < tokens.count {
            let status = tokens[index]
            index += 1
            guard index < tokens.count else { break }
            let first = tokens[index]
            index += 1
            let path: String
            let renamedFrom: String?
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard index < tokens.count else { break }
                path = tokens[index]
                index += 1
                renamedFrom = first
            } else {
                path = first
                renamedFrom = nil
            }
            let count = counts[path] ?? Counts(added: 0, removed: 0, isBinary: false)
            details.append(ChangedFileDetail(path: path, kind: kind(of: status),
                                             added: count.added, removed: count.removed,
                                             isBinary: count.isBinary, renamedFrom: renamedFrom))
        }
        return details
    }

    private func kind(of status: String) -> ChangeKind {
        switch status.first {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .added
        default: return .modified
        }
    }

    /// Splits bytes on their zero values; the terminator is dropped rather
    /// than answered as an empty trailing token.
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
