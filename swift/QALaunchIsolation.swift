import Foundation

/// No paths, logging, app delegates or other singletons may be initialized
/// before this check in a QA executable. Finder/LaunchServices can relaunch a
/// signed bundle without inheriting the test harness's environment.
enum QALaunchIsolation {
    struct Refusal: LocalizedError {
        let errorDescription: String?
    }

    static func validate(environment: [String: String] = ProcessInfo.processInfo.environment,
                         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let raw = environment["VOICE_FLOW_CONFIG_ROOT"], !raw.isEmpty,
              NSString(string: raw).isAbsolutePath,
              !raw.split(separator: "/").contains("..") else {
            throw Refusal(errorDescription: "Voice Flow QA requires an explicit absolute VOICE_FLOW_CONFIG_ROOT. No app services were started.")
        }
        let root = try resolvedPath(URL(fileURLWithPath: raw, isDirectory: true))
        let daily = try resolvedPath(homeDirectory.appendingPathComponent(".config/voice-flow", isDirectory: true))
        func contains(_ parent: String, _ child: String) -> Bool {
            parent == "/" || child == parent || child.hasPrefix(parent + "/")
        }
        guard !contains(root, daily), !contains(daily, root) else {
            throw Refusal(errorDescription: "Voice Flow QA refuses a configuration root that overlaps the daily app's data. No app services were started.")
        }
        for key in ["VOICE_FLOW_QA_PORT", "VOICE_FLOW_QA_SYNC_PORT"] {
            if let raw = environment[key] {
                guard let port = Int(raw), (1024...65535).contains(port), ![8792, 8793].contains(port) else {
                    throw Refusal(errorDescription: "Voice Flow QA requires valid ports distinct from the daily app. No app services were started.")
                }
            }
        }
        let control = environment["VOICE_FLOW_QA_PORT"] ?? "18792"
        let sync = environment["VOICE_FLOW_QA_SYNC_PORT"] ?? "18793"
        guard Int(control) != Int(sync) else {
            throw Refusal(errorDescription: "Voice Flow QA control and sync ports must differ. No app services were started.")
        }
    }

    private static func resolvedPath(_ input: URL) throws -> String {
        // Foundation does not resolve a symlink when the final child does not
        // exist. Resolve the nearest existing ancestor, then append that tail.
        var ancestor = input.standardizedFileURL
        var missing: [String] = []
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            // A dangling symlink could lead into a not-yet-created daily child.
            // Refuse it instead of guessing the eventual filesystem location.
            if (try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw Refusal(errorDescription: "Voice Flow QA refuses a configuration root through a dangling symlink. No app services were started.")
            }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { resolved.appendPathComponent(component, isDirectory: true) }
        return resolved.standardizedFileURL.path
    }
}
