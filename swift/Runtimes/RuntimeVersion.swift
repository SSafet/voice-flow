import Foundation

/// The supported version range of a runtime (06 §3.6).
///
/// Dotted numbers are compared component by component, never as text, so
/// `0.9.0` is below `0.153.0`. The Codex range is a half-open interval because
/// the app-server protocol is marked experimental by its vendor: a silent
/// protocol change is worse than a refusal. It can be moved for one launch so
/// the refusal is observable on a running system.
struct RuntimeVersionRange: Equatable {
    let minimumInclusive: String
    let maximumExclusive: String

    static let codexDefault = RuntimeVersionRange(
        minimumInclusive: "0.153.0", maximumExclusive: "0.154.0")

    static func codex(environment: [String: String]) -> RuntimeVersionRange {
        RuntimeVersionRange(
            minimumInclusive: environment["VOICE_FLOW_CODEX_VERSION_MIN"] ?? codexDefault.minimumInclusive,
            maximumExclusive: environment["VOICE_FLOW_CODEX_VERSION_MAX"] ?? codexDefault.maximumExclusive)
    }

    func contains(_ version: String) -> Bool {
        guard let numbers = Self.numbers(version) else { return false }
        return Self.compare(numbers, Self.numbers(minimumInclusive) ?? []) >= 0
            && Self.compare(numbers, Self.numbers(maximumExclusive) ?? []) < 0
    }

    /// "0.153.0 or newer and below 0.154.0" — the sentence a refusal carries.
    var text: String { "\(minimumInclusive) or newer and below \(maximumExclusive)" }

    private static func numbers(_ version: String) -> [Int]? {
        guard let token = RuntimeVersionProbe.parse(version) else { return nil }
        let parts = token.split(separator: ".").map { Int($0) ?? 0 }
        return parts.isEmpty ? nil : parts
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

/// Reads a version out of a runtime's own `--version` line.
enum RuntimeVersionProbe {
    /// The first dotted-number token of a line, or nil when there is none.
    static func parse(_ output: String) -> String? {
        guard let range = output.range(of: #"\d+(?:\.\d+)+"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }
}

/// Runs `<binary> --version` once per (path, modification time) and answers
/// from memory afterwards, so a status sweep never spawns a shell storm.
final class RuntimeVersionCache {
    private struct Entry {
        let modified: Date
        let version: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init() {}

    /// A path that does not exist has no version and is not cached, so a later
    /// install is seen on the next ask.
    func version(ofBinaryAt path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        lock.lock()
        if let entry = entries[path], entry.modified == modified {
            lock.unlock()
            return entry.version
        }
        lock.unlock()
        guard let version = Self.run(path) else { return nil }
        guard let modified else { return version }
        lock.lock()
        entries[path] = Entry(modified: modified, version: version)
        lock.unlock()
        return version
    }

    private static func run(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return RuntimeVersionProbe.parse(text)
    }
}
