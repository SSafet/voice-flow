import Foundation

// Work package V4, task 2: the per-turn checkpoints, the per-turn changed
// files and the git state a turn ends with (06 §3.16 "Checkpoints",
// "Changed files per turn", "Git state at turn end").
//
// Everything is observed on a real git repository built in a scratch folder,
// with the real `git` program, because the whole point of the technique is
// what it does and does not do to a repository the person is also using.

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
    .appendingPathComponent("vf-git-checkpoints-\(UUID().uuidString)", isDirectory: true)
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

func newRepository(_ name: String, commit: Bool = true) -> URL {
    let folder = scratch.appendingPathComponent(name, isDirectory: true)
    try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    shell("git init -q -b main .", in: folder)
    if commit {
        write("one\n", to: folder.appendingPathComponent("kept.txt"))
        shell("git add -A && git -c user.email=t@example.com -c user.name=T commit -q -m first",
              in: folder)
    }
    return folder
}

guard case .success(let program) = GitProgramLocator.find(
    environment: ProcessInfo.processInfo.environment.filter {
        $0.key != GitProgramLocator.overrideEnvironmentKey
    }) else {
    FileHandle.standardError.write(Data("FAIL: git was not found on this Mac\n".utf8))
    exit(1)
}
let runner = GitRunner(program: program)
let scratchIndexes = scratch.appendingPathComponent("thread-scratch", isDirectory: true)
let checkpoints = GitCheckpoints(runner: runner, scratchFolder: scratchIndexes)

func record(_ folder: URL, _ threadId: String, _ turnId: String,
            _ phase: CheckpointPhase) -> Checkpoint? {
    switch checkpoints.record(folder: folder, threadId: threadId, turnId: turnId, phase: phase) {
    case .success(let checkpoint): return checkpoint
    case .failure(let warning):
        expect(false, "recording \(phase.rawValue) failed: \(warning.message)")
        return nil
    }
}

// ─────────── the reference, the commit and the tree it points at ───────────

let repo = newRepository("repo")
guard let before = record(repo, "th_1", "tu_1", .before) else { exit(1) }
expectEqual(before.ref, "refs/atika/checkpoints/th_1/tu_1-before",
            "the reference is named for the thread and the turn, never for a count")
expectEqual(before.commit.count, 40, "the checkpoint is an ordinary commit")
expectEqual(shell("git rev-parse \(before.ref)", in: repo)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            before.commit, "the reference points at the commit that was reported")
expectEqual(shell("git rev-parse \(before.commit)^{tree}", in: repo)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            before.tree, "the commit carries the tree that was reported")

// ─────────── what the person's repository looks like afterwards ───────────

// The fact 06 §8 item 10 is observed on: a file staged by hand stays staged,
// nothing else is staged, and no branch appears.
let staged = newRepository("staged")
write("hand\n", to: staged.appendingPathComponent("hand.txt"))
shell("git add hand.txt", in: staged)
write("free\n", to: staged.appendingPathComponent("free.txt"))
let statusBefore = shell("git status --porcelain", in: staged)
let headBefore = shell("git rev-parse HEAD", in: staged)
let branchesBefore = shell("git branch --format=%(refname)", in: staged)
let indexModifiedBefore = (try? fileManager.attributesOfItem(
    atPath: staged.appendingPathComponent(".git/index").path)[.modificationDate]) as? Date

guard let stagedBefore = record(staged, "th_2", "tu_2", .before) else { exit(1) }
write("free changed\n", to: staged.appendingPathComponent("free.txt"))
guard let stagedAfter = record(staged, "th_2", "tu_2", .after) else { exit(1) }

// Read before any other git command, because a plain `git status` may refresh
// and rewrite the index itself and would hide what is being checked here.
let indexModifiedAfter = (try? fileManager.attributesOfItem(
    atPath: staged.appendingPathComponent(".git/index").path)[.modificationDate]) as? Date
