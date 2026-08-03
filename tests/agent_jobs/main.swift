import Foundation
import SQLite3

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)

expect(AgentExecutionOwnershipIssue.resolve(
    jobAssistantSlug: "flora", conversationAssistantSlug: "flora",
    assistantAvailable: true) == nil,
       "matching automation ownership was rejected")
expect(AgentExecutionOwnershipIssue.resolve(
    jobAssistantSlug: "flora", conversationAssistantSlug: "flora",
    assistantAvailable: false) == .missingAssistant,
       "missing Assistant did not fail closed")
expect(AgentExecutionOwnershipIssue.resolve(
    jobAssistantSlug: "flora", conversationAssistantSlug: "research",
    assistantAvailable: true) == .conversationOwnerMismatch,
       "cross-Assistant conversation mismatch was accepted")

// A pre-model-picker database must migrate additively and preserve a null
// model so the legacy global default remains the execution fallback.
let legacyURL = VoiceFlowPaths.shared.file("jobs-legacy-model.sqlite")
var legacyDB: OpaquePointer?
expect(sqlite3_open(legacyURL.path, &legacyDB) == SQLITE_OK,
       "could not create legacy job database")
let legacySQL = """
CREATE TABLE agent_jobs (
  id TEXT PRIMARY KEY, assistant_slug TEXT NOT NULL,
  conversation_id TEXT NOT NULL, runtime TEXT NOT NULL,
  trigger_kind TEXT NOT NULL, prompt TEXT NOT NULL,
  trust_profile TEXT NOT NULL, state TEXT NOT NULL,
  next_run_at REAL, interval_seconds REAL, concurrency_key TEXT NOT NULL,
  daily_budget_usd REAL NOT NULL, max_duration_seconds REAL NOT NULL,
  max_attempts INTEGER NOT NULL, created_at REAL NOT NULL,
  updated_at REAL NOT NULL, pending_trigger_at REAL
);
INSERT INTO agent_jobs VALUES(
  'legacy-model','flora','legacy-c','opencode','manual','legacy',
  'unattended','completed',NULL,NULL,'legacy-c',1,900,3,
  1800000000,1800000000,NULL
);
"""
expect(sqlite3_exec(legacyDB, legacySQL, nil, nil, nil) == SQLITE_OK,
       "could not seed legacy job database")
sqlite3_close(legacyDB)
let migrated = try AgentJobStore(url: legacyURL)
let migratedLegacy = try migrated.job(id: "legacy-model")
expect(migratedLegacy?.modelID == nil,
       "legacy null model did not survive migration")

let corruptURL = VoiceFlowPaths.shared.file("jobs-corrupt.sqlite")
try Data("this is not sqlite".utf8).write(to: corruptURL, options: .atomic)
do {
    _ = try AgentJobStore(url: corruptURL)
    expect(false, "corrupt job database was accepted")
} catch AgentJobStoreError.database { }
catch { expect(false, "corrupt job database produced an untyped error: \(error)") }

let unwritableDirectory = VoiceFlowPaths.shared.directory("jobs-unwritable")
_ = chmod(unwritableDirectory.path, S_IRUSR | S_IXUSR)
defer { _ = chmod(unwritableDirectory.path, S_IRWXU) }
do {
    _ = try AgentJobStore(url: unwritableDirectory.appendingPathComponent("jobs.sqlite"))
    expect(false, "unwritable job path was accepted")
} catch AgentJobStoreError.database { }
catch { expect(false, "unwritable job path produced an untyped error: \(error)") }

let url = VoiceFlowPaths.shared.file("jobs-test.sqlite")
let store = try AgentJobStore(url: url)
let jobA = AgentJob(
    id: "job-a", assistantSlug: "flora", conversationID: "conversation-a",
    runtime: .opencode, trigger: .manual, modelID: "test/model-fast",
    prompt: "A", nextRunAt: now,
    dailyBudgetUSD: 2, maxAttempts: 3, createdAt: now, updatedAt: now)
let jobConflict = AgentJob(
    id: "job-conflict", assistantSlug: "flora", conversationID: "conversation-a",
    runtime: .codex, trigger: .manual, prompt: "conflict", nextRunAt: now,
    dailyBudgetUSD: 2, maxAttempts: 3,
    createdAt: now.addingTimeInterval(1), updatedAt: now.addingTimeInterval(1))
let jobB = AgentJob(
    id: "job-b", assistantSlug: "flora", conversationID: "conversation-b",
    runtime: .codex, trigger: .interval, prompt: "B", nextRunAt: now,
    intervalSeconds: 60, dailyBudgetUSD: 2, maxAttempts: 3,
    createdAt: now.addingTimeInterval(2), updatedAt: now.addingTimeInterval(2))
