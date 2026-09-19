import Foundation
import GRDB

// V1, task 3 — the project registry: which folders are projects, what each
// thread's working folder is, and project/relocate (06 §3.3).

let root = makeConfigRoot("v1-projects")
defer { try? fixtureFileManager.removeItem(at: root) }

let (pool, store) = try openStore(configRoot: root, homeID: "h_mac_one")
let paths = makePaths(root)
let probe = StubGitProbe()
var clock = Date(timeIntervalSince1970: 1_790_000_000)
var minted = 0
let registry = ProjectRegistry(
    store: store, paths: paths, git: probe,
    now: { clock }, newID: { minted += 1; return "p_made_\(minted)" })

// --------------------------------------------------------- the General project

let general = try registry.ensureGeneral()
require(general.isGeneral, "the General project is marked as the built-in one")
require(general.name == ProjectRegistry.generalName, "it is called General")
let generalFolder = URL(fileURLWithPath: general.path, isDirectory: true)
require(generalFolder.standardizedFileURL
        == root.appendingPathComponent(ProjectRegistry.generalFolder, isDirectory: true).standardizedFileURL,
        "its folder is projects/general inside the configuration root")
require(fixtureFileManager.fileExists(atPath: general.path), "the folder was made")
require(general.available, "it is available")
require(general.remoteAccess == .readWrite, "it is reachable like any other project")

let generalAgain = try registry.ensureGeneral()
require(generalAgain.id == general.id, "asking again gives the same project, not a second one")
require(generalAgain.version == general.version, "asking again does not raise its version")
let generals = try registry.list(includeArchived: true).filter(\.isGeneral)
require(generals.count == 1, "there is exactly one General project")
ok("the General project exists, in projects/general, and is created once")

// ----------------------------------------------------------- adding a project

let repo = makeFolder(root.appendingPathComponent("atika", isDirectory: true))
probe.remotes[repo.standardizedFileURL.path] = "git@github.com:safet/atika.git"
probe.branches[repo.standardizedFileURL.path] = "main"

let added = try registry.create(commandID: "cmd_add", name: "Atika", path: repo.path, gitRemote: nil)
require(!added.id.isEmpty && added.id != general.id, "the project is given an id of its own")
require(added.gitRemote == "git@github.com:safet/atika.git",
        "gitRemote is read from the folder, not given as a setting")
require(added.gitDefaultBranch == "main", "gitDefaultBranch is read from the folder too")
require(added.remoteAccess == .readWrite,
        "remoteAccess defaults to read_write: adding a folder is the act of making it reachable")
require(added.available, "a folder that is there is available")
require(added.version == 1, "a new project starts at version 1")
require(probe.asked.contains(repo.standardizedFileURL.path), "the folder was really asked about")

let plain = makeFolder(root.appendingPathComponent("notes", isDirectory: true))
let plainProject = try registry.create(commandID: "cmd_add_2", name: "Notes", path: plain.path, gitRemote: nil)
require(plainProject.gitRemote == nil, "a folder that is not a repository has no remote")
require(plainProject.gitDefaultBranch == nil, "and no default branch")

requireRefusal(.notFound, "adding a folder that is not there") {
    _ = try registry.create(commandID: "cmd_add_3", name: "Missing",
                            path: root.appendingPathComponent("nowhere").path, gitRemote: nil)
}
requireRefusal(.notFound, "adding a file instead of a folder") {
    let file = root.appendingPathComponent("a-file.txt")
    fixtureFileManager.createFile(atPath: file.path, contents: Data("x".utf8))
    _ = try registry.create(commandID: "cmd_add_4", name: "File", path: file.path, gitRemote: nil)
}
ok("adding a project reads the folder's git facts and refuses a path with no folder at it")

// ------------------------------------------------------- available is computed

// 06 §3.2: `available` is computed when the record is read, not stored. A
// folder that is moved makes its project unavailable and nothing is deleted.
try pool.read { db in
    let names = try db.columns(in: "projects").map(\.name)
    require(!names.contains("available"),
            "there is no available column: the fact is measured, never remembered")
    require(names.contains("path") && names.contains("record"),
            "the queried path and the whole record are both kept")
}

