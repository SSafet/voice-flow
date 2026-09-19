import Foundation

/// The three folders a turn carries (06 §3.6): where the runtime works, the
/// read-only persona folder it reads instructions from, and the writable
/// scratch folder that belongs to the thread rather than to the project.
struct RuntimeFolders: Equatable {
    /// The thread's workspaceRoot: the project folder or its own working copy.
    let workingDirectory: URL
    /// Read only; nil for a thread with no persona.
    let personaDirectory: URL?
    /// `<config root>/thread-scratch/<thread id>/`, writable.
    let scratchDirectory: URL

    init(workingDirectory: URL, personaDirectory: URL?, scratchDirectory: URL) {
        self.workingDirectory = workingDirectory
        self.personaDirectory = personaDirectory
        self.scratchDirectory = scratchDirectory
    }

    /// Resolves the thread's own scratch folder and makes sure it exists, so a
    /// runtime can be written into it as soon as the rule file allows it.
    static func scratchDirectory(threadID: String, configRoot: URL) -> URL {
        let directory = configRoot
            .appendingPathComponent("thread-scratch", isDirectory: true)
            .appendingPathComponent(threadID, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