expectEqual(indexModifiedAfter, indexModifiedBefore,
            "the repository's own index file was never written")

expectEqual(shell("git rev-parse HEAD", in: staged), headBefore, "HEAD did not move")
expectEqual(shell("git branch --format=%(refname)", in: staged), branchesBefore,
            "no branch was created")
expectEqual(shell("git diff --cached --name-only", in: staged)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "hand.txt", "the file staged by hand is still the only staged file")
let statusAfterChange = shell("git status --porcelain", in: staged)
expect(statusAfterChange != statusBefore,
       "the test itself changed a file, so the two status readings must differ")
expect(statusAfterChange.contains("A  hand.txt"),
       "the staged file is still staged: \(statusAfterChange)")

let listed = shell("git for-each-ref --format=%(refname) refs/atika/checkpoints/", in: staged)
    .split(separator: "\n").map(String.init)
expectEqual(listed.sorted(), [stagedAfter.ref, stagedBefore.ref].sorted(),
            "for-each-ref lists the before and the after reference and nothing else")

// ─────────── what goes into a checkpoint ───────────

let content = newRepository("content")
write("*.log\nbuilt/\n", to: content.appendingPathComponent(".gitignore"))
shell("git add -A && git -c user.email=t@example.com -c user.name=T commit -q -m ignore", in: content)
write("noise\n", to: content.appendingPathComponent("debug.log"))
write("noise\n", to: content.appendingPathComponent("built/artifact.bin"))
write("new\n", to: content.appendingPathComponent("fresh.txt"))
guard let contentPoint = record(content, "th_3", "tu_3", .before) else { exit(1) }
let tracked = shell("git ls-tree -r --name-only \(contentPoint.commit)", in: content)
expect(tracked.contains("fresh.txt"), "a file that was never added is in the checkpoint")
expect(!tracked.contains("debug.log"), "an ignored file is not: the technique honours .gitignore")
expect(!tracked.contains("built/artifact.bin"), "and the same for an ignored folder")

// A repository whose first commit has not happened yet still gets checkpoints.
let unborn = newRepository("unborn", commit: false)
write("first\n", to: unborn.appendingPathComponent("first.txt"))
guard let unbornPoint = record(unborn, "th_4", "tu_4", .before) else { exit(1) }
expect(shell("git ls-tree -r --name-only \(unbornPoint.commit)", in: unborn).contains("first.txt"),
       "a repository with no commit yet is recorded from nothing")
expectEqual(shell("git rev-parse --verify --quiet HEAD", in: unborn)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "", "and recording it did not give the repository a first commit")

// ─────────── recording the same thing twice ───────────

guard let repeatedFirst = record(repo, "th_1", "tu_1", .before) else { exit(1) }
expectEqual(repeatedFirst.ref, before.ref, "the second recording answers with the same name")
let afterRepeat = shell("git for-each-ref --format=%(refname) \(CheckpointRefs.threadPrefix("th_1"))",
                        in: repo).split(separator: "\n")
expectEqual(afterRepeat.count, 1, "recording twice leaves one reference, not two")

// ─────────── the temporary index ───────────

let leftovers = (try? fileManager.subpathsOfDirectory(atPath: scratchIndexes.path)) ?? []
let filesLeft = leftovers.filter {
    var isDirectory: ObjCBool = false
    let path = scratchIndexes.appendingPathComponent($0).path
    _ = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
    return !isDirectory.boolValue
}
expectEqual(filesLeft, [], "every temporary index file is removed once it has been used")

// Which index file git was actually given, observed by letting the real
// program run behind a wrapper that writes the value down.
let indexLog = scratch.appendingPathComponent("index-file.log", isDirectory: false)
let wrapper = scratch.appendingPathComponent("logging-git", isDirectory: false)
try Data("""
#!/bin/bash
if [ "$1" != "--version" ]; then echo "${GIT_INDEX_FILE-unset}" >> "\(indexLog.path)"; fi
exec "\(program.url.path)" "$@"
""".utf8).write(to: wrapper)
try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
let watched = GitCheckpoints(
    runner: GitRunner(program: GitProgram(url: wrapper, version: program.version)),
    scratchFolder: scratchIndexes)
