import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  App-side OpenCode updates
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
//  The runtime never updates itself: `OPENCODE_DISABLE_AUTOUPDATE` stays on
//  and the sandbox denies writes to its own executable, because a process
//  that can rewrite the binary that runs next session has a persistence
//  channel nobody reviews. Voice Flow does the updating instead, outside the
//  sandbox and outside the signed app bundle:
//
//    fetch the release feed → verify the publisher's sha256 for the asset →
//    unpack to a staging dir → check the binary reports the released version →
//    seal it with its own hash → the supervisor prefers it on the next roll.
//
//  The seal is the part that keeps working after the update: every launch
//  re-hashes the staged binary against the manifest written here, so a file
//  edited after staging is refused exactly like a tampered bundle.

struct OpenCodeReleaseAsset: Equatable {
    let version: String
    let assetURL: URL
    /// Lowercase hex sha256 the release feed publishes for the asset.
    let assetSHA256: String
}

struct StagedOpenCodeRuntime: Codable, Equatable {
    let version: String
    let architecture: String
    let binarySHA256: String
    let assetSHA256: String
    let stagedAt: Date
}

enum OpenCodeUpdaterError: LocalizedError {
    case feedUnavailable(String)
    case noAssetForArchitecture(String)
    case missingPublishedDigest(String)
    case digestMismatch(expected: String, actual: String)
    case unpackFailed(String)
    case versionMismatch(expected: String, actual: String)
    case notNewer(candidate: String, current: String)

    var errorDescription: String? {
        switch self {
        case .feedUnavailable(let detail): return "OpenCode release feed unavailable: \(detail)"
        case .noAssetForArchitecture(let arch): return "the release has no \(arch) asset"
        case .missingPublishedDigest(let name): return "\(name) is published without a sha256 digest"
        case .digestMismatch(let expected, let actual):
            return "download digest \(actual) does not match the published \(expected)"
        case .unpackFailed(let detail): return "could not unpack the OpenCode release: \(detail)"
        case .versionMismatch(let expected, let actual):
            return "downloaded binary reports \(actual), release claims \(expected)"
        case .notNewer(let candidate, let current):
            return "\(candidate) is not newer than \(current)"
        }
    }
}

enum OpenCodeVersion {
    static func components(_ raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stripped = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        // A release may carry a suffix ("1.18.14-beta.1"); compare the numbers.
        let core = stripped.split(separator: "-", maxSplits: 1).first.map(String.init) ?? stripped
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            result.append(value)
        }
        return result
    }

    static func normalized(_ raw: String) -> String? {
        components(raw).map { $0.map(String.init).joined(separator: ".") }
    }

    /// Strictly newer, so a yanked release or a hand-edited manifest can never
    /// walk the runtime backwards.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let left = components(candidate), let right = components(current) else { return false }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}

final class OpenCodeUpdater {
    static let shared = OpenCodeUpdater()
    static let feedURL = URL(string: "https://api.github.com/repos/anomalyco/opencode/releases/latest")!
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let manifestName = "staged.json"

    private let session: URLSession
    private let feed: URL
    private let lock = NSLock()
    private var inFlight = false

    init(session: URLSession = .shared, feed: URL = OpenCodeUpdater.feedURL) {
        self.session = session
        self.feed = feed
    }

    static var stagingRoot: URL {
        VoiceFlowPaths.shared.directory("runtime/opencode-staged")
    }

    static var architecture: String {
#if arch(arm64)
        return "arm64"
#else
        return "x86_64"
#endif
    }

    /// Release assets are named by CPU, not by Apple's arch spelling.
    static func assetName(for architecture: String) -> String {
        architecture == "arm64" ? "opencode-darwin-arm64.zip" : "opencode-darwin-x64.zip"
    }

    // ── Feed ────────────────────────────────────────────

