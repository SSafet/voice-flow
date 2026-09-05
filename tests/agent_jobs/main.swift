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
expect(migratedLegacy?.selectedSourceIDs == [] && migratedLegacy?.sourceAccessMode == .standard,
       "legacy job silently gained source access or review mode")
expect(migratedLegacy?.modelID == nil,
       "legacy null model did not survive migration")
expect(migratedLegacy?.name == "legacy",
       "legacy prompt was not migrated to a stable automation name")
expect(migratedLegacy?.isEnabled == true && migratedLegacy?.generation == 1,
       "legacy automation control fields were not backfilled")
let reopenedMigration = try AgentJobStore(url: legacyURL)
let reopenedLegacy = try reopenedMigration.job(id: "legacy-model")
expect(reopenedLegacy == migratedLegacy,
       "automation schema migration was not idempotent")

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
    id: "job-a", name: "Morning brief",
    assistantSlug: "flora", conversationID: "conversation-a",
    runtime: .opencode, trigger: .manual, modelID: "test/model-fast",
    reasoningEffort: "low",
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
// An automation pins its effort next to its model, and both survive the
// round-trip through SQLite; an unusable value is stored as "provider decides".
let storedEffortJob = try store.job(id: "job-a")
let storedUnsetEffortJob = try store.job(id: "job-conflict")
expect(storedEffortJob?.reasoningEffort == "low",
       "the pinned reasoning effort did not survive the job round-trip")
expect(storedUnsetEffortJob?.reasoningEffort == nil,
       "an unset reasoning effort should stay unset")
expect(AgentJob(assistantSlug: "flora", conversationID: "c",
                runtime: .codex, trigger: .manual, reasoningEffort: "turbo",
                prompt: "p").reasoningEffort == nil,
       "an unknown effort should normalize to the provider default")
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
expect(storedModelJob?.name == "Morning brief",
       "stable automation name did not round-trip")

// Automation detail/edit/delete use the job database as their single
// lifecycle boundary. History is paged newest-first, configuration edits
// preserve state/creation, and deletion removes runs atomically.
let lifecycleStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-automation-lifecycle.sqlite"))
let lifecycleJob = AgentJob(
    id: "lifecycle", name: "Weekly synthesis",
    assistantSlug: "flora", conversationID: "lifecycle-c",
    runtime: .codex, trigger: .manual, prompt: "Synthesize the week",
    nextRunAt: now, dailyBudgetUSD: 5,
    createdAt: now, updatedAt: now)
try lifecycleStore.put(lifecycleJob)
let lifecycleRun = try lifecycleStore.claimNext(
    workerID: "lifecycle-worker", now: now)!
do {
    try lifecycleStore.delete(jobID: lifecycleJob.id)
    expect(false, "running automation was deleted")
} catch AgentJobStoreError.invalidState { }
catch { expect(false, "running deletion produced the wrong error: \(error)") }
try lifecycleStore.complete(
    runID: lifecycleRun.id, workerID: "lifecycle-worker",
    resultMessageID: UUID(), costUSD: 0.35,
    now: now.addingTimeInterval(2))
let lifecycleRuns = try lifecycleStore.runs(jobID: lifecycleJob.id, limit: 10)
expect(lifecycleRuns.map(\.id) == [lifecycleRun.id],
       "automation run history was not returned newest-first")
let lifecycleSpend = try lifecycleStore.spentToday(jobID: lifecycleJob.id, now: now)
expect(abs(lifecycleSpend - 0.35) < 0.0001,
       "automation daily spend did not include completed runs")
try lifecycleStore.updateConfiguration(
    jobID: lifecycleJob.id,
    configuration: AgentJobConfiguration(
        name: "Weekly operating review", assistantSlug: "flora",
        conversationID: "lifecycle-c", runtime: .opencode,
        modelID: "test/model-review", trigger: .interval,
        prompt: "Review the operating week", trustProfile: .unattended,
        intervalSeconds: 3600, dailyTimeMinutes: nil,
        concurrencyKey: "lifecycle-c",
        dailyBudgetUSD: 7, maxDurationSeconds: 600, maxAttempts: 2),
    now: now.addingTimeInterval(3))
