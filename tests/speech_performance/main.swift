import Cocoa
import Foundation

// Real controller + URLSession + AVAudioEngine; HTTP fixture supplies silence.
setenv("VOICE_FLOW_QA_OPENAI_API_KEY", "fixture", 1)
let scenario = ProcessInfo.processInfo.environment["VF_SPEECH_CASE"] ?? "steady"
let controller = TTSController()
let start = ProcessInfo.processInfo.systemUptime
var firstPlaying: Double?
var finishedAt: Double?
var maxPosition = 0.0
var error: String?
var paused = false
var pauseViolation = false
var stopped = false
var stopViolation = false
controller.onQueuedSpeechFinished = { finishedAt = ProcessInfo.processInfo.systemUptime - start }
controller.onStatusChanged = { status in
    if status.phase == .playing {
        if firstPlaying == nil { firstPlaying = ProcessInfo.processInfo.systemUptime - start }
        if paused { pauseViolation = true }
        if stopped { stopViolation = true }
    }
    maxPosition = max(maxPosition, status.currentTime)
    if status.phase == .error { error = status.message }
}
try controller.beginQueuedSpeech(sentences: [scenario], voice: "coral", speed: 1, instructions: "")
if scenario == "pause" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { paused = true; controller.pause() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
        paused = false
        controller.togglePause()
    }
}
if scenario == "cancel" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { stopped = true; controller.stop() }
}
if scenario == "replace" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        try! controller.beginQueuedSpeech(sentences: ["short"], voice: "coral", speed: 1, instructions: "")
    }
}
while ProcessInfo.processInfo.systemUptime - start < 3.5 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
}
let result: [String: Any] = ["scenario": scenario, "first_playing_ms": firstPlaying.map { $0 * 1000 } ?? -1,
    "queue_finished_ms": finishedAt.map { $0 * 1000 } ?? -1,
    "max_rendered_position_seconds": maxPosition,
    "pause_violation": pauseViolation, "stop_violation": stopViolation,
    "error": error ?? "", "duration_seconds": controller.status.duration]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
controller.shutdown()
if scenario == "invalid" || scenario == "http_error" {
    if error == nil { exit(1) }
} else if scenario == "cancel" {
    if stopViolation || firstPlaying != nil { exit(1) }
} else if firstPlaying == nil || error != nil || finishedAt == nil || pauseViolation { exit(1) }