    static func parseLatestRelease(_ data: Data, architecture: String) throws -> OpenCodeReleaseAsset {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OpenCodeUpdaterError.feedUnavailable("response was not JSON")
        }
        guard let tag = object["tag_name"] as? String,
              let version = OpenCodeVersion.normalized(tag) else {
            throw OpenCodeUpdaterError.feedUnavailable("release has no usable tag_name")
        }
        let wanted = assetName(for: architecture)
        let assets = object["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { $0["name"] as? String == wanted }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString) else {
            throw OpenCodeUpdaterError.noAssetForArchitecture(architecture)
        }
        // The publisher's own digest is the only integrity claim available:
        // these binaries are ad-hoc signed, so there is no identity to verify.
        guard let digest = asset["digest"] as? String,
              digest.lowercased().hasPrefix("sha256:") else {
            throw OpenCodeUpdaterError.missingPublishedDigest(wanted)
        }
        let hex = String(digest.dropFirst("sha256:".count)).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            throw OpenCodeUpdaterError.missingPublishedDigest(wanted)
        }
        return OpenCodeReleaseAsset(version: version, assetURL: url, assetSHA256: hex)
    }

    // ── Staging ─────────────────────────────────────────

    static func manifestURL(root: URL = OpenCodeUpdater.stagingRoot) -> URL {
        root.appendingPathComponent(manifestName)
    }

    static func binaryURL(root: URL = OpenCodeUpdater.stagingRoot, version: String) -> URL {
        root.appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("opencode")
    }

    static func stagedManifest(root: URL = OpenCodeUpdater.stagingRoot) -> StagedOpenCodeRuntime? {
        guard let data = try? Data(contentsOf: manifestURL(root: root)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(StagedOpenCodeRuntime.self, from: data),
              manifest.architecture == architecture,
              OpenCodeVersion.components(manifest.version) != nil else { return nil }
        return manifest
    }

    /// The staged runtime the supervisor may launch: present, matching this
    /// architecture, and still hashing to what was sealed at staging time.
    static func verifiedStagedBinary(
        root: URL = OpenCodeUpdater.stagingRoot,
        hash: (String) -> String? = OpenCodeUpdater.sha256
    ) -> (path: String, version: String)? {
        guard let manifest = stagedManifest(root: root) else { return nil }
        let binary = binaryURL(root: root, version: manifest.version)
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              let actual = hash(binary.path),
              actual.caseInsensitiveCompare(manifest.binarySHA256) == .orderedSame else {
            return nil
        }
        return (binary.path, manifest.version)
    }

    /// Cheap enough to consult on every connection acquire: reads the small
    /// manifest, never hashes the 100 MB binary.
    static func stagedVersion(root: URL = OpenCodeUpdater.stagingRoot) -> String? {
        stagedManifest(root: root)?.version
    }

    static func sha256(path: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .split(separator: " ").first.map { $0.lowercased() }
    }

    // ── Update flow ─────────────────────────────────────

    /// Returns the newly staged runtime, or nil when already current. Never
    /// touches the running runtime — the supervisor rolls onto the staged
    /// binary on its next acquire, once in-flight turns have drained.
    @discardableResult
    func updateIfAvailable(currentVersion: String) async throws -> StagedOpenCodeRuntime? {
        let claimed = lock.withLock { () -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard claimed else { return nil }
        defer { lock.withLock { inFlight = false } }

        var request = URLRequest(url: feed)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("voice-flow", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OpenCodeUpdaterError.feedUnavailable("HTTP \(http.statusCode)")
        }
        let release = try Self.parseLatestRelease(data, architecture: Self.architecture)
        guard OpenCodeVersion.isNewer(release.version, than: currentVersion) else {
            throw OpenCodeUpdaterError.notNewer(
                candidate: release.version, current: currentVersion)
        }
        return try await stage(release)
    }

    func stage(_ release: OpenCodeReleaseAsset) async throws -> StagedOpenCodeRuntime {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("vf-opencode-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var request = URLRequest(url: release.assetURL)
        request.timeoutInterval = 600
        request.setValue("voice-flow", forHTTPHeaderField: "User-Agent")
        let (downloaded, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OpenCodeUpdaterError.feedUnavailable("asset HTTP \(http.statusCode)")
        }
        let archive = work.appendingPathComponent("opencode.zip")
        try fm.moveItem(at: downloaded, to: archive)

        guard let actualDigest = Self.sha256(path: archive.path) else {
            throw OpenCodeUpdaterError.unpackFailed("could not hash the download")
        }
        guard actualDigest.caseInsensitiveCompare(release.assetSHA256) == .orderedSame else {
            throw OpenCodeUpdaterError.digestMismatch(
                expected: release.assetSHA256, actual: actualDigest)
        }

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw OpenCodeUpdaterError.unpackFailed("ditto exited \(ditto.terminationStatus)")
        }
        guard let binary = Self.locateBinary(in: unpacked) else {
            throw OpenCodeUpdaterError.unpackFailed("no opencode binary inside the archive")
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let reported = try Self.reportedVersion(of: binary.path)
        guard OpenCodeVersion.normalized(reported) == release.version else {
            throw OpenCodeUpdaterError.versionMismatch(
                expected: release.version, actual: reported)
        }
        guard let binaryHash = Self.sha256(path: binary.path) else {
            throw OpenCodeUpdaterError.unpackFailed("could not hash the unpacked binary")
        }

        let root = Self.stagingRoot
        let destinationDirectory = root.appendingPathComponent(release.version, isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent("opencode")
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: binary, to: destination)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        let manifest = StagedOpenCodeRuntime(
            version: release.version, architecture: Self.architecture,
            binarySHA256: binaryHash, assetSHA256: release.assetSHA256,
            stagedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Seal last: a manifest is only ever written for a binary already in
        // place, so a crash mid-stage leaves the previous runtime authoritative.
        try encoder.encode(manifest).write(to: Self.manifestURL(root: root), options: .atomic)
        Self.pruneOldVersions(root: root, keeping: manifest.version)
        return manifest
    }

    static func locateBinary(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in walker where url.lastPathComponent == "opencode" {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    static func reportedVersion(of path: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw OpenCodeUpdaterError.unpackFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw OpenCodeUpdaterError.unpackFailed("--version exited \(process.terminationStatus)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let token = text.split(whereSeparator: { $0.isWhitespace })
            .first { OpenCodeVersion.components(String($0)) != nil }
        guard let token else {
            throw OpenCodeUpdaterError.unpackFailed("--version printed no version")
        }
        return String(token)
    }

    static func pruneOldVersions(root: URL, keeping version: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries where entry.lastPathComponent != version
            && entry.lastPathComponent != manifestName {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
