import Foundation
func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
let text = "{\"event\":\"result\",\"text\":\"Здравей 🌍\"}\n{\"event\":\"done\"}\n"
let bytes = Data(text.utf8)
for split in 0...bytes.count {
    var decoder = SpeechJSONLines()
    let lines = decoder.append(Data(bytes.prefix(split))) + decoder.append(Data(bytes.dropFirst(split)))
    expect(lines == text.split(separator: "\n").map(String.init), "fragmented pipe lost UTF-8 at \(split)")
}
var decoder = SpeechJSONLines()
var lines: [String] = []
for byte in bytes { lines += decoder.append(Data([byte])) }
expect(lines.count == 2, "byte-by-byte framing")
expect(!SpeechStartupPolicy.canStart(bufferedSeconds: 0.2, elapsed: 0.1, complete: false), "first burst must wait")
expect(SpeechStartupPolicy.canStart(bufferedSeconds: 0.2, elapsed: 0.22, complete: false), "guarded startup")
expect(SpeechStartupPolicy.canStart(bufferedSeconds: 0.5, elapsed: 0.01, complete: false), "fast full buffer")
expect(!SpeechStartupPolicy.canStart(bufferedSeconds: 0.1, elapsed: 0.4, complete: false), "insufficient audio")
expect(SpeechStartupPolicy.canStart(bufferedSeconds: 0.05, elapsed: 0.1, complete: true), "short completed response")
print("PASS speech transport: every UTF-8 boundary and startup policy")
