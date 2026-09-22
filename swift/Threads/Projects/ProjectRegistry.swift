import Foundation
import GRDB

/// Where a thread's turns will run: the project's own folder, or a worktree
/// under the configuration root named by the contract's one branch-name
/// function. V1 records the path and the branch name (06 §3.3, decision 5);
/// the git commands that make the worktree are work package V4's.
struct PlannedWorkspace: Equatable {
    let root: TPWorkspaceRoot
    let branch: String?
}

/// The project registry (06 §3.3): the General project, adding, updating,
/// removing and relocating a folder, what "available" measures, and each
/// thread's planned working folder.
///
/// It has no database of its own: every project write goes through
/// `ThreadStore.upsertProject` and every thread rewrite through
/// `ThreadStore.apply`, so the store stays the single writer. Every command
/// that carries a `commandID` goes through `ThreadStore.settle`, so a repeat
/// takes effect once and answers with the first result.
final class ProjectRegistry {
    static let generalName = "General"
    static let generalFolder = "projects/general"

    private let store: ThreadStore
    private let paths: VoiceFlowPaths
    private let git: ProjectGitProbe
    private let now: () -> Date
    private let newID: () -> String

    init(store: ThreadStore, paths: VoiceFlowPaths, git: ProjectGitProbe = SystemGitProbe(),
         now: @escaping () -> Date = Date.init,
         newID: @escaping () -> String = { UUID().uuidString }) {
        self.store = store
        self.paths = paths
        self.git = git
        self.now = now
        self.newID = newID
    }

    // MARK: - the General project

    /// The one row with `is_general` set. When there is none it makes the
    /// folder `projects/general/` inside the configuration root, mints an id,
    /// and writes the record; asking again answers the same record and raises
    /// no version. There is never a second General project.
    @discardableResult
    func ensureGeneral() throws -> TPProject {
        if let existing = try store.projects(includeArchived: true)
            .first(where: { $0.isGeneral }) {
            return measured(existing)
        }
        let folder = paths.configRoot.appendingPathComponent(
            ProjectRegistry.generalFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ThreadStoreError(code: .invalidParams,
                                   message: "could not make the General folder: \(error)")
        }
        let general = TPProject(
            archivedAt: nil, available: true, createdAt: timestamp(), deletedAt: nil,
            gitDefaultBranch: nil, gitRemote: nil, homeID: StoreHome.marker, id: newID(),
            isGeneral: true, name: ProjectRegistry.generalName, path: folder.path,
            remoteAccess: .readWrite, version: 1)
        try store.upsertProject(general)
        return try project(general.id)
    }

    // MARK: - adding, changing, removing

    /// Adds a folder as a project. It refuses `not_found` when there is no
    /// folder at `path`, reads the remote and the default branch from the
    /// folder, and makes it reachable with `read_write`. A `gitRemote` is used
    /// only when the probe answers nothing: the folder is the fact.
    func create(commandID: String, name: String, path: String,
                gitRemote: String?) throws -> TPProject {
        try settled(commandID: commandID, method: "project/create",
                    params: ["name": name, "path": path,
                             "gitRemote": jsonOrNull(gitRemote)]) { db in
            guard self.folderExists(at: path) else {
                throw ThreadStoreError(code: .notFound, message: "folder not found: \(path)")
            }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let probedRemote = self.git.remote(at: folder)
            let project = TPProject(
                archivedAt: nil, available: true, createdAt: self.timestamp(), deletedAt: nil,
                gitDefaultBranch: self.git.defaultBranch(at: folder),
                gitRemote: probedRemote ?? gitRemote, homeID: StoreHome.marker,
                id: self.newID(), isGeneral: false, name: name, path: path,
                remoteAccess: .readWrite, version: 1)
            try self.store.upsertProject(project, in: db)
            return project
        }
    }

    /// Changes only the fields it was given and raises `version` once for the
    /// whole change. `archived: true` sets `archivedAt`, `false` clears it.
    func update(commandID: String, projectID: String, name: String?, archived: Bool?,
                remoteAccess: TPRemoteAccess?) throws -> TPProject {
        try settled(commandID: commandID, method: "project/update",
                    params: ["projectID": projectID, "name": jsonOrNull(name),
                             "archived": jsonOrNull(archived),
                             "remoteAccess": jsonOrNull(remoteAccess)]) { db in
            let current = try self.project(projectID, in: db)
            let archivedAt: String?
            if let archived {
                archivedAt = archived ? self.timestamp() : nil
            } else {
                archivedAt = current.archivedAt
            }
            let updated = self.copy(current, archivedAt: .some(archivedAt),
                                    name: name ?? current.name,
                                    remoteAccess: remoteAccess ?? current.remoteAccess,
                                    version: current.version + 1)
            try self.store.upsertProject(updated, in: db)
            return updated
        }
    }

