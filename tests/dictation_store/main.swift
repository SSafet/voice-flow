import Foundation

// DictationStore, the append-only dictation archive, and the record sync's
// acting device (07 §3.4).
//
// `dictations.json` keeps its shape and its present reader, the record sync,
// and it keeps only the newest 200 entries. A derived index cannot be rebuilt
// from a source that forgets, so every dictation is also appended to
// `dictations/<yyyy-mm>.jsonl`, whoever stored it, and a dictation made on the
// phone arrives through the record sync carrying the device that made it.

func vflog(_ message: String) {}

private var failures: [String] = []
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do { if try !condition() { failures.append(message) } }
    catch { failures.append("\(message) — the check itself threw \(error)") }
}
private func finish(_ label: String) -> Never {
    if failures.isEmpty { print("\(label): ok"); exit(0) }
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    fputs("\(label): \(failures.count) failure(s)\n", stderr)
    exit(1)
}

guard VoiceFlowPaths.shared.isIsolated else {
    fputs("FAIL: VOICE_FLOW_CONFIG_ROOT is not an isolated directory\n", stderr)
    exit(1)
}

private let files = FileManager.default
private func makeRoot(_ name: String) -> URL {
    let url = VoiceFlowPaths.shared.configRoot.appendingPathComponent(name, isDirectory: true)
    try? files.removeItem(at: url)
    try! files.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func entry(_ id: String, _ text: String, _ timestamp: String,
                   destination: CaptureDestination = .kept,
                   originDevice: String? = nil) -> HistoryEntry {
    HistoryEntry(text: text, time: String(timestamp.dropFirst(11).prefix(5)),
                 timestamp: timestamp, id: id, destination: destination,
                 seen: nil, capability: .dictate, attachments: nil,
                 captureId: nil, originDevice: originDevice)
}

// ── the archive remembers what the file forgets ───────────────────────────

do {
    let root = makeRoot("archive")
    let store = DictationStore(root: root)
    var written: [HistoryEntry] = []
    for index in 0..<250 {
        let day = String(format: "%02d", (index % 28) + 1)
        written.append(entry("id-\(index)", "dictation number \(index)",
                             "2026-09-\(day)T10:\(String(format: "%02d", index % 60)):00Z"))
    }
    // Newest first, as the file has always been ordered.
    store.save(Array(written.reversed()))

    let onDisk = store.all()
    expect(onDisk.count == DictationStore.keepInFile,
           "dictations.json keeps \(onDisk.count) entries, not \(DictationStore.keepInFile)")
    expect(onDisk.first?.id == "id-249", "dictations.json is not newest first")

    let archived = DictationArchive.load(root: root)
    expect(archived.count == 250,
           "the archive kept \(archived.count) of 250 dictations — the source still forgets")
    expect(Set(archived.compactMap(\.id)).count == 250, "the archive folded away distinct dictations")
    expect(archived.map(\.timestamp) == written.sorted { $0.timestamp! > $1.timestamp! }.map(\.timestamp), "the archive is not newest first by creation time")
}

// ── a month per file, chosen by the dictation's own time ──────────────────

do {
    let root = makeRoot("months")
    let store = DictationStore(root: root)
    store.save([entry("august", "older", "2026-08-31T23:59:00Z"),
                entry("september", "newer", "2026-09-01T00:01:00Z")])
    let august = DictationArchive.url(root: root, month: "2026-08")
    let september = DictationArchive.url(root: root, month: "2026-09")
    expect(files.fileExists(atPath: august.path), "no archive file for August")
    expect(files.fileExists(atPath: september.path), "no archive file for September")
    let augustText = (try? String(contentsOf: august, encoding: .utf8)) ?? ""
    expect(augustText.contains("\"august\"") && !augustText.contains("\"september\""),
           "a dictation was archived in the wrong month's file")
    expect(DictationArchive.month(for: entry("x", "t", "2026-08-31T23:59:00Z")) == "2026-08",
           "the month is not taken from the dictation's own time")
}

// ── appending twice is one dictation, and a later line wins ───────────────

do {
    let root = makeRoot("idempotent")
    let store = DictationStore(root: root)
    let first = entry("same", "first wording", "2026-09-12T14:03:22Z")
    store.save([first])
    store.save([first])
    expect(DictationArchive.load(root: root).count == 1,
           "the same dictation stored twice became two")

    var corrected = first
    corrected.text = "corrected wording"
    store.save([corrected])
    let folded = DictationArchive.load(root: root)
    expect(folded.count == 1, "a corrected dictation became a second one")
    expect(folded.first?.text == "corrected wording",
           "reading the archive did not take the later line: \(folded.first?.text ?? "nothing")")

    store.remove(id: "same")
    expect(DictationArchive.load(root: root).isEmpty,
           "a deleted dictation is still read out of the archive")
    expect(store.all().isEmpty, "a deleted dictation is still in dictations.json")
    // A tombstone is a line, not an erasure: the file only ever grows.
    let monthFile = DictationArchive.url(root: root, month: "2026-09")
    let text = (try? String(contentsOf: monthFile, encoding: .utf8)) ?? ""
    expect(text.split(separator: "\n").count == 3,
           "the archive is not append-only, or it appended an unchanged dictation: "
           + "\(text.split(separator: "\n").count) lines instead of 3")
}

// ── every path that stores a dictation reaches the archive ────────────────

do {
    let root = makeRoot("observers")
    let store = DictationStore(root: root)
    var recordSyncSaw = 0
    var somebodyElseSaw = 0
    store.addPersistObserver { _ in recordSyncSaw += 1 }
    store.addPersistObserver { _ in somebodyElseSaw += 1 }
    store.save([entry("hooked", "spoken", "2026-09-12T14:03:22Z")])
    expect(recordSyncSaw == 1, "the first observer was not called")
    expect(somebodyElseSaw == 1,
           "a second observer silently unsubscribed the first — the hook is still one slot")
    expect(DictationArchive.load(root: root).count == 1,
           "the archive did not hear a save made through another caller's hook")

    store.upsert(entry("upserted", "arrived later", "2026-09-13T09:00:00Z"))
    expect(store.all().count == 2, "upsert did not add the dictation to the file")
    expect(DictationArchive.load(root: root).count == 2, "upsert did not reach the archive")
    expect(recordSyncSaw == 2, "upsert did not tell the observers")
}

// ── the dictations that dropped out of the newest 200 are recovered ───────

do {
    let root = makeRoot("import")
    let store = DictationStore(root: root)
    store.save([entry("kept-1", "still here", "2026-09-12T14:03:22Z")])

    let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
    try! files.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    let backup = backupDirectory.appendingPathComponent("dictations-july.json")
    let old = [entry("old-1", "from July", "2026-07-01T08:00:00Z"),
               entry("kept-1", "still here", "2026-09-12T14:03:22Z")]
    try! JSONEncoder().encode(old).write(to: backup)

    // A data-source copy of the same file, with one entry that never had an id.
    let snapshot = backupDirectory.appendingPathComponent("builtin-dictations.json")
    var noIdentity = entry("", "spoken before identities existed", "2026-06-02T11:00:00Z")
    noIdentity.id = nil
    try! JSONEncoder().encode([noIdentity, old[0]]).write(to: snapshot)

    let result = DictationArchive.importOnce(from: [backup, snapshot], root: root)
    expect(result.added == 2, "the import added \(result.added) dictations, not the 2 that are new")
    let recovered = DictationArchive.load(root: root)
    expect(recovered.count == 3, "the archive holds \(recovered.count) dictations after the import, not 3")
    expect(recovered.contains { $0.id == "old-1" }, "the July dictation was not recovered")
    expect(recovered.contains { $0.text == "spoken before identities existed" },
           "a dictation with no identity was dropped instead of matched by time and text")

    let sizeBefore = (try? files.attributesOfItem(atPath:
        DictationArchive.url(root: root, month: "2026-07").path)[.size] as? Int) ?? 0
    let again = DictationArchive.importOnce(from: [backup, snapshot], root: root)
    expect(again.added == 0, "importing the same files twice added \(again.added) dictations")
    let sizeAfter = (try? files.attributesOfItem(atPath:
        DictationArchive.url(root: root, month: "2026-07").path)[.size] as? Int) ?? 0
    expect(sizeBefore == sizeAfter, "importing twice rewrote the archive")
    expect(DictationArchive.load(root: root).count == 3, "importing twice changed what the archive holds")
}

// ── the record sync keeps the device that made the change ─────────────────

do {
    let page = """
    {"changes":[{"seq":"41","kind":"record","actor":{"kind":"device","deviceId":"dev-phone"},
      "record":{"collection":"dictations","recordId":"rec-1","version":"3","schemaVersion":1,
                "payload":{"text":"ask Georgi about the VAT threshold","destination":"kept",
                           "createdAt":"2026-09-14T07:12:00Z"},"seq":"41"}},
     {"seq":"42","kind":"record",
      "record":{"collection":"dictations","recordId":"rec-2","version":"1","schemaVersion":1,
                "payload":{"text":"no actor on this one","destination":"kept",
                           "createdAt":"2026-09-14T07:13:00Z"},"seq":"42"}}],
     "nextCursor":"42","hasMore":false,"highWatermark":"42","epoch":"e1",
     "serverTime":"2026-09-14T07:14:00Z"}
    """
    guard let decoded = try? JSONDecoder().decode(CloudPage.self, from: Data(page.utf8)) else {
        failures.append("a change page carrying an acting device no longer decodes")
        finish("dictation store")
    }
    expect(decoded.changes.first?.actor?.deviceId == "dev-phone",
           "the acting device was dropped by the decoder")
    expect(decoded.changes.count == 2 && decoded.changes[1].actor == nil,
           "a change without an acting device no longer decodes")

    guard let record = decoded.changes.first?.record else {
        failures.append("the change carried no record")
        finish("dictation store")
    }
    let fromPhone = RemoteDictation.entry(from: record, actorDeviceID: "dev-phone",
                                          thisDeviceID: "dev-mac", existing: nil)
    expect(fromPhone?.id == "rec-1", "the dictation did not take the record's identity")
    expect(fromPhone?.originDevice == "dev-phone",
           "a dictation made on the phone is not marked as made there")
    expect(fromPhone?.text == "ask Georgi about the VAT threshold", "the dictation lost its words")
    expect(fromPhone?.effectiveDestination == .kept, "the dictation lost its destination")
    expect(fromPhone?.timestamp == "2026-09-14T07:12:00Z", "the dictation lost the time it was made")

    let fromHere = RemoteDictation.entry(from: record, actorDeviceID: "dev-mac",
                                         thisDeviceID: "dev-mac", existing: nil)
    expect(fromHere?.originDevice == nil, "a dictation made on this Mac was marked as made elsewhere")

    // Changes are applied in order, so the change that created the record is
    // the one that names its device; a later edit from anywhere never moves it.
    let existing = entry("rec-1", "older wording", "2026-09-14T07:12:00Z", originDevice: "dev-phone")
    let edited = RemoteDictation.entry(from: record, actorDeviceID: "dev-mac",
                                       thisDeviceID: "dev-mac", existing: existing)
    expect(edited?.originDevice == "dev-phone",
           "an edit made here moved the dictation's origin device")

    let deleted = CloudRecord(collection: .dictations, recordId: "rec-1", version: "4",
                              schemaVersion: 1, payload: nil,
                              deletedAt: "2026-09-14T08:00:00Z", seq: "43")
    expect(RemoteDictation.isDeletion(deleted), "a tombstoned record was not recognised as a deletion")
    expect(RemoteDictation.entry(from: deleted, actorDeviceID: "dev-phone",
                                 thisDeviceID: "dev-mac", existing: nil) == nil,
           "a tombstoned record was turned into a dictation")

    let root = makeRoot("remote")
    let store = DictationStore(root: root)
    if let fromPhone { store.upsert(fromPhone) }
    let reloaded = DictationStore(root: root).all()
    expect(reloaded.first?.originDevice == "dev-phone",
           "the origin device did not survive a reload of dictations.json")
    expect(DictationArchive.load(root: root).first?.originDevice == "dev-phone",
           "the origin device did not survive the archive")
}

finish("dictation store")

final class PendingInteraction { var sessionId: String? }
struct CaptureSummary {}