let editedLifecycle = try lifecycleStore.job(id: lifecycleJob.id)
expect(editedLifecycle?.name == "Weekly operating review"
       && editedLifecycle?.runtime == .opencode
       && editedLifecycle?.state == .queued
       && editedLifecycle?.nextRunAt == now.addingTimeInterval(3 + 3_600)
       && editedLifecycle?.generation == lifecycleJob.generation + 1
       && editedLifecycle?.createdAt == now,
       "automation configuration edit did not preserve identity and reschedule safely")
try lifecycleStore.delete(jobID: lifecycleJob.id)
let deletedLifecycleJob = try lifecycleStore.job(id: lifecycleJob.id)
let deletedLifecycleRuns = try lifecycleStore.runs(jobID: lifecycleJob.id)
expect(deletedLifecycleJob == nil && deletedLifecycleRuns.isEmpty,
       "automation deletion did not remove the job and its run history atomically")

// Assistant deletion prepares every owned job transactionally and can restore
// the exact prior states if moving the folder to Trash fails.
let deletionStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-assistant-delete.sqlite"))
let deletionJobs = [
    AgentJob(id: "delete-ready", assistantSlug: "research", conversationID: "d1",
             runtime: .codex, trigger: .manual, prompt: "one", state: .completed,
             nextRunAt: nil, createdAt: now, updatedAt: now),
    AgentJob(id: "delete-queued", assistantSlug: "research", conversationID: "d2",
             runtime: .codex, trigger: .interval, prompt: "two", state: .queued,
             nextRunAt: now.addingTimeInterval(60), intervalSeconds: 60,
             createdAt: now, updatedAt: now),
    AgentJob(id: "delete-disabled", assistantSlug: "research", conversationID: "d3",
             runtime: .codex, trigger: .manual, prompt: "three", state: .disabled,
             nextRunAt: nil, createdAt: now, updatedAt: now),
]
for job in deletionJobs { try deletionStore.put(job) }
let deletionSnapshots = try deletionStore.disableJobsForAssistant("research", now: now)
expect(deletionSnapshots.count == 3,
       "Assistant deletion did not capture every job state")
let disabledDeletionJobs = try deletionStore.jobs(limit: 10)
expect(disabledDeletionJobs.allSatisfy { $0.state == .disabled },
       "Assistant deletion preparation left an owned job enabled")
try deletionStore.restoreJobStates(deletionSnapshots)
let restoredDeletionJobs = try deletionStore.jobs(limit: 10)
expect(restoredDeletionJobs.first(where: { $0.id == "delete-ready" })?.state == .completed
       && restoredDeletionJobs.first(where: { $0.id == "delete-queued" })?.state == .queued
       && restoredDeletionJobs.first(where: { $0.id == "delete-disabled" })?.state == .disabled,
       "failed Trash compensation did not restore exact job states")

let runningDeleteStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-assistant-delete-running.sqlite"))
try runningDeleteStore.put(AgentJob(
    id: "delete-running", assistantSlug: "research", conversationID: "d-running",
    runtime: .codex, trigger: .manual, prompt: "running", state: .running,
    nextRunAt: nil, createdAt: now, updatedAt: now))
do {
    _ = try runningDeleteStore.disableJobsForAssistant("research", now: now)
    expect(false, "Assistant deletion accepted a running automation")
} catch AgentJobStoreError.invalidState { }
catch { expect(false, "running deletion guard produced the wrong error: \(error)") }
let runningAfterRejectedDelete = try runningDeleteStore.job(id: "delete-running")
expect(runningAfterRejectedDelete?.state == .running,
       "running deletion guard partially mutated the job")
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

let disabledTransition = try store.disable(
    jobID: "job-b", now: now.addingTimeInterval(40))
let cancelled = try store.job(id: "job-b")
let listed = try store.jobs()
expect(disabledTransition.job.isEnabled == false && cancelled?.isEnabled == false,
       "job disablement was not durable")
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

// Disable cancels the active run and fences stale completions. Enable restores
// eligibility but an interval does not run until its next scheduled time.
let disabledInterval = try intervalStore.disable(
    jobID: "interval-reset", now: now.addingTimeInterval(12))
