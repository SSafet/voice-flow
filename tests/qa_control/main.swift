import Foundation

func vflog(_ message: String) {}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

expect(VoiceFlowPaths.shared.isIsolated, "QA test did not receive an isolated root")
let token = try QAControlSecurity.installToken()
expect(token.count == 64, "QA token is not 256-bit hex")
expect(QAControlSecurity.matches(token, token: token), "valid token was rejected")
expect(!QAControlSecurity.matches(token + "x", token: token), "length mismatch was accepted")
let wrongSuffix = token.last == "0" ? "1" : "0"
expect(!QAControlSecurity.matches(String(token.dropLast()) + wrongSuffix, token: token),
       "wrong token was accepted")
let tokenURL = VoiceFlowPaths.shared.file("qa-control-token")
let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
expect(permissions == 0o600, "QA token file is not mode 0600")

QAEventRecorder.shared.reset()
QAEventRecorder.shared.append("started", ["value": "one"])
QAEventRecorder.shared.append("finished", ["secret": "api_key=abcdefghijklmnop"])
let events = QAEventRecorder.shared.snapshot(after: 1)
expect(events.count == 1, "event cursor did not filter")
let payload = events.first?["payload"] as? [String: Any]
expect((payload?["secret"] as? String)?.contains("abcdefghijklmnop") == false,
       "event journal did not redact a secret")
print("QA control tests passed")
