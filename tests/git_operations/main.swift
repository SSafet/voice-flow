import Foundation

// Work package V4, task 4: the git and history operations the files interface
// serves for a Mac-homed project (06 §3.16 "Operations served through the files
// interface", "History"). The answers are the contract's own shapes, so the
// Changes and history views cannot tell a Mac from the Atika machine.

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { return }
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    failures += 1
}
func expectEqual<T: Equatable>(_ actual: T, _ wanted: T, _ message: String) {
    expect(actual == wanted, "\(message) — wanted \(wanted), got \(actual)")
}

let fileManager = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("vf-git-operations-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: scratch) }

@discardableResult
func shell(_ command: String, in folder: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = folder
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func write(_ text: String, to url: URL) {
    try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

func commit(_ message: String, in folder: URL) -> String {
    shell("git add -A && git -c user.email=t@example.com -c user.name=Tester commit -q -m '\(message)'",
          in: folder)
    return shell("git rev-parse HEAD", in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
}

guard case .success(let program) = GitProgramLocator.find(
    environment: ProcessInfo.processInfo.environment.filter {
        $0.key != GitProgramLocator.overrideEnvironmentKey
    }) else {
    FileHandle.standardError.write(Data("FAIL: git was not found on this Mac\n".utf8))
    exit(1)
}
let operations = GitFilesOperations(program: .success(program),
                                    scratchFolder: scratch.appendingPathComponent("thread-scratch",
                                                                                  isDirectory: true))
let withoutGit = GitFilesOperations(
    program: .failure(GitUnavailable(message: "git was not found on this Mac (looked in /usr/bin/git)")),
    scratchFolder: scratch.appendingPathComponent("thread-scratch-2", isDirectory: true))

// ───────────────────────────── git status ─────────────────────────────

let plain = scratch.appendingPathComponent("plain", isDirectory: true)
try fileManager.createDirectory(at: plain, withIntermediateDirectories: true)
guard case .success(let plainStatus) = operations.status(folder: plain) else {
    FileHandle.standardError.write(Data("FAIL: a folder that is not a repository must still answer\n".utf8))
    exit(1)
}
expectEqual(plainStatus.isRepo, false, "a folder that is not a repository says so")
expectEqual(plainStatus.entries, [], "and lists nothing")
expectEqual(plainStatus.ahead, 0, "with nothing ahead")
expectEqual(plainStatus.behind, 0, "and nothing behind")
expectEqual(plainStatus.branch, nil, "and no branch")

expectEqual(operations.unavailableReason, nil, "with git present there is no reason to report")
expect(withoutGit.unavailableReason != nil, "with no git the Changes view is told why")
guard case .success(let noGitStatus) = withoutGit.status(folder: plain) else {
    FileHandle.standardError.write(Data("FAIL: with no git every project still answers\n".utf8))
    exit(1)
}
expectEqual(noGitStatus.isRepo, false, "with no git every project reports that it is not a repository")

let repo = scratch.appendingPathComponent("repo", isDirectory: true)
try fileManager.createDirectory(at: repo, withIntermediateDirectories: true)
shell("git init -q -b main .", in: repo)
write("one\n", to: repo.appendingPathComponent("kept.txt"))
write("two\n", to: repo.appendingPathComponent("edited.txt"))
write("space\n", to: repo.appendingPathComponent("with space.txt"))
write("odd\n", to: repo.appendingPathComponent("odd\nname.txt"))
let firstCommit = commit("first", in: repo)

write("one\nadded\n", to: repo.appendingPathComponent("staged.txt"))
shell("git add staged.txt", in: repo)
write("two\nchanged\n", to: repo.appendingPathComponent("edited.txt"))
write("brand new\n", to: repo.appendingPathComponent("untracked.txt"))

guard case .success(let status) = operations.status(folder: repo) else {
    FileHandle.standardError.write(Data("FAIL: the status of a repository could not be read\n".utf8))
    exit(1)
}
expectEqual(status.isRepo, true, "a repository says it is one")
expectEqual(status.branch, "main", "and names its branch")
expectEqual(status.upstream, nil, "with no remote there is no upstream")
func entry(_ path: String) -> TPGitStatusEntry? { status.entries.first { $0.path == path } }
expectEqual(entry("staged.txt")?.index, "A", "a staged new file is added in the staging area")
expectEqual(entry("staged.txt")?.worktree, ".", "and unchanged since in the working copy")
expectEqual(entry("edited.txt")?.index, ".", "an edited tracked file is unchanged in the staging area")
expectEqual(entry("edited.txt")?.worktree, "M", "and modified in the working copy")
expectEqual(entry("untracked.txt")?.index, "?", "an untracked file is reported as untracked")
expectEqual(entry("untracked.txt")?.worktree, "?", "on both sides")
expect(entry("kept.txt") == nil, "an unchanged file is not listed")
expect(entry("with space.txt") == nil, "nor is an unchanged file whose name has a space")

write("changed\n", to: repo.appendingPathComponent("with space.txt"))
write("changed\n", to: repo.appendingPathComponent("odd\nname.txt"))
guard case .success(let oddStatus) = operations.status(folder: repo) else {
    FileHandle.standardError.write(Data("FAIL: the status with odd names could not be read\n".utf8))
    exit(1)
}
expect(oddStatus.entries.contains { $0.path == "with space.txt" },
       "a path with a space is one entry: \(oddStatus.entries.map(\.path))")
expect(oddStatus.entries.contains { $0.path == "odd\nname.txt" },
       "a path with a line break is one entry: \(oddStatus.entries.map(\.path))")

let origin = scratch.appendingPathComponent("origin.git", isDirectory: true)
shell("git init -q --bare \(origin.path)", in: scratch)
shell("git remote add origin \(origin.path) && git push -q -u origin main", in: repo)
write("later\n", to: repo.appendingPathComponent("later.txt"))
_ = commit("second", in: repo)
guard case .success(let trackedStatus) = operations.status(folder: repo) else {
    FileHandle.standardError.write(Data("FAIL: the tracked status could not be read\n".utf8))
    exit(1)
}
expectEqual(trackedStatus.upstream, "origin/main", "the upstream is named as git names it")
expectEqual(trackedStatus.ahead, 1, "one commit is ahead of it")
expectEqual(trackedStatus.behind, 0, "and none behind")

let detached = scratch.appendingPathComponent("detached", isDirectory: true)
shell("git clone -q \(repo.path) \(detached.path)", in: scratch)
shell("git checkout -q --detach HEAD", in: detached)
guard case .success(let detachedStatus) = operations.status(folder: detached) else {
    FileHandle.standardError.write(Data("FAIL: the detached status could not be read\n".utf8))
    exit(1)
}
expectEqual(detachedStatus.isRepo, true, "a detached head is still a repository")
expectEqual(detachedStatus.branch, nil, "on no branch")
expectEqual(detachedStatus.upstream, nil, "and with no upstream")

// ───────────────────────────── git init ─────────────────────────────

let fresh = scratch.appendingPathComponent("fresh", isDirectory: true)
try fileManager.createDirectory(at: fresh, withIntermediateDirectories: true)
guard case .success(let initialised) = operations.initRepository(folder: fresh) else {
    FileHandle.standardError.write(Data("FAIL: git init did not answer\n".utf8))
    exit(1)
}
expectEqual(initialised.isRepo, true, "the folder is a repository afterwards")
expect(fileManager.fileExists(atPath: fresh.appendingPathComponent(".git").path),
       "and git made it one")
let gitDirectory = shell("git rev-parse --absolute-git-dir", in: fresh)
guard case .success(let initialisedAgain) = operations.initRepository(folder: fresh) else {
    FileHandle.standardError.write(Data("FAIL: git init on a repository must not be an error\n".utf8))
    exit(1)
}
expectEqual(initialisedAgain.isRepo, true, "asking again answers the same")
expectEqual(shell("git rev-parse --absolute-git-dir", in: fresh), gitDirectory,
            "and did not make a second repository inside the first")

// ───────────────────────────── git diff ─────────────────────────────

func diffText(from: String?, to: String?, path: String?) -> String? {
    switch operations.diff(folder: repo, from: from, to: to, path: path) {
    case .success(let data): return String(decoding: data, as: UTF8.self)
    case .failure(let error):
        expect(false, "the diff failed: \(error.code) \(error.message)")
        return nil
    }
}

write("only in the working copy\n", to: repo.appendingPathComponent("never-added.txt"))
write("two\nchanged again\n", to: repo.appendingPathComponent("edited.txt"))
guard let workingDiff = diffText(from: nil, to: nil, path: nil) else { exit(1) }
expect(workingDiff.contains("never-added.txt"),
       "a diff against the working copy shows a file that was never added, which plain git diff would miss")
expect(workingDiff.contains("changed again"), "and the edits to a tracked file")
let refsBeforeDiff = shell("git for-each-ref --format=%(refname) refs/", in: repo)

guard let pathDiff = diffText(from: nil, to: nil, path: "edited.txt") else { exit(1) }
expect(pathDiff.contains("edited.txt"), "a diff limited to one path shows that path")
expect(!pathDiff.contains("never-added.txt"), "and nothing else")

shell("git update-ref refs/atika/checkpoints/th_1/tu_1-before \(firstCommit)", in: repo)
guard let checkpointDiff = diffText(from: "refs/atika/checkpoints/th_1/tu_1-before", to: nil, path: nil)
else { exit(1) }
expect(checkpointDiff.contains("later.txt"),
       "a checkpoint reference may be the left-hand side of a diff")
expectEqual(shell("git for-each-ref --format=%(refname) refs/", in: repo), refsBeforeDiff,
            "and asking for diffs wrote no reference of its own")

for refused in ["main", "HEAD~1", "refs/heads/main", "--upload-pack=/bin/sh", "@{upstream}"] {
    switch operations.diff(folder: repo, from: refused, to: nil, path: nil) {
    case .success:
        expect(false, "\"\(refused)\" is not a revision a client may name")
    case .failure(let error):
        expectEqual(error.code, "invalid_params", "\"\(refused)\" is refused as a bad parameter")
    }
}

switch operations.diff(folder: plain, from: nil, to: nil, path: nil) {
case .success:
    expect(false, "a folder that is not a repository has no diff")
case .failure(let error):
    expectEqual(error.code, "files.no_history",
                "and says so with the contract's code for a root that keeps no history")
}

// ───────────────────────────── history ─────────────────────────────

let documents = scratch.appendingPathComponent("documents", isDirectory: true)
try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
shell("git init -q -b main .", in: documents)
write("first line\n", to: documents.appendingPathComponent("doc/old.md"))
let docFirst = commit("wrote the note", in: documents)
shell("git mv doc/old.md doc/new.md", in: documents)
let docSecond = commit("renamed the note", in: documents)
write("first line\nsecond line\n", to: documents.appendingPathComponent("doc/new.md"))
let docThird = commit("added a line", in: documents)

guard case .success(let history) = operations.history(folder: documents, path: "doc/new.md") else {
    FileHandle.standardError.write(Data("FAIL: the history could not be read\n".utf8))
    exit(1)
}
expectEqual(history.source, TPHistorySource.git, "a git repository's history comes from git")
expectEqual(history.entries.count, 3,
            "the rename is followed, so all three commits are there: \(history.entries.map(\.version.id))")
expectEqual(history.entries.map(\.version.id), [docThird, docSecond, docFirst],
            "newest first")
expect(history.entries.allSatisfy { $0.version.kind == .commit },
       "history lists commits, never checkpoints — the contract refuses that")
expectEqual(history.entries.first?.subject, "added a line", "the subject is the commit's subject")
expectEqual(history.entries.first?.author, "Tester", "the author is the commit's author")
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime]
for entry in history.entries {
    expect(entry.at.hasSuffix("Z"), "a time is written in UTC and ends in Z: \(entry.at)")
    expect(formatter.date(from: entry.at) != nil, "and parses as ISO 8601: \(entry.at)")
}

guard case .success(let emptyHistory) = operations.history(folder: documents, path: "doc/never.md") else {
    FileHandle.standardError.write(Data("FAIL: a path with no commits must still answer\n".utf8))
    exit(1)
}
expectEqual(emptyHistory.source, TPHistorySource.git, "the root still keeps history")
expectEqual(emptyHistory.entries, [], "this path just has none")

guard case .success(let noHistory) = operations.history(folder: plain, path: "anything.txt") else {
    FileHandle.standardError.write(Data("FAIL: a folder that is not a repository must still answer\n".utf8))
    exit(1)
}
expectEqual(noHistory.source, TPHistorySource.none,
            "a folder that is not a repository has no history, so the view says so in words")
expectEqual(noHistory.entries, [], "and lists nothing")

guard case .success(let noGitHistory) = withoutGit.history(folder: documents, path: "doc/new.md") else {
    FileHandle.standardError.write(Data("FAIL: with no git the history must still answer\n".utf8))
    exit(1)
}
expectEqual(noGitHistory.source, TPHistorySource.none, "with no git there is no history either")

// ───────────────────────────── reading a version ─────────────────────────────

func readVersion(_ folder: URL, _ path: String, _ version: TPVersionRef) -> Result<Data, GitOperationError> {
    operations.historyRead(folder: folder, path: path, version: version)
}

switch readVersion(documents, "doc/new.md", TPVersionRef(id: docSecond, kind: .commit)) {
case .success(let data):
    expectEqual(String(decoding: data, as: UTF8.self), "first line\n",
                "the file comes back as it was in that commit")
case .failure(let error):
    expect(false, "reading a version failed: \(error.code) \(error.message)")
}

switch readVersion(documents, "doc/new.md", TPVersionRef(id: docFirst, kind: .commit)) {
case .success:
    expect(false, "the file did not exist under that name in the first commit")
case .failure(let error):
    expectEqual(error.code, "files.not_found", "so the answer is that it is not there")
}

shell("git update-ref refs/atika/checkpoints/th_2/tu_2-after \(docThird)", in: documents)
switch readVersion(documents, "doc/new.md",
                   TPVersionRef(id: "refs/atika/checkpoints/th_2/tu_2-after", kind: .checkpoint)) {
case .success(let data):
    expectEqual(String(decoding: data, as: UTF8.self), "first line\nsecond line\n",
                "a checkpoint reference can be read, which is what the contract says it is for")
case .failure(let error):
    expect(false, "reading a checkpoint failed: \(error.code) \(error.message)")
}

switch readVersion(documents, "doc/new.md", TPVersionRef(id: "refs/heads/main", kind: .checkpoint)) {
case .success:
    expect(false, "a reference that is not a checkpoint is not read as one")
case .failure(let error):
    expectEqual(error.code, "invalid_params", "it is refused as a bad parameter")
}

switch readVersion(documents, "doc/new.md", TPVersionRef(id: "snap_1", kind: .snapshot)) {
case .success:
    expect(false, "snapshots exist only on the Atika machine")
case .failure(let error):
    expectEqual(error.code, "not_supported", "so a Mac refuses one by name")
}

if failures > 0 {
    FileHandle.standardError.write(Data("git_operations: \(failures) failure(s)\n".utf8))
    exit(1)
}
print("git_operations: status, diff, init, history and reading a version, in the contract's own shapes")