    /// Archives a project: it sets `archivedAt`, raises `version`, never sets
    /// `deletedAt` and never touches the folder. Its threads stay readable.
    func remove(commandID: String, projectID: String) throws -> TPProject {
        try settled(commandID: commandID, method: "project/remove",
                    params: ["projectID": projectID]) { db in
            let current = try self.project(projectID, in: db)
            let removed = self.copy(current, archivedAt: .some(self.timestamp()),
                                    version: current.version + 1)
            try self.store.upsertProject(removed, in: db)
            return removed
        }
    }

    /// Points a project at a new path. It refuses `not_found` when the project
    /// is unknown or nothing is at `path`; otherwise it stores the new path,
    /// reads the remote and the default branch again, raises `version`, and
    /// moves every thread of the project whose workspace root sat under the old
    /// path under the new one, keeping its kind, branch, baseCommit and rootId.
    func relocate(commandID: String, projectID: String, path: String) throws -> TPProject {
        try settled(commandID: commandID, method: "project/relocate",
                    params: ["projectID": projectID, "path": path]) { db in
            let current = try self.project(projectID, in: db)
            guard self.folderExists(at: path) else {
                throw ThreadStoreError(code: .notFound, message: "folder not found: \(path)")
            }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let relocated = self.copy(current, available: true,
                                      gitDefaultBranch: .some(
                                        self.git.defaultBranch(at: folder)),
                                      gitRemote: .some(self.git.remote(at: folder)),
                                      path: path, version: current.version + 1)
            try self.store.upsertProject(relocated, in: db)
            try self.rewriteWorkspaces(projectID: projectID,
                                       from: current.path, to: path, in: db)
            return relocated
        }
    }

    // MARK: - reading

    /// The project with the measured `available`, or `not_found` for an
    /// unknown id. A read writes nothing and raises no version.
    func project(_ id: String) throws -> TPProject {
        guard let stored = try store.project(id) else {
            throw ThreadStoreError(code: .notFound, message: "no project \(id)")
        }
        return measured(stored)
    }

    private func project(_ id: String, in db: Database) throws -> TPProject {
        guard let stored = try store.project(id, in: db) else {
            throw ThreadStoreError(code: .notFound, message: "no project \(id)")
        }
        return measured(stored)
    }

    func list(includeArchived: Bool) throws -> [TPProject] {
        try store.projects(includeArchived: includeArchived).map(measured)
    }

    /// What a thread's send is refused with when the project's folder is not
    /// there.
    func requireAvailable(_ project: TPProject) throws {
        guard folderExists(at: project.path) else {
            throw ThreadStoreError(code: .notFound,
                                   message: "folder not found: \(project.path)")
        }
    }

    // MARK: - the planned working folder

    /// The folder a thread's turns will run in. Without an own working copy it
    /// is the project's folder. With one it is a worktree under the
    /// configuration root, named by the contract's one branch-name function,
    /// and only for a project that has a repository. Nothing is created on
    /// disk: V4 runs `git worktree add`.
    func plannedWorkspace(project: TPProject, threadID: String, title: String,
                          ownWorkingCopy: Bool) throws -> PlannedWorkspace {
        try requireAvailable(project)
        guard ownWorkingCopy else {
            let root = TPWorkspaceRoot(baseCommit: nil, branch: nil, kind: .project,
                                       path: project.path, rootID: project.id)
            return PlannedWorkspace(root: root, branch: nil)
        }
        guard project.gitRemote != nil || project.gitDefaultBranch != nil else {
            throw ThreadStoreError(
                code: .notSupported,
                message: "project \(project.id) has no repository to make a worktree from")
        }
        let branch = ContractBranchName.threadBranchName(title: title, threadId: threadID)
        let path = paths.configRoot
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(project.id, isDirectory: true)
            .appendingPathComponent(threadID, isDirectory: true)
            .path
        let root = TPWorkspaceRoot(baseCommit: nil, branch: branch, kind: .worktree,
                                   path: path, rootID: threadID)
        return PlannedWorkspace(root: root, branch: branch)
    }

    // MARK: - the command ledger

