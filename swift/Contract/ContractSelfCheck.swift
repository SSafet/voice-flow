import Foundation

/// Decodes every committed fixture with the generated types and runs the four
/// pure rules against their fixture files, at launch, so a contract copy that
/// does not match the code this app was built from is visible in the About
/// window instead of turning into a decoding failure during a turn.
enum ContractSelfCheck {
    struct Outcome {
        let protocolVersion: String
        let schemaSHA256: String
        let fixtureFiles: Int
        let examples: Int
        let ruleCases: Int
        let problems: [String]

        var passed: Bool { problems.isEmpty }

        /// "Thread protocol 2, schema 4ebb898c6fab, all fixtures decoded
        /// (66 files, 162 examples), all four rules match (74 cases)"
        var aboutLine: String {
            let schema = String(schemaSHA256.prefix(12))
            guard passed else {
                return "Thread protocol \(protocolVersion), schema \(schema), "
                    + "\(problems.count) problem(s): \(problems[0])"
            }
            return "Thread protocol \(protocolVersion), schema \(schema), "
                + "all fixtures decoded (\(fixtureFiles) files, \(examples) examples), "
                + "all four rules match (\(ruleCases) cases)"
        }
    }

    private static let lock = NSLock()
    private static var stored: Outcome?

    /// The outcome of the run the app made at launch.
    static var lastOutcome: Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// The app's own run, against what `install.sh` put into the bundle.
    @discardableResult
    static func bundled() -> Outcome {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let outcome = run(
            fixturesRoot: resources.appendingPathComponent("ContractFixtures", isDirectory: true),
            lock: resources.appendingPathComponent("thread-protocol.lock", isDirectory: false)
        )
        lock.lock()
        stored = outcome
        lock.unlock()
        return outcome
    }

