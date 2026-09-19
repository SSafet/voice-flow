import Foundation

// Every committed fixture decodes with the generated types, and the check says
// so in one line. It must also be able to fail: three kinds of damage are made
// in a copy and each one has to be reported.

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let fixtures = repositoryRoot.appendingPathComponent("contract-fixtures", isDirectory: true)
let lock = repositoryRoot.appendingPathComponent("thread-protocol.lock", isDirectory: false)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}

let good = ContractSelfCheck.run(fixturesRoot: fixtures, lock: lock)
guard good.passed else { fail("the committed fixtures decode: \(good.problems)") }
guard good.fixtureFiles > 0, good.examples > 0, good.ruleCases > 0 else {
    fail("the check counted nothing: \(good.aboutLine)")
}
guard good.protocolVersion == "2" else { fail("the lock says protocol version 2, not \(good.protocolVersion)") }
guard good.schemaSHA256.count == 64 else { fail("the lock carries a schema hash") }

// The line accounts for every fixture file the bundle carries, counted from the
// folders themselves. Some committed fixtures have no generated Swift type and
// are never decoded; the line says how many rather than claiming them all.
var jsonOnDisk = 0
for (set, _) in tpFixtureFolders {
    let folder = fixtures.appendingPathComponent(set, isDirectory: true)
    jsonOnDisk += ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter { $0.hasSuffix(".json") }.count
}
guard good.fixtureFiles + good.skippedFiles == jsonOnDisk else {
    fail("the line accounts for every fixture file on disk: "
        + "\(good.fixtureFiles) decoded plus \(good.skippedFiles) skipped is not \(jsonOnDisk)")
}
guard good.aboutLine.contains("\(good.fixtureFiles) of \(jsonOnDisk) fixture files decoded") else {
    fail("the line says how many of the files on disk were decoded: \(good.aboutLine)")
}
if good.skippedFiles > 0 {
    guard good.aboutLine.contains("\(good.skippedFiles) have no generated Swift type") else {
        fail("the line says why the rest were skipped: \(good.aboutLine)")
    }
}
print(good.aboutLine)

// A copy, damaged three ways at once.
let damaged = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("vf-self-check-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: damaged) }
let damagedFixtures = damaged.appendingPathComponent("contract-fixtures", isDirectory: true)
try FileManager.default.copyItem(at: fixtures, to: damagedFixtures)
let set = damagedFixtures.appendingPathComponent("thread-protocol", isDirectory: true)
try Data(#"{"type":"Thread","examples":[{"id":42}]}"#.utf8)
    .write(to: set.appendingPathComponent("Thread.json"))
try FileManager.default.removeItem(at: set.appendingPathComponent("Turn.json"))
try Data(#"{"nope":1}"#.utf8).write(to: set.appendingPathComponent("Unknown.json"))

let bad = ContractSelfCheck.run(fixturesRoot: damagedFixtures, lock: lock)
guard !bad.passed else { fail("damaged fixtures must not pass") }
for expected in ["Thread.json", "Turn.json", "Unknown.json"] {
    guard bad.problems.contains(where: { $0.contains(expected) }) else {
        fail("the damage to \(expected) is reported; got \(bad.problems)")
    }
}
guard !bad.aboutLine.contains("fixture files decoded") else {
    fail("a failing check must not print the passing line: \(bad.aboutLine)")
}

// A missing lock is a problem, not a crash.
let noLock = ContractSelfCheck.run(
    fixturesRoot: fixtures, lock: damaged.appendingPathComponent("nothing.lock"))
guard !noLock.passed, noLock.problems.contains(where: { $0.contains("thread-protocol.lock") }) else {
    fail("a missing lock is reported")
}

print("contract self-check: \(good.fixtureFiles) fixture files, \(good.examples) examples, "
    + "\(good.ruleCases) rule cases; three kinds of damage were each reported")
