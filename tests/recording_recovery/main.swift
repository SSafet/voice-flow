import Foundation
import GRDB

// RecordingRecovery (07 §3.12): the seventeen recordings that were saved
// before transcription and never delivered become dictations, or "no speech
// found", or stay with their reason. Retrying is safe to repeat.
//
// The speech-to-text call is the one outside boundary; it is an input to the
// recovery, exercised here with a deterministic transcriber. Everything else
// is the real index, the real folder and the real DictationStore.

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
private var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!

private func makeRoot(_ name: String) -> URL {
    let url = VoiceFlowPaths.shared.configRoot.appendingPathComponent(name, isDirectory: true)
    try? files.removeItem(at: url)
    try! files.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func epoch(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0, _ ss: Int = 0) -> Int {
    Int(utc.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm, second: ss))!
        .timeIntervalSince1970)
}

@discardableResult
private func addRecording(_ index: CapturedIndex, root: URL, uuid: String, tStart: Int,
                          extraJSON: String? = nil) -> String {
    let path = "pending-audio/\(uuid).wav"
    let url = root.appendingPathComponent(path)
    try! files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data("RIFFfake".utf8).write(to: url)
    let id = CapturedItemID.recording(uuid)
    try! index.upsert(CapturedItemRow(
        id: id, kind: .recording, source: .recording, tStart: tStart, tEnd: tStart,
        path: path, extraJSON: extraJSON ?? "{\"state\":\"undelivered\"}"))
    return id
}

private func fileExists(_ root: URL, _ relative: String) -> Bool {
    files.fileExists(atPath: root.appendingPathComponent(relative).path)
}

private struct StubTranscriber: SpeechTranscribing {
    let answers: [String: String]
    let failuresByID: [String: Error]
    func transcribe(fileURL: URL) throws -> String {
        let uuid = fileURL.deletingPathExtension().lastPathComponent
        if let error = failuresByID[uuid] { throw error }
        return answers[uuid] ?? ""
    }
}
private struct NoInternet: Error {}

let root = makeRoot("recovery")
let index = CapturedIndex(pool: try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root)))
let dictations = DictationStore(root: root)

let deliveredID = addRecording(index, root: root, uuid: "11111111-1111-1111-1111-111111111111",
                               tStart: epoch(2026, 9, 5, 10, 30, 0))
let noSpeechID = addRecording(index, root: root, uuid: "22222222-2222-2222-2222-222222222222",
                              tStart: epoch(2026, 9, 12, 15, 45, 0))
let failedID = addRecording(index, root: root, uuid: "33333333-3333-3333-3333-333333333333",
                            tStart: epoch(2026, 9, 12, 16, 0, 0))

let recovery = RecordingRecovery(
    index: index, root: root,
    transcriber: StubTranscriber(
        answers: ["11111111-1111-1111-1111-111111111111": "  ask Georgi about the VAT threshold  ",
                  "33333333-3333-3333-3333-333333333333": "unused"],
        failuresByID: ["33333333-3333-3333-3333-333333333333": NoInternet()]),
    dictations: dictations,
    now: { Date(timeIntervalSince1970: TimeInterval(epoch(2026, 9, 19, 12, 0, 0))) })

expect(try recovery.undelivered().count == 3, "the three undelivered recordings were not listed")

let result = recovery.retry(ids: nil)
expect(result.started == 3, "the retry started \(result.started) of 3 recordings")
expect(result.delivered == 1, "the retry delivered \(result.delivered), not 1")
expect(result.noSpeech == 1, "the retry found \(result.noSpeech) empty, not 1")
expect(result.failed == 1, "the retry failed \(result.failed), not 1")

// ── a text result becomes a kept dictation with the recording's own time ───

expect(try index.item(id: deliveredID) == nil, "the delivered recording is still in the index")
expect(!fileExists(root, "pending-audio/11111111-1111-1111-1111-111111111111.wav"),
       "the delivered recording's file was not removed")
let kept = dictations.all().filter { $0.id == "11111111-1111-1111-1111-111111111111" }
expect(kept.count == 1, "the delivered recording did not become exactly one dictation")
expect(kept.first?.text == "ask Georgi about the VAT threshold",
       "the dictation did not keep the transcription: \(kept.first?.text ?? "nil")")
expect(kept.first?.effectiveDestination == .kept,
       "the recovered dictation was not kept: \(String(describing: kept.first?.effectiveDestination))")
expect(kept.first?.timestamp?.hasPrefix("2026-09-05T10:30:00") == true,
       "the recovered dictation lost its original time: \(kept.first?.timestamp ?? "nil")")

// ── an empty result is "no speech found", and its file is kept ──────────────

guard let noSpeechRow = try index.item(id: noSpeechID) else {
    failures.append("the empty recording was removed instead of marked")
    finish("recording recovery")
}
expect(RecordingRecovery.state(of: noSpeechRow) == .noSpeechFound,
       "an empty transcript was not marked 'no speech found'")
expect(noSpeechRow.extraJSON?.contains("no_speech_at") == true,
       "the 'no speech found' marking carries no time for the seven-day rule")
expect(fileExists(root, "pending-audio/22222222-2222-2222-2222-222222222222.wav"),
       "the 'no speech found' recording's file was removed before its seven days")

// ── an error keeps the recording, with its reason, still retryable ─────────

guard let failedRow = try index.item(id: failedID) else {
    failures.append("a failed recording was removed instead of kept")
    finish("recording recovery")
}
expect(RecordingRecovery.state(of: failedRow) == .undelivered,
       "a recording whose transcription errored is no longer retryable")
expect(failedRow.extraJSON?.contains("last_error") == true,
       "a failed recording kept no reason")
expect(fileExists(root, "pending-audio/33333333-3333-3333-3333-333333333333.wav"),
       "a failed recording's file was removed")

// ── retrying again repeats only what is still undelivered ──────────────────

let second = recovery.retry(ids: nil)
expect(second.started == 1, "the second retry started \(second.started), not only the failed one")
expect(try index.item(id: deliveredID) == nil, "the second retry re-delivered a recording")
expect(dictations.all().filter { $0.id == "11111111-1111-1111-1111-111111111111" }.count == 1,
       "the second retry made a second dictation for the same recording")

// ── the delivery path's own empty transcript is a "no speech found" too ────

let runUUID = "44444444-4444-4444-4444-444444444444"
let runID = addRecording(index, root: root, uuid: runUUID, tStart: epoch(2026, 9, 12, 12, 0, 0))
recovery.markNoSpeech(recordingID: runID)
guard let marked = try index.item(id: runID) else {
    failures.append("markNoSpeech removed the recording instead of marking it")
    finish("recording recovery")
}
expect(RecordingRecovery.state(of: marked) == .noSpeechFound,
       "the delivery path's empty transcript was not marked 'no speech found'")
expect(fileExists(root, "pending-audio/\(runUUID).wav"),
       "the delivery path's empty transcript removed the file instead of leaving it for seven days")

finish("recording recovery")