expect(disabledInterval.cancelledRunIDs == [intervalRun2!.id],
       "disable did not return the exact executor handle to join")
let staleIntervalFinish = try intervalStore.complete(
    runID: intervalRun2!.id, workerID: "interval-2",
    resultMessageID: UUID(), costUSD: 0,
    now: now.addingTimeInterval(13))
expect(staleIntervalFinish == .superseded,
       "a disabled run was allowed to reschedule itself")
let disabledRunNow = try intervalStore.runNow(
    jobID: "interval-reset", at: now.addingTimeInterval(13))
if case .rejectedDisabled = disabledRunNow { }
else { expect(false, "run now accepted a disabled automation") }
let cancelledClaim = try intervalStore.claimNext(
    workerID: "interval-3", now: now.addingTimeInterval(13))
expect(cancelledClaim == nil,
       "disabled job was revived without enable")
let enabledInterval = try intervalStore.enable(
    jobID: "interval-reset", now: now.addingTimeInterval(14))
let enabledJob = try intervalStore.job(id: "interval-reset")
expect(enabledInterval.didTransition && enabledJob?.state == .queued
       && enabledJob?.nextRunAt == now.addingTimeInterval(24),
       "explicit enable did not schedule the next interval")
let intervalTooEarly = try intervalStore.claimNext(
    workerID: "interval-too-early", now: now.addingTimeInterval(14))
expect(intervalTooEarly == nil,
       "enabling an interval started it immediately")

// A daily automation reschedules itself onto the next local wall-clock
// occurrence of its time — after completion, after enable, and after stop.
let dailyStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-daily-test.sqlite"))
expect(AgentDailyTime.minutes(from: "8") == 480
       && AgentDailyTime.minutes(from: "08:00") == 480
       && AgentDailyTime.minutes(from: "23:59") == 1_439
       && AgentDailyTime.minutes(from: "24:00") == nil
       && AgentDailyTime.minutes(from: "8:60") == nil
       && AgentDailyTime.minutes(from: "eight") == nil,
       "daily time parsing accepted or rejected the wrong shapes")
let eightAM = 8 * 60
let dailyJob = AgentJob(
    id: "daily-brief", name: "Morning brief", assistantSlug: "flora",
    conversationID: "daily-c", runtime: .codex, trigger: .daily,
    prompt: "Brief me", nextRunAt: now, dailyTimeMinutes: eightAM,
    dailyBudgetUSD: 10, createdAt: now, updatedAt: now)
try dailyStore.put(dailyJob)
let storedDaily = try dailyStore.job(id: "daily-brief")
expect(storedDaily?.dailyTimeMinutes == eightAM,
       "daily time did not round-trip through the store")
let dailyRun = try dailyStore.claimNext(workerID: "daily-worker", now: now)!
let dailyDone = now.addingTimeInterval(60)
try dailyStore.complete(
    runID: dailyRun.id, workerID: "daily-worker",
    resultMessageID: UUID(), costUSD: 0.1, now: dailyDone)
let rescheduledDaily = try dailyStore.job(id: "daily-brief")
let expectedNext = AgentJob.nextDailyRun(minutes: eightAM, after: dailyDone)
var expectedComponents = Calendar.current.dateComponents(
    [.hour, .minute], from: rescheduledDaily?.nextRunAt ?? .distantPast)
expect(rescheduledDaily?.state == .queued
       && rescheduledDaily?.nextRunAt == expectedNext
       && (rescheduledDaily?.nextRunAt ?? .distantPast) > dailyDone
       && (rescheduledDaily?.nextRunAt ?? .distantFuture)
           <= dailyDone.addingTimeInterval(25 * 3_600)
       && expectedComponents.hour == 8 && expectedComponents.minute == 0,
       "a completed daily automation was not rescheduled to the next 08:00")
_ = try dailyStore.disable(jobID: "daily-brief", now: dailyDone.addingTimeInterval(1))
let enabledDaily = try dailyStore.enable(
    jobID: "daily-brief", now: dailyDone.addingTimeInterval(2))
