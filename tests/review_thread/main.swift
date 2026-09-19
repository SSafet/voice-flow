import Foundation

// ReviewThread: the one "Workflow review" thread in the project V2 created,
// created once. The thread store is a fake sink, so this suite needs no
// database; it pins the idempotency, the fields and the refusals.

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
        if try !condition() {
            FileHandle.standardError.write(Data(("not ok - " + message + "\n").utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data(("not ok - \(message): \(error)\n").utf8))
        exit(1)
    }
}
func ok(_ message: String) { print("ok - " + message) }

final class FakeSink: ReviewThreadSink {
    var projectList: [TPProject]
    var threadList: [TPThread] = []
    var applied: [TPThread] = []
    init(projectList: [TPProject]) { self.projectList = projectList }
    func projects(named name: String) throws -> [TPProject] { projectList.filter { $0.name == name } }
    func threads(includeArchived: Bool) throws -> [TPThread] { threadList }
    func thread(id: String) throws -> TPThread? { threadList.first { $0.id == id } }
    func applyThread(_ thread: TPThread) throws { threadList.append(thread); applied.append(thread) }
}

func project(id: String, name: String, path: String) -> TPProject {
    TPProject(archivedAt: nil, available: true, createdAt: "2026-09-18T00:00:00Z",
              deletedAt: nil, gitDefaultBranch: nil, gitRemote: nil, homeID: "self",
              id: id, isGeneral: false, name: name, path: path,
              remoteAccess: .readWrite, version: 1)
}

let watcherProject = project(id: "p-watcher", name: "Workflow review", path: "/tmp/watcher")
let sink = FakeSink(projectList: [watcherProject])
let marker = FileManager.default.temporaryDirectory
    .appendingPathComponent("review-thread-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: marker) }
let at = Date(timeIntervalSince1970: 1_700_000_000)

let thread = try ReviewThread.ensure(
    sink: sink, personaID: "persona-review", personaName: "Workflow review",
    markerURL: marker, now: at, newID: { "thread-review-1" })

expect(thread.id == "thread-review-1", "the created thread takes the minted id")
expect(thread.title == "Workflow review", "the thread is titled Workflow review")
expect(thread.projectID == watcherProject.id, "the thread belongs to the project V2 created")
expect(thread.titleSource == .custom, "the created title is not an auto title")
expect(thread.activity == .idle, "the thread starts idle")
expect(thread.runtime == .opencode, "the review runs through OpenCode by default")
expect(thread.trustProfile == .unattended, "the review never stops to ask")
expect(thread.personaID == "persona-review" && thread.personaName == "Workflow review",
       "the thread carries its persona")
expect(thread.workspaceRoot.kind == .project, "the thread runs in the project folder")
expect(thread.workspaceRoot.path == "/tmp/watcher", "the workspace root is the watcher folder")
expect(thread.workspaceRoot.rootID == watcherProject.id, "a project root names the project")
expect(thread.version == 1, "the created record is version 1")
expect(thread.createdAt.hasSuffix("Z"), "createdAt is an ISO 8601 UTC timestamp")
expect(thread.deletedAt == nil && thread.archivedAt == nil, "the created thread is live")
expect(sink.applied.count == 1, "the thread is applied exactly once")
ok("ensure creates the Workflow review thread with the fields branch 09 reads")

let again = try ReviewThread.ensure(
    sink: sink, personaID: "persona-review", personaName: "Workflow review",
    markerURL: marker, now: at, newID: { "thread-review-2" })
expect(again.id == thread.id, "a second ensure returns the same thread")
expect(sink.threadList.count == 1, "a second ensure creates no second thread")
expect(sink.applied.count == 1, "a second ensure applies nothing")
ok("ensure is idempotent through the marker")

// A marker whose thread is gone makes a fresh thread rather than a silent no-op.
sink.threadList = []
let afterLoss = try ReviewThread.ensure(
    sink: sink, personaID: nil, personaName: nil,
    markerURL: marker, now: at, newID: { "thread-review-3" })
expect(afterLoss.id == "thread-review-3", "a lost thread is created again")
expect(sink.threadList.count == 1, "exactly one thread exists after the loss")
ok("a marker whose thread is gone is replaced, not trusted")

// The project is V2's single creator: none, or two, refuses by name.
let emptySink = FakeSink(projectList: [])
let noMarker = marker.appendingPathExtension("none")
var refusedMissing = false
do { _ = try ReviewThread.ensure(sink: emptySink, personaID: nil, personaName: nil,
                                 markerURL: noMarker, now: at, newID: { "x" }) }
catch let error as ReviewThreadError {
    if case .projectNotFound(let name) = error { refusedMissing = name == "Workflow review" }
} catch {}
expect(refusedMissing, "a missing Workflow review project is refused by name")

let twoProjects = FakeSink(projectList: [watcherProject,
    project(id: "p-other", name: "Workflow review", path: "/tmp/other")])
var refusedAmbiguous = false
do { _ = try ReviewThread.ensure(sink: twoProjects, personaID: nil, personaName: nil,
                                 markerURL: noMarker, now: at, newID: { "x" }) }
catch let error as ReviewThreadError {
    if case .projectAmbiguous = error { refusedAmbiguous = true }
} catch {}
expect(refusedAmbiguous, "two projects named Workflow review are refused rather than guessed")
ok("a missing or doubled project refuses by name")

print("review thread tests passed")