    /// `fixturesRoot` holds one folder per contract set, named `<set>` as
    /// `scripts/sync-thread-protocol.sh` writes it.
    ///
    /// The generated table gives the fixture types as one union across all
    /// contract sets, not one list per set. So each set's folder is read for
    /// its own files, and a generated type is reported missing only when no
    /// set carries it. This way the check decodes whatever contract sets the
    /// pinned commit carries and never hard-codes the list of sets.
    static func run(fixturesRoot: URL, lock lockFile: URL) -> Outcome {
        var problems: [String] = []
        let lockValues = readLock(lockFile, problems: &problems)
        var files = 0
        var examples = 0
        var presentEverywhere = Set<String>()
        let known = Set(tpFixtureTypes).union(tpFixtureTypesWithoutSwift)
        if tpFixtureFolders.isEmpty { problems.append("the generated fixture table lists no contract set") }
        for (set, _) in tpFixtureFolders {
            let folder = fixturesRoot.appendingPathComponent(set, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let present = Set(entries.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
            if present.isEmpty {
                problems.append("\(set): no fixture file under \(folder.path)")
                continue
            }
            presentEverywhere.formUnion(present)
            for name in present.subtracting(known).sorted() {
                problems.append("\(set)/\(name).json: the generated table does not know this type")
            }
            for type in tpFixtureTypes.sorted() where present.contains(type) {
                files += 1
                let file = folder.appendingPathComponent("\(type).json", isDirectory: false)
                do {
                    guard let count = try tpDecodeFixture(type: type, data: Data(contentsOf: file)) else {
                        problems.append("\(set)/\(type).json: the generated table does not decode this type")
                        continue
                    }
                    if count == 0 { problems.append("\(set)/\(type).json: no examples") }
                    examples += count
                } catch {
                    problems.append("\(set)/\(type).json: \(error)")
                }
            }
        }
        for type in tpFixtureTypes.sorted() where !presentEverywhere.contains(type) {
            problems.append("\(type).json: the file is missing")
        }
        let rules = runRules(
            rulesFolder: fixturesRoot
                .appendingPathComponent("thread-protocol", isDirectory: true)
                .appendingPathComponent("rules", isDirectory: true),
            problems: &problems
        )
        return Outcome(
            protocolVersion: lockValues.version,
            schemaSHA256: lockValues.schema,
            fixtureFiles: files,
            examples: examples,
            ruleCases: rules,
            problems: problems
        )
    }

    private static func readLock(_ file: URL, problems: inout [String]) -> (version: String, schema: String) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            problems.append("thread-protocol.lock is not beside the app")
            return ("?", "?")
        }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[line.startIndex..<separator])] = String(line[line.index(after: separator)...])
        }
        let version = values["protocol_version"] ?? "?"
        let schema = values["schema_sha256"] ?? "?"
        if version == "?" || schema == "?" { problems.append("thread-protocol.lock is incomplete") }
        return (version, schema)
    }

    // MARK: the four pure rules

    private struct RuleFile<Case: Decodable>: Decodable { let rule: String; let cases: [Case] }
    private struct BranchCase: Decodable { let title: String; let threadId: String; let expected: String }
    private struct TitleCase: Decodable { let text: String; let expected: String }
    private struct CutCase: Decodable { let name: String; let text: String; let maxUnits: Int; let expected: String }
    private struct CleanCase: Decodable { let text: String; let expected: String }
    private struct CleanUnitCase: Decodable { let name: String; let textUnits: [UInt16]; let expectedUnits: [UInt16] }
    private struct CleanFile: Decodable { let rule: String; let cases: [CleanCase]; let unitCases: [CleanUnitCase] }

    /// Returns the number of cases that ran; every mismatch is a problem.
    static func runRules(rulesFolder: URL, problems: inout [String]) -> Int {
        var ran = 0
        let decoder = JSONDecoder()
        func load<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
            let file = rulesFolder.appendingPathComponent(name, isDirectory: false)
            do {
                return try decoder.decode(T.self, from: Data(contentsOf: file))
            } catch {
                problems.append("rules/\(name): \(error)")
                return nil
            }
        }
        if let file = load("branch-names.json", RuleFile<BranchCase>.self) {
            if file.cases.isEmpty { problems.append("rules/branch-names.json: no cases") }
            for item in file.cases {
                ran += 1
                let got = ContractBranchName.threadBranchName(title: item.title, threadId: item.threadId)
                if got != item.expected {
                    problems.append("threadBranchName(\(item.title.debugDescription), \(item.threadId)): "
                        + "\(got) is not \(item.expected)")
                }
            }
        }
        if let file = load("first-line-titles.json", RuleFile<TitleCase>.self) {
            if file.cases.isEmpty { problems.append("rules/first-line-titles.json: no cases") }
            for item in file.cases {
                ran += 1
                let got = ContractTitle.firstLineTitle(item.text)
                if got != item.expected {
                    problems.append("firstLineTitle(\(item.text.debugDescription)): "
                        + "\(got.debugDescription) is not \(item.expected.debugDescription)")
                }
            }
        }
        if let file = load("cut-text.json", RuleFile<CutCase>.self) {
            if file.cases.isEmpty { problems.append("rules/cut-text.json: no cases") }
            for item in file.cases {
                ran += 1
                let got = ContractText.cutText(item.text, maxUnits: item.maxUnits)
                if got != item.expected {
                    problems.append("cutText(\(item.name)): "
                        + "\(got.debugDescription) is not \(item.expected.debugDescription)")
                }
            }
        }
        if let file = load("clean-text.json", CleanFile.self) {
            if file.cases.isEmpty || file.unitCases.isEmpty { problems.append("rules/clean-text.json: no cases") }
            for item in file.cases {
                ran += 1
                let got = ContractText.cleanText(item.text)
                if got != item.expected {
                    problems.append("cleanText(\(item.text.debugDescription)): "
                        + "\(got.debugDescription) is not \(item.expected.debugDescription)")
                }
            }
            for item in file.unitCases {
                ran += 1
                let got = ContractText.cleanUnits(item.textUnits)
                if got != item.expectedUnits {
                    problems.append("cleanUnits(\(item.name)): \(got) is not \(item.expectedUnits)")
                }
            }
        }
        return ran
    }
}
