import Foundation

/// The one place a thread's git branch is named
/// (`packages/thread-protocol/src/branch-name.ts`):
/// `atika/<title slug>-<last six characters of the thread id, in lower case>`.
///
/// Two details keep this copy and the TypeScript one equal on every input:
/// only the ASCII letters A–Z are lower-cased, with no locale and no Unicode
/// case rules, and a hyphen left at the end by the cut at 40 is trimmed too.
enum ContractBranchName {
    static let branchPrefix = "atika/"
    static let branchSlugMax = 40
    static let branchSlugFallback = "thread"
    static let branchIDSuffixLength = 6

    static func lowerASCII(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            (scalar.value >= 65 && scalar.value <= 90)
                ? Unicode.Scalar(scalar.value + 32)!
                : scalar
        }))
    }

    static func trimHyphens(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, scalars[start] == "-" { start += 1 }
        while end > start, scalars[end - 1] == "-" { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    /// Every run of characters other than a–z and 0–9 becomes one hyphen.
    static func hyphenate(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for scalar in value.unicodeScalars {
            let kept = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if kept {
                out.append(scalar)
                inRun = false
            } else if !inRun {
                out.append("-")
                inRun = true
            }
        }
        return String(out)
    }

    static func threadBranchSlug(_ title: String) -> String {
        let hyphenated = trimHyphens(hyphenate(lowerASCII(title)))
        let cut = trimHyphens(ContractText.cutText(hyphenated, maxUnits: branchSlugMax))
        return cut.isEmpty ? branchSlugFallback : cut
    }

    static func threadBranchName(title: String, threadId: String) -> String {
        let units = Array(threadId.utf16)
        let tail = units.count <= branchIDSuffixLength
            ? units
            : Array(units[(units.count - branchIDSuffixLength)...])
        return branchPrefix
            + threadBranchSlug(title)
            + "-"
            + lowerASCII(String(decoding: tail, as: UTF16.self))
    }
}
