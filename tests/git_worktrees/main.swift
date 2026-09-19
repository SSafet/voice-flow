import Foundation

// Work package V4, task 3: the git worktree a thread with its own working copy
// works in (06 §3.3 "Own working copy", §3.16). The branch is named by the
// contract's one rule and by nothing else, creating one twice creates nothing
// the second time, and a working copy is only removed when git says it is safe.

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
    .appendingPathComponent("vf-git-worktrees-\(UUID().uuidString)", isDirectory: true)
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
    try? Data(text.utf8).write(to: url)
}

func newRepository(_ name: String) -> URL {
    let folder = scratch.appendingPathComponent(name, isDirectory: true)
    try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    shell("git init -q -b main .", in: folder)
    write("one\n", to: folder.appendingPathComponent("kept.txt"))
    shell("git add -A && git -c user.email=t@example.com -c user.name=T commit -q -m first", in: folder)
    return folder
}

guard case .success(let program) = GitProgramLocator.find(
    environment: ProcessInfo.processInfo.environment.filter {
        $0.key != GitProgramLocator.overrideEnvironmentKey
    }) else {
    FileHandle.standardError.write(Data("FAIL: git was not found on this Mac\n".utf8))
    exit(1)
}
let worktrees = GitWorktrees(runner: GitRunner(program: program))
let configRoot = scratch.appendingPathComponent("config", isDirectory: true)

// ─────────────────────────── where it goes, and its name ───────────────────────────

expectEqual(GitWorktrees.path(configRoot: configRoot, projectId: "pr_1", threadId: "th_1").path,
            configRoot.appendingPathComponent("worktrees/pr_1/th_1", isDirectory: true).path,
            "a working copy lives under the configuration root's worktrees folder, by project and thread")

let project = newRepository("project")
let title = "Fix the sandbox rule file"
let threadId = "th_01JABCDEF9"
guard case .success(let first) = worktrees.ensure(
    projectFolder: project, projectId: "pr_1", threadId: threadId,
    title: title, configRoot: configRoot) else {
    FileHandle.standardError.write(Data("FAIL: the working copy was not created\n".utf8))
    exit(1)
}
expectEqual(first.branch, ContractBranchName.threadBranchName(title: title, threadId: threadId),
            "the branch is named by the contract's one rule and by no second rule here")
expectEqual(first.created, true, "the first call created it")
expectEqual(first.path.path,
            GitWorktrees.path(configRoot: configRoot, projectId: "pr_1", threadId: threadId).path,
            "at the path the rule above gives")
expect(fileManager.fileExists(atPath: first.path.appendingPathComponent("kept.txt").path),
       "the project's files are checked out in it")
expectEqual(first.baseCommit,
            shell("git rev-parse HEAD", in: project).trimmingCharacters(in: .whitespacesAndNewlines),
            "it starts from where the project is now")
expectEqual(shell("git rev-parse --abbrev-ref HEAD", in: first.path)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            first.branch, "and it is on that branch")

// ─────────────────────────── asking for it again ───────────────────────────

guard case .success(let again) = worktrees.ensure(
    projectFolder: project, projectId: "pr_1", threadId: threadId,
    title: title, configRoot: configRoot) else {
    FileHandle.standardError.write(Data("FAIL: asking again must not be an error\n".utf8))
    exit(1)
}
expectEqual(again.created, false, "the second call created nothing")
expectEqual(again.path.path, first.path.path, "and answers with the same folder")
expectEqual(again.branch, first.branch, "on the same branch")
expectEqual(shell("git branch --list --format='%(refname:short)' \(first.branch)", in: project)
                .split(separator: "\n").count,
            1, "there is one branch with that name, not two")
expectEqual(shell("git worktree list --porcelain", in: project)
                .split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count,
            2, "the project folder and one working copy, and nothing else")

// A title that leaves nothing behind still gives a usable branch, because the
// contract's rule says so; V4 must not invent its own fallback.
guard case .success(let odd) = worktrees.ensure(
    projectFolder: project, projectId: "pr_1", threadId: "th_01JZZZZZZ1",
    title: "。。。", configRoot: configRoot) else {
    FileHandle.standardError.write(Data("FAIL: a title of punctuation must still work\n".utf8))
    exit(1)
}
expectEqual(odd.branch, ContractBranchName.threadBranchName(title: "。。。", threadId: "th_01JZZZZZZ1"),
            "still the contract's rule")