try store.put(jobA)
try store.put(jobConflict)
try store.put(jobB)
let initialReferences = try store.jobReferencesByConversation()
expect(initialReferences["conversation-a"] == Set(["job-a", "job-conflict"]),
       "authoritative job references collapsed a shared conversation")
let sharedConversationJobs = try store.jobs(conversationID: "conversation-a")
expect(sharedConversationJobs.map(\.id) == ["job-a", "job-conflict"],
       "conversation lookup did not include every referencing job")
let storedModelJob = try store.job(id: "job-a")
expect(storedModelJob?.modelID == "test/model-fast",
       "per-job model ID did not round-trip")
let inboxJob = AgentJob(
    id: "inbox", assistantSlug: "flora", conversationID: "inbox-c",
    runtime: .opencode, trigger: .inbox, prompt: "inbox", state: .completed,
    nextRunAt: nil, concurrencyKey: "inbox-c", dailyBudgetUSD: 2,
    maxAttempts: 3, createdAt: now, updatedAt: now)
try store.put(inboxJob)

let firstEvent = try store.enqueueEvent(source: "capture", eventID: "event-1", jobID: "job-a", at: now)
let duplicateEvent = try store.enqueueEvent(source: "capture", eventID: "event-1", jobID: "job-a", at: now)
expect(firstEvent, "first event was not admitted")
expect(!duplicateEvent, "duplicate trigger was admitted")
let inboxCount = try store.enqueueTrigger(
    .inbox, source: "inbox", eventID: "inbox-event", at: now.addingTimeInterval(100))
let duplicateInboxCount = try store.enqueueTrigger(
    .inbox, source: "inbox", eventID: "inbox-event", at: now.addingTimeInterval(100))
expect(inboxCount == 1 && duplicateInboxCount == 0,
       "typed trigger fanout was not exactly once")

let runA = try store.claimNext(workerID: "worker-a", now: now, leaseSeconds: 10)
expect(runA?.jobID == "job-a", "fair queue did not claim oldest due job")
let runB = try store.claimNext(workerID: "worker-b", now: now, leaseSeconds: 10)
expect(runB?.jobID == "job-b", "conversation exclusion did not skip conflicting job")
let heartbeat = try store.heartbeat(
    runID: runA!.id, workerID: "worker-a", now: now.addingTimeInterval(5), leaseSeconds: 10)
let wrongHeartbeat = try store.heartbeat(
    runID: runA!.id, workerID: "wrong-worker", now: now.addingTimeInterval(5))
expect(heartbeat, "lease owner heartbeat failed")
expect(!wrongHeartbeat, "non-owner heartbeat succeeded")

try store.complete(
    runID: runA!.id, workerID: "worker-a", resultMessageID: UUID(),
    costUSD: 0.2, now: now.addingTimeInterval(6))
let conflictRun = try store.claimNext(
    workerID: "worker-c", now: now.addingTimeInterval(6), leaseSeconds: 2)
expect(conflictRun?.jobID == "job-conflict", "released conversation was not admitted")
let recovered = try store.recoverExpired(now: now.addingTimeInterval(20), retryDelay: 1)
expect(recovered == 2, "expired runs were not recovered exactly once")
let duplicateRecovery = try store.recoverExpired(now: now.addingTimeInterval(20), retryDelay: 1)
expect(duplicateRecovery == 0, "expired run recovery duplicated work")

let retry = try store.claimNext(workerID: "worker-retry", now: now.addingTimeInterval(21))
expect(retry != nil, "recovered job was not retried")
try store.fail(
    runID: retry!.id, workerID: "worker-retry", error: "temporary",
    retryable: false, now: now.addingTimeInterval(22))

let budgetJob = AgentJob(
    id: "budget", assistantSlug: "flora", conversationID: "budget-c",
    runtime: .opencode, trigger: .manual, prompt: "budget", nextRunAt: now,
    dailyBudgetUSD: 0, maxAttempts: 2, createdAt: now, updatedAt: now)
try store.put(budgetJob)
_ = try store.claimNext(workerID: "budget-worker", now: now.addingTimeInterval(30))
let storedBudget = try store.job(id: "budget")
expect(storedBudget?.state == .blocked, "zero-budget job was not blocked")

try store.cancel(jobID: "job-b", now: now.addingTimeInterval(40))
let cancelled = try store.job(id: "job-b")
let listed = try store.jobs()
expect(cancelled?.state == .cancelled, "job cancellation was not durable")
expect(listed.count == 5, "job listing lost rows")

// An event arriving during a lease must never start a concurrent duplicate;
// it coalesces into exactly one immediate follow-up after completion.
let coalesceStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-coalesce-test.sqlite"))
let coalesceJob = AgentJob(
    id: "coalesce", assistantSlug: "flora", conversationID: "coalesce-c",
    runtime: .opencode, trigger: .capture, prompt: "coalesce",
    nextRunAt: now, dailyBudgetUSD: 10, maxAttempts: 3,
    createdAt: now, updatedAt: now)
