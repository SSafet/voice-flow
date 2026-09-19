import Foundation

/// The one-time recovery of dictations the newest-200 `dictations.json` forgot:
/// the July backup files in the data folder and any `builtin-dictations` copy
/// under `source-snapshots/` or `legacy/`, wherever the data-source importer has
/// already moved them. `run` is safe to call at every launch because
/// `DictationArchive.importOnce` remembers the files it has read and adds only
/// what the archive does not already hold.
enum LegacyDictationRecovery {
    private static let julyTokens = ["july", "2026-07"]

    static func candidateFiles(root: URL) -> [URL] {
        let files = FileManager.default
        var found: [URL] = []

        var searchDirectories = [root]
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        if files.fileExists(atPath: backups.path) { searchDirectories.append(backups) }
        for directory in searchDirectories {
            let entries = (try? files.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      url.pathExtension == "json" else { continue }
                let name = url.lastPathComponent.lowercased()
                guard name.contains("dictation"),
                      julyTokens.contains(where: { name.contains($0) }) else { continue }
                found.append(url)
            }
        }

        for folder in ["source-snapshots", "legacy"] {
            let base = root.appendingPathComponent(folder, isDirectory: true)
            found.append(contentsOf: builtinCopies(under: base))
        }

        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    @discardableResult
    static func run(root: URL) -> DictationImport {
        DictationArchive.importOnce(from: candidateFiles(root: root), root: root)
    }

    private static func builtinCopies(under base: URL) -> [URL] {
        let files = FileManager.default
        guard let enumerator = files.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.pathExtension == "json",
                  url.lastPathComponent.lowercased().hasPrefix("builtin-dictations") else { continue }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }
}
