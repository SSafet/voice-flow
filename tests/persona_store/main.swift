import Foundation

// The Mac persona store (11-personas.md §3.3, §3.5, §3.7; 06-voiceflow-mac.md
// §3.4): one writer with one lock table, revision-checked atomic writes, the
// memory tool's refusals, git history through V4's runner, the watch's outside
// changes, persona/create, persona/delete and the template copy.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("ok   \(message)")
    } else {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func makeRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("voice-flow-persona-store-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

private func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

final class StubDefaults: PersonaDefaultProviding {
    var defaultPersonaID: String?
    init(_ id: String?) { defaultPersonaID = id }
}

final class StubInUse: PersonaInUseProviding {
    var names: [String: [String]] = [:]
    func triggerNames(naming personaID: String) -> [String] { names[personaID] ?? [] }
}

// One runner and one database for the whole suite, built the way the app
// builds them (V4's GitRunner, K8's ThreadDatabase).
guard case .success(let gitProgram) = GitProgramLocator.find(
    environment: ProcessInfo.processInfo.environment) else {
    fputs("FAIL: no git program; the persona history cannot be tested\n", stderr)
    exit(1)
}
let git = GitRunner(program: gitProgram)

let configRoot = makeRoot()
let personasRoot = configRoot.appendingPathComponent("personas", isDirectory: true)
try? FileManager.default.createDirectory(at: personasRoot, withIntermediateDirectories: true)
guard let pool = try? ThreadDatabase.open(at: ThreadDatabase.url(configRoot: configRoot)) else {
    fputs("FAIL: threads.sqlite could not be opened\n", stderr)
    exit(1)
}

let templatesRoot = makeRoot()
write("---\nname: Assistant\ndescription: the default persona\nskills: persona-authoring\n---\nYou help.\n",
      to: templatesRoot.appendingPathComponent("assistant/persona.md"))
write("---\nname: persona-authoring\ndescription: write persona folders\n---\nBody\n",
      to: templatesRoot.appendingPathComponent("assistant/skills/persona-authoring/SKILL.md"))
write("---\nname: Scout\ndescription: looks around\n---\nScout body\n",
      to: templatesRoot.appendingPathComponent("assistant/delegates/scout/persona.md"))
write("---\nname: Researcher\ndescription: finds things\n---\nResearch.\n",
      to: templatesRoot.appendingPathComponent("researcher/persona.md"))

let defaults = StubDefaults(nil)
let inUse = StubInUse()
var published: [TPPersona] = []
let recordStore = PersonaRecordStore(database: pool)
let store = PersonaStore(
    rootURL: personasRoot, homeId: "home-test",
    database: recordStore,
    history: PersonaHistory(rootURL: personasRoot, runner: git),
    templatesRoot: templatesRoot,
    defaults: defaults, inUse: inUse,
    publish: { published.append($0) })
_ = store.load()

func gitLog(_ root: URL) -> String {
    switch git.run(["log", "--format=%an|%ae|%s"], in: root, query: true) {
    case .success(let output): return output.text
    case .failure: return ""
    }
}

// ── create ───────────────────────────────────────────────
// 11 §3.5 persona/create; 06 §3.4 the folder and its history.

let flora: TPPersona
do {
    flora = try store.create(name: "FLORA", description: "organizes thoughts",
                             instructions: "You are FLORA.", voice: "nova")
} catch {
    expect(false, "create writes a persona: \(error)")
    fputs("\(failures) persona store checks failed\n", stderr)
    exit(1)
}
expect(flora.id == "flora", "the slug is made from the name")
expect(flora.name == "FLORA", "the display name is kept")
expect(flora.instructions == "You are FLORA.", "the instructions are the body")
expect(flora.voice == "nova", "the voice is kept")
expect(flora.issues.isEmpty && flora.usable, "a freshly created persona is usable")
expect(flora.revision == PersonaFormat.sha256Hex(Data(read(
    personasRoot.appendingPathComponent("flora/persona.md")).utf8)),
    "the record's revision is the hash of persona.md")
expect(FileManager.default.fileExists(
    atPath: personasRoot.appendingPathComponent("flora/memory/core.md").path),
    "create writes memory/core.md")
expect(FileManager.default.fileExists(
    atPath: personasRoot.appendingPathComponent("flora/memory/ledger.md").path),
    "create writes memory/ledger.md")
expect(!FileManager.default.fileExists(
    atPath: personasRoot.appendingPathComponent("flora/workspace").path),
    "create does not write the empty workspace/ subfolder")
expect(gitLog(personasRoot).contains("VoiceFlow Personas|personas@localhost|flora: persona.md: create"),
       "the creation is committed with the store's fixed author and a named message")
expect(published.contains { $0.id == "flora" && $0.version == 1 },
       "the created record is published at version 1")

// A second persona with the same name is refused by name, not silently renamed.
do {
    _ = try store.create(name: "flora")
    expect(false, "a duplicate name is refused")
} catch PersonaStoreError.nameTaken(_) { } catch {
    expect(false, "a duplicate name gives name_taken, got \(error)")
}
// An empty or over-long name is a malformed request, refused by name.
do {
    _ = try store.create(name: "   ")
    expect(false, "an empty name is refused")
} catch PersonaStoreError.invalidPersona(_) { } catch {
    expect(false, "an empty name gives invalid_persona, got \(error)")
}
do {
    _ = try store.create(name: String(repeating: "a", count: 65))
    expect(false, "an over-long name is refused")
} catch PersonaStoreError.invalidPersona(_) { } catch {
    expect(false, "an over-long name gives invalid_persona, got \(error)")
}
// A missing persona is named, not confused with an unusable one.
do {
    _ = try store.document(id: "no-such-persona")
    expect(false, "a missing persona is refused")
} catch PersonaStoreError.gone(_) { } catch {
    expect(false, "a missing persona gives persona_gone, got \(error)")
}
do {
    _ = try store.updateMemory(id: "no-such-persona", kind: "core", content: "x",
                               expectedRevision: "0")
    expect(false, "memory of a missing persona is refused")
} catch PersonaStoreError.unavailable(_) { } catch {
    expect(false, "memory of a missing persona gives unavailable, got \(error)")
}
// A different name that makes the same slug gets -2 (11 §3.5).
do {
    let second = try store.create(name: "Flora!")
    expect(second.id == "flora-2", "a slug collision gets -2, got \(second.id)")
} catch {
    expect(false, "a slug collision creates the next slug: \(error)")
}

// ── templates (11 §3.9, 06 §3.4) ─────────────────────────

let templates = store.listTemplates()
expect(templates.map(\.id).sorted() == ["assistant", "researcher"],
       "persona/templates lists the template folders")
do {
    let copied = try store.create(name: "Second assistant", fromTemplate: "assistant")
    expect(FileManager.default.fileExists(atPath: personasRoot
        .appendingPathComponent("\(copied.id)/skills/persona-authoring/SKILL.md").path),
        "create from a template copies its skills")
    expect(copied.delegates.contains { $0.id == "scout" && $0.personaDelegatePrivate },
           "create from a template keeps its private delegate")
} catch {
    expect(false, "create from a template copies the folder: \(error)")
}
do {
    _ = try store.create(name: "Nope", fromTemplate: "does-not-exist")
    expect(false, "an unknown template is refused")
} catch PersonaStoreError.templateUnknown(_) { } catch {
    expect(false, "an unknown template gives template_unknown, got \(error)")
}

// ── delete (11 §3.5, 06 §3.4) ────────────────────────────

// The default persona cannot be deleted.
defaults.defaultPersonaID = "flora"
_ = store.load()
expect(store.record(id: "flora")?.isDefault == true, "the default provider marks isDefault")
do {
    try store.delete(id: "flora")
    expect(false, "the default persona is refused")
} catch PersonaStoreError.isDefault(_) { } catch {
    expect(false, "deleting the default gives persona_is_default, got \(error)")
}
// A persona a trigger names cannot be deleted.
inUse.names["flora-2"] = ["Morning briefing", "Nightly review"]
do {
    try store.delete(id: "flora-2")
    expect(false, "an in-use persona is refused")
} catch PersonaStoreError.inUse(_, let names) {
    expect(names == ["Morning briefing", "Nightly review"], "persona_in_use names the triggers")
} catch {
    expect(false, "deleting an in-use persona gives persona_in_use, got \(error)")
}
// A free persona moves to .trash and its record carries deletedAt.
inUse.names["flora-2"] = []
do {
    try store.delete(id: "flora-2")
    expect(!FileManager.default.fileExists(
        atPath: personasRoot.appendingPathComponent("flora-2").path),
        "delete removes the folder from the root")
    let trash = (try? FileManager.default.contentsOfDirectory(
        at: personasRoot.appendingPathComponent(".trash"),
        includingPropertiesForKeys: nil)) ?? []
    expect(trash.contains { $0.lastPathComponent.hasPrefix("flora-2-") },
           "delete moves the folder into .trash/<slug>-<time>/")
    expect(store.record(id: "flora-2")?.deletedAt != nil, "the deleted record carries deletedAt")
    expect(!store.records.contains { $0.id == "flora-2" },
           "a deleted persona leaves the active list")
} catch {
    expect(false, "delete moves the folder to .trash: \(error)")
}

// ── the memory tool's write path (11 §3.7, 06 §3.4) ──────

guard let before = try? store.readMemory(id: "flora", kind: "core") else {
    expect(false, "memory can be read")
    fputs("\(failures) persona store checks failed\n", stderr)
    exit(1)
}
do {
    let written = try store.updateMemory(
        id: "flora", kind: "core", content: "remembered fact\n",
        expectedRevision: before.revision)
    expect(written.content == "remembered fact\n", "memory update returns the new content")
    expect(written.revision != before.revision, "memory update returns the new revision")
    expect(gitLog(personasRoot).contains("flora: memory/core.md: memory tool"),
           "a memory write is committed with the memory-tool cause")
} catch {
    expect(false, "a memory update on the current revision succeeds: \(error)")
}
do {
    _ = try store.updateMemory(id: "flora", kind: "core", content: "stale write",
                               expectedRevision: before.revision)
    expect(false, "a stale revision is refused")
} catch PersonaStoreError.invalidRevision { } catch {
    expect(false, "a stale revision gives invalid_revision, got \(error)")
}
do {
    _ = try store.updateMemory(id: "flora", kind: "core", content: "sk-live-abcdefghijklmnopqrstuv",
                               expectedRevision: before.revision)
    expect(false, "a secret is refused")
} catch PersonaStoreError.secretDetected { } catch {
    expect(false, "a secret gives secret_detected, got \(error)")
}
guard let current = try? store.readMemory(id: "flora", kind: "core") else {
    expect(false, "memory can be read again")
    fputs("\(failures) persona store checks failed\n", stderr)
    exit(1)
}
do {
    _ = try store.updateMemory(id: "flora", kind: "core",
                               content: String(repeating: "x", count: 12_001),
                               expectedRevision: current.revision)
    expect(false, "core memory over its cap is refused")
} catch PersonaStoreError.oversized(let limit) {
    expect(limit == 12_000, "oversized names the core limit, got \(limit)")
} catch {
    expect(false, "core over the cap gives oversized(12000), got \(error)")
}
do {
    _ = try store.updateMemory(id: "flora", kind: "ledger",
                               content: String(repeating: "x", count: 24_001),
                               expectedRevision: (try store.readMemory(id: "flora", kind: "ledger")).revision)
    expect(false, "ledger over its cap is refused")
} catch PersonaStoreError.oversized(let limit) {
    expect(limit == 24_000, "oversized names the ledger limit, got \(limit)")
} catch {
    expect(false, "ledger over the cap gives oversized(24000), got \(error)")
}

// A read of an over-cap file clips at the cap and says so.
write(String(repeating: "y", count: 25_000), to: personasRoot.appendingPathComponent("flora/memory/ledger.md"))
if let clipped = try? store.readMemory(id: "flora", kind: "ledger") {
    expect(clipped.clipped, "a read of an over-cap file is marked clipped")
    expect(clipped.content.count == 24_000, "a ledger read clips at its own cap")
} else {
    expect(false, "an over-cap file still reads")
}

// ── the watch's outside changes (11 §3.3 item 3, 06 §3.4) ─

let outsideFile = personasRoot.appendingPathComponent("flora/persona.md")
let commitsBeforeOutside = gitLog(personasRoot).split(separator: "\n").count
write("---\nname: FLORA\ndescription: hand edited\n---\nA new instruction.\n", to: outsideFile)
let changed = store.handleExternalChange(paths: [outsideFile.path])
expect(changed.contains { $0.id == "flora" && $0.instructions == "A new instruction." },
       "an outside edit reaches the record")
expect(gitLog(personasRoot).contains("flora: persona.md: changed outside the platform"),
       "an outside edit is committed as changed outside the platform")
expect(gitLog(personasRoot).split(separator: "\n").count > commitsBeforeOutside,
       "an outside edit adds a commit")
let versionAfterOutside = store.record(id: "flora")?.version ?? 0
let commitsAfterOutside = gitLog(personasRoot).split(separator: "\n").count
_ = store.handleExternalChange(paths: [outsideFile.path])
expect(store.record(id: "flora")?.version == versionAfterOutside,
       "seeing the same outside content again does not raise the version")
expect(gitLog(personasRoot).split(separator: "\n").count == commitsAfterOutside,
       "seeing the same outside content again adds no commit")
// A store write followed by the watcher's own event is not an outside change.
let coreFile = personasRoot.appendingPathComponent("flora/memory/core.md")
let commitsBeforeEcho = gitLog(personasRoot).split(separator: "\n").count
_ = store.handleExternalChange(paths: [coreFile.path])
expect(!gitLog(personasRoot).contains("flora: memory/core.md: changed outside the platform"),
       "the store's own write is not reported as an outside change")
expect(gitLog(personasRoot).split(separator: "\n").count == commitsBeforeEcho,
       "the watcher echoing the store's own write adds no commit")

// ── two writers, one lock table (11 §3.3 item 2, 06 defect 28) ─

guard let concurrentBase = try? store.readMemory(id: "flora", kind: "core") else {
    expect(false, "memory can be read for the contention test")
    fputs("\(failures) persona store checks failed\n", stderr)
    exit(1)
}
let resultLock = NSLock()
var outcomes: [String] = []
DispatchQueue.concurrentPerform(iterations: 2) { index in
    do {
        _ = try store.updateMemory(id: "flora", kind: "core",
                                   content: "fact \(index)\n",
                                   expectedRevision: concurrentBase.revision)
        resultLock.lock(); outcomes.append("ok"); resultLock.unlock()
    } catch PersonaStoreError.invalidRevision {
        resultLock.lock(); outcomes.append("invalid_revision"); resultLock.unlock()
    } catch {
        resultLock.lock(); outcomes.append("other:\(error)"); resultLock.unlock()
    }
}
expect(outcomes.filter { $0 == "ok" }.count == 1,
       "of two concurrent updates on one revision exactly one succeeds, got \(outcomes)")
expect(outcomes.filter { $0 == "invalid_revision" }.count == 1,
       "the other concurrent update is refused with invalid_revision, got \(outcomes)")

// ── recreate from Atika's records after a home takeover (11 §3.4, decision 23) ─

let takeoverConfig = makeRoot()
let takeoverRoot = takeoverConfig.appendingPathComponent("personas", isDirectory: true)
guard let takeoverPool = try? ThreadDatabase.open(at: ThreadDatabase.url(configRoot: takeoverConfig)) else {
    expect(false, "the takeover database opens")
    fputs("\(failures) persona store checks failed\n", stderr)
    exit(1)
}
let takeoverStore = PersonaStore(
    rootURL: takeoverRoot, homeId: "home-test",
    database: PersonaRecordStore(database: takeoverPool),
    history: PersonaHistory(rootURL: takeoverRoot, runner: git),
    templatesRoot: templatesRoot,
    defaults: StubDefaults(nil), inUse: StubInUse(), publish: { _ in })
let recordJSON = """
{"coreMemory":"a fact only in core memory","delegates":[{"id":"scout","name":"Scout","private":true}],
 "homeId":"home-test","id":"flora","instructions":"Recovered instructions.","isDefault":false,
 "issues":[],"name":"FLORA","revision":"0000","skills":[{"description":"file tickets","name":"tickets"}],
 "usable":true,"version":9}
"""
guard let recoveredRecord = try? JSONDecoder().decode(TPPersona.self, from: Data(recordJSON.utf8)) else {
    expect(false, "the mirrored record decodes")
    fputs("\(failures) persona store checks failed\n", stderr)
    exit(1)
}
let recreated = (try? takeoverStore.recreate(fromRecords: [recoveredRecord])) ?? []
expect(recreated.count == 1, "recreate writes one folder per record")
expect(read(takeoverRoot.appendingPathComponent("flora/persona.md")).contains("Recovered instructions."),
       "recreate recovers the instructions")
expect(read(takeoverRoot.appendingPathComponent("flora/memory/core.md")).contains("a fact only in core memory"),
       "recreate recovers the core memory")
expect(recreated.first?.instructions == "Recovered instructions.", "the recovered record keeps the instructions")
expect(recreated.first?.coreMemory == "a fact only in core memory", "the recovered record keeps core memory")
expect(recreated.first?.issues.contains { $0.code == PersonaIssueCode.skillListedMissing("tickets") } == true,
       "a skill whose files are gone is skill_listed_missing")
expect(recreated.first?.issues.contains { $0.code == PersonaIssueCode.delegateUnresolved("scout") } == true,
       "a private delegate whose folder is gone is delegate_unresolved")

if failures == 0 {
    print("persona store tests passed")
} else {
    fputs("\(failures) persona store checks failed\n", stderr)
    exit(1)
}
