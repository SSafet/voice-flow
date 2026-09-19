import Foundation

/// The instruction text of the "Workflow review" persona, the successor of
/// `watcher/ANALYZE.md`. The text is a repository file
/// (`assets/personas/workflow-review.md`) that `install.sh` copies into
/// `Contents/Resources/personas/`, so it can be edited without a rebuild of the
/// Swift string and read from the bundle at run time.
enum WorkflowReviewPersona {
    static let resourcePath = "assets/personas/workflow-review.md"
    static let bundleResourceName = "personas/workflow-review.md"

    static func load(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// The bundle copy first; the repository file when there is no bundle, so a
    /// development run and the tests read the same text the app ships.
    static func instructions() throws -> String {
        if let bundleURL = Bundle.main.resourceURL?.appendingPathComponent(bundleResourceName),
           FileManager.default.fileExists(atPath: bundleURL.path) {
            return try load(from: bundleURL)
        }
        for root in repositoryRoots() {
            let url = root.appendingPathComponent(resourcePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return try load(from: url)
            }
        }
        throw WorkflowReviewPersonaError.instructionsNotFound(resourcePath)
    }

    private static func repositoryRoots() -> [URL] {
        var roots: [URL] = []
        if let raw = ProcessInfo.processInfo.environment["VOICE_FLOW_REPO_ROOT"], !raw.isEmpty {
            roots.append(URL(fileURLWithPath: raw, isDirectory: true))
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        return roots
    }
}

enum WorkflowReviewPersonaError: Error, Equatable {
    case instructionsNotFound(String)
}
