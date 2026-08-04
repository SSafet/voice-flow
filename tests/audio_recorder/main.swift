import Cocoa
import Foundation

// VF-44 regression suite. Compiled against the full app sources with
// -D VOICE_FLOW_QA so AudioRecorder's fixture path stands in for a live
// microphone: start() loads a known 3,200-sample voiced buffer without
// touching CoreAudio, and the stop/drain machinery runs for real.

// The fixture flag must be in the environment before AudioRecorder reads it.
setenv("VOICE_FLOW_QA_AUDIO_FIXTURE", "1", 1)

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func pumpRunLoop(seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

let fixtureBytes = 3_200 * 2  // 3,200 int16 samples

// ── 1. The exact reported sequence: stop, then a start inside the drain
//       window. The draining recording must be settled and delivered before
//       the new run touches the buffer — never destroyed.
do {
    let recorder = AudioRecorder()
    recorder.start()
    expect(recorder.isRecording, "fixture start must report recording")
    expect(recorder.isBusy, "recording recorder must be busy")

    var results: [Data?] = []
    recorder.stop { results.append($0) }
    expect(!recorder.isRecording, "stop flips isRecording immediately")
    expect(recorder.isBusy, "draining recorder must still be busy (VF-44)")
    expect(results.isEmpty, "completion must not fire before drain settles")

    // The racing start — under the pre-fix code this reset audioData and the
    // first recording's bytes were unrecoverable.
    recorder.start()
    expect(results.count == 1, "racing start must settle the pending drain synchronously")
    expect(results[0] != nil, "the draining recording must survive the racing start")
    expect(results[0]?.count == fixtureBytes,
           "first recording bytes must be intact (got \(results[0]?.count ?? -1), want \(fixtureBytes))")
    expect(recorder.isRecording, "the racing start must still yield a live recording")

    // The original drain timer must not double-fire the completion.
    pumpRunLoop(seconds: 0.35)
    expect(results.count == 1, "stop completion must fire exactly once")
    recorder.cancel()
}

// ── 2. A normal stop with no racing start still completes via the drain
//       timer and stops being busy.
do {
    let recorder = AudioRecorder()
    recorder.start()
    var results: [Data?] = []
    recorder.stop { results.append($0) }
    let deadline = Date().addingTimeInterval(2)
    while results.isEmpty && Date() < deadline { pumpRunLoop(seconds: 0.05) }
    expect(results.count == 1, "drain timer must complete an unraced stop")
    expect(results[0]?.count == fixtureBytes, "unraced stop must deliver the full recording")
    expect(!recorder.isBusy, "settled recorder must not be busy")
}

// ── 3. PendingAudioStore: WAV round-trip, removal, pruning.
do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("vf-pending-audio-test-\(UUID().uuidString)").path
    let root = VoiceFlowPaths(environment: [VoiceFlowPaths.configRootEnvironmentKey: tmp])
    let pcm = Data((0..<6400).map { UInt8($0 % 251) })
    let runId = UUID()

    let url = PendingAudioStore.save(pcm: pcm, runId: runId, sampleRate: 16000, root: root)
    expect(url != nil, "save must return the written file")
    let written = try! Data(contentsOf: url!)
    expect(written.count == 44 + pcm.count, "WAV must be header + payload")
    expect(String(data: written.prefix(4), encoding: .ascii) == "RIFF", "WAV must start with RIFF")
    expect(String(data: written.subdata(in: 8..<12), encoding: .ascii) == "WAVE", "WAV must declare WAVE")
    let rate = written.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
    expect(UInt32(littleEndian: rate) == 16000, "WAV must record the sample rate")
    expect(written.suffix(pcm.count) == pcm, "payload bytes must be intact")
    expect(PendingAudioStore.pendingFiles(root: root).count == 1, "one pending file after save")

    PendingAudioStore.remove(runId: runId, root: root)
    expect(PendingAudioStore.pendingFiles(root: root).isEmpty, "remove must delete the file")

    // Pruning: save beyond the cap with strictly ordered mtimes; only the
    // newest keepLimit survive and the oldest are the ones dropped.
    var ids: [UUID] = []
    for i in 0..<(PendingAudioStore.keepLimit + 3) {
        let id = UUID()
        ids.append(id)
        _ = PendingAudioStore.save(pcm: pcm, runId: id, sampleRate: 16000, root: root)
        let file = PendingAudioStore.directory(root: root)
            .appendingPathComponent("\(id.uuidString).wav")
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(i))],
            ofItemAtPath: file.path)
    }
    // One more save triggers the prune against the ordered mtimes.
    let last = UUID()
    _ = PendingAudioStore.save(pcm: pcm, runId: last, sampleRate: 16000, root: root)
    let kept = Set(PendingAudioStore.pendingFiles(root: root).map { $0.lastPathComponent })
    expect(kept.count <= PendingAudioStore.keepLimit,
           "prune must cap pending files at \(PendingAudioStore.keepLimit) (got \(kept.count))")
    expect(!kept.contains("\(ids[0].uuidString).wav"), "prune must drop the oldest file first")
    expect(kept.contains("\(last.uuidString).wav"), "prune must keep the newest file")
    try? FileManager.default.removeItem(atPath: tmp)
}

print("audio recorder tests passed")
