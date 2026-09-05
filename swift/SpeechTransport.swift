import Foundation

/// Pipe callbacks can split a JSON line anywhere, including inside UTF-8.
/// Decode only complete frames so concurrent speech results never disappear.
struct SpeechJSONLines {
    private var pending = Data()
    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            if let line = String(data: pending[..<newline], encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
            pending.removeSubrange(...newline)
        }
        return lines
    }
}

/// The provider can send 200 ms of PCM then pause ~400 ms. Starting on its
/// first packet stutters. Allow 220 ms for that next burst, or start sooner
/// whenever the original 500 ms safety buffer is already available.
enum SpeechStartupPolicy {
    static let graceSeconds = 0.220
    static func canStart(bufferedSeconds: Double, elapsed: Double, complete: Bool) -> Bool {
        complete || bufferedSeconds >= 0.500 || (bufferedSeconds >= 0.200 && elapsed >= graceSeconds)
    }
}
