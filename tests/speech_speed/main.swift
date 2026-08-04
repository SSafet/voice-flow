import Cocoa
import Foundation

// VF-56: speech speed is one persisted setting. The pill's chip, the
// Speech drawer, and the Settings window all read/write UserSettings.ttsSpeed,
// so the contract here is: full-range round-trip through settings.json and
// the engine clamp both honor 0.25…4.0.

setenv("VOICE_FLOW_CONFIG_ROOT",
       FileManager.default.temporaryDirectory
           .appendingPathComponent("vf-speed-test-\(UUID().uuidString)").path, 1)

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// Round-trip: a pill-set 2.7× must survive save/load exactly (the old
// Settings slider clamped to 0.5–2.0 and silently rewrote it).
do {
    let writer = UserSettings()
    writer.ttsSpeed = 2.7
    writer.save()

    let reader = UserSettings()
    reader.load()
    expect(abs(reader.ttsSpeed - 2.7) < 0.0001,
           "ttsSpeed must round-trip through settings.json (got \(reader.ttsSpeed))")
}

// Engine clamp matches the UI range end to end.
do {
    var request = TTSRequest(text: "x", voice: "alloy", speed: 9.9, instructions: "")
    expect(request.normalized().speed == 4.0, "speed clamps at 4.0")
    request.speed = 0.01
    expect(request.normalized().speed == 0.25, "speed clamps at 0.25")
    request.speed = 2.7
    expect(request.normalized().speed == 2.7, "in-range speed is untouched")
}

print("speech speed tests passed")