let plain = scratch.appendingPathComponent("plain", isDirectory: true)
try fileManager.createDirectory(at: plain, withIntermediateDirectories: true)
switch worktrees.ensure(projectFolder: plain, projectId: "pr_2", threadId: "th_2",
                        title: "anything", configRoot: configRoot) {
case .success:
    expect(false, "a folder that is not a git repository gets no working copy")
case .failure(let failure):
    if case .failed(_, let message) = failure {
        expect(!message.isEmpty, "the refusal carries git's message")
    } else {
        expect(false, "the refusal is git's own, not a time limit: \(failure)")
    }
}

// ─────────────────────────── removing it ───────────────────────────

func removal(_ worktree: GitWorktree) -> WorktreeRemoval {
    switch worktrees.remove(projectFolder: project, worktree: worktree.path,
                            branch: worktree.branch, defaultBranch: "main") {
    case .success(let outcome):
        return outcome
    case .failure(let failure):
        FileHandle.standardError.write(Data("FAIL: removing failed: \(failure)\n".utf8))
        exit(1)
    }
}

write("work in progress\n", to: first.path.appendingPathComponent("draft.txt"))
switch removal(first) {
case .kept(let reason):
    expect(reason.lowercased().contains("uncommitted"),
           "a working copy with uncommitted work is kept, and the reason says so: \(reason)")
case .removed:
    expect(false, "a working copy with uncommitted work must not be removed")
}
expect(fileManager.fileExists(atPath: first.path.path), "and the folder is still there")

shell("git add -A && git -c user.email=t@example.com -c user.name=T commit -q -m draft", in: first.path)
switch removal(first) {
case .kept(let reason):
    expect(reason.contains(first.branch),
           "a branch that is neither merged nor pushed is kept, named in the reason: \(reason)")
case .removed:
    expect(false, "work that exists nowhere else must not be thrown away")
}

shell("git merge -q --no-edit \(first.branch)", in: project)
switch removal(first) {
case .removed:
    expect(!fileManager.fileExists(atPath: first.path.path), "the folder is gone")
case .kept(let reason):
    expect(false, "a clean working copy whose branch is merged is removed, not kept: \(reason)")
}
expect(!shell("git worktree list --porcelain", in: project).contains(first.path.lastPathComponent),
       "and git no longer lists it")

// Pushed instead of merged is the other way a working copy may go.
let origin = scratch.appendingPathComponent("origin.git", isDirectory: true)
shell("git init -q --bare \(origin.path)", in: scratch)
shell("git remote add origin \(origin.path) && git push -q -u origin main", in: project)
guard case .success(let pushedCopy) = worktrees.ensure(
    projectFolder: project, projectId: "pr_1", threadId: "th_01JPUSHED1",
    title: "Pushed work", configRoot: configRoot) else {
    FileHandle.standardError.write(Data("FAIL: the second working copy was not created\n".utf8))
    exit(1)
}
write("pushed\n", to: pushedCopy.path.appendingPathComponent("pushed.txt"))
shell("git add -A && git -c user.email=t@example.com -c user.name=T commit -q -m pushed && git push -q -u origin HEAD",
      in: pushedCopy.path)
switch removal(pushedCopy) {
case .removed:
    expect(!fileManager.fileExists(atPath: pushedCopy.path.path),
           "a clean working copy whose branch is pushed is removed")
case .kept(let reason):
    expect(false, "a pushed branch is safe to remove: \(reason)")
}

// ─────────────────────────── pruning at launch ───────────────────────────

guard case .success(let orphan) = worktrees.ensure(
    projectFolder: project, projectId: "pr_1", threadId: "th_01JORPHAN1",
    title: "Gone by hand", configRoot: configRoot) else {
    FileHandle.standardError.write(Data("FAIL: the third working copy was not created\n".utf8))
    exit(1)
}
try fileManager.removeItem(at: orphan.path)
expect(shell("git worktree list --porcelain", in: project).contains(orphan.path.lastPathComponent),
       "git still lists a working copy whose folder was deleted by hand")
switch worktrees.prune(projectFolder: project) {
case .success:
    expect(!shell("git worktree list --porcelain", in: project).contains(orphan.path.lastPathComponent),
           "pruning removes the record of a folder that is gone")
case .failure(let failure):
    expect(false, "pruning failed: \(failure)")
}

switch worktrees.list(projectFolder: project) {
case .success(let listed):
    expect(!listed.contains { $0.lastPathComponent == orphan.path.lastPathComponent },
           "the list matches what git lists")
    expect(listed.contains { $0.path == project.path },
           "and names the project folder itself, which is git's first entry")
case .failure(let failure):
    expect(false, "listing failed: \(failure)")
}

if failures > 0 {
    FileHandle.standardError.write(Data("git_worktrees: \(failures) failure(s)\n".utf8))
    exit(1)
}
print("git_worktrees: one working copy per thread, named by the contract, removed only when git says it is safe")
