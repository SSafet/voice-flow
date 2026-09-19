import Foundation

/// The two text rules of the contract that work on UTF-16 code units
/// (`packages/thread-protocol/src/clean-text.ts`, `src/cut-text.ts`).
///
/// They are written on `String.UTF16View` and not on `Character` or
/// `Unicode.Scalar`, because the contract counts UTF-16 code units: one
/// `Character` can be many of them.
enum ContractText {
    static let replacementUnit: UInt16 = 0xFFFD

    /// The first half of a character outside the basic plane.
    static func isHighSurrogate(_ unit: UInt16) -> Bool { unit >= 0xD800 && unit <= 0xDBFF }

    /// The second half of one.
    static func isLowSurrogate(_ unit: UInt16) -> Bool { unit >= 0xDC00 && unit <= 0xDFFF }

    /// Every U+0000 and every lone surrogate becomes U+FFFD; a well-formed pair
    /// is left as it is and nothing else changes. One unit in, one unit out, so
    /// the length in UTF-16 code units never changes and the offsets of a live
    /// delta still agree with the text of the completed item.
    static func cleanUnits(_ units: [UInt16]) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var index = 0
        while index < units.count {
            let unit = units[index]
            if isHighSurrogate(unit), index + 1 < units.count, isLowSurrogate(units[index + 1]) {
                out.append(unit)
                out.append(units[index + 1])
                index += 2
                continue
            }
            out.append(unit == 0 || isHighSurrogate(unit) || isLowSurrogate(unit) ? replacementUnit : unit)
            index += 1
        }
        return out
    }

    /// `cleanText` for text that is already a Swift `String`, which can never
    /// hold a lone surrogate; U+0000 is what this catches.
    static func cleanText(_ text: String) -> String {
        String(decoding: cleanUnits(Array(text.utf16)), as: UTF16.self)
    }

    /// At most `maxUnits` UTF-16 code units, never splitting a surrogate pair:
    /// when the unit that would end the cut is a high surrogate the cut takes
    /// one unit less. It cuts and does nothing else — no cleaning, no trimming,
    /// no ellipsis. A producer cuts first and cleans what it kept.
    static func cutText(_ text: String, maxUnits: Int) -> String {
        guard maxUnits > 0 else { return "" }
        let units = Array(text.utf16)
        if units.count <= maxUnits { return text }
        let end = isHighSurrogate(units[maxUnits - 1]) ? maxUnits - 1 : maxUnits
        return String(decoding: units[0..<end], as: UTF16.self)
    }
}