expectedComponents = Calendar.current.dateComponents(
    [.hour, .minute], from: enabledDaily.job.nextRunAt ?? .distantPast)
expect(enabledDaily.job.state == .queued
       && expectedComponents.hour == 8 && expectedComponents.minute == 0,
       "enabling a daily automation did not schedule its next 08:00")
try dailyStore.updateConfiguration(
    jobID: "daily-brief",
    configuration: AgentJobConfiguration(
        name: "Morning brief", assistantSlug: "flora",
        conversationID: "daily-c", runtime: .codex, modelID: nil,
        trigger: .daily, prompt: "Brief me", trustProfile: .unattended,
        intervalSeconds: nil, dailyTimeMinutes: 19 * 60 + 30,
        concurrencyKey: "daily-c", dailyBudgetUSD: 10,
        maxDurationSeconds: 900, maxAttempts: 3),
    now: dailyDone.addingTimeInterval(3))
let retimedDaily = try dailyStore.job(id: "daily-brief")
expectedComponents = Calendar.current.dateComponents(
    [.hour, .minute], from: retimedDaily?.nextRunAt ?? .distantPast)
expect(retimedDaily?.dailyTimeMinutes == 19 * 60 + 30
       && retimedDaily?.state == .queued
       && expectedComponents.hour == 19 && expectedComponents.minute == 30,
       "changing the daily time did not reschedule onto the new time")

// Stop is not Disable. It joins only the active execution wave, clears a
// trigger that arrived before the stop transaction, and keeps the automation
// eligible for later events.
let stopStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-stop-semantics.sqlite"))
let stopJob = AgentJob(
    id: "stop-event", name: "Inbox triage", assistantSlug: "flora",
    conversationID: "stop-event-c", runtime: .opencode, trigger: .capture,
    prompt: "Triage capture", nextRunAt: now, dailyBudgetUSD: 10,
    maxAttempts: 2, createdAt: now, updatedAt: now)
try stopStore.put(stopJob)
let stoppedRun = try stopStore.claimNext(workerID: "stop-worker", now: now)!
_ = try stopStore.enqueueEvent(
    source: "capture", eventID: "before-stop", jobID: stopJob.id,
    at: now.addingTimeInterval(1))
let pendingBeforeStop = try stopStore.hasPendingTrigger(jobID: stopJob.id)
expect(pendingBeforeStop,
       "pre-stop trigger was not coalesced")
let stopped = try stopStore.stopActiveRun(
    jobID: stopJob.id, now: now.addingTimeInterval(2))
expect(stopped.didTransition && stopped.cancelledRunIDs == [stoppedRun.id]
       && stopped.job.isEnabled && stopped.job.state == .completed
       && stopped.job.nextRunAt == nil,
       "Stop did not return an enabled event automation to Ready")
let pendingAfterStop = try stopStore.hasPendingTrigger(jobID: stopJob.id)
expect(!pendingAfterStop,
       "Stop did not clear the pre-existing follow-up")
let staleStopFailure = try stopStore.fail(
    runID: stoppedRun.id, workerID: "stop-worker", error: "late",
    retryable: true, now: now.addingTimeInterval(3), retryDelay: 0)
expect(staleStopFailure == .superseded,
       "a stopped executor revived its retry epoch")
let postStopEvent = try stopStore.enqueueEvent(
    source: "capture", eventID: "after-stop", jobID: stopJob.id,
    at: now.addingTimeInterval(4))
let postStopRun = try stopStore.claimNext(
    workerID: "stop-worker-2", now: now.addingTimeInterval(4))
expect(postStopEvent && postStopRun?.generation == stopped.job.generation + 1,
       "an event linearized after Stop was not admitted as new work")

let intervalStopStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-stop-interval.sqlite"))
try intervalStopStore.put(AgentJob(
    id: "stop-interval", assistantSlug: "flora", conversationID: "stop-interval-c",
    runtime: .codex, trigger: .interval, prompt: "Poll",
    nextRunAt: now, intervalSeconds: 90, dailyBudgetUSD: 10,
    createdAt: now, updatedAt: now))
