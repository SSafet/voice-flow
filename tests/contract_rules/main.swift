import Foundation

// The four pure rules of the thread protocol, against the contract's own
// fixture files. The fixtures are read from the repository by path, because
// this suite is compiled by scripts/test-agent-harness.sh and not by Swift
// Package Manager, so there is no resource bundle to ask.

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tests/contract_rules
    .deletingLastPathComponent()   // tests
    .deletingLastPathComponent()   // the repository
let rulesFolder = repositoryRoot
    .appendingPathComponent("contract-fixtures/thread-protocol/rules", isDirectory: true)

var failures: [String] = []
var ran = 0

func check(_ what: String, _ got: String, _ expected: String) {
    ran += 1
    if got != expected {
        failures.append("\(what): \(got.debugDescription) is not \(expected.debugDescription)")
    }
}

func load<T: Decodable>(_ name: String, _ type: T.Type) -> T {
    let file = rulesFolder.appendingPathComponent(name, isDirectory: false)
    do {
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
    } catch {
        FileHandle.standardError.write(Data("not ok - \(name): \(error)\n".utf8))
        exit(1)
    }
}

struct RuleFile<Case: Decodable>: Decodable { let rule: String; let cases: [Case] }
struct BranchCase: Decodable { let title: String; let threadId: String; let expected: String }
struct TitleCase: Decodable { let text: String; let expected: String }
struct CutCase: Decodable { let name: String; let text: String; let maxUnits: Int; let expected: String }
struct CleanCase: Decodable { let text: String; let expected: String }
struct CleanUnitCase: Decodable { let name: String; let textUnits: [UInt16]; let expectedUnits: [UInt16] }
struct CleanFile: Decodable { let rule: String; let cases: [CleanCase]; let unitCases: [CleanUnitCase] }

let branches = load("branch-names.json", RuleFile<BranchCase>.self)
precondition(!branches.cases.isEmpty, "branch-names.json has no cases")
for item in branches.cases {
    check(
        "threadBranchName(\(item.title.debugDescription), \(item.threadId))",
        ContractBranchName.threadBranchName(title: item.title, threadId: item.threadId),
        item.expected
    )
}

let titles = load("first-line-titles.json", RuleFile<TitleCase>.self)
precondition(!titles.cases.isEmpty, "first-line-titles.json has no cases")
for item in titles.cases {
    check(
        "firstLineTitle(\(item.text.debugDescription))",
        ContractTitle.firstLineTitle(item.text),
        item.expected
    )
}

let cuts = load("cut-text.json", RuleFile<CutCase>.self)
precondition(!cuts.cases.isEmpty, "cut-text.json has no cases")
for item in cuts.cases {
    check("cutText(\(item.name))", ContractText.cutText(item.text, maxUnits: item.maxUnits), item.expected)
}

let cleans = load("clean-text.json", CleanFile.self)
precondition(!cleans.cases.isEmpty && !cleans.unitCases.isEmpty, "clean-text.json has no cases")
for item in cleans.cases {
    check("cleanText(\(item.text.debugDescription))", ContractText.cleanText(item.text), item.expected)
}
// A Swift String cannot hold a lone surrogate, so those cases are given as
// UTF-16 code units and the rule is applied to units.
for item in cleans.unitCases {
    ran += 1
    let got = ContractText.cleanUnits(item.textUnits)
    if got != item.expectedUnits {
        failures.append("cleanUnits(\(item.name)): \(got) is not \(item.expectedUnits)")
    }
}

// The rules must be able to disagree; a test that only ever compares equal
// values would pass against an empty implementation.
precondition(
    ContractBranchName.threadBranchName(title: "Fix cart", threadId: "01J8ZK3F9A2C") != "atika/",
    "the branch-name rule returns something"
)

if failures.isEmpty {
    print("contract rules: \(ran) cases, all match")
    exit(0)
}
for failure in failures { FileHandle.standardError.write(Data("not ok - \(failure)\n".utf8)) }
FileHandle.standardError.write(Data("contract rules: \(failures.count) of \(ran) cases do not match\n".utf8))
exit(1)