let moved = root.appendingPathComponent("atika-moved", isDirectory: true)
try fixtureFileManager.moveItem(at: repo, to: moved)
let unavailable = try registry.project(added.id)
require(!unavailable.available, "a project whose folder is not there reads as unavailable")
require(unavailable.path == repo.path, "its recorded path is untouched")
require(unavailable.version == added.version, "reading it does not raise its version")
requireRefusal(.notFound, "a thread in an unavailable project") {
    try registry.requireAvailable(unavailable)
}
ok("available is computed at read and an unavailable project refuses work by name")

// ------------------------------------------------------------ project/relocate

// A thread of the project, so the rewrite of workspaceRoot paths can be seen.
let threadRoot = TPWorkspaceRoot(baseCommit: nil, branch: nil, kind: .project,
                                 path: repo.path, rootID: added.id)
_ = try store.apply([.thread(makeThread(id: "t_in_project", projectID: added.id,
                                        workspaceRoot: threadRoot))])
let worktreeRoot = TPWorkspaceRoot(
    baseCommit: "aaa111", branch: "atika/fix-the-store-abcdef", kind: .worktree,
    path: root.appendingPathComponent("worktrees/\(added.id)/t_worktree").path,
    rootID: "t_worktree")
_ = try store.apply([.thread(makeThread(id: "t_worktree", projectID: added.id,
                                        workspaceRoot: worktreeRoot, branch: worktreeRoot.branch))])

probe.remotes[moved.standardizedFileURL.path] = "git@github.com:safet/atika-2.git"
probe.branches[moved.standardizedFileURL.path] = "trunk"

let relocated = try registry.relocate(commandID: "cmd_relocate", projectID: added.id, path: moved.path)
require(relocated.id == added.id, "the project keeps its id")
require(relocated.path == moved.path, "the new path is stored")
require(relocated.available, "the project is available again, so its threads run")
require(relocated.version == added.version + 1, "the record's version rises")
require(relocated.gitRemote == "git@github.com:safet/atika-2.git",
        "gitRemote is read again from the folder that is there now")
require(relocated.gitDefaultBranch == "trunk", "gitDefaultBranch is read again too")
require(relocated.name == added.name, "nothing else changes")
require(relocated.remoteAccess == added.remoteAccess, "remoteAccess is left as it was")

let movedThread = try store.thread("t_in_project")
require(movedThread?.workspaceRoot.path == moved.path,
        "a thread that worked in the project folder now works in the new one")
require(movedThread?.projectID == added.id, "its project is unchanged")
let movedWorktree = try store.thread("t_worktree")
require(movedWorktree?.workspaceRoot.branch == "atika/fix-the-store-abcdef",
        "a thread with its own working copy keeps its branch")
require(movedWorktree?.workspaceRoot.kind == .worktree, "and keeps its kind")

// The rewrite happens in the same transaction as the project's own change: a
// relocate that fails leaves both untouched.
requireRefusal(.notFound, "relocating to a path with nothing at it") {
    _ = try registry.relocate(commandID: "cmd_relocate_2", projectID: added.id,
                              path: root.appendingPathComponent("not-here").path)
}
let afterFailedRelocate = try registry.project(added.id)
require(afterFailedRelocate.path == moved.path, "the failed relocate changed no path")
require(afterFailedRelocate.version == relocated.version, "and raised no version")
require(try store.thread("t_in_project")?.workspaceRoot.path == moved.path,
        "and rewrote no thread")

requireRefusal(.notFound, "relocating a project that is not here") {
    _ = try registry.relocate(commandID: "cmd_relocate_3", projectID: "p_nothing", path: moved.path)
}
ok("project/relocate stores the new path, re-reads git, raises the version and rewrites its threads")

// ----------------------------------------------------- the working folder

let plainRecord = try registry.project(plainProject.id)
let simple = try registry.plannedWorkspace(project: plainRecord, threadID: "t_simple",
                                           title: "Quick question", ownWorkingCopy: false)