_ = try intervalStopStore.claimNext(workerID: "interval-stop-worker", now: now)
let intervalStopped = try intervalStopStore.stopActiveRun(
    jobID: "stop-interval", now: now.addingTimeInterval(5))
expect(intervalStopped.job.isEnabled && intervalStopped.job.state == .queued
       && intervalStopped.job.nextRunAt == now.addingTimeInterval(95),
       "stopped interval did not preserve its schedule")

let disabledEventStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-disabled-events.sqlite"))
try disabledEventStore.put(AgentJob(
    id: "disabled-event", assistantSlug: "flora", conversationID: "disabled-event-c",
    runtime: .codex, trigger: .watcher, prompt: "Review", state: .completed,
    nextRunAt: nil, createdAt: now, updatedAt: now))
_ = try disabledEventStore.disable(jobID: "disabled-event", now: now)
let droppedDisabledEvent = try disabledEventStore.enqueueEvent(
    source: "watcher", eventID: "disabled-once", jobID: "disabled-event", at: now)
_ = try disabledEventStore.enable(jobID: "disabled-event", now: now.addingTimeInterval(1))
let replayedDisabledEvent = try disabledEventStore.enqueueEvent(
    source: "watcher", eventID: "disabled-once", jobID: "disabled-event",
    at: now.addingTimeInterval(2))
expect(!droppedDisabledEvent && !replayedDisabledEvent,
       "a disabled exactly-once event was not recorded and dropped")

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
let retryRunNow = try retryStore.runNow(
    jobID: retryJob.id, at: now.addingTimeInterval(3))
let retryGeneration: Int
if case .queued(let queuedRetry) = retryRunNow {
    retryGeneration = queuedRetry.generation
} else {
    retryGeneration = -1
}
let freshRetry = try retryStore.claimNext(
    workerID: "retry-fresh", now: now.addingTimeInterval(3))
expect(retryGeneration == (terminalRetry?.generation ?? 0) + 1
       && freshRetry?.attempt == 1 && freshRetry?.generation == retryGeneration,
       "Run Now after exhausted retries did not start a fresh execution generation")
// App teardown hands a leased run back as interrupted and reschedules —
// quitting Voice Flow mid-run must never mark a healthy automation failed.
let releaseStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-release-test.sqlite"))
let releaseJob = AgentJob(
    id: "release-job", assistantSlug: "flora", conversationID: "release-c",
    runtime: .opencode, trigger: .manual, prompt: "release", nextRunAt: now,
    createdAt: now, updatedAt: now)
try releaseStore.put(releaseJob)
let releaseRun = try releaseStore.claimNext(workerID: "release-worker", now: now)!
let released = try releaseStore.releaseInterrupted(
    runID: releaseRun.id, workerID: "release-worker", reason: "app quit",
    now: now.addingTimeInterval(1), retryDelay: 0)
expect(released, "release did not find the leased run")
let releasedJob = try releaseStore.job(id: "release-job")
expect(releasedJob?.state == .queued && releasedJob?.isEnabled == true,
       "app-quit release must reschedule the job, not fail it")
let releasedRun = try releaseStore.run(id: releaseRun.id)
expect(releasedRun?.state == .interrupted && releasedRun?.error == "app quit",
       "app-quit release must record an interrupted run, not a failure")
let resumedRun = try releaseStore.claimNext(
    workerID: "release-worker-2", now: now.addingTimeInterval(2))
expect(resumedRun?.jobID == "release-job",
       "released job was not claimable again on the next launch")
let releasedTwice = try releaseStore.releaseInterrupted(
    runID: releaseRun.id, workerID: "release-worker", reason: "app quit")
expect(!releasedTwice, "release must be idempotent for a run that is no longer leased")

// Failed is terminal until explicit Retry: neither event intake nor a
// disable→enable round-trip may silently revive a terminally failed job.
let terminalStore = try AgentJobStore(
    url: VoiceFlowPaths.shared.file("jobs-terminal-test.sqlite"))
let terminalJob = AgentJob(
    id: "terminal-job", assistantSlug: "flora", conversationID: "terminal-c",
    runtime: .opencode, trigger: .inbox, prompt: "terminal", nextRunAt: now,
    maxAttempts: 1, createdAt: now, updatedAt: now)
