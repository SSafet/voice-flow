import Foundation
import GRDB

// Work package V10, the Mac's half of the settings interface (02 §3.13, 06 §3.15).
//
// Every assertion here drives the real service over a real threads.sqlite opened
// through K8's migrator, and reads the stored section back. No test asserts a
// stub: the store and the service are the product.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
}

func setting(_ kind: TPSettingValueKind, boolean: Bool? = nil, json: String? = nil,
             number: Double? = nil, text: String? = nil, textList: [String]? = nil) -> TPSettingValue {
    TPSettingValue(boolean: boolean, settingValueJSON: json, kind: kind,
                   number: number, text: text, textList: textList)
}
func textValue(_ text: String) -> TPSettingValue { setting(.text, text: text) }
func boolValue(_ value: Bool) -> TPSettingValue { setting(.boolean, boolean: value) }
func numberValue(_ value: Double) -> TPSettingValue { setting(.number, number: value) }

func fieldValue(_ section: TPSettingsSection, _ field: String) -> TPSettingValue? {
    section.fields.first { $0.field == field }?.value
}

func get(_ service: MacSettingsService, sections: [TPSettingsSectionID]?) throws -> TPSettingsGetResult {
    let params = TPSettingsGetParams(sections: sections)
    let result = try service.handle(method: "settings/get", paramsJSON: JSONEncoder().encode(params))
    return try JSONDecoder().decode(TPSettingsGetResult.self, from: result)
}

func set(_ service: MacSettingsService, section: TPSettingsSectionID,
         field: String, value: TPSettingValue) throws -> TPSettingsSetResult {
    let params = TPSettingsSetParams(field: field, section: section, value: value)
    let result = try service.handle(method: "settings/set", paramsJSON: JSONEncoder().encode(params))
    return try JSONDecoder().decode(TPSettingsSetResult.self, from: result)
}

func codeOf(_ body: () throws -> Void) -> String? {
    do { try body(); return nil }
    catch let error as MacInterfaceError { return error.code }
    catch { return "unexpected: \(error)" }
}

