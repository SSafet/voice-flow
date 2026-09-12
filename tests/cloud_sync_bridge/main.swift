import Cocoa

func prove(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fatalError(message) }
}
let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("vf-cloud-bridge-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixtureRoot) }
let bridge = CloudSyncBridge(root: fixtureRoot)
let account = CloudAccountSelection(origin: "https://atika.test", userID: "synthetic-owner", email: "test@example.test", deviceID: "synthetic-device", transport: "cloud", signedIn: true)
try bridge.saveSelection(account)
let partition = account.partition!
let timestamp = CloudWire.timestamp()
let raw = HistoryEntry(text: "portable dictation words", time: "10:20:30", timestamp: timestamp,
    id: "dictation-one", destination: .kept, seen: false, capability: .snapshot,
    attachments: ["/private/local-path-canary.jpg"], captureId: "local-capture-canary")
bridge.captureDictations([raw])
var conversation = AssistantConversation(id: "thread-one", codexThreadId: "external-runtime-canary",
    title: "Portable thread", messages: [AssistantHistoryMessage(role: .user, text: "portable user words", attachmentNote: "/private/attachment-note-canary")],
    automationJobID: "local-job-canary")
bridge.captureConversations([conversation])
var state = try bridge.store!.state(partition)
let bytes = try JSONEncoder().encode(state)
let cloud = String(decoding: bytes, as: UTF8.self)
for canary in ["local-path-canary", "local-capture-canary", "external-runtime-canary", "attachment-note-canary", "local-job-canary"] {
    try prove(!cloud.contains(canary), "native source field crossed into cloud: \(canary)")
}
try prove(state.records["dictations:dictation-one"]?.payload?.captureKind == "dictateSnapshot", "portable capture kind retained")
try prove(state.records.count == 3, "dictation, header and completed message captured")
conversation.turnState = .running
conversation.messages.append(AssistantHistoryMessage(role: .assistant, text: "in-flight partial"))
bridge.captureConversations([conversation])
try prove(bridge.store!.state(partition).records.count == 3, "running transcript not replicated")

// Replay an older interrupted intent before a new capture. The current value
// must be the newest local edit and both immutable operations must remain.
let intentRoot = fixtureRoot.appendingPathComponent("cloud-sync-intents", isDirectory: true)
try FileManager.default.createDirectory(at: intentRoot, withIntermediateDirectories: true)
let oldEdit = CloudLocalEdit(collection: .dictations, recordId: "dictation-one", payload: CloudPayload(text: "older interrupted edit", destination: "kept"))
struct Intent: Encodable { var partition: String; var edits: [CloudLocalEdit] }
try JSONEncoder().encode(Intent(partition: partition, edits: [oldEdit])).write(to: intentRoot.appendingPathComponent("00000000000000000002.json"), options: .atomic)
let reopened = CloudSyncBridge(root: fixtureRoot)
var newer = raw; newer.text = "newest local edit"
reopened.captureDictations([newer])
state = try reopened.store!.state(partition)
try prove(state.records["dictations:dictation-one"]?.payload?.text == "newest local edit", "journal replay did not regress new edit")
let pending = state.records["dictations:dictation-one"]!.pending
try prove(pending.map { $0.payload?.text } == ["portable dictation words", "older interrupted edit", "newest local edit"], "intent order survives process loss")
try prove(try FileManager.default.contentsOfDirectory(atPath: intentRoot.path).isEmpty, "acknowledged local journals removed")

// Corrupt legacy input remains byte-identical and is not imported as empty.
let broken = Data("{broken native history".utf8)
let historyURL = fixtureRoot.appendingPathComponent("dictations.json")
try broken.write(to: historyURL)
do { try reopened.bootstrapIfNeeded(); fatalError("corrupt import accepted") } catch { }
try prove(try Data(contentsOf: historyURL) == broken, "corrupt original remains intact")
try prove(!reopened.store!.state(partition).imported, "failed import is not marked complete")
var legacy = raw; legacy.id = nil
try JSONEncoder().encode([legacy]).write(to: historyURL)
try reopened.bootstrapIfNeeded()
let firstIDs = Set(try reopened.store!.state(partition).records.keys)
let persistedLegacy = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: historyURL))
try prove(persistedLegacy.count == 1 && persistedLegacy[0].id != nil, "legacy native source receives a durable identity")
try prove(firstIDs.contains(CloudSyncStore.key(.dictations, persistedLegacy[0].id!)), "native and cloud migration share the same identity")
try prove(persistedLegacy[0].attachments == legacy.attachments && persistedLegacy[0].text == legacy.text, "identity migration preserves native attachments and text")
try reopened.bootstrapIfNeeded()
try prove(Set(reopened.store!.state(partition).records.keys) == firstIDs, "repeat import retains generated IDs")
try prove(FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent("cloud-sync-import-ids.json").path), "generated identity map is durable")
try prove(FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent("cloud-sync-backups").path), "legacy backups retained")
print("PASS cloud native adapter: typed canary exclusion, running-turn boundary, ordered recovery intent, corrupt-store preservation, stable-ID backed migration")

// A record beyond the metadata limit is retained separately and does not
// prevent other records from syncing. A later valid edit resolves that copy.
var oversized = raw; oversized.id = "oversized"; oversized.text = String(repeating: "x", count: 70_000)
var independent = raw; independent.id = "independent"; independent.text = "still queued normally"
reopened.captureDictations([oversized, independent])
try prove(reopened.reviewCount() == 1, "unsupported text has a retained review copy")
try prove(reopened.store!.state(partition).records["dictations:independent"]?.payload?.text == "still queued normally", "oversized row does not block independent records")
oversized.text = "edited into a portable record"
reopened.captureDictations([oversized])
try prove(reopened.reviewCount() == 0, "valid correction resolves review while preserving archive")
try prove(reopened.store!.state(partition).records["dictations:oversized"]?.payload?.text == oversized.text, "corrected record is queued")
