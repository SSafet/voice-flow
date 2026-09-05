import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func wait(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(condition(), "Timed out: \(description)")
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-sources-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let store = DataSourceStore(root: root)
let collector = SourceCollector(store: store)
expect(store.listSources().count == 4, "Built-in registry must be visible before configuration")
let files = root.appendingPathComponent("input")
try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
try Data("Original local evidence".utf8).write(to: files.appendingPathComponent("notes.md"))
try Data([0, 1, 2]).write(to: files.appendingPathComponent("ignored.bin"))
let secret = root.appendingPathComponent("outside.txt")
try Data("DO NOT COPY".utf8).write(to: secret)
try FileManager.default.createSymbolicLink(at: files.appendingPathComponent("escape.txt"), withDestinationURL: secret)
let local = SourceDefinition(name: "Project notes", kind: .localFolder, location: files.path, instructions: "Summarize changes with evidence.")
try store.save(local)
var result: String? = "pending", complete = false
collector.refresh(sourceID: local.id) { result = $0; complete = true }
wait("local collection") { complete }
expect(result == nil, "Local collection failed: \(result ?? "")")
expect(store.status(sourceID: local.id).itemCount == 1 && store.status(sourceID: local.id).skippedCount == 2, "Skipped files and symlinks are observable")
let snapshot = store.snapshots(sourceID: local.id)[0]
let inspected = try store.readItem(sourceID: local.id, snapshotID: snapshot.id, itemID: snapshot.items[0].id)
expect(inspected == "Original local evidence", "Inspect local copy")
let frozen = store.freezeContext(sourceIDs: [local.id])
try Data("Updated evidence".utf8).write(to: files.appendingPathComponent("notes.md"))
complete = false
collector.refresh(sourceID: local.id) { result = $0; complete = true }
wait("updated collection") { complete }
expect(store.snapshots(sourceID: local.id).count == 2, "Snapshots remain immutable")
expect(frozen.sources[0].documents[0].text == "Original local evidence", "Turn-frozen context changed during later refresh")
let bounded = store.freezeContext(sourceIDs: [local.id], maxCharacters: 5)
expect(bounded.sources[0].instructions.count + bounded.sources[0].documents.reduce(0) { $0 + $1.text.count } <= 5, "Context bounds include authored guidance")
expect(store.freezeContext(sourceIDs: ["removed"]).issues.count == 1, "Missing source must be explicit")
let restored = DataSourceStore(root: root)
expect(restored.source(id: local.id) == local && restored.status(sourceID: local.id).itemCount == 1, "Registry and status persist")
expect(restored.snapshots(sourceID: local.id).count == 2, "Snapshot index survives restart")
try collector.pause(sourceID: local.id, paused: true)
expect(store.source(id: local.id)?.enabled == false && store.snapshots(sourceID: local.id).count == 2, "Pause retains collected evidence")

let emails = root.appendingPathComponent("mail")
try FileManager.default.createDirectory(at: emails, withIntermediateDirectories: true)
let eml = """
From: sender@example.test
To: recipient@example.test
Subject: =?UTF-8?B?VGVzdCBtYWls?=
Content-Type: multipart/alternative; boundary="mail-boundary"

--mail-boundary
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: quoted-printable

First=20line=0ASecond line
--mail-boundary
Content-Type: text/html

<p>Duplicate HTML alternative</p>
--mail-boundary--
"""
try Data(eml.utf8).write(to: emails.appendingPathComponent("message.eml"))
let mbox = "From sender Sat Sep 5 12:00:00 2026\nSubject: Mailbox one\nContent-Type: text/plain\n\nFirst mailbox message\nFrom sender Sat Sep 5 12:01:00 2026\nSubject: Mailbox two\nContent-Type: text/plain\nContent-Transfer-Encoding: base64\n\nU2Vjb25kIG1haWxib3ggbWVzc2FnZQ==\n"
try Data(mbox.utf8).write(to: emails.appendingPathComponent("archive.mbox"))
let mail = SourceDefinition(name: "Mail export", kind: .emailCopies, location: emails.path)
try store.save(mail)
complete = false
collector.refresh(sourceID: mail.id) { result = $0; complete = true }
wait("mail import") { complete }
expect(result == nil && store.status(sourceID: mail.id).itemCount == 3, "EML and mbox export import")
let mailContext = store.freezeContext(sourceIDs: [mail.id])
expect(mailContext.sources[0].documents.contains { $0.title == "Test mail" && $0.text.contains("First line\nSecond line") && !$0.text.contains("Duplicate HTML") }, "Encoded subject, quoted printable and alternative MIME parsing")
expect(mailContext.promptText.contains("Second mailbox message"), "Base64 mbox body")

try Data("[{\"text\":\"Existing dictation\",\"timestamp\":\"2026-09-05T12:00:00Z\",\"time\":\"12:00\"}]".utf8).write(to: root.appendingPathComponent("dictations.json"))
let builtIn = store.source(id: "builtin-dictations")!
let builtInResult = try SourceCollector.collect(builtIn, root: root)
expect(builtInResult.documents[0].text == "Existing dictation", "Built-in reads actual isolated data")
expect(builtInResult.documents[0].capturedAt == ISO8601DateFormatter().date(from: "2026-09-05T12:00:00Z"), "Built-in preserves recorded date")

try Data("{\"unexpected\":[]}".utf8).write(to: root.appendingPathComponent("assistant-sessions.json"))
var rejectedCorruptHistory = false
 do { _ = try SourceCollector.collect(store.source(id: "builtin-assistantHistory")!, root: root) } catch { rejectedCorruptHistory = true }
expect(rejectedCorruptHistory, "Malformed built-in history must fail instead of reporting an empty successful collection")
let brokenCapture = root.appendingPathComponent("captures/broken")
try FileManager.default.createDirectory(at: brokenCapture, withIntermediateDirectories: true)
try Data("not JSON".utf8).write(to: brokenCapture.appendingPathComponent("meta.json"))
var rejectedCorruptCapture = false
 do { _ = try SourceCollector.collect(store.source(id: "builtin-captures")!, root: root) } catch { rejectedCorruptCapture = true }
expect(rejectedCorruptCapture, "Unreadable capture metadata must surface a source error")
let fixture = Process()
fixture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
let portFile = root.appendingPathComponent("http-port")
fixture.arguments = ["python3", "tests/data_sources/http_fixture.py", portFile.path]
try fixture.run()
defer { fixture.terminate(); fixture.waitUntilExit() }
wait("HTTP fixture startup") { FileManager.default.fileExists(atPath: portFile.path) }
let port = try String(contentsOf: portFile, encoding: .utf8)
let origin = "http://127.0.0.1:\(port)"
var website = SourceDefinition(name: "Website fixture", kind: .website, location: origin)
try store.save(website)
complete = false
collector.refresh(sourceID: website.id) { result = $0; complete = true }
wait("real HTTP collection") { complete }
expect(result == nil, "HTTP collection failed")
let websiteFirst = store.snapshots(sourceID: website.id)[0]
expect(websiteFirst.items[0].preview.contains("Collected over HTTP.") && !websiteFirst.items[0].preview.contains("hidden()"), "HTML readable extraction")
for endpoint in ["error", "large"] {
    website.location = origin + "/" + endpoint
    try store.save(website)
    complete = false
    collector.refresh(sourceID: website.id) { result = $0; complete = true }
    wait("HTTP \(endpoint)") { complete }
    expect(result != nil && store.status(sourceID: website.id).lastError != nil, "HTTP \(endpoint) must surface failure")
    expect(store.snapshots(sourceID: website.id).first?.id == websiteFirst.id, "HTTP error must preserve last successful snapshot")
}
website.location = origin + "/changed"; try store.save(website)
complete = false
collector.refresh(sourceID: website.id) { result = $0; complete = true }
wait("HTTP change") { complete }
expect(store.status(sourceID: website.id).lastError == nil && store.snapshots(sourceID: website.id).count == 2, "Successful refresh clears error and adds evidence")
website.location = origin + "/slow"; try store.save(website)
complete = false
collector.refresh(sourceID: website.id) { result = $0; complete = true }
try collector.pause(sourceID: website.id, paused: true)
wait("pause in flight") { complete }
expect(store.snapshots(sourceID: website.id).count == 2 && !store.status(sourceID: website.id).refreshing, "Paused work must not land late")
var automatic = SourceDefinition(name: "Automatic website", kind: .website, location: origin + "/changed")
try store.save(automatic)
collector.start()
wait("automatic source polling without desktop watcher") { store.status(sourceID: automatic.id).lastSuccess != nil }
expect(store.status(sourceID: automatic.id).itemCount == 1, "Independent scheduler collects website with no WorkflowWatcher instance")
collector.stop()
let old = store.snapshots(sourceID: mail.id)[0]
let oldURL = store.snapshotURL(sourceID: mail.id, snapshotID: old.id)!.appendingPathComponent("snapshot.json")
let expired = SourceSnapshot(id: old.id, sourceID: old.sourceID, collectedAt: Date().addingTimeInterval(-400 * 86400), items: old.items, bytes: old.bytes, skippedCount: old.skippedCount)
try JSONEncoder().encode(expired).write(to: oldURL, options: .atomic)
store.pruneExpiredSnapshots()
expect(store.snapshots(sourceID: mail.id).isEmpty, "Retention expires even the latest copy without touching live originals")
expect(FileManager.default.fileExists(atPath: emails.appendingPathComponent("message.eml").path), "Retention must not delete originals")
let sourceFolder = store.snapshotURL(sourceID: local.id, snapshotID: snapshot.id)!.deletingLastPathComponent()
try store.remove(sourceID: local.id)
expect(store.source(id: local.id) == nil && FileManager.default.fileExists(atPath: sourceFolder.path), "Disconnect keeps copies")
expect(store.snapshotURL(sourceID: "../escape", snapshotID: "bad") == nil, "Snapshot path traversal rejected")
collector.stop()
print("PASS: Sources registry, immutable snapshots, read projections, local bounds/symlinks, EML/mbox MIME, frozen context, persistence, real HTTP success/change/failure/oversize, pause cancellation, independent polling, age retention and disconnect retention")
