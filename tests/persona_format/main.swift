import Foundation

// The persona format (11-personas.md §3.1–§3.3, 06-voiceflow-mac.md §3.4):
// the YAML header read with Yams, the slug and length rules, the folder reader
// with its link boundary, and the checker every persona store must agree with.
// The last section is the build check K5 asks for: for every fixture personas
// root under contract-fixtures/personas/folders, the store produces exactly the
// records and issues of the expected.json beside it.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("ok   \(message)")
    } else {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

// ── temporary folders ────────────────────────────────────

private func makeRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("voice-flow-persona-format-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

// ── the slug rule (11 §3.5; K5 decision 16) ──────────────
// K5's fixtures/rules/slugs.json is the contract: both homes give the same name
// the same slug, so the cases are read from the copied file, never re-typed here.

private struct SlugCase: Decodable { let name: String; let taken: [String]; let slug: String }
private struct SlugFixture: Decodable { let rule: String; let cases: [SlugCase] }

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tests/persona_format
    .deletingLastPathComponent()   // tests
    .deletingLastPathComponent()   // repository root
let personaFixturesRoot = repositoryRoot
    .appendingPathComponent("contract-fixtures/personas", isDirectory: true)

let slugFixtureURL = personaFixturesRoot.appendingPathComponent("rules/slugs.json")
guard let slugData = try? Data(contentsOf: slugFixtureURL),
      let slugFixture = try? JSONDecoder().decode(SlugFixture.self, from: slugData) else {
    fputs("FAIL: \(slugFixtureURL.path) is missing or does not decode as {rule, cases}; "
          + "the copy script must carry K5's rule fixtures\n", stderr)
    exit(1)
}
expect(slugFixture.cases.count >= 11,
       "the slug fixture carries K5's cases, found \(slugFixture.cases.count)")
expect(slugFixture.rule.contains("persona"), "the fixture names the slug rule")
for item in slugFixture.cases {
    let slug = PersonaFormat.slug(fromName: item.name, taken: Set(item.taken))
    expect(slug == item.slug, "slug(\(item.name.debugDescription)) == \(item.slug), got \(slug)")
    expect(PersonaFormat.isSlug(slug), "slug(\(item.name.debugDescription)) is a valid slug")
    expect(!item.taken.contains(slug), "slug(\(item.name.debugDescription)) is not already taken")
}
expect(PersonaFormat.isSlug("flora"), "plain slug accepted")
expect(!PersonaFormat.isSlug("Flora"), "uppercase refused")
expect(!PersonaFormat.isSlug("a--b"), "double hyphen refused")
expect(!PersonaFormat.isSlug("-a"), "leading hyphen refused")
expect(!PersonaFormat.isSlug("a-"), "trailing hyphen refused")
expect(!PersonaFormat.isSlug("a_b"), "underscore refused")
expect(!PersonaFormat.isSlug(String(repeating: "a", count: 65)), "over-long slug refused")
expect(PersonaFormat.isReservedFolderName(".trash"), ".trash is reserved")
expect(PersonaFormat.isReservedFolderName("_drafts"), "_drafts is reserved")
expect(!PersonaFormat.isReservedFolderName("flora"), "flora is not reserved")

// ── lengths count UTF-16 code units and never split a pair ─
// The cut is the contract package's own rule, already in Swift as
// ContractText.cutText (K8); this package declares no second cut.

expect(ContractText.cutText("abcdef", maxUnits: 4) == "abcd", "cuts at the unit count")
expect(ContractText.cutText("abc", maxUnits: 4) == "abc", "short text is unchanged")
expect(ContractText.cutText("abc\u{1F600}", maxUnits: 4) == "abc",
       "a cut never leaves half a surrogate pair")
expect(ContractText.cutText("ab\u{1F600}", maxUnits: 4) == "ab\u{1F600}",
       "a whole pair inside the limit is kept")
expect(PersonaFormat.sha256Hex(Data()) ==
       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
       "SHA-256 of no bytes")

// ── the front matter (Yams; K5 decisions 2, 3, 11, 17) ───

let simple = PersonaFrontMatter.parse("""
---
name: FLORA
description: organizes thoughts
---
You are FLORA.
""")
if case .success(let document) = simple {
    expect(document.fields["name"] == .text("FLORA"), "name is read as text")
    expect(document.fields["description"] == .text("organizes thoughts"), "description is read")
    expect(document.body == "You are FLORA.", "body follows the closing line")
} else {
    expect(false, "a well-formed file parses")
}

let typed = PersonaFrontMatter.parse("---\nname: 007\nflag: No\nmodel: null\nvoice:\n---\nBody")
if case .success(let document) = typed {
    expect(document.fields["name"] == .text("007"), "007 is the text 007, not the number 7")
    expect(document.fields["flag"] == .text("No"), "No is the text No, not a boolean")
    expect(document.fields["model"] == .text("null"), "null is the text null, not nil")
    expect(document.fields["voice"] == .text(""), "an empty value is the empty text")
} else {
    expect(false, "typed scalars parse")
}

let rich = PersonaFrontMatter.parse("""
---
name: "Quoted: name"
description: >-
  folded text
  second line
skills:
  - a
  - b
unknown_key: kept
---
Body
""")
if case .success(let document) = rich {
    expect(document.fields["name"] == .text("Quoted: name"), "a quoted scalar is read, colon and all")
    expect(document.fields["description"] == .text("folded text second line"), "a folded scalar is read")
    expect(document.fields["skills"] == .list(["a", "b"]), "a YAML list is read as a list")
    expect(document.fields["unknown_key"] == .text("kept"), "an unknown key is kept")
} else {
    expect(false, "quoted, folded and list values parse")
}

let crlf = PersonaFrontMatter.parse("---\r\nname: FLORA\r\nvoice: nova\r\n---\r\nBody\r\n")
if case .success(let document) = crlf {
    expect(document.fields["name"] == .text("FLORA"), "CRLF headers parse")
    expect(document.fields["voice"] == .text("nova"), "CRLF values carry no carriage return")
} else {
    expect(false, "CRLF header parses")
}

let lopsided = PersonaFrontMatter.parse("---\nname: A\n----\n ---\nBody")
if case .failure(let problem) = lopsided {
    expect(problem == .noClosingLine, "a longer run of dashes is not a closing line")
} else {
    expect(false, "an unclosed header is refused")
}
expect(PersonaFrontMatter.parse("name: A\n---\nBody") == .failure(.noOpeningLine),
       "a missing opening line is named")
expect(PersonaFrontMatter.parse("---\nname: A\nBody") == .failure(.noClosingLine),
       "a missing closing line is named")
if case .failure(let problem) = PersonaFrontMatter.parse("---\n- a\n- b\n---\nBody") {
    expect(problem == .notAMapping, "a list in place of keys is refused")
} else {
    expect(false, "a list in place of keys is refused")
}
if case .failure(let problem) = PersonaFrontMatter.parse("---\njust text\n---\nBody") {
    expect(problem == .notAMapping, "plain text in place of keys is refused")
} else {
    expect(false, "plain text in place of keys is refused")
}
for bad in ["---\nname: A\nname: B\n---\n", "---\nname: [unclosed\n---\n"] {
    if case .failure(let problem) = PersonaFrontMatter.parse(bad) {
        expect(problem == .invalidYAML, "an invalid mapping is invalid_yaml: \(bad.debugDescription)")
    } else {
        expect(false, "an invalid mapping is refused: \(bad.debugDescription)")
    }
}

// Rewriting keeps unknown keys and key order (decision 17).
let rewritten = PersonaFrontMatter.updateHeader(
    "---\nname: FLORA\ndescription: old\nsources: a, b\n---\nBody\n",
    values: [("name", "FLORA"), ("description", "new")])
expect(rewritten.contains("sources: a, b"), "an unknown key survives a rewrite")
expect(rewritten.contains("description: new"), "a known key takes its new value")
expect(rewritten.contains("Body"), "the body survives a rewrite")

// ── header reading (11 §3.1) ─────────────────────────────

private func header(_ text: String) -> Result<PersonaHeader, PersonaHeaderRead.Problem> {
    switch PersonaFrontMatter.parse(text) {
    case .success(let document): return PersonaHeaderRead.read(document)
    case .failure(let problem): return .failure(.keyInvalid(key: "persona.md", detail: problem.rawValue))
    }
}

if case .success(let read) = header("---\nname: FLORA\nskills: a, b\ndelegates: [x, y]\n---\nB") {
    expect(read.name == "FLORA", "the header name is read")
    expect(read.skills == ["a", "b"], "a comma-separated skills value is read")
    expect(read.delegates == ["x", "y"], "a YAML list delegates value is read")
} else {
    expect(false, "a complete header reads")
}
// The seven keys of 06 §3.4: the effort key is spelled `effort` in the file and
// is the record's reasoningEffort.
if case .success(let read) = header(
    "---\nname: FLORA\ndescription: d\nvoice: nova\nmodel: openrouter/x\neffort: high\n---\nB") {
    expect(read.description == "d", "the description is read")
    expect(read.voice == "nova", "the voice is read")
    expect(read.model == "openrouter/x", "the model is read")
    expect(read.effort == "high", "the header key is `effort`")
    expect(read.skills == nil, "an absent skills key is absent, not an empty list")
    expect(read.delegates == nil, "an absent delegates key is absent, not an empty list")
} else {
    expect(false, "a header with description, voice, model and effort reads")
}
if case .failure(let problem) = header("---\ndescription: no name\n---\nBody") {
    expect(problem == .nameMissing, "a header without a name is name_missing")
} else {
    expect(false, "a header without a name is refused")
}
if case .failure(let problem) = header("---\nname: FLORA\ndescription:\n  - not a string\n---\nBody") {
    if case .keyInvalid(let key, _) = problem {
        expect(key == "description", "a description of the wrong shape names the key")
    } else {
        expect(false, "a description of the wrong shape is key_invalid")
    }
} else {
    expect(false, "a description of the wrong shape is refused")
}
if case .failure(let problem) = header("---\nname: \(String(repeating: "a", count: 65))\n---\nB") {
    if case .keyInvalid(let key, _) = problem {
        expect(key == "name", "an over-long name names the key")
    } else {
        expect(false, "an over-long name is key_invalid")
    }
} else {
    expect(false, "an over-long name is refused")
}

// ── the folder reader and the checker (11 §3.3 item 1) ───

let readerRoot = makeRoot()
let floraFile = "---\nname: FLORA\nmodel: openrouter/x\neffort: high\n---\nYou are FLORA.\n"
write(floraFile, to: readerRoot.appendingPathComponent("flora/persona.md"))
write("core facts\n", to: readerRoot.appendingPathComponent("flora/memory/core.md"))
write("---\nname: tickets\ndescription: file tickets\n---\nBody\n",
      to: readerRoot.appendingPathComponent("flora/skills/tickets/SKILL.md"))
write("not a persona\n", to: readerRoot.appendingPathComponent("My Persona/persona.md"))
write("ignored\n", to: readerRoot.appendingPathComponent(".trash/old/persona.md"))
try? Data("outside\n".utf8).write(to: readerRoot.appendingPathComponent("outside.txt"))
// memory/ledger.md is a link out of the persona folder, and nothing else wrote
// that path first, so the link is really there.
let ledgerLink = readerRoot.appendingPathComponent("flora/memory/ledger.md")
try? FileManager.default.createSymbolicLink(
    at: ledgerLink, withDestinationURL: readerRoot.appendingPathComponent("outside.txt"))
expect((try? FileManager.default.destinationOfSymbolicLink(atPath: ledgerLink.path)) != nil,
       "the escaping link of this test was created")

let readerSnapshot = PersonaRootReader.read(root: readerRoot)
expect(readerSnapshot.personas.map(\.slug) == ["flora"],
       "only slug-named folders are personas, found \(readerSnapshot.personas.map(\.slug))")
expect(readerSnapshot.invalidFolderNames == ["My Persona"],
       "a folder that is not a slug is reported, not dropped")
expect(readerSnapshot.personas.first?.escapedPaths == ["memory/ledger.md"],
       "a link that leaves the persona folder is recorded")

let readerCheck = PersonaChecker.check(readerSnapshot,
    input: PersonaChecker.Input(homeId: "home-test", defaultPersonaId: "flora"))
guard let flora = readerCheck.records.first(where: { $0.id == "flora" }) else {
    expect(false, "the checker produced a record for flora")
    fputs("\(failures) persona format checks failed\n", stderr)
    exit(1)
}
expect(!flora.usable, "a link that leaves the folder makes the persona unusable")
expect(flora.issues.contains { $0.code == PersonaIssueCode.symlinkEscape },
       "the symlink_escape issue is reported")
expect(flora.revision == PersonaFormat.sha256Hex(Data(floraFile.utf8)),
       "the revision is the hash of persona.md's bytes")
expect(flora.isDefault, "the home's default persona is marked isDefault")
expect(flora.homeID == "home-test", "the record carries the home id")
expect(flora.version == 1, "the checker produces the first version")
expect(flora.deletedAt == nil, "the checker produces no deletedAt")
expect(flora.model == "openrouter/x", "the record carries the header's model")
expect(flora.reasoningEffort == "high", "the header's effort is the record's reasoningEffort")
expect(flora.coreMemory == "core facts\n", "the record carries memory/core.md")
// No skills key: every valid skill folder is active (06 §3.4).
expect(flora.skills.map(\.name) == ["tickets"],
       "a persona with no skills key gets every valid skill folder, got \(flora.skills.map(\.name))")
expect(flora.skills.first?.description == "file tickets",
       "the active skill carries the description of its SKILL.md")

// A persona folder with no persona.md is frontmatter_invalid, not a silent skip.
let missingRoot = makeRoot()
write("x\n", to: missingRoot.appendingPathComponent("ghost/memory/core.md"))
let missingCheck = PersonaChecker.check(PersonaRootReader.read(root: missingRoot),
    input: PersonaChecker.Input(homeId: "home-test", defaultPersonaId: nil))
expect(missingCheck.records.count == 1, "a folder without persona.md is still a persona")
expect(missingCheck.records.first?.issues.contains { $0.code == PersonaIssueCode.frontmatterInvalid } == true,
       "a folder without persona.md is frontmatter_invalid")

// Duplicate names are reported on every persona that shares the name, and the
// name is unique without regard to letter case (06 §3.4).
let duplicateRoot = makeRoot()
write("---\nname: FLORA\n---\nA\n", to: duplicateRoot.appendingPathComponent("flora/persona.md"))
write("---\nname: flora\n---\nB\n", to: duplicateRoot.appendingPathComponent("flora-2/persona.md"))
let duplicateCheck = PersonaChecker.check(PersonaRootReader.read(root: duplicateRoot),
    input: PersonaChecker.Input(homeId: "home-test", defaultPersonaId: nil))
expect(duplicateCheck.records.count == 2, "both folders are personas")
expect(duplicateCheck.records.allSatisfy { record in
    record.issues.contains { $0.code == PersonaIssueCode.nameDuplicate }
}, "every persona sharing a name, whatever its letter case, is name_duplicate")
expect(duplicateCheck.records.allSatisfy { !$0.usable },
       "name_duplicate makes both personas unusable")
expect(duplicateCheck.records.map(\.id) == ["flora", "flora-2"],
       "records come in UTF-8 order of the slug, got \(duplicateCheck.records.map(\.id))")

// ── the build check: every K5 fixture folder ─────────────

struct FixtureInput: Decodable { let homeId: String; let defaultPersonaId: String? }
struct FixtureExpectation: Decodable {
    let input: FixtureInput
    let records: [TPPersona]
    let invalidFolderNames: [String]
}

let fixturesRoot = personaFixturesRoot.appendingPathComponent("folders", isDirectory: true)

let cases = [
    "core-memory", "delegates", "empty-root", "folder-names", "frontmatter-invalid",
    "instructions-limit", "name-duplicate", "name-missing", "skills", "symlink-escape",
    "valid-full", "voiceflow-today", "yaml-forms",
]
let found = (try? FileManager.default.contentsOfDirectory(
    at: fixturesRoot, includingPropertiesForKeys: [.isDirectoryKey]))?
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    .map(\.lastPathComponent).sorted() ?? []
expect(found == cases.sorted(),
       "the persona fixtures are exactly K5's cases, found \(found)")

for caseName in cases {
    let caseRoot = fixturesRoot.appendingPathComponent(caseName)
    guard let data = try? Data(contentsOf: caseRoot.appendingPathComponent("expected.json")),
          let expectation = try? JSONDecoder().decode(FixtureExpectation.self, from: data) else {
        expect(false, "\(caseName): expected.json decodes as records and issues")
        continue
    }
    let result = PersonaChecker.check(
        PersonaRootReader.read(root: caseRoot.appendingPathComponent("personas")),
        input: PersonaChecker.Input(homeId: expectation.input.homeId,
                                    defaultPersonaId: expectation.input.defaultPersonaId))
    expect(result.records == expectation.records,
           "\(caseName): the checker produces exactly the listed records and issues")
    expect(result.invalidFolderNames == expectation.invalidFolderNames,
           "\(caseName): the invalid folder names are exactly the listed ones")
}

var allRecords: [TPPersona] = []
for caseName in cases {
    let url = fixturesRoot.appendingPathComponent(caseName).appendingPathComponent("expected.json")
    guard let data = try? Data(contentsOf: url),
          let expectation = try? JSONDecoder().decode(FixtureExpectation.self, from: data) else { continue }
    allRecords.append(contentsOf: expectation.records)
}
let shownCodes = Set(allRecords.flatMap { $0.issues.map { $0.code.split(separator: ":").first.map(String.init) ?? $0.code } })
for code in [PersonaIssueCode.frontmatterInvalid, PersonaIssueCode.nameMissing,
             PersonaIssueCode.nameDuplicate, PersonaIssueCode.instructionsTooLong,
             PersonaIssueCode.symlinkEscape, "skill_invalid", "skill_listed_missing",
             "delegate_unresolved", PersonaIssueCode.delegateNested, PersonaIssueCode.coreOverCap] {
    expect(shownCodes.contains(code), "the fixtures show the issue code \(code)")
}
expect(allRecords.contains { $0.usable }, "the fixtures show a usable persona")
expect(allRecords.contains { !$0.usable }, "the fixtures show an unusable persona")
expect(allRecords.contains { $0.isDefault }, "the fixtures show a default persona")
expect(allRecords.contains { $0.delegates.contains { $0.personaDelegatePrivate } },
       "the fixtures show a private delegate")
expect(allRecords.contains { $0.delegates.contains { !$0.personaDelegatePrivate } },
       "the fixtures show a resolvable delegate")

if failures == 0 {
    print("persona format tests passed")
} else {
    fputs("\(failures) persona format checks failed\n", stderr)
    exit(1)
}