guard case .success = watched.record(folder: repo, threadId: "th_9", turnId: "tu_9", phase: .before) else {
    FileHandle.standardError.write(Data("FAIL: the watched recording did not succeed\n".utf8))
    exit(1)
}
let indexValues = ((try? String(contentsOf: indexLog, encoding: .utf8)) ?? "")
    .split(separator: "\n").map(String.init)
expect(!indexValues.isEmpty, "the wrapper saw git run")
expect(indexValues.contains { $0.hasPrefix(scratchIndexes.path) },
       "the steps that build the tree are given a temporary index under the scratch folder: \(indexValues)")
expect(!indexValues.contains { $0.hasSuffix("/.git/index") },
       "and never the repository's own index: \(indexValues)")

// ─────────── a checkpoint that cannot be taken ───────────

let refusing = scratch.appendingPathComponent("refusing-git", isDirectory: false)
try Data("""
#!/bin/bash
if [ "$1" = "--version" ]; then echo "git version 9.9.9 (fake)"; exit 0; fi
echo "fatal: Unable to create '.git/index.lock': File exists." >&2
exit 128
""".utf8).write(to: refusing)
try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: refusing.path)
let refusingPoints = GitCheckpoints(
    runner: GitRunner(program: GitProgram(url: refusing, version: "9.9.9")),
    scratchFolder: scratchIndexes)
switch refusingPoints.record(folder: repo, threadId: "th_5", turnId: "tu_5", phase: .before) {
case .success:
    expect(false, "a repository that refuses must not answer with a checkpoint")
case .failure(let warning):
    expectEqual(warning.message, "fatal: Unable to create '.git/index.lock': File exists.",
                "the warning repeats git's own message, which is what the turn shows")
}
let leftoversAfterFailure = (try? fileManager.subpathsOfDirectory(atPath: scratchIndexes.path)) ?? []
expect(leftoversAfterFailure.allSatisfy { $0.isEmpty || !$0.contains("tu_5") },
       "a failed recording leaves no temporary index behind: \(leftoversAfterFailure)")

// ─────────── the changed files of a turn ───────────

let work = newRepository("work")
write("a\nb\nc\n", to: work.appendingPathComponent("edited.txt"))
write("x\ny\n", to: work.appendingPathComponent("removed.txt"))
write("old name\n", to: work.appendingPathComponent("before name.txt"))
write("line\n", to: work.appendingPathComponent("odd\nname.txt"))
try Data([0x00, 0x01, 0x02, 0x00, 0xff]).write(to: work.appendingPathComponent("picture.bin"))
shell("git add -A && git -c user.email=t@example.com -c user.name=T commit -q -m base", in: work)

guard let workBefore = record(work, "th_6", "tu_6", .before) else { exit(1) }
write("a\nb\nc\nd\ne\n", to: work.appendingPathComponent("edited.txt"))
try? fileManager.removeItem(at: work.appendingPathComponent("removed.txt"))
write("old name\n", to: work.appendingPathComponent("after name.txt"))
try? fileManager.removeItem(at: work.appendingPathComponent("before name.txt"))
write("brand new\n", to: work.appendingPathComponent("created.txt"))
write("line\nline two\n", to: work.appendingPathComponent("odd\nname.txt"))
try Data([0x00, 0x01, 0x02, 0x00, 0xfe, 0xfe]).write(to: work.appendingPathComponent("picture.bin"))
guard let workAfter = record(work, "th_6", "tu_6", .after) else { exit(1) }

