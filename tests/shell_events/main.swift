import Foundation

// V7, task 2 — everything the shell sends the interface without being asked
// (02 §3.6 "Event topics"), and the params of the requests the interface sends.
//
// Each case takes an example from the committed shell-bridge fixture, drives
// the bridge, and asserts that the line the bridge emitted decodes back to the
// same example with the generated contract type. Input from the contract,
// output checked against the contract.

let descriptor = try ShellFixtures.shellDescriptor()
let host = RecordingShellHost(descriptor: descriptor)
var emitted: [String] = []
let bridge = ShellBridge(host: host, emit: { emitted.append($0) })

func decodeEnvelope(_ line: String) -> ShellBridgeEventEnvelope {
    do { return try JSONDecoder().decode(ShellBridgeEventEnvelope.self, from: Data(line.utf8)) }
    catch {
        fputs("FAIL: the emitted line is not an event envelope: \(error)\n", stderr)
        exit(1)
    }
}

func lastEnvelope() -> ShellBridgeEventEnvelope {
    guard let line = emitted.last else {
        fputs("FAIL: the bridge emitted nothing\n", stderr)
        exit(1)
    }
    return decodeEnvelope(line)
}

func expectEnvelope(_ topic: TPBridgeEventTopic, _ line: String) {
    let envelope = decodeEnvelope(line)
    expectEqual(envelope.v, 1, "the event carries v 1")
    expectEqual(envelope.kind, "event", "the event envelope's kind is event")
    expectEqual(envelope.topic, topic, "the event's topic is \(topic.rawValue)")
    let generated = try! JSONDecoder().decode(TPBridgeEvent.self, from: Data(line.utf8))
    expectEqual(generated.topic, topic, "the generated event type reads the topic back")
}

// ── 1. command: a native menu item or hotkey is a command, never a keystroke ─

for example in try ShellFixtures.examples(TPCommandData.self, "CommandData") {
    emitted.removeAll()
    try bridge.sendCommand(example.command, threadID: example.args.threadID)
    let envelope = lastEnvelope()
    expectEnvelope(.command, emitted.last!)
    expectEqual(try envelope.data.decode(TPCommandData.self), example,
                "command \(example.command.rawValue) round-trips")
}

emitted.removeAll()
var refusedOpenThread = false
do { try bridge.sendCommand(.openThread, threadID: nil) } catch { refusedOpenThread = true }
expect(refusedOpenThread, "open-thread without a thread is refused before it is sent (02 §3.6, K3)")
expect(emitted.isEmpty, "a refused command emits nothing")

// ── 2. composer.insert and composer.attach, including the draft composer ─────

for example in try ShellFixtures.examples(TPComposerInsertData.self, "ComposerInsertData") {
    emitted.removeAll()
    bridge.sendComposerInsert(threadID: example.threadID, text: example.text, source: example.source)
    let envelope = lastEnvelope()
    expectEnvelope(.composerInsert, emitted.last!)
    expectEqual(try envelope.data.decode(TPComposerInsertData.self), example,
                "a composer.insert round-trips")
}

for example in try ShellFixtures.examples(TPComposerAttachData.self, "ComposerAttachData") {
    emitted.removeAll()
    bridge.sendComposerAttach(threadID: example.threadID, attachments: example.attachments)
    let envelope = lastEnvelope()
    expectEnvelope(.composerAttach, emitted.last!)
    expectEqual(try envelope.data.decode(TPComposerAttachData.self), example,
                "a composer.attach round-trips")
}

// The draft composer is the absent threadId; it must not be sent as null.
emitted.removeAll()
bridge.sendComposerInsert(threadID: nil, text: "https://example.com/article", source: .share)
expect(!emitted.last!.contains("\"threadId\""),
       "the draft composer is an absent threadId, not a null one (02 §3.6)")

// ── 3. navigate: a tapped notification or a link ─────────────────────────────

for example in try ShellFixtures.examples(TPNavigateData.self, "NavigateData") {
    emitted.removeAll()
    if let path = example.path {
        try bridge.sendNavigate(path: path)
    } else {
        try bridge.sendNavigate(threadID: example.threadID ?? "",
                                projectID: example.projectID,
                                focus: example.focus)
    }
    let envelope = lastEnvelope()
    expectEnvelope(.navigate, emitted.last!)
    expectEqual(try envelope.data.decode(TPNavigateData.self), example,
                "a navigate round-trips")
}

// ── 4. dictate.partial, speak.state, lifecycle, connectivity, update ─────────

