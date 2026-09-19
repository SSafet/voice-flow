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
        let target = toolsDirectory(configHome: configHome)
        let parent = target.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".tools-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        for (name, source) in AgentToolProjection(endpoint: endpoint, token: token).sources() {
            try Data(source.utf8).write(
                to: staging.appendingPathComponent("\(name).ts"), options: [.atomic])
        }
        let names = try manager.contentsOfDirectory(atPath: staging.path).sorted()

        let previous = parent.appendingPathComponent("tools-previous-\(UUID().uuidString)")
        let existed = manager.fileExists(atPath: target.path)
        if existed { try manager.moveItem(at: target, to: previous) }
        do {
            try manager.moveItem(at: staging, to: target)
            if existed { try? manager.removeItem(at: previous) }
        } catch {
            if existed { try? manager.moveItem(at: previous, to: target) }
            throw error
        }
        return names
    }
}
