import Foundation

public func renderTable(_ rows: [ProofRow], title: String) -> String {
    let checks = rows.filter { $0.kind == .check }
    let notes = rows.filter { $0.kind == .observation }
    let width = max(rows.map { $0.name.count }.max() ?? 10, 10)

    var out = "\n\(title)\n\n"
    out += "CHECKS\n"
    for row in checks {
        let mark = (row.passed ?? false) ? "pass" : "FAIL"
        out += "  \(mark)  \(row.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(row.detail)\n"
    }
    if !notes.isEmpty {
        out += "\nOBSERVATIONS\n"
        for row in notes {
            out += "  note  \(row.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(row.detail)\n"
        }
    }
    let failed = checks.filter { ($0.passed ?? false) == false }
    out += "\n\(checks.count - failed.count) of \(checks.count) checks passed"
    out += failed.isEmpty ? ".\n" : ", failed: \(failed.map(\.name).joined(separator: ", ")).\n"
    return out
}

public func allChecksPassed(_ rows: [ProofRow]) -> Bool {
    let checks = rows.filter { $0.kind == .check }
    return !checks.isEmpty && checks.allSatisfy { $0.passed == true }
}
