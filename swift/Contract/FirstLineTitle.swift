import Foundation

/// The title a new thread gets at once on its home
/// (`packages/thread-protocol/src/first-line-title.ts`): the first non-empty
/// line of the first message, cut at a word boundary at 48 code points.
///
/// Details that keep this copy and the TypeScript one equal on every input:
/// lines are split on LF; a line is trimmed of space, tab and carriage return
/// only; characters are counted as Unicode scalars, which is what
/// `Array.from` walks in TypeScript; the word boundary is the last space
/// inside the cut, and a space at position zero does not count as one.
enum ContractTitle {
    static let firstLineTitleMax = 48
    static let firstLineTitleEmpty = "New thread"

    static func trimLine(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        func isTrimmed(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\r"
        }
        var start = 0
        var end = scalars.count
        while start < end, isTrimmed(scalars[start]) { start += 1 }
        while end > start, isTrimmed(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    static func firstLineTitle(_ text: String) -> String {
        let line = text
            .components(separatedBy: "\n")
            .lazy
            .map(trimLine)
            .first(where: { !$0.isEmpty })
        guard let line else { return firstLineTitleEmpty }
        let points = Array(line.unicodeScalars)
        if points.count <= firstLineTitleMax { return line }
        let cut = Array(points[0..<(firstLineTitleMax - 1)])
        let lastSpace = cut.lastIndex(of: " ")
        let kept: [Unicode.Scalar]
        if let lastSpace, lastSpace > 0 {
            kept = Array(cut[0..<lastSpace])
        } else {
            kept = cut
        }
        return trimLine(String(String.UnicodeScalarView(kept))) + "\u{2026}"
    }
}
