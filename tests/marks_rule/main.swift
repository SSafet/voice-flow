import Foundation

// The one Swift copy of the contract's Mark rule (07 §3.7), held to the
// contract's own fixture file so the two checks cannot drift apart. The zod
// source checks which optional fields each kind requires; a generated Swift
// type cannot, so `MarkRule` carries that rule here and `OverlayService` uses
// it. A valid mark must decode and be accepted; an invalid mark must either
// fail to decode or be refused by the rule.

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tests/marks_rule
    .deletingLastPathComponent()   // tests
    .deletingLastPathComponent()   // the repository
let fixtureURL = repositoryRoot
    .appendingPathComponent("contract-fixtures/thread-protocol/rules/marks.json")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}

func decode(_ object: Any) -> TPMark? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(TPMark.self, from: data)
}

guard let fixture = (try? JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))) as? [String: Any] else {
    fail("the contract fixture \(fixtureURL.path) is readable JSON")
}
guard let valid = fixture["valid"] as? [Any], let invalid = fixture["invalid"] as? [Any] else {
    fail("the fixture carries a valid list and an invalid list")
}
guard valid.count == 9 else { fail("the fixture carries 9 valid marks, not \(valid.count)") }
guard invalid.count == 16 else { fail("the fixture carries 16 invalid marks, not \(invalid.count)") }

// Every valid mark decodes and the rule accepts it.
var validCount = 0
for (index, object) in valid.enumerated() {
    guard let mark = decode(object) else {
        fail("valid mark \(index + 1) decodes with TPMark")
    }
    if let problem = MarkRule.problem(mark) {
        fail("valid mark \(index + 1) is accepted; MarkRule says: \(problem)")
    }
    validCount += 1
}

// Every invalid mark is refused: by decoding (a missing or ill-typed field) or
// by the rule (an optional field the kind requires, or a number out of range).
var refusedByRule = 0
for (index, entry) in invalid.enumerated() {
    guard let entry = entry as? [String: Any], let raw = entry["mark"] else {
        fail("invalid mark \(index + 1) carries a mark object")
    }
    let reason = entry["reason"] as? String ?? "no reason"
    guard let mark = decode(raw) else { continue }   // refused by the type itself
    guard MarkRule.problem(mark) != nil else {
        fail("invalid mark \(index + 1) (\(reason)) is refused")
    }
    refusedByRule += 1
}

// A rule that could not refuse anything would make the loop above vacuous; at
// least the eight refinement cases (arrow/line/pen/highlight/badge/text and the
// box shape and range cases) have to come from the rule and not from decoding.
guard refusedByRule >= 6 else {
    fail("at least six invalid marks are refused by MarkRule itself, not by decoding: \(refusedByRule)")
}

// Problems carry the mark's own number, because `screen_draw` reports them that
// way (07 §3.8).
let firstValid = decode(valid[0])!
let refinementCases = invalid.compactMap { entry -> TPMark? in
    guard let entry = entry as? [String: Any], let raw = entry["mark"] else { return nil }
    return decode(raw)
}
let refused = MarkRule.problems([firstValid] + refinementCases)
guard !refused.isEmpty else { fail("problems are reported for the refused marks") }
guard refused.contains(where: { $0.message.contains("from") }) else {
    fail("the refusals carry their reasons: \(refused.map(\.message))")
}

// A text mark with a note longer than the contract allows is refused by the
// rule, because the generator cannot carry `max(2000)` into Swift's type.
let textMark = TPMark(
    box: [0, 0, 100, 20], center: nil, color: .red, from: nil, kind: .text, label: nil, n: 1,
    note: String(repeating: "x", count: 2_001), origin: [0, 0], points: nil, stroke: 2, to: nil,
    underText: nil)
guard MarkRule.problem(textMark) != nil else {
    fail("a note longer than 2000 characters is refused")
}

print("mark rule: \(validCount) valid accepted, \(invalid.count) invalid refused (\(refusedByRule) by the rule)")