// A real database file at the real name, opened through the one migrator.
let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("v10-settings-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let pool = try ThreadDatabase.open(at: root.appendingPathComponent("threads.sqlite"))

let migrated = try pool.read { db in
    try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type = 'table' AND name = 'mac_settings'") ?? false
}
expect(migrated, "mac_settings is registered in K8's one migrator, so it lives in threads.sqlite")

let store = MacSettingsStore(database: pool)
let service = MacSettingsService(store: store)
var changedNotifications: [TPSettingsChangedParams] = []
service.onChanged = { changedNotifications.append($0) }

// 1. The Mac serves exactly the sections 06 §3.15 names, in the contract's order,
//    and never the sections Atika holds. agents_may_see is a native "This device"
//    switch (05 §3.6 step 7, L5), not a settings-interface section.
let expectedSections: [TPSettingsSectionID] = [
    .speech, .dictationAndWakeNames, .hotkeys, .runtimes, .captureRetention,
    .threadDefaults, .concurrencyLimits, .grantedFolders, .storageAndBackups,
]
expect(MacSettingsSections.served == expectedSections,
       "the Mac serves its own sections in one fixed order: \(MacSettingsSections.served)")
for other: TPSettingsSectionID in [.accountAndDevices, .triggers, .connectors, .modelsAndProviders,
                                   .keysAndKillSwitches, .notificationRules, .appearance, .keyboardMap] {
    expect(!MacSettingsSections.isServed(other), "\(other.rawValue) is Atika's, not this Mac's")
}
expect(!MacSettingsSections.isServed(.agentsMaySee),
       "agents_may_see is changed in This device natively, not through the settings interface")
expect(MacSettingsSections.threadDefaultFields == ["runtime", "model", "effort", "persona", "trustProfile"],
       "the thread-default fields are the five the design names")

// 2. `get` with no list answers every served section, each with every field it declares.
let all = try get(service, sections: nil)
expect(all.sections.map { $0.id } == expectedSections, "get with no list answers every served section")
for section in all.sections {
    let declared = MacSettingsSections.fields(of: section.id).map { $0.name }
    expect(section.fields.map { $0.field } == declared,
           "\(section.id.rawValue) answers every declared field in order")
}
expect(all.sections.first { $0.id == .captureRetention }
        .flatMap { fieldValue($0, "capturedPicturesBudgetGB") }?.number == 25,
       "the captured-pictures budget ships at 25 GB (S5's setting)")

// 3. `get` with a list answers only what was asked, and refuses a section this Mac does not serve.
let one = try get(service, sections: [.captureRetention])
expect(one.sections.map { $0.id } == [.captureRetention], "get with a list answers just that section")
expect(codeOf { _ = try get(service, sections: [.connectors]) } == "settings.unknown_field",
       "an Atika-held section is refused by name, not silently dropped")
expect(codeOf { _ = try get(service, sections: [.agentsMaySee]) } == "settings.unknown_field",
       "agents_may_see is refused by name because it lives in This device")

// 4. `set` stores a value, answers the stored section, and notifies subscribers.
let stored = try set(service, section: .captureRetention, field: "watcherEnabled", value: boolValue(true))
expect(fieldValue(stored.section, "watcherEnabled")?.boolean == true, "set answers the stored value")
expect(changedNotifications.last?.section == .captureRetention, "the change notification names the section")
expect(changedNotifications.last?.fields == ["watcherEnabled"], "the change notification names the field")
let reread = try get(service, sections: [.captureRetention])
expect(fieldValue(reread.sections[0], "watcherEnabled")?.boolean == true, "a later get reads the stored value")

// 5. Writing the same value again changes nothing and does not notify: a set is idempotent.
let before = changedNotifications.count
let again = try set(service, section: .captureRetention, field: "watcherEnabled", value: boolValue(true))
expect(fieldValue(again.section, "watcherEnabled")?.boolean == true, "the stored value is still true")
expect(changedNotifications.count == before, "an unchanged set sends no settings/changed")

// 6. A second change to the same field notifies once more.
_ = try set(service, section: .captureRetention, field: "watcherEnabled", value: boolValue(false))
expect(changedNotifications.count == before + 1, "a real change notifies once")

// 7. Refusals are named codes, not English.
expect(codeOf { _ = try set(service, section: .speech, field: "notAField", value: textValue("x")) } == "settings.unknown_field",
       "an unknown field inside a served section is settings.unknown_field")
expect(codeOf { _ = try set(service, section: .captureRetention, field: "watcherEnabled", value: textValue("yes")) } == "settings.invalid_value",
       "a text value for a boolean field is settings.invalid_value")
expect(codeOf { _ = try set(service, section: .captureRetention, field: "capturedPicturesBudgetGB", value: textValue("25")) } == "settings.invalid_value",
       "a text value for a number field is settings.invalid_value")
expect(codeOf { _ = try set(service, section: .grantedFolders, field: "folders", value: textValue("not-a-list")) } == "settings.invalid_value",
       "a text value for a text-list field is settings.invalid_value")

// 8. Free text carries no U+0000 (the contract's text rule), refused by name.
let nul = "a\u{0000}b"
expect(codeOf { _ = try set(service, section: .threadDefaults, field: "runtime", value: textValue(nul)) } == "settings.invalid_value",
       "a text value holding U+0000 is settings.invalid_value")

// 9. A kill switch holds the Mac's settings read-only, and its reason travels on the refusal.
let held = MacSettingsService(store: store, readOnlyReason: { "held by the kill switch kill_device:mac" })
expect(codeOf { _ = try set(held, section: .speech, field: "voice", value: textValue("Nova")) } == "settings.read_only",
       "a held setting refuses settings.read_only")
do {
    _ = try set(held, section: .speech, field: "voice", value: textValue("Nova"))
    fail("the read-only refusal must throw")
} catch let error as MacInterfaceError {
    expect(error.message.contains("kill_device:mac"), "the refusal carries its reason in the message")
}
let heldRead = try get(held, sections: [.speech])
expect(heldRead.sections.count == 1, "a held setting is still readable")

// 10. Malformed input and an unknown method are named refusals, not crashes.
expect(codeOf { _ = try service.handle(method: "settings/get", paramsJSON: Data("{".utf8)) } == "invalid_params",
       "malformed params are invalid_params")
expect(codeOf { _ = try service.handle(method: "settings/nope", paramsJSON: Data("{}".utf8)) } == "not_supported",
       "an unknown method is not_supported")

// 11. The service serves exactly the two settings methods and one notification.
expect(MacSettingsService.methodNames == ["settings/get", "settings/set"], "the Mac serves get and set")
expect(MacSettingsService.notificationNames == ["settings/changed"], "the Mac emits settings/changed")
expect(MacInterfaceError(code: "x", message: "y", retryable: false).code == "x", "the refusal shape carries a code")

print("mac settings tests passed")
