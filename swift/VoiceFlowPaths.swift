import Foundation

/// One source of truth for Voice Flow's writable data locations.
///
/// Production keeps the historical `~/.config/voice-flow` layout. A QA build
/// or test process can set `VOICE_FLOW_CONFIG_ROOT` to an absolute directory
/// before launch, isolating every store from the user's real data.
struct VoiceFlowPaths: Equatable {
    static let configRootEnvironmentKey = "VOICE_FLOW_CONFIG_ROOT"
    static let shared = VoiceFlowPaths()

    let configRoot: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let raw = environment[Self.configRootEnvironmentKey], !raw.isEmpty,
           NSString(string: raw).isAbsolutePath {
            configRoot = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        } else {
            configRoot = homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("voice-flow", isDirectory: true)
                .standardizedFileURL
        }
        try? FileManager.default.createDirectory(
            at: configRoot, withIntermediateDirectories: true)
    }

    var isIsolated: Bool {
        ProcessInfo.processInfo.environment[Self.configRootEnvironmentKey] != nil
    }

    func file(_ name: String) -> URL {
        configRoot.appendingPathComponent(name, isDirectory: false)
    }

    func directory(_ name: String, create: Bool = true) -> URL {
        let url = configRoot.appendingPathComponent(name, isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func contains(_ candidate: URL) -> Bool {
        let root = configRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
}