guard case .success(let changes) = checkpoints.changedFiles(
    folder: work, from: workBefore.commit, to: workAfter.commit) else {
    FileHandle.standardError.write(Data("FAIL: the changed files could not be read\n".utf8))
    exit(1)
}
func change(_ path: String) -> ChangedFileDetail? { changes.files.first { $0.path == path } }

expectEqual(changes.files.map(\.path), changes.files.map(\.path).sorted(),
            "the list is in path order, so two clients never disagree about it")
expectEqual(change("edited.txt")?.kind, ChangeKind.modified, "the edited file is modified")
expectEqual(change("edited.txt")?.added, 2, "two lines were added to it")
expectEqual(change("edited.txt")?.removed, 0, "and none removed")
expectEqual(change("created.txt")?.kind, ChangeKind.added, "the new file is added")
expectEqual(change("removed.txt")?.kind, ChangeKind.deleted, "the gone file is deleted")
expectEqual(change("removed.txt")?.removed, 2, "with its lines counted as removed")
expectEqual(change("after name.txt")?.kind, ChangeKind.renamed, "the moved file is renamed")
expectEqual(change("after name.txt")?.renamedFrom, "before name.txt", "and says where it came from")
expect(change("odd\nname.txt") != nil,
       "a path with a line break in it survives: \(changes.files.map(\.path))")
expectEqual(change("odd\nname.txt")?.added, 1, "and its line counts are read")
expectEqual(change("picture.bin")?.isBinary, true, "a file git calls binary is marked as one")
expectEqual(change("picture.bin")?.added, 0, "with no line counts, because there are none")
expectEqual(change("picture.bin")?.removed, 0, "on either side")

let carried = changes.turnChangedFiles()
expectEqual(carried.count, changes.files.count, "every change is carried while there are few")
expectEqual(carried.map(\.path), changes.files.map(\.path), "in the same order")
expectEqual(changes.total, changes.files.count, "the total counts every change")

// The cap the record carries, exercised for real.
let many = newRepository("many")
shell("for i in $(seq 1 320); do printf 'one\\n' > file-$i.txt; done", in: many)
guard let manyBefore = record(many, "th_7", "tu_7", .before) else { exit(1) }
shell("for i in $(seq 1 320); do printf 'one\\ntwo\\n' > file-$i.txt; done", in: many)
guard let manyAfter = record(many, "th_7", "tu_7", .after) else { exit(1) }
guard case .success(let manyChanges) = checkpoints.changedFiles(
    folder: many, from: manyBefore.commit, to: manyAfter.commit) else {
    FileHandle.standardError.write(Data("FAIL: the large changed set could not be read\n".utf8))
    exit(1)
}
expectEqual(manyChanges.total, 320, "the total is the real number of changed files")
expectEqual(manyChanges.turnChangedFiles().count, GitCheckpoints.changedFilesMax,
            "the record carries at most the contract's maximum")
expectEqual(GitCheckpoints.changedFilesMax, 300, "which is the contract's TURN_CHANGED_FILES_MAX")

// ─────────── a tree of the working copy that leaves no reference ───────────

let refsBeforeTree = shell("git for-each-ref --format=%(refname) refs/", in: work)
guard case .success(let throwaway) = checkpoints.workingCopyTree(
    folder: work, threadId: "th_6", turnId: "tu_6") else {
    FileHandle.standardError.write(Data("FAIL: the working-copy tree could not be built\n".utf8))
    exit(1)
}
expectEqual(shell("git for-each-ref --format=%(refname) refs/", in: work), refsBeforeTree,
            "building a throw-away tree writes no reference")
expect(shell("git ls-tree -r --name-only \(throwaway)", in: work).contains("created.txt"),
       "a file that was never added is in the throw-away tree, which is why it exists")

// ─────────── the git state a turn ends with ───────────

