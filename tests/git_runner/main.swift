import Foundation

// Work package V4, task 1: the one place that finds and runs the `git` program
// (06 §3.16 "Running git"), and the rule that decides which revision a client
// may name.
//
// Nothing here asserts against a double of our own making: the argument list,
// the environment and the working directory are observed by letting the runner
// launch a real program that writes down exactly what it was given, and the
// happy paths run the real `git` on a real repository built in a scratch
// folder.

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
    .appendingPathComponent("vf-git-runner-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: scratch) }

/// `/tmp` is a symbolic link to `/private/tmp` on macOS, and a child process
/// reports the resolved path, so every comparison of a path goes through this.
func resolved(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

@discardableResult
func shell(_ command: String, in folder: URL) -> (code: Int32, out: String) {
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
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Writes an executable script and returns its URL.
func script(_ name: String, _ body: String) -> URL {
    let url = scratch.appendingPathComponent(name, isDirectory: false)
    try? body.write(to: url, atomically: true, encoding: .utf8)
    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

// ─────────────────────────── finding the program ───────────────────────────

// A stand-in that answers `--version` the way git does. The locator must read
// the version out of that line and not invent one.
let fakeGit = script("fake-git", """
#!/bin/bash
if [ "$1" = "--version" ]; then echo "git version 9.9.9 (fake)"; exit 0; fi
printf '%s\\n' "$@" > "${VF_TEST_ARGV_FILE:-/dev/null}"
{
  echo "PWD=$PWD"
  echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT-unset}"
  echo "GIT_ASKPASS=${GIT_ASKPASS-unset}"
  echo "SSH_ASKPASS=${SSH_ASKPASS-unset}"
  echo "GIT_PAGER=${GIT_PAGER-unset}"
  echo "LC_ALL=${LC_ALL-unset}"
  echo "GIT_INDEX_FILE=${GIT_INDEX_FILE-unset}"
  echo "INHERITED=${VF_TEST_INHERITED-unset}"
} > "${VF_TEST_ENV_FILE:-/dev/null}"
exit 0
""")

switch GitProgramLocator.find(environment: [GitProgramLocator.overrideEnvironmentKey: fakeGit.path]) {
case .success(let program):
    expectEqual(program.url.path, fakeGit.path, "the override names the program that is used")
    expectEqual(program.version, "9.9.9", "the version is read out of git's own --version line")
case .failure(let unavailable):
    expect(false, "the override should have been accepted: \(unavailable.message)")
}

let missing = scratch.appendingPathComponent("no-such-git", isDirectory: false).path
switch GitProgramLocator.find(environment: [GitProgramLocator.overrideEnvironmentKey: missing]) {
case .success:
    expect(false, "a program that is not there must not be reported as found")
case .failure(let unavailable):
    expect(unavailable.message.contains(missing),
           "the reason names the path that was tried: \(unavailable.message)")
}

// Something that runs but is not git must be refused, not accepted with a
// nonsense version.
let notGit = script("not-git", "#!/bin/bash\necho hello\n")
switch GitProgramLocator.find(environment: [GitProgramLocator.overrideEnvironmentKey: notGit.path]) {
case .success(let program):
    expect(false, "a program that does not print a git version was accepted as \(program.version)")
case .failure(let unavailable):
    expect(!unavailable.message.isEmpty, "the refusal says why")
}

// The real program on this Mac, found the way the app finds it at launch.
guard case .success(let realGit) = GitProgramLocator.find(
    environment: ProcessInfo.processInfo.environment.filter {
        $0.key != GitProgramLocator.overrideEnvironmentKey
    }) else {
    FileHandle.standardError.write(Data("FAIL: git was not found on this Mac\n".utf8))
    exit(1)
}
expect(realGit.version.split(separator: ".").count >= 2,
       "a real version has at least two numbers, got \(realGit.version)")
expect(fileManager.isExecutableFile(atPath: realGit.url.path), "the program found is executable")

// ──────────────────────── what the runner hands to git ────────────────────────

let argvFile = scratch.appendingPathComponent("argv.txt", isDirectory: false)
let envFile = scratch.appendingPathComponent("env.txt", isDirectory: false)
setenv("VF_TEST_ARGV_FILE", argvFile.path, 1)
setenv("VF_TEST_ENV_FILE", envFile.path, 1)
setenv("VF_TEST_INHERITED", "yes", 1)

let fakeProgram = GitProgram(url: fakeGit, version: "9.9.9")
let fakeRunner = GitRunner(program: fakeProgram)

func argv() -> [String] {
    let text = (try? String(contentsOf: argvFile, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        .filter { !$0.isEmpty }
}

func childEnvironment() -> [String: String] {
    let text = (try? String(contentsOf: envFile, encoding: .utf8)) ?? ""
    var found: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let split = line.firstIndex(of: "=") else { continue }
        found[String(line[line.startIndex..<split])] = String(line[line.index(after: split)...])
    }
    return found
}

_ = fakeRunner.run(["status", "--porcelain=v2"], in: scratch, query: true)
expectEqual(argv().first, "--no-optional-locks",
            "a query asks git not to take the optional locks (06 §3.16)")

_ = fakeRunner.run(["commit-tree", "abc"], in: scratch, query: false)
expect(!argv().contains("--no-optional-locks"),
       "a command that writes does not pass --no-optional-locks")

_ = fakeRunner.run(["diff"], in: scratch, query: true,
                   clientValues: ["HEAD", "refs/atika/checkpoints/t/u-after"],
                   paths: ["src/a b.swift"])
let withValues = argv()
guard let endOfOptions = withValues.firstIndex(of: "--end-of-options"),
      let separator = withValues.firstIndex(of: "--"),
      withValues.count > endOfOptions + 2 else {
    FileHandle.standardError.write(
        Data("FAIL: the argument list carries --end-of-options, two values and -- : \(withValues)\n".utf8))
    exit(1)
}
expectEqual(Array(withValues[(endOfOptions + 1)...(endOfOptions + 2)]),
            ["HEAD", "refs/atika/checkpoints/t/u-after"],
            "every value that came from a client is passed after --end-of-options")
expect(separator > endOfOptions, "paths come after the revisions, behind --")
expectEqual(withValues.last, "src/a b.swift", "a path with a space survives as one argument")

_ = fakeRunner.run(["status"], in: scratch, query: true)
expect(!argv().contains("--end-of-options"),
       "nothing is added when the caller passed no client value")

// The environment the child is given.
let indexFile = scratch.appendingPathComponent("temp-index", isDirectory: false)
_ = fakeRunner.run(["write-tree"], in: scratch, query: false, indexFile: indexFile)
let childEnv = childEnvironment()
expectEqual(childEnv["GIT_TERMINAL_PROMPT"], "0", "git may never stop to ask for a password")
expectEqual(childEnv["LC_ALL"], "C", "git speaks one language, so the output can be parsed")
expect(childEnv["GIT_ASKPASS"] != "unset", "an askpass helper is set so nothing opens a window")
expect(childEnv["SSH_ASKPASS"] != "unset", "the same for ssh")
expectEqual(childEnv["GIT_PAGER"], "cat", "no pager")
expectEqual(childEnv["GIT_INDEX_FILE"], indexFile.path, "the temporary index is given to git by path")
expectEqual(childEnv["INHERITED"], "yes", "the rest of the process environment is inherited")
expectEqual(childEnv["PWD"], resolved(scratch), "git runs in the folder it was given")

_ = fakeRunner.run(["status"], in: scratch, query: true)
expectEqual(childEnvironment()["GIT_INDEX_FILE"], "unset",
            "without a temporary index git uses the repository's own")

// ─────────────────────────── failure and time limit ───────────────────────────

let failing = script("failing-git", """
#!/bin/bash
if [ "$1" = "--version" ]; then echo "git version 9.9.9 (fake)"; exit 0; fi
echo "fatal: Unable to create '.git/index.lock': File exists." >&2
exit 128
""")
let failingRunner = GitRunner(program: GitProgram(url: failing, version: "9.9.9"))
switch failingRunner.run(["add", "-A"], in: scratch, query: false) {
case .success(let output):
    expect(false, "a non-zero exit is a failure, not a success with code \(output.exitCode)")
case .failure(let failure):
    expectEqual(failure, .failed(exitCode: 128,
                                 message: "fatal: Unable to create '.git/index.lock': File exists."),
                "the failure carries git's own message, so a warning can repeat it word for word")
}

let marker = scratch.appendingPathComponent("slow-finished.txt", isDirectory: false)
let slow = script("slow-git", """
#!/bin/bash
if [ "$1" = "--version" ]; then echo "git version 9.9.9 (fake)"; exit 0; fi
sleep 3
echo done > "\(marker.path)"
""")
let slowRunner = GitRunner(program: GitProgram(url: slow, version: "9.9.9"), timeout: 0.5)
let startedAt = Date()
switch slowRunner.run(["fsck"], in: scratch, query: true) {
case .success:
    expect(false, "a command past its time limit must not come back as a success")
case .failure(let failure):
    expectEqual(failure, .timedOut(seconds: 0.5), "the failure says it ran out of time")
}
expect(Date().timeIntervalSince(startedAt) < 3, "the runner gives up at its limit, not at the child's")
Thread.sleep(forTimeInterval: 4)
expect(!fileManager.fileExists(atPath: marker.path),
       "the child is killed, not left running to finish behind the app's back")

// ───────────────────────────── on a real repository ─────────────────────────────

let repo = scratch.appendingPathComponent("repo", isDirectory: true)
try fileManager.createDirectory(at: repo, withIntermediateDirectories: true)
shell("git init -q -b main . && git -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m first", in: repo)

let runner = GitRunner(program: realGit)
guard case .success(let head) = runner.run(["rev-parse", "HEAD"], in: repo, query: true) else {
    FileHandle.standardError.write(Data("FAIL: the real runner could not read HEAD\n".utf8))
    exit(1)
}
let headCommit = head.text.trimmingCharacters(in: .whitespacesAndNewlines)
expectEqual(headCommit.count, 40, "a commit id is forty characters")

// ───────────────────────── which revisions a client may name ─────────────────────────

expect(GitRevision.isCommitId(headCommit), "a full commit id has the shape of one")
expect(GitRevision.isCommitId(String(headCommit.prefix(7))), "an abbreviated commit id has it too")
expect(!GitRevision.isCommitId("DEADBEEF"), "upper case is not the shape git prints")
expect(!GitRevision.isCommitId("abc"), "three characters are too few to mean one commit")
expect(!GitRevision.isCommitId("main"), "a branch name is not a commit id")

expect(CheckpointRefs.isCheckpointRef("refs/atika/checkpoints/th_1/tu_1-before"),
       "a checkpoint reference is recognised")
expect(!CheckpointRefs.isCheckpointRef("refs/heads/main"), "a branch reference is not one")
expect(!CheckpointRefs.isCheckpointRef("refs/atika/checkpoints/../../heads/main"),
       "a reference that climbs out of the checkpoint space is not one")
expect(!CheckpointRefs.isCheckpointRef("refs/atika/checkpoints/"),
       "the bare prefix names no checkpoint")
expect(!CheckpointRefs.isCheckpointRef("refs/atika/checkpoints/a b/c"),
       "a reference with a space in it is not one")

expectEqual(CheckpointRefs.ref(threadId: "th_1", turnId: "tu_1", phase: .before),
            "refs/atika/checkpoints/th_1/tu_1-before",
            "the reference name is the one branch 04 uses on the Atika machine")
expectEqual(CheckpointRefs.ref(threadId: "th_1", turnId: "tu_1", phase: .after),
            "refs/atika/checkpoints/th_1/tu_1-after", "and the same for the after side")
expectEqual(CheckpointRefs.threadPrefix("th_1"), "refs/atika/checkpoints/th_1/",
            "one thread's checkpoints live under one prefix")

func accepted(_ value: String) -> Bool {
    if case .success = GitRevision.accept(value, folder: repo, runner: runner) { return true }
    return false
}
func refusal(_ value: String) -> GitOperationError? {
    if case .failure(let error) = GitRevision.accept(value, folder: repo, runner: runner) { return error }
    return nil
}

expect(accepted("HEAD"), "HEAD is allowed")
expect(accepted(headCommit), "a commit id of this repository is allowed")

shell("git update-ref refs/atika/checkpoints/th_1/tu_1-before HEAD", in: repo)
expect(accepted("refs/atika/checkpoints/th_1/tu_1-before"),
       "a checkpoint reference of this project is allowed")

for refused in ["main", "HEAD~1", "HEAD^", "@", "-", "", "refs/heads/main",
                "--upload-pack=/bin/sh", "$(whoami)", "refs/atika/checkpoints/th_9/tu_9-before",
                String(repeating: "f", count: 40)] {
    guard let error = refusal(refused) else {
        expect(false, "\"\(refused)\" must be refused")
        continue
    }
    expectEqual(error.code, "invalid_params", "\"\(refused)\" is refused as a bad parameter")
    expect(error.message.contains(refused) || refused.isEmpty,
           "the refusal names the value it refused: \(error.message)")
}

if failures > 0 {
    FileHandle.standardError.write(Data("git_runner: \(failures) failure(s)\n".utf8))
    exit(1)
}
print("git_runner: the program is found, git is run the one way, revisions are checked")
