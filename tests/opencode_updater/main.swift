import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

// ── version ordering ────────────────────────────────────
expect(OpenCodeVersion.isNewer("1.18.14", than: "1.17.11"),
       "a newer release must be recognized")
expect(OpenCodeVersion.isNewer("1.10.0", than: "1.9.9"),
       "version parts are numbers, not strings")
expect(!OpenCodeVersion.isNewer("1.17.11", than: "1.17.11"),
       "the same version is not an update")
expect(!OpenCodeVersion.isNewer("1.17.10", than: "1.17.11"),
       "an older release must never take over — no silent downgrades")
expect(!OpenCodeVersion.isNewer("nightly", than: "1.17.11"),
       "an unparsable tag must not be treated as newer")
expect(OpenCodeVersion.normalized("v1.18.14") == "1.18.14",
       "a v-prefixed tag should normalize")
expect(OpenCodeVersion.normalized("1.18.14-beta.1") == "1.18.14",
       "a pre-release suffix should compare by its numbers")

// ── release feed parsing ────────────────────────────────
func feed(name: String = "opencode-darwin-arm64.zip",
          tag: String = "v1.18.14",
          digest: String? = "sha256:ad8125bb649086eb9210a87bbd27ac453a526e2432aebd4d3c9853e2d42e3291",
          url: String = "https://example.invalid/opencode-darwin-arm64.zip") -> Data {
    var asset: [String: Any] = ["name": name, "browser_download_url": url]
    if let digest { asset["digest"] = digest }
    return try! JSONSerialization.data(withJSONObject: [
        "tag_name": tag,
        "assets": [asset, ["name": "latest.json", "browser_download_url": "https://example.invalid/x"]],
    ])
}

let release = try OpenCodeUpdater.parseLatestRelease(feed(), architecture: "arm64")
expect(release.version == "1.18.14", "release version was not taken from the tag")
expect(release.assetSHA256
        == "ad8125bb649086eb9210a87bbd27ac453a526e2432aebd4d3c9853e2d42e3291",
       "the published digest was not carried through")
expect(OpenCodeUpdater.assetName(for: "x86_64") == "opencode-darwin-x64.zip",
       "the Intel asset is named by CPU, not by Apple's arch spelling")

func rejects(_ data: Data, architecture: String = "arm64", _ message: String) {
    do {
        _ = try OpenCodeUpdater.parseLatestRelease(data, architecture: architecture)
        expect(false, message)
    } catch { }
}
// These binaries are ad-hoc signed, so the publisher's checksum is the only
// integrity claim there is — a release without one must never be installed.
rejects(feed(digest: nil), "an asset with no published digest was accepted")
rejects(feed(digest: "md5:abc"), "a non-sha256 digest was accepted")
rejects(feed(digest: "sha256:not-hex"), "a malformed digest was accepted")
rejects(feed(), architecture: "x86_64", "an arm64-only release was accepted for Intel")
rejects(Data("not json".utf8), "a non-JSON feed was accepted")

// ── the seal on a staged runtime ────────────────────────
let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("vf-updater-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

expect(OpenCodeUpdater.verifiedStagedBinary(root: root, hash: { _ in "x" }) == nil,
       "an empty staging root must not yield a runtime")

let version = "1.18.14"
let binary = OpenCodeUpdater.binaryURL(root: root, version: version)
try FileManager.default.createDirectory(
    at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

func writeManifest(version: String, sha: String, architecture: String = OpenCodeUpdater.architecture) throws {
    let manifest = StagedOpenCodeRuntime(
        version: version, architecture: architecture, binarySHA256: sha,
        assetSHA256: String(repeating: "a", count: 64), stagedAt: Date())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: OpenCodeUpdater.manifestURL(root: root), options: .atomic)
}

try writeManifest(version: version, sha: "sealed")
let resolved = OpenCodeUpdater.verifiedStagedBinary(root: root, hash: { _ in "sealed" })
expect(resolved?.version == version && resolved?.path == binary.path,
       "a sealed staged runtime should be offered to the supervisor")
expect(OpenCodeUpdater.stagedVersion(root: root) == version,
       "the cheap version probe should read the manifest")

// The seal is re-checked on every launch, not just at staging time.
expect(OpenCodeUpdater.verifiedStagedBinary(root: root, hash: { _ in "tampered" }) == nil,
       "a staged binary edited after staging must be refused")

try writeManifest(version: version, sha: "sealed", architecture: "ppc")
expect(OpenCodeUpdater.verifiedStagedBinary(root: root, hash: { _ in "sealed" }) == nil,
       "a runtime staged for another architecture must be refused")

try writeManifest(version: "9.9.9", sha: "sealed")
expect(OpenCodeUpdater.verifiedStagedBinary(root: root, hash: { _ in "sealed" }) == nil,
       "a manifest pointing at a version with no binary must be refused")

try Data("{ not json".utf8).write(to: OpenCodeUpdater.manifestURL(root: root))
expect(OpenCodeUpdater.stagedManifest(root: root) == nil,
       "a corrupt manifest must read as no staged runtime, not a crash")

// ── housekeeping ────────────────────────────────────────
let stale = root.appendingPathComponent("1.17.11", isDirectory: true)
try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
OpenCodeUpdater.pruneOldVersions(root: root, keeping: version)
expect(!FileManager.default.fileExists(atPath: stale.path),
       "a superseded staged version should be pruned")
expect(FileManager.default.fileExists(atPath: binary.path),
       "pruning removed the version it was told to keep")

print("opencode updater tests passed")
