import Foundation

// The Today layer and the delegates layer (06 §3.17, 06 §3.6, 06 §8 items 11
// and 13): Today.md is in the General project, every turn reads it, a long note
// is cut at the stated limit with a line that says so, an unreadable note says
// so instead of guessing, and the layer travels in the turn's message beside
// memory while the delegates block travels in the instruction channel.

let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("vf-turn-prompt-\(UUID().uuidString)", isDirectory: true)
let general = root.appendingPathComponent("projects/general", isDirectory: true)
try FileManager.default.createDirectory(at: general, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let now = turnEngineFixedDate
let zone = TimeZone(identifier: "Europe/Zurich")!

// 1. The note lives at the General project's own path.
checkEqual("the note is Today.md in the General project",
           TodayNote.path(generalProjectFolder: general).path,
           general.appendingPathComponent("Today.md").path)

// 2. The layer carries the path, the date, the zone, when the file changed and
//    the text itself, plus the fixed words that keep it honest.
let noteText = "Ship the turn engine. Then review the queue."
try noteText.write(to: TodayNote.path(generalProjectFolder: general), atomically: true, encoding: .utf8)
let layer = TodayNote.layer(generalProjectFolder: general, now: now, timeZone: zone)
check("the layer names the file's path", layer.contains(TodayNote.path(generalProjectFolder: general).path))
check("the layer carries today's date", layer.contains("2026-09-19"), layer)
check("the layer carries the zone", layer.contains("Europe/Zurich"), layer)
check("the layer says when it changed", layer.contains("last changed"), layer)
check("the layer carries the note's text", layer.contains(noteText), layer)
check("the layer grants no permission", layer.contains("grants no permission"), layer)
check("the layer does not override the request", layer.contains("does not override the current request"), layer)
check("the layer tells the agent how to change it", layer.contains("edit the file"), layer)
check("the layer says when it was changed today", layer.contains("today's intent"), layer)
check("the layer says otherwise treat it as earlier context", layer.contains("earlier context"), layer)

// 3. A note longer than the limit is cut at the limit, and the layer says so.
let longNote = String(repeating: "x", count: TodayNote.maxCharacters + 500)
try longNote.write(to: TodayNote.path(generalProjectFolder: general), atomically: true, encoding: .utf8)
let cutLayer = TodayNote.layer(generalProjectFolder: general, now: now, timeZone: zone)
check("a long note is cut at the limit", cutLayer.contains(String(repeating: "x", count: TodayNote.maxCharacters)))
check("a long note is not carried whole",
      !cutLayer.contains(String(repeating: "x", count: TodayNote.maxCharacters + 100)))
check("the cut is stated", cutLayer.contains("cut"), cutLayer)

// 4. An unreadable note says so and tells the agent not to guess; the turn can
//    still run.
try FileManager.default.removeItem(at: TodayNote.path(generalProjectFolder: general))
let missingLayer = TodayNote.layer(generalProjectFolder: general, now: now, timeZone: zone)
check("a missing note is reported", missingLayer.contains("could not be read"), missingLayer)
check("the agent is told not to guess", missingLayer.contains("do not guess"), missingLayer)

// 5. The delegates block names each delegate, the one tool to call it, and the
//    fixed limits; a persona with no delegates gets nothing.
let delegates = [
    TPPersonaDelegate(description: "Writes the release notes", id: "scribe", name: "Scribe",
                      personaDelegatePrivate: false),
    TPPersonaDelegate(description: "Runs the test suite", id: "tester", name: "Tester",
                      personaDelegatePrivate: false),
]
let block = DelegateLayer.block(delegates)
check("the block names each delegate", block.contains("Scribe") && block.contains("Tester"), block)
check("the block describes each delegate",
      block.contains("Writes the release notes") && block.contains("Runs the test suite"), block)
check("the block names the one tool", block.contains("voiceflow_delegate"), block)
check("the block says how to name one", block.contains("@Scribe"), block)
check("the block states the depth limit", block.contains("one level"), block)
check("the block states the concurrency limit", block.contains("three at a time"), block)
check("the block states the per-turn limit", block.contains("twelve"), block)
check("the block states there is no retry", block.contains("no retry"), block)
checkEqual("no delegates means no block", DelegateLayer.block([]), "")

// 6. The channels are fixed: Today travels in the turn's message beside memory,
//    delegates travel in the instruction channel, and neither leaks across.
let message = TurnPromptChannels.userMessage(handoff: "handoff", memory: "memory",
                                             todayContext: "TODAY-LAYER", sources: "sources",
                                             task: "do it")
let instructions = TurnPromptChannels.instructions(systemRole: "role", persona: "persona",
                                                   skills: "skills", sourceInstructions: "",
                                                   delegatesBlock: "DELEGATES-BLOCK",
                                                   additional: "")
check("the message carries Today", message.contains("TODAY-LAYER"), message)
check("the message keeps memory beside it",
      message.range(of: "memory")!.lowerBound < message.range(of: "TODAY-LAYER")!.lowerBound, message)
check("the instructions do not carry Today", !instructions.contains("TODAY-LAYER"), instructions)
check("the instructions carry delegates", instructions.contains("DELEGATES-BLOCK"), instructions)
check("the message does not carry delegates", !message.contains("DELEGATES-BLOCK"), message)

// 7. The engine puts the real Today layer into every turn it starts, and hands
//    the delegates block to the driver.
let harness = EngineHarness()
try FileManager.default.createDirectory(at: harness.generalFolder, withIntermediateDirectories: true)
try noteText.write(to: TodayNote.path(generalProjectFolder: harness.generalFolder),
                   atomically: true, encoding: .utf8)
let driver = harness.driver
let runtime = driver.runtimes[.opencode]!
runtime.holdThreads = []
harness.store.seed(thread: makeThread(id: "thread-today"))
driver.delegatesByThread["thread-today"] = delegates
_ = try await harness.engine.startTurn(StartTurnRequest(
    commandID: "today-1", threadID: "thread-today", text: "what is next", attachmentIDs: [],
    startedBy: userStartedBy(), requestExpirySec: nil, retryOfTurnID: nil, model: nil,
    reasoningEffort: nil, sentFrom: nil, speakReply: false))
await harness.engine.waitUntilIdle()
let made = driver.madeRequests.last
check("the engine read the real note", made?.todayContext.contains(noteText) ?? false,
      made?.todayContext ?? "no request")
check("the engine read the turn's delegates", made?.delegatesBlock.contains("Scribe") ?? false,
      made?.delegatesBlock ?? "no request")

finishTurnEngine("turn prompt")
