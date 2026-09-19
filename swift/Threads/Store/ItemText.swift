import Foundation

/// The contract's text limits and the one cut, in bytes (`06 §3.2`).
///
/// A message, reasoning or a notice is cut at `messageMaxBytes`; a tool call's
/// text at `toolOutputMaxBytes`. Both are counted in UTF-8 bytes over the
/// string's UTF-16 code units, and the cut never halves a character: it is
/// handed to `ContractText.cutText`, which owns that rule, and what it keeps is
/// then passed through `ContractText.cleanText`.
enum ItemText {
    static let messageMaxBytes = 200 * 1024
    static let toolOutputMaxBytes = 32 * 1024

    /// How many of `text`'s UTF-16 code units fit `budgetBytes`, walking the
    /// units in order and adding each one's cost in UTF-8 bytes. A surrogate
    /// pair is one character and costs four bytes as a pair, so the boundary
    /// the count returns never falls between its two halves.
    static func maxUnits(for text: String, budgetBytes: Int) -> Int {
        let units = Array(text.utf16)
        var used = 0
        var counted = 0
        var index = 0
        while index < units.count {
            let width: Int
            let cost: Int
            if ContractText.isHighSurrogate(units[index]),
               index + 1 < units.count,
               ContractText.isLowSurrogate(units[index + 1]) {
                width = 2
                cost = 4
            } else {
                width = 1
                cost = utf8Length(of: units[index])
            }
            guard used + cost <= budgetBytes else { break }
            used += cost
            counted += width
            index += width
        }
        return counted
    }

    /// Cuts first with `ContractText.cutText`, then cleans what was kept, in
    /// that order, and says whether anything was cut. The cut is what
    /// `ContractText.cutText` keeps, never a slice of this function's own.
    static func fit(_ text: String, budgetBytes: Int) -> (kept: String, cut: Bool) {
        let units = maxUnits(for: text, budgetBytes: budgetBytes)
        let cut = units < text.utf16.count
        let kept = ContractText.cleanText(ContractText.cutText(text, maxUnits: units))
        return (kept, cut)
    }

    private static func utf8Length(of unit: UInt16) -> Int {
        if unit < 0x80 { return 1 }
        if unit < 0x800 { return 2 }
        return 3
    }
}