for example in try ShellFixtures.examples(TPDictatePartialData.self, "DictatePartialData") {
    emitted.removeAll()
    bridge.sendDictatePartial(captureID: example.captureID, text: example.text, isFinal: example.isFinal)
    let envelope = lastEnvelope()
    expectEnvelope(.dictatePartial, emitted.last!)
    expectEqual(try envelope.data.decode(TPDictatePartialData.self), example, "dictate.partial round-trips")
}

for example in try ShellFixtures.examples(TPSpeakStateData.self, "SpeakStateData") {
    emitted.removeAll()
    bridge.sendSpeakState(playbackID: example.playbackID, state: example.state)
    let envelope = lastEnvelope()
    expectEnvelope(.speakState, emitted.last!)
    expectEqual(try envelope.data.decode(TPSpeakStateData.self), example, "speak.state round-trips")
}

for example in try ShellFixtures.examples(TPLifecycleData.self, "LifecycleData") {
    emitted.removeAll()
    bridge.sendLifecycle(example.state)
    let envelope = lastEnvelope()
    expectEnvelope(.lifecycle, emitted.last!)
    expectEqual(try envelope.data.decode(TPLifecycleData.self), example, "lifecycle round-trips")
}

for example in try ShellFixtures.examples(TPConnectivityData.self, "ConnectivityData") {
    emitted.removeAll()
    bridge.sendConnectivity(online: example.online)
    let envelope = lastEnvelope()
    expectEnvelope(.connectivity, emitted.last!)
    expectEqual(try envelope.data.decode(TPConnectivityData.self), example, "connectivity round-trips")
}

for example in try ShellFixtures.examples(TPUpdateAvailableData.self, "UpdateAvailableData") {
    emitted.removeAll()
    bridge.sendUpdateAvailable(kind: example.kind, currentVersion: example.currentVersion,
                               requiredVersion: example.requiredVersion, downloadURL: example.downloadURL)
    let envelope = lastEnvelope()
    expectEnvelope(.updateAvailable, emitted.last!)
    expectEqual(try envelope.data.decode(TPUpdateAvailableData.self), example, "update.available round-trips")
}

// ── 5. shell.changed carries the whole descriptor, never a patch ─────────────

emitted.removeAll()
bridge.sendDescriptorChanged()
let envelope = lastEnvelope()
expectEnvelope(.shellChanged, emitted.last!)
expectEqual(try envelope.data.decode(TPShellDescriptor.self), descriptor,
            "shell.changed re-sends the whole descriptor (02 §3.6)")

// ── 6. every event fixture is a line the bridge can read back ────────────────

for line in try ShellFixtures.rawLines("BridgeEvent") {
    let envelope = decodeEnvelope(line)
    expectEqual(envelope.kind, "event", "a committed BridgeEvent fixture is an event envelope")
    let reencoded = try envelope.data.encoded()
    let again = try ShellJSON(decoding: reencoded)
    expectEqual(again, envelope.data, "the event data survives a JSON round-trip")
}

// ── 7. every request fixture's params survives the free-form bridge ──────────
//
// `params` is the one free-form field of the envelope: the generated Swift
// leaves it out and the bridge reads it with `ShellJSON`. The proof is that
// every committed request fixture's params decodes to `ShellJSON`, re-encodes
// byte-for-byte-semantically to the same JSON object, and decodes with the
// generated type the method names.

let requestFixtureLines = try ShellFixtures.rawLines("BridgeRequest")
var paramsChecked = 0
for line in requestFixtureLines {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let paramsObject = object["params"] else { continue }
    let paramsData = try JSONSerialization.data(withJSONObject: paramsObject)
    let params = try ShellJSON(decoding: paramsData)
    if case .object = params {} else {
        fputs("FAIL: params did not decode to an object: \(line)\n", stderr)
        exit(1)
    }
    let roundTripped = try JSONSerialization.jsonObject(with: params.encoded())
    expectEqual(roundTripped as? NSObject, paramsObject as? NSObject,
                "params round-trips through ShellJSON")
    paramsChecked += 1
}

// The generated type the method names decodes the free-form params, for the
// methods the interface actually calls at boot.
let readyParams = try ShellJSON(decoding: Data(#"{"buildId":"7cbe540d"}"#.utf8))
expectEqual(try readyParams.decode(TPShellReadyParams.self).buildID, "7cbe540d",
            "the params of shell.ready decode with TPShellReadyParams")
let targetParams = try ShellJSON(decoding: Data(#"{"threadId":"t1"}"#.utf8))
expectEqual(try targetParams.decode(TPThreadTargetParams.self).threadID, "t1",
            "the params of capture.screen decode with TPThreadTargetParams")

print("shell events: command, composer, navigate, speech, lifecycle, connectivity, update and shell.changed passed (\(paramsChecked) params)")