    /// Runs `work` once per `commandID` through `ThreadStore.settle`, and
    /// answers the project the ledger holds. The work encodes the project it
    /// wrote; a repeat is answered from that record without running again.
    private func settled(commandID: String, method: String, params: [String: Any],
                         work: (Database) throws -> TPProject) throws -> TPProject {
        let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        let settlement = try store.settle(
            commandID: commandID, threadID: nil, method: method, params: data,
            run: { db in Data(try ThreadRecords.encode(work(db)).utf8) })
        // Return the result this command committed, even when a later command
        // has changed the project. Only folder availability is measured anew.
        return measured(try ThreadRecords.decodeProject(
            String(decoding: settlement.result, as: UTF8.self), homeID: store.homeID))
    }

    // MARK: - thread workspaces

    /// Moves each thread of the project whose workspace root sat under
    /// `oldPath` under `newPath` in one batch, keeping its kind, branch,
    /// baseCommit and rootId. A thread outside the old path is left alone.
    private func rewriteWorkspaces(projectID: String, from oldPath: String,
                                   to newPath: String, in db: Database) throws {
        let threads = try store.threads(in: db, includeArchived: true)
        var writes: [ThreadWrite] = []
        for thread in threads where thread.projectID == projectID {
            guard let movedPath = moved(thread.workspaceRoot.path,
                                        from: oldPath, to: newPath) else {
                continue
            }
            let root = TPWorkspaceRoot(baseCommit: thread.workspaceRoot.baseCommit,
                                       branch: thread.workspaceRoot.branch,
                                       kind: thread.workspaceRoot.kind,
                                       path: movedPath,
                                       rootID: thread.workspaceRoot.rootID)
            writes.append(.thread(copy(thread, workspaceRoot: root)))
        }
        guard !writes.isEmpty else { return }
        try store.apply(writes, in: db)
    }

    /// The same path under the new root, or nothing when it was not under the
    /// old one.
    private func moved(_ path: String, from oldPath: String, to newPath: String) -> String? {
        if path == oldPath { return newPath }
        let prefix = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return newPath + String(path.dropFirst(oldPath.count))
    }

    // MARK: - measured availability

    /// Every read fills `available` by checking the recorded path; nothing is
    /// written and no version is raised.
    private func measured(_ project: TPProject) -> TPProject {
        copy(project, available: folderExists(at: project.path))
    }

    private func folderExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    // MARK: - record copies

    private func copy(_ project: TPProject, archivedAt: String?? = nil, available: Bool? = nil,
                      gitDefaultBranch: String?? = nil, gitRemote: String?? = nil,
                      name: String? = nil, path: String? = nil,
                      remoteAccess: TPRemoteAccess? = nil, version: Int? = nil) -> TPProject {
        TPProject(
            archivedAt: archivedAt ?? project.archivedAt,
            available: available ?? project.available,
            createdAt: project.createdAt, deletedAt: project.deletedAt,
            gitDefaultBranch: gitDefaultBranch ?? project.gitDefaultBranch,
            gitRemote: gitRemote ?? project.gitRemote, homeID: project.homeID,
            id: project.id, isGeneral: project.isGeneral, name: name ?? project.name,
            path: path ?? project.path, remoteAccess: remoteAccess ?? project.remoteAccess,
            version: version ?? project.version)
    }

    private func copy(_ thread: TPThread, workspaceRoot: TPWorkspaceRoot) -> TPThread {
        TPThread(activity: thread.activity, archivedAt: thread.archivedAt,
                 attention: thread.attention, branch: thread.branch, cloud: thread.cloud,
                 createdAt: thread.createdAt, deletedAt: thread.deletedAt,
                 externalClient: thread.externalClient, homeID: thread.homeID, id: thread.id,
                 lastActivityAt: thread.lastActivityAt, lastReadAt: thread.lastReadAt,
                 lastTurn: thread.lastTurn, mirrorBlocked: thread.mirrorBlocked,
                 model: thread.model, personaID: thread.personaID,
                 personaName: thread.personaName, pinnedAt: thread.pinnedAt,
                 pinnedSlot: thread.pinnedSlot, projectID: thread.projectID,
                 reasoningEffort: thread.reasoningEffort, runtime: thread.runtime,
                 startedBy: thread.startedBy, supports: thread.supports, title: thread.title,
                 titleSource: thread.titleSource, trustProfile: thread.trustProfile,
                 version: thread.version, workspaceRoot: workspaceRoot)
    }

    private func jsonOrNull(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private func jsonOrNull(_ value: Bool?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private func jsonOrNull(_ value: TPRemoteAccess?) -> Any {
        value.map { $0.rawValue as Any } ?? NSNull()
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now())
    }
}
