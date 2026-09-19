import Foundation

/// VoiceFlow's tools written into OpenCode's redirected settings folder
/// (06 §3.6), once per server start and never anywhere else.
///
/// The tool sources stay where they are generated today; only where they are
/// written changes. A generated file carries this server's token, so it must
/// never land in a project or a persona folder, where it would be committed.
enum OpenCodeLaunch {
    /// `<configHome>/opencode/tools` — where OpenCode scans its own settings.
    static func toolsDirectory(configHome: URL) -> URL {
        configHome.appendingPathComponent("opencode/tools", isDirectory: true)
    }

    /// Writes the tools, replacing the folder as one step so a second start
    /// leaves exactly this start's tools with this start's token.
    @discardableResult
    static func writeToolFiles(endpoint: URL, token: String, configHome: URL) throws -> [String] {
        let manager = FileManager.default
        let staging = configHome.appendingPathComponent(
            ".opencode-tools-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try AgentToolProjection(endpoint: endpoint, token: token).project(into: staging)
        let generated = staging.appendingPathComponent(".opencode/tools", isDirectory: true)
        let names = try manager.contentsOfDirectory(atPath: generated.path).sorted()

        let target = toolsDirectory(configHome: configHome)
        let parent = target.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let previous = parent.appendingPathComponent("tools-previous-\(UUID().uuidString)")
        let existed = manager.fileExists(atPath: target.path)
        if existed { try manager.moveItem(at: target, to: previous) }
        do {
            try manager.moveItem(at: generated, to: target)
            if existed { try? manager.removeItem(at: previous) }
        } catch {
            if existed { try? manager.moveItem(at: previous, to: target) }
            throw error
        }
        return names
    }
}