try terminalStore.put(terminalJob)
let terminalRun = try terminalStore.claimNext(workerID: "terminal-worker", now: now)!
try terminalStore.fail(
    runID: terminalRun.id, workerID: "terminal-worker",
    error: "exhausted", retryable: false, now: now.addingTimeInterval(1))
let terminalFixture = try terminalStore.job(id: "terminal-job")
expect(terminalFixture?.state == .failed, "terminal fixture did not reach failed")
let eventRevived = try terminalStore.enqueueEvent(
    source: "inbox", eventID: "revive-1", jobID: "terminal-job",
    at: now.addingTimeInterval(2))
let afterEvent = try terminalStore.job(id: "terminal-job")
expect(!eventRevived && afterEvent?.state == .failed,
       "an event revived a terminally failed job without explicit Retry")
let triggerRevived = try terminalStore.enqueueTrigger(
    .inbox, source: "inbox", eventID: "revive-2", at: now.addingTimeInterval(3))
let afterTrigger = try terminalStore.job(id: "terminal-job")
expect(triggerRevived == 0 && afterTrigger?.state == .failed,
       "a fanned trigger revived a terminally failed job")
_ = try terminalStore.disable(jobID: "terminal-job", now: now.addingTimeInterval(4))
_ = try terminalStore.enable(jobID: "terminal-job", now: now.addingTimeInterval(5))
let reenabled = try terminalStore.job(id: "terminal-job")
expect(reenabled?.state == .failed && reenabled?.isEnabled == true,
       "disable→enable erased a terminal failure without explicit Retry")
let claimedWithoutRetry = try terminalStore.claimNext(
    workerID: "terminal-worker-2", now: now.addingTimeInterval(6))
expect(claimedWithoutRetry == nil,
       "a re-enabled failed job became claimable without Retry")
guard case .queued = try terminalStore.runNow(
    jobID: "terminal-job", at: now.addingTimeInterval(7)) else {
    fputs("FAIL: explicit Retry no longer revives a failed job\n", stderr); exit(1)
}

// An older build toggles enablement through `state` alone. The divergence
// must reconcile on every open — not only during the one-shot migration —
// or a disabled automation can run again after a downgrade round-trip.
let divergenceURL = VoiceFlowPaths.shared.file("jobs-divergence-test.sqlite")
do {
    let seedStore = try AgentJobStore(url: divergenceURL)
    try seedStore.put(AgentJob(
        id: "divergent-job", assistantSlug: "flora", conversationID: "divergent-c",
        runtime: .opencode, trigger: .inbox, prompt: "divergent", nextRunAt: now,
        createdAt: now, updatedAt: now))
}
func oldBuildWrite(_ sql: String) {
    var db: OpaquePointer?
    expect(sqlite3_open(divergenceURL.path, &db) == SQLITE_OK, "raw open failed")
    expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "raw old-build write failed")
    sqlite3_close(db)
}
oldBuildWrite("UPDATE agent_jobs SET state='disabled', next_run_at=NULL WHERE id='divergent-job'")
let afterOldDisable = try AgentJobStore(url: divergenceURL)
let oldDisabled = try afterOldDisable.job(id: "divergent-job")
expect(oldDisabled?.isEnabled == false,
       "an old-build disable was not reconciled — the automation would run again")
let divergedEvent = try afterOldDisable.enqueueEvent(
    source: "inbox", eventID: "diverge-1", jobID: "divergent-job",
    at: now.addingTimeInterval(1))
expect(!divergedEvent,
       "an event queued an automation the user disabled on an older build")
oldBuildWrite("UPDATE agent_jobs SET state='queued', next_run_at=1800000000 WHERE id='divergent-job'")
let afterOldEnable = try AgentJobStore(url: divergenceURL)
let oldEnabled = try afterOldEnable.job(id: "divergent-job")
expect(oldEnabled?.isEnabled == true && oldEnabled?.state == .queued,
       "an old-build enable left the job permanently stuck queued-but-disabled")

print("agent job store tests passed")