guard case .success(let plainState) = checkpoints.state(folder: work) else {
    FileHandle.standardError.write(Data("FAIL: the git state could not be read\n".utf8))
    exit(1)
}
expectEqual(plainState.branch, "main", "the branch the working folder is on")
expectEqual(plainState.headCommit.count, 40, "the commit it is at")
expectEqual(plainState.dirty, true, "the turn left files uncommitted")
expectEqual(plainState.upstreamRef, nil, "with no remote there is no upstream")
expectEqual(plainState.pushed, nil, "and nothing is known about pushing")

let origin = scratch.appendingPathComponent("origin.git", isDirectory: true)
shell("git init -q --bare \(origin.path)", in: scratch)
let tracked2 = newRepository("tracked")
shell("git remote add origin \(origin.path) && git push -q -u origin main", in: tracked2)
guard case .success(let pushedState) = checkpoints.state(folder: tracked2) else {
    FileHandle.standardError.write(Data("FAIL: the pushed state could not be read\n".utf8))
    exit(1)
}
expectEqual(pushedState.dirty, false, "a clean folder is not dirty")
expectEqual(pushedState.upstreamRef, "origin/main", "the upstream is named")
expectEqual(pushedState.unpushedCount, 0, "nothing is waiting to be pushed")
expectEqual(pushedState.pushed, true, "so the head is pushed")

write("two\n", to: tracked2.appendingPathComponent("second.txt"))
shell("git add -A && git -c user.email=t@example.com -c user.name=T commit -q -m second", in: tracked2)
guard case .success(let aheadState) = checkpoints.state(folder: tracked2) else {
    FileHandle.standardError.write(Data("FAIL: the ahead state could not be read\n".utf8))
    exit(1)
}
expectEqual(aheadState.unpushedCount, 1, "one commit is not pushed")
expectEqual(aheadState.pushed, false, "so the head is not pushed")

shell("git checkout -q --detach HEAD", in: tracked2)
guard case .success(let detachedState) = checkpoints.state(folder: tracked2) else {
    FileHandle.standardError.write(Data("FAIL: the detached state could not be read\n".utf8))
    exit(1)
}
expectEqual(detachedState.branch, "(detached)", "a detached head says so instead of naming a branch")
expectEqual(detachedState.upstreamRef, nil, "and has no upstream")

let notARepo = scratch.appendingPathComponent("plain", isDirectory: true)
try fileManager.createDirectory(at: notARepo, withIntermediateDirectories: true)
expectEqual(checkpoints.isInsideWorkTree(folder: notARepo), false,
            "a folder that is not a repository is recognised")
expectEqual(checkpoints.isInsideWorkTree(folder: work), true, "and one that is, too")
switch checkpoints.record(folder: notARepo, threadId: "th_8", turnId: "tu_8", phase: .before) {
case .success:
    expect(false, "a folder that is not a repository gets no checkpoint")
case .failure(let warning):
    expect(!warning.message.isEmpty, "and the warning says why")
}

// ─────────── deleting a thread's checkpoints ───────────

switch checkpoints.deleteThreadCheckpoints(folder: staged, threadId: "th_2") {
case .success(let removed):
    expectEqual(removed, 2, "both of the thread's references are deleted")
case .failure(let warning):
    expect(false, "deleting the thread's checkpoints failed: \(warning.message)")
}
expectEqual(shell("git for-each-ref --format=%(refname) refs/atika/checkpoints/", in: staged)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "", "nothing is left under the checkpoint prefix")
switch checkpoints.deleteThreadCheckpoints(folder: staged, threadId: "th_2") {
case .success(let removed):
    expectEqual(removed, 0, "deleting again removes nothing and is not an error")
case .failure(let warning):
    expect(false, "deleting twice must not fail: \(warning.message)")
}

if failures > 0 {
    FileHandle.standardError.write(Data("git_checkpoints: \(failures) failure(s)\n".utf8))
    exit(1)
}
print("git_checkpoints: checkpoints, changed files and git state, with the person's repository untouched")
