import Foundation
import GRDB

// Work package V10, the three persona operations on the Mac's loopback door
// (02 §3.13, 11 §3.5, decision 18).
//
// The operations are thin: they check the home, apply a command id once, and map
// the persona store's own refusals by code. They are driven here against a real
// PersonaStore writing real folders, and the default persona is the real
// thread_defaults setting through V10's provider, so a delete of the default is
// refused by the store's own rule and not by a stub.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
}
func codeOf(_ body: () throws -> Void) -> String? {
    do { try body(); return nil }
    catch let error as MacInterfaceError { return error.code }
    catch { return "unexpected: \(error)" }
}

let homeId = "home-v10-test"
let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("v10-personas-\(UUID().uuidString)", isDirectory: true)
let personasRoot = root.appendingPathComponent("personas", isDirectory: true)
let templatesRoot = root.appendingPathComponent("persona-templates", isDirectory: true)
try FileManager.default.createDirectory(at: templatesRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

// The settings store is the one owner of the default persona; H4's store reads it.
let pool = try ThreadDatabase.open(at: root.appendingPathComponent("threads.sqlite"))
let settingsStore = MacSettingsStore(database: pool)
let defaults = MacDefaultPersonaProvider(store: settingsStore)

let personas = PersonaStore(
    rootURL: personasRoot, homeId: homeId,
    database: nil, history: nil, templatesRoot: templatesRoot,
    defaults: defaults, inUse: nil, publish: nil)
let operations = MacPersonaOperations(store: personas, homeId: homeId)

func create(name: String, commandId: String, fromTemplate: String? = nil) throws -> TPPersonaCreateResult {
    let params = TPPersonaCreateParams(
        commandID: commandId, description: nil, fromTemplate: fromTemplate, homeID: homeId,
        instructions: nil, model: nil, name: name, reasoningEffort: nil, voice: nil)
    let out = try operations.handle(method: "persona/create", paramsJSON: JSONEncoder().encode(params))
    return try JSONDecoder().decode(TPPersonaCreateResult.self, from: out)
}
func delete(personaId: String, commandId: String) throws {
    let params = TPPersonaDeleteParams(commandID: commandId, homeID: homeId, personaID: personaId)
    _ = try operations.handle(method: "persona/delete", paramsJSON: JSONEncoder().encode(params))
}

// 1. The three operations, and nothing else: no persona/update and no
//    persona/setDefault exist (02 §3.13, decision 18).
expect(MacPersonaOperations.methodNames == ["persona/templates", "persona/create", "persona/delete"],
       "the Mac serves exactly the three persona operations")
expect(!MacPersonaOperations.methodNames.contains("persona/update"), "there is no persona/update")
expect(!MacPersonaOperations.methodNames.contains("persona/setDefault"), "there is no persona/setDefault")

// 2. Templates are read from this home's templates root; an empty root is an empty list.
func templates(home: String) throws -> TPPersonaTemplatesResult {
    let params = TPPersonaTemplatesParams(homeID: home)
    let out = try operations.handle(method: "persona/templates", paramsJSON: JSONEncoder().encode(params))
    return try JSONDecoder().decode(TPPersonaTemplatesResult.self, from: out)
}
let emptyTemplates = try templates(home: homeId)
expect(emptyTemplates.templates.isEmpty, "an empty templates root answers no templates")

// 3. Create writes a real persona folder via H4's store and answers its record.
let made = try create(name: "Second Brain", commandId: "cmd-create-1")
expect(made.persona.name == "Second Brain", "create answers the name it was given")
expect(made.persona.homeID == homeId, "create answers a record on this home")
expect(made.persona.id == "second-brain", "create answers the slug the store made from the name")
expect(made.persona.usable, "a freshly created persona is usable")
expect(personas.record(id: made.persona.id) != nil, "the record is in the store after create")

// 4. A repeated command id returns the original result and creates no second folder.
let replay = try create(name: "Second Brain Entirely", commandId: "cmd-create-1")
expect(replay == made, "a command id that was already applied returns the original result")
expect(personas.records.filter { $0.id == "second-brain" }.count == 1, "the replay created nothing new")

// 5. A name already taken is refused by the store's own code.
expect(codeOf { _ = try create(name: "second brain", commandId: "cmd-create-2") } == "name_taken",
       "a name that already exists is name_taken")
expect(codeOf { _ = try create(name: "From Nowhere", commandId: "cmd-create-3", fromTemplate: "no-such-template") } == "template_unknown",
       "an unknown template is template_unknown")

// 6. A command id that names a different home is refused, so a Mac never acts for another home.
let otherHome = TPPersonaTemplatesParams(homeID: "some-other-home")
expect(codeOf { _ = try operations.handle(method: "persona/templates", paramsJSON: JSONEncoder().encode(otherHome)) } == "invalid_params",
       "another home's persona operations are refused")

// 7. The default persona is the thread_defaults setting; the store refuses its delete.
let second = try create(name: "Night Shift", commandId: "cmd-create-4")
defaults.defaultPersonaID = second.persona.id
expect((try? settingsStore.value(section: .threadDefaults, field: "persona").text) == second.persona.id,
       "setting the default persona writes thread_defaults.persona")
expect(codeOf { try delete(personaId: second.persona.id, commandId: "cmd-delete-1") } == "persona_is_default",
       "deleting the default persona is refused by name")

// 8. Move the default away and the same delete now succeeds, keeping the record
//    with a deletedAt rather than erasing it.
defaults.defaultPersonaID = made.persona.id
try delete(personaId: second.persona.id, commandId: "cmd-delete-2")
expect(personas.record(id: second.persona.id)?.deletedAt != nil,
       "a deleted persona keeps its record with deletedAt set")

// 9. A delete for a persona that does not exist is persona_gone, and a replay of
//    the same delete command is applied once.
expect(codeOf { try delete(personaId: "does-not-exist", commandId: "cmd-delete-3") } == "persona_gone",
       "deleting a persona that does not exist is persona_gone")
defaults.defaultPersonaID = nil
try delete(personaId: made.persona.id, commandId: "cmd-delete-4")
try delete(personaId: made.persona.id, commandId: "cmd-delete-4")
expect(personas.record(id: made.persona.id)?.deletedAt != nil, "the replay of a delete applied once")

print("mac persona operations tests passed")