try coalesceStore.put(coalesceJob)
let coalesceRun = try coalesceStore.claimNext(workerID: "coalesce-1", now: now)!
let coalesced = try coalesceStore.enqueueTrigger(
    .capture, source: "capture", eventID: "while-running",
    at: now.addingTimeInterval(1))
expect(coalesced == 1, "running event was not recorded")
let concurrentDuplicate = try coalesceStore.claimNext(
    workerID: "coalesce-2", now: now.addingTimeInterval(1))
expect(concurrentDuplicate == nil,
       "running event admitted a concurrent duplicate")
try coalesceStore.complete(
    runID: coalesceRun.id, workerID: "coalesce-1",
    resultMessageID: UUID(), costUSD: 0.1,
    now: now.addingTimeInterval(2))
let followUp = try coalesceStore.claimNext(
    workerID: "coalesce-2", now: now.addingTimeInterval(2))
expect(followUp?.jobID == "coalesce", "coalesced follow-up was not scheduled")
try coalesceStore.complete(
    runID: followUp!.id, workerID: "coalesce-2",
    resultMessageID: UUID(), costUSD: 0.1,
    now: now.addingTimeInterval(3))
let extraFollowUp = try coalesceStore.claimNext(
    workerID: "coalesce-3", now: now.addingTimeInterval(3))
expect(extraFollowUp == nil,
       "one running event produced more than one follow-up")

// maxAttempts applies to one failure streak, not the lifetime of an interval
// automation. A successful interval resets the attempt window.
let intervalStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-interval-test.sqlite"))
let intervalJob = AgentJob(
    id: "interval-reset", assistantSlug: "flora", conversationID: "interval-c",
    runtime: .codex, trigger: .interval, prompt: "interval",
    nextRunAt: now, intervalSeconds: 10, dailyBudgetUSD: 10,
    maxAttempts: 1, createdAt: now, updatedAt: now)
try intervalStore.put(intervalJob)
let intervalRun1 = try intervalStore.claimNext(workerID: "interval-1", now: now)!
try intervalStore.complete(
    runID: intervalRun1.id, workerID: "interval-1",
    resultMessageID: UUID(), costUSD: 0,
    now: now.addingTimeInterval(1))
let intervalRun2 = try intervalStore.claimNext(
    workerID: "interval-2", now: now.addingTimeInterval(11))
expect(intervalRun2 != nil, "successful interval did not reset maxAttempts")

// Disabled/cancelled jobs stay inert until explicitly enabled; run-now then
// enters the same durable admission path.
try intervalStore.cancel(jobID: "interval-reset", now: now.addingTimeInterval(12))
try intervalStore.runNow(jobID: "interval-reset", at: now.addingTimeInterval(13))
let cancelledClaim = try intervalStore.claimNext(
    workerID: "interval-3", now: now.addingTimeInterval(13))
expect(cancelledClaim == nil,
       "cancelled job was revived without enable")
try intervalStore.setEnabled(
    jobID: "interval-reset", enabled: true, now: now.addingTimeInterval(14))
let enabledJob = try intervalStore.job(id: "interval-reset")
expect(enabledJob?.state == .queued,
       "explicit enable did not restore queue state")

let retryStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-retry-test.sqlite"))
let retryJob = AgentJob(
    id: "retry-twice", assistantSlug: "flora", conversationID: "retry-c",
    runtime: .opencode, trigger: .manual, prompt: "retry", nextRunAt: now,
    dailyBudgetUSD: 10, maxAttempts: 2, createdAt: now, updatedAt: now)
try retryStore.put(retryJob)
let retryOne = try retryStore.claimNext(workerID: "retry-1", now: now)!
expect(retryOne.attempt == 1, "first retry attempt number changed")
try retryStore.fail(
    runID: retryOne.id, workerID: "retry-1", error: "HTTP 429 api_key=sk-live-abcdefghijklmnop",
    retryable: true, now: now.addingTimeInterval(1), retryDelay: 0)
let retryTwo = try retryStore.claimNext(
    workerID: "retry-2", now: now.addingTimeInterval(1))!
expect(retryTwo.attempt == 2, "retry did not increment the durable attempt number")
try retryStore.fail(
    runID: retryTwo.id, workerID: "retry-2", error: "still unavailable",
    retryable: true, now: now.addingTimeInterval(2), retryDelay: 0)
let terminalRetry = try retryStore.job(id: retryJob.id)
expect(terminalRetry?.state == .failed,
       "maximum retry attempts did not leave a terminal failure")
let retryRows = try retryStore.activeRuns()
expect(retryRows.isEmpty, "terminal retry left an active lease")
print("agent job store tests passed")