require(simple.root.kind == .project, "without an own working copy the thread works in the project folder")
require(simple.root.path == plainRecord.path, "at the project's path")
require(simple.root.rootID == plainRecord.id, "the files root of a project folder is the project's id")
require(simple.root.branch == nil, "and it has no branch of its own")
require(simple.branch == nil, "so no branch name is reserved")

let gitRecord = try registry.project(added.id)
let own = try registry.plannedWorkspace(project: gitRecord, threadID: "th_0123456789abcdef",
                                        title: "Fix the store", ownWorkingCopy: true)
require(own.root.kind == .worktree, "an own working copy is a worktree")
let expectedBranch = ContractBranchName.threadBranchName(title: "Fix the store",
                                                         threadId: "th_0123456789abcdef")
require(own.branch == expectedBranch,
        "the branch name comes from the contract's one function, not from a second rule here")
require(own.root.branch == expectedBranch, "the same name is recorded on the workspace root")
require(own.root.path == root.appendingPathComponent(
            "worktrees/\(gitRecord.id)/th_0123456789abcdef").path,
        "the worktree sits under worktrees/<project>/<thread> in the configuration root")
require(own.root.rootID == "th_0123456789abcdef", "a worktree's files root is the thread's id")

requireRefusal(.notSupported, "an own working copy in a folder that is not a repository") {
    _ = try registry.plannedWorkspace(project: plainRecord, threadID: "t_x", title: "x",
                                      ownWorkingCopy: true)
}
requireRefusal(.notFound, "planning a working folder for an unavailable project") {
    let gone = makeProject(id: "p_gone", name: "Gone",
                           path: root.appendingPathComponent("vanished").path)
    _ = try registry.plannedWorkspace(project: gone, threadID: "t_y", title: "y",
                                      ownWorkingCopy: false)
}
ok("the working folder is the project folder, or a worktree named by the contract's branch function")

// ------------------------------------------------------ update and remove

let renamed = try registry.update(commandID: "cmd_update", projectID: plainProject.id,
                                  name: "Notes and drafts", archived: nil, remoteAccess: .readOnly)
require(renamed.name == "Notes and drafts", "the name changes")
require(renamed.remoteAccess == .readOnly, "remoteAccess changes")
require(renamed.version == plainProject.version + 1, "the version rises once for the whole change")

clock = clock.addingTimeInterval(60)
let removed = try registry.remove(commandID: "cmd_remove", projectID: plainProject.id)
require(removed.archivedAt != nil, "removing a project archives it")
require(removed.deletedAt == nil, "it is not deleted")
require(fixtureFileManager.fileExists(atPath: plain.path), "its folder is never touched")
require(try store.projects(includeArchived: false).map(\.id).contains(plainProject.id) == false,
        "it drops out of the ordinary listing")
require(try registry.project(plainProject.id).id == plainProject.id,
        "its threads can still read it")

requireRefusal(.notFound, "updating a project that is not here") {
    _ = try registry.update(commandID: "cmd_update_2", projectID: "p_nothing", name: "x",
                            archived: nil, remoteAccess: nil)
}
requireRefusal(.notFound, "removing a project that is not here") {
    _ = try registry.remove(commandID: "cmd_remove_2", projectID: "p_nothing")
}
ok("update changes the record and remove archives it without touching the folder")

// ----------------------------------------------------------- command ledger

// Every one of these methods carries a commandId, so a repeat must take effect
// once (06 §3.2, thread_commands).
let firstRemove = try registry.remove(commandID: "cmd_remove_once", projectID: added.id)
let repeatRemove = try registry.remove(commandID: "cmd_remove_once", projectID: added.id)
require(firstRemove.archivedAt == repeatRemove.archivedAt,
        "repeating a project command answers with the first result")
require(repeatRemove.version == firstRemove.version,
        "and does not raise the version a second time")
ok("project commands are settled once per commandId")

print("thread store projects: General, adding, available, relocate, working folders, archiving")
