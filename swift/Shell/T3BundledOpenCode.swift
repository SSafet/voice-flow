import Foundation
import CryptoKit

/// The native package selects T3's existing OpenCode binaryPath setting. T3
/// verifies the same release hash again when it creates the provider driver.
struct T3BundledOpenCode {
    let executable: URL

    init(bundle: Bundle = .main) throws {
        guard let resources = bundle.resourceURL else { throw T3EnvironmentProcessError.invalidArtifact }
        let root = resources.appendingPathComponent("Runtime/OpenCode", isDirectory: true)
        let binary = root.appendingPathComponent("opencode")
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path,
              binary.standardizedFileURL.path == binary.resolvingSymlinksInPath().path,
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw T3EnvironmentProcessError.invalidArtifact
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: binary.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw T3EnvironmentProcessError.invalidArtifact
        }
        struct Manifest: Decodable {
            struct Asset: Decodable { let binarySHA256: String }
            let version: String
            let assets: [String: Asset]
        }
        struct Receipt: Decodable {
            let version: String
            let architecture: String
            let sourceBinarySHA256: String
            let installedBinarySHA256: String
        }
        let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("versions.json")))
        let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: root.appendingPathComponent("installed.json")))
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard let manifest, let receipt, manifest.version == "2.0.12",
              receipt.version == manifest.version, receipt.architecture == architecture,
              let expected = manifest.assets[architecture]?.binarySHA256,
              receipt.sourceBinarySHA256 == expected,
              receipt.installedBinarySHA256 == expected,
              Self.digest(binary) == expected else { throw T3EnvironmentProcessError.invalidArtifact }
        executable = binary
    }

    private static func digest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }

    /// Called only while T3EnvironmentProcess owns the isolated home lock.
    func configure(home: URL) throws {
        try Self.configure(home: home, executable: executable)
    }

    /// Kept separate from bundle verification so persistence can be exercised
    /// with a synthetic path without creating or launching an OpenCode process.
    static func configure(home: URL, executable: URL) throws {
        let state = home.appendingPathComponent("userdata", isDirectory: true)
        let settingsURL = state.appendingPathComponent("settings.json")
        let managedURL = state.appendingPathComponent("native-opencode-runtime.json")
        let manager = FileManager.default
        try manager.createDirectory(at: state, withIntermediateDirectories: true)
        var settings: [String: Any] = [:]
        if manager.fileExists(atPath: settingsURL.path) {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))
            guard let object = value as? [String: Any] else { throw T3EnvironmentProcessError.invalidRuntimeState }
            settings = object
        }
        let previousManagedPath: String? = {
            guard let data = try? Data(contentsOf: managedURL),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
            return value["binaryPath"]
        }()
        func isManaged(_ value: Any?) -> Bool {
            guard let path = value as? String else { return value == nil }
            return path.isEmpty || path == "opencode" || path == previousManagedPath
        }
        var changed = false
        var providers = settings["providers"] as? [String: Any] ?? [:]
        if settings["providers"] != nil && settings["providers"] as? [String: Any] == nil {
            throw T3EnvironmentProcessError.invalidRuntimeState
        }
        var openCode = providers["opencode"] as? [String: Any] ?? [:]
        if providers["opencode"] != nil && providers["opencode"] as? [String: Any] == nil {
            throw T3EnvironmentProcessError.invalidRuntimeState
        }
        if isManaged(openCode["binaryPath"]) && (openCode["binaryPath"] as? String) != executable.path {
            openCode["binaryPath"] = executable.path
            changed = true
        }
        if openCode["enabled"] == nil {
            openCode["enabled"] = true
            changed = true
        }
        providers["opencode"] = openCode
        settings["providers"] = providers

        if var instances = settings["providerInstances"] as? [String: Any] {
            for (id, raw) in instances {
                guard var instance = raw as? [String: Any], instance["driver"] as? String == "opencode" else { continue }
                guard var config = instance["config"] as? [String: Any] ?? (instance["config"] == nil ? [:] : nil) else { continue }
                if isManaged(config["binaryPath"]) && (config["binaryPath"] as? String) != executable.path {
                    config["binaryPath"] = executable.path
                    instance["config"] = config
                    instances[id] = instance
                    changed = true
                }
            }
            settings["providerInstances"] = instances
        } else if settings["providerInstances"] != nil {
            throw T3EnvironmentProcessError.invalidRuntimeState
        }
        if changed {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
        }
        // The receipt identifies only fields this native package wrote. A user
        // selection that differs from it stays untouched on later app updates.
        let receipt = try JSONSerialization.data(withJSONObject: ["binaryPath": executable.path], options: [.sortedKeys])
        try receipt.write(to: managedURL, options: .atomic)
    }
}
