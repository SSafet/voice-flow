import Foundation
import SQLite3

enum AgentJobTriggerKind: String, Codable, CaseIterable {
    case manual
    case interval
    case inbox
    case capture
    case watcher
}

enum AgentJobState: String, Codable {
    case queued
    case running
    case blocked
    case failed
    case completed
    case cancelled
    case disabled
}

enum AgentRunState: String, Codable {
    case running
    case completed
    case failed
    case interrupted
    case cancelled
}

struct AgentJob: Equatable {
    let id: String
    let name: String
    let assistantSlug: String
    let conversationID: String
    let runtime: AgentRuntimeKind
    let modelID: String?
    let trigger: AgentJobTriggerKind
    let prompt: String
    let trustProfile: AgentTrustProfile
    let state: AgentJobState
    let isEnabled: Bool
    let generation: Int
    let nextRunAt: Date?
    let intervalSeconds: TimeInterval?
    let concurrencyKey: String
    let dailyBudgetUSD: Double
    let maxDurationSeconds: TimeInterval
    let maxAttempts: Int
    let createdAt: Date
    let updatedAt: Date

    init(id: String = UUID().uuidString, name: String? = nil,
         assistantSlug: String, conversationID: String,
         runtime: AgentRuntimeKind, trigger: AgentJobTriggerKind,
         modelID: String? = nil,
         prompt: String, trustProfile: AgentTrustProfile = .unattended,
         state: AgentJobState = .queued, nextRunAt: Date? = Date(),
         isEnabled: Bool? = nil, generation: Int = 1,
         intervalSeconds: TimeInterval? = nil,
         concurrencyKey: String? = nil,
         dailyBudgetUSD: Double = 1.0,
         maxDurationSeconds: TimeInterval = 900,
         maxAttempts: Int = 3,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = Self.normalizedName(name, prompt: prompt)
        self.assistantSlug = assistantSlug
        self.conversationID = conversationID
        self.runtime = runtime
        let trimmedModel = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.modelID = trimmedModel.isEmpty ? nil : trimmedModel
        self.trigger = trigger
        self.prompt = prompt
        self.trustProfile = trustProfile
        self.state = state
        self.isEnabled = isEnabled ?? (state != .disabled && state != .cancelled)
        self.generation = max(0, generation)
        self.nextRunAt = nextRunAt
        self.intervalSeconds = intervalSeconds
        self.concurrencyKey = concurrencyKey ?? conversationID
        self.dailyBudgetUSD = dailyBudgetUSD
        self.maxDurationSeconds = maxDurationSeconds
        self.maxAttempts = maxAttempts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func normalizedName(_ proposed: String?, prompt: String) -> String {
        let explicit = proposed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstPromptLine = prompt
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = explicit.isEmpty ? firstPromptLine : explicit
        let fallback = source.isEmpty ? "Untitled automation" : source
        return String(fallback.prefix(80))
    }
}

struct AgentJobConfiguration: Equatable {
    let name: String
    let assistantSlug: String
    let conversationID: String
    let runtime: AgentRuntimeKind
    let modelID: String?
    let trigger: AgentJobTriggerKind
    let prompt: String
    let trustProfile: AgentTrustProfile
    let intervalSeconds: TimeInterval?
    let concurrencyKey: String
    let dailyBudgetUSD: Double
    let maxDurationSeconds: TimeInterval
    let maxAttempts: Int
}

struct AgentRun: Equatable {
    let id: String
    let jobID: String
    let turnID: UUID
    let runtime: AgentRuntimeKind
    let generation: Int
    let state: AgentRunState
    let workerID: String
    let leaseExpiresAt: Date
    let heartbeatAt: Date
    let attempt: Int
    let startedAt: Date
    let finishedAt: Date?
    let costUSD: Double
    let error: String?
    let resultMessageID: UUID?
}

struct AgentJobStateSnapshot: Equatable {
    let id: String
    let state: AgentJobState
    let isEnabled: Bool
    let generation: Int
    let nextRunAt: Date?
    let pendingTriggerAt: Date?
    let updatedAt: Date
}

struct AgentJobControlTransition: Equatable {
    let job: AgentJob
    let cancelledRunIDs: [String]
    let didTransition: Bool
}

enum AgentRunNowOutcome: Equatable {
    case queued(AgentJob)
    case rejectedDisabled(AgentJob)
    case rejectedRunning(AgentJob)
}

enum AgentJobFinishOutcome: Equatable {
    case applied
    case superseded
}

enum AgentJobStoreError: LocalizedError {
    case database(String)
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .database(let detail): return "Agent job database error: \(detail)"
        case .invalidState(let detail): return "Agent job state error: \(detail)"
        }
    }
}

final class AgentJobStore {
    static let globalConcurrency = 3
    static let runtimeConcurrency: [AgentRuntimeKind: Int] = [.codex: 2, .opencode: 3]

    private let db: OpaquePointer
    private let lock = NSRecursiveLock()

    init(url: URL = VoiceFlowPaths.shared.file("agent-jobs.sqlite")) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            throw AgentJobStoreError.database("could not open \(url.path)")
        }
        db = handle
        sqlite3_busy_timeout(db, 5_000)
        do { try migrate() } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    func put(_ job: AgentJob) throws {
        try lock.withLock {
            let sql = """
            INSERT INTO agent_jobs (
              id, assistant_slug, conversation_id, runtime, trigger_kind,
              prompt, trust_profile, state, next_run_at, interval_seconds,
              concurrency_key, daily_budget_usd, max_duration_seconds,
              max_attempts, created_at, updated_at, model_id, name,
              is_enabled, execution_generation
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              assistant_slug=excluded.assistant_slug,
              conversation_id=excluded.conversation_id,
              runtime=excluded.runtime, trigger_kind=excluded.trigger_kind,
              prompt=excluded.prompt, trust_profile=excluded.trust_profile,
              state=excluded.state, next_run_at=excluded.next_run_at,
              interval_seconds=excluded.interval_seconds,
              concurrency_key=excluded.concurrency_key,
              daily_budget_usd=excluded.daily_budget_usd,
              max_duration_seconds=excluded.max_duration_seconds,
              max_attempts=excluded.max_attempts, updated_at=excluded.updated_at,
              model_id=excluded.model_id, name=excluded.name,
              is_enabled=excluded.is_enabled,
              execution_generation=excluded.execution_generation
            """
            try withStatement(sql) { statement in
                bind(job, to: statement)
                try stepDone(statement)
            }
        }
    }

    func job(id: String) throws -> AgentJob? {
        try lock.withLock {
            try withStatement("SELECT * FROM agent_jobs WHERE id=?") { statement in
                bindText(id, at: 1, to: statement)
                return sqlite3_step(statement) == SQLITE_ROW ? decodeJob(statement) : nil
            }
        }
    }

    func jobs(limit: Int = 100) throws -> [AgentJob] {
        try lock.withLock {
            try withStatement(
                "SELECT * FROM agent_jobs ORDER BY updated_at DESC LIMIT ?") { statement in
                sqlite3_bind_int(statement, 1, Int32(min(max(limit, 1), 500)))
                var result: [AgentJob] = []
                while sqlite3_step(statement) == SQLITE_ROW { result.append(decodeJob(statement)) }
                return result
            }
        }
    }

    func jobs(conversationID: String) throws -> [AgentJob] {
        try lock.withLock {
            try withStatement(
                "SELECT * FROM agent_jobs WHERE conversation_id=? ORDER BY created_at,id") { statement in
                bindText(conversationID, at: 1, to: statement)
                var result: [AgentJob] = []
                while sqlite3_step(statement) == SQLITE_ROW { result.append(decodeJob(statement)) }
                return result
            }
        }
    }

    func runs(jobID: String, limit: Int = 30, before: Date? = nil) throws -> [AgentRun] {
        try lock.withLock {
            let boundedLimit = min(max(limit, 1), 100)
            if let before {
                return try runs(
                    sql: "SELECT * FROM agent_runs WHERE job_id=? AND started_at<? ORDER BY started_at DESC LIMIT ?",
                    bind: { statement in
                        self.bindText(jobID, at: 1, to: statement)
                        sqlite3_bind_double(statement, 2, before.timeIntervalSince1970)
                        sqlite3_bind_int(statement, 3, Int32(boundedLimit))
                    })
            }
            return try runs(
                sql: "SELECT * FROM agent_runs WHERE job_id=? ORDER BY started_at DESC LIMIT ?",
                bind: { statement in
                    self.bindText(jobID, at: 1, to: statement)
                    sqlite3_bind_int(statement, 2, Int32(boundedLimit))
                })
        }
    }

    func spentToday(jobID: String, now: Date = Date()) throws -> Double {
        try lock.withLock {
            let start = Calendar(identifier: .gregorian).startOfDay(for: now)
            return try scalarDouble(
                "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs WHERE job_id=? AND started_at>=?",
                text: jobID, number: start.timeIntervalSince1970)
        }
    }

    func hasPendingTrigger(jobID: String) throws -> Bool {
        try lock.withLock {
            try scalarDouble(
                "SELECT COALESCE(pending_trigger_at,0) FROM agent_jobs WHERE id=?",
                text: jobID) > 0
        }
    }

    func updateConfiguration(
        jobID: String, configuration: AgentJobConfiguration,
        now: Date = Date()
    ) throws {
        try lock.withLock {
            guard let current = try jobUnlocked(id: jobID) else {
                throw AgentJobStoreError.invalidState("automation no longer exists")
            }
            guard current.state != .running else {
                throw AgentJobStoreError.invalidState("stop the automation before editing it")
            }
            let prompt = configuration.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                throw AgentJobStoreError.invalidState("instructions cannot be empty")
            }
            var state = current.state
            var nextRunAt = current.nextRunAt
            var generation = current.generation
            if current.isEnabled,
               current.state != .blocked, current.state != .failed,
               configuration.trigger != current.trigger
                || (configuration.trigger == .interval
                    && configuration.intervalSeconds != current.intervalSeconds) {
                generation += 1
                if configuration.trigger == .interval,
                   let interval = configuration.intervalSeconds {
                    state = .queued
                    nextRunAt = now.addingTimeInterval(max(1, interval))
                } else {
                    state = .completed
                    nextRunAt = nil
                }
            }
            if !current.isEnabled { nextRunAt = nil }
            let updated = AgentJob(
                id: current.id, name: configuration.name,
                assistantSlug: configuration.assistantSlug,
                conversationID: configuration.conversationID,
                runtime: configuration.runtime, trigger: configuration.trigger,
                modelID: configuration.modelID, prompt: prompt,
                trustProfile: configuration.trustProfile,
                state: state, nextRunAt: nextRunAt,
                isEnabled: current.isEnabled, generation: generation,
                intervalSeconds: configuration.intervalSeconds,
                concurrencyKey: configuration.concurrencyKey,
                dailyBudgetUSD: max(0, configuration.dailyBudgetUSD),
                maxDurationSeconds: max(1, configuration.maxDurationSeconds),
                maxAttempts: max(1, configuration.maxAttempts),
                createdAt: current.createdAt, updatedAt: now)
            try put(updated)
        }
    }

    func delete(jobID: String) throws {
        try lock.withLock {
            try transaction {
                guard let job = try jobUnlocked(id: jobID) else { return }
                guard job.state != .running else {
                    throw AgentJobStoreError.invalidState(
                        "stop the automation before deleting it")
                }
                let liveRuns = try scalarInt(
                    "SELECT COUNT(*) FROM agent_runs WHERE job_id=? AND state='running'",
                    text: jobID)
                guard liveRuns == 0 else {
                    throw AgentJobStoreError.invalidState(
                        "stop the automation before deleting it")
                }
                try withStatement("DELETE FROM agent_runs WHERE job_id=?") { statement in
                    bindText(jobID, at: 1, to: statement)
                    try stepDone(statement)
                }
                try withStatement("DELETE FROM agent_jobs WHERE id=?") { statement in
                    bindText(jobID, at: 1, to: statement)
                    try stepDone(statement)
                }
            }
        }
    }

    /// Complete authoritative reference set, including disabled, completed,
    /// cancelled, failed, and blocked jobs. History retention/deletion must
    /// never infer this from only runnable rows.
    func jobReferencesByConversation() throws -> [String: Set<String>] {
        try lock.withLock {
            try withStatement(
                "SELECT conversation_id,id FROM agent_jobs ORDER BY conversation_id,id") { statement in
                var result: [String: Set<String>] = [:]
                while sqlite3_step(statement) == SQLITE_ROW {
                    result[text(statement, 0), default: []].insert(text(statement, 1))
                }
                return result
            }
        }
    }

    /// Exactly-once trigger intake. A duplicate source/event pair makes no
    /// state change even across app restarts.
    @discardableResult
    func enqueueEvent(source: String, eventID: String, jobID: String,
                      at: Date = Date()) throws -> Bool {
        try lock.withLock {
            try transaction {
                try withStatement(
                    "INSERT OR IGNORE INTO processed_events(source,event_id,processed_at) VALUES(?,?,?)") { statement in
                    bindText(source, at: 1, to: statement)
                    bindText(eventID, at: 2, to: statement)
                    sqlite3_bind_double(statement, 3, at.timeIntervalSince1970)
                    try stepDone(statement)
                }
                guard sqlite3_changes(db) == 1 else { return false }
                try withStatement(
                    """
                    UPDATE agent_jobs SET
                      state=CASE WHEN state='running' THEN state ELSE 'queued' END,
                      next_run_at=CASE WHEN state='running' THEN next_run_at ELSE ? END,
                      pending_trigger_at=CASE WHEN state='running' THEN ? ELSE pending_trigger_at END,
                      execution_generation=CASE
                        WHEN state IN ('running','queued') THEN execution_generation
                        ELSE execution_generation+1 END,
                      updated_at=?
                    WHERE id=? AND is_enabled=1
                    """) { statement in
                    sqlite3_bind_double(statement, 1, at.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 2, at.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 3, at.timeIntervalSince1970)
                    bindText(jobID, at: 4, to: statement)
                    try stepDone(statement)
                }
                return sqlite3_changes(db) == 1
            }
        }
    }

    /// Fans one exactly-once typed event into every matching durable job in
    /// the same transaction. The event row prevents duplicate intake after a
    /// watcher/inbox/capture reconnect or app restart.
    @discardableResult
    func enqueueTrigger(_ trigger: AgentJobTriggerKind,
                        source: String, eventID: String,
                        at: Date = Date()) throws -> Int {
        try lock.withLock {
            try transaction {
                try withStatement(
                    "INSERT OR IGNORE INTO processed_events(source,event_id,processed_at) VALUES(?,?,?)") { statement in
                    bindText(source, at: 1, to: statement)
                    bindText(eventID, at: 2, to: statement)
                    sqlite3_bind_double(statement, 3, at.timeIntervalSince1970)
                    try stepDone(statement)
                }
                guard sqlite3_changes(db) == 1 else { return 0 }
                try withStatement(
                    """
                    UPDATE agent_jobs SET
                      state=CASE WHEN state='running' THEN state ELSE 'queued' END,
                      next_run_at=CASE WHEN state='running' THEN next_run_at ELSE ? END,
                      pending_trigger_at=CASE WHEN state='running' THEN ? ELSE pending_trigger_at END,
                      execution_generation=CASE
                        WHEN state IN ('running','queued') THEN execution_generation
                        ELSE execution_generation+1 END,
                      updated_at=?
                    WHERE trigger_kind=? AND is_enabled=1
                    """) { statement in
                    sqlite3_bind_double(statement, 1, at.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 2, at.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 3, at.timeIntervalSince1970)
                    bindText(trigger.rawValue, at: 4, to: statement)
                    try stepDone(statement)
                }
                return Int(sqlite3_changes(db))
            }
        }
    }

    /// Atomically admits one fair due job, enforcing global/runtime caps,
    /// per-conversation and concurrency-key exclusion, attempts, and budget.
    func claimNext(workerID: String, now: Date = Date(),
                   leaseSeconds: TimeInterval = 30) throws -> AgentRun? {
        try lock.withLock {
            try transaction {
                let active = try scalarInt("SELECT COUNT(*) FROM agent_runs WHERE state='running'")
                guard active < Self.globalConcurrency else { return nil }
                let candidates = try dueJobs(now: now)
                for job in candidates {
                    let runtimeActive = try scalarInt(
                        "SELECT COUNT(*) FROM agent_runs WHERE state='running' AND runtime=?",
                        text: job.runtime.rawValue)
                    guard runtimeActive < (Self.runtimeConcurrency[job.runtime] ?? 1) else { continue }
                    let conflict = try scalarInt(
                        """
                        SELECT COUNT(*) FROM agent_runs r
                        JOIN agent_jobs j ON j.id=r.job_id
                        WHERE r.state='running' AND
                          (j.conversation_id=? OR j.concurrency_key=?)
                        """, texts: [job.conversationID, job.concurrencyKey])
                    guard conflict == 0 else { continue }
                    let attempts = try scalarInt(
                        """
                        SELECT COUNT(*) FROM agent_runs
                        WHERE job_id=? AND execution_generation=?
                        """, text: job.id, integer: job.generation)
                    guard attempts < job.maxAttempts else {
                        try setJobState(job.id, state: .failed, at: now)
                        continue
                    }
                    let startOfDay = Calendar(identifier: .gregorian).startOfDay(for: now)
                    let spent = try scalarDouble(
                        "SELECT COALESCE(SUM(cost_usd),0) FROM agent_runs WHERE job_id=? AND started_at>=?",
                        text: job.id, number: startOfDay.timeIntervalSince1970)
                    guard spent < job.dailyBudgetUSD else {
                        try setJobState(job.id, state: .blocked, at: now)
                        continue
                    }
                    let run = AgentRun(
                        id: UUID().uuidString, jobID: job.id, turnID: UUID(),
                        runtime: job.runtime, generation: job.generation,
                        state: .running, workerID: workerID,
                        leaseExpiresAt: now.addingTimeInterval(leaseSeconds),
                        heartbeatAt: now, attempt: attempts + 1,
                        startedAt: now, finishedAt: nil, costUSD: 0,
                        error: nil, resultMessageID: nil)
                    try insert(run)
                    try withStatement(
                        "UPDATE agent_jobs SET state='running',next_run_at=NULL,updated_at=? WHERE id=?") { statement in
                        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                        bindText(job.id, at: 2, to: statement)
                        try stepDone(statement)
                    }
                    return run
                }
                return nil
            }
        }
    }

    @discardableResult
    func heartbeat(runID: String, workerID: String, now: Date = Date(),
                   leaseSeconds: TimeInterval = 30) throws -> Bool {
        try lock.withLock {
            try withStatement(
                """
                UPDATE agent_runs SET heartbeat_at=?, lease_expires_at=?
                WHERE id=? AND worker_id=? AND state='running'
                """) { statement in
                sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                sqlite3_bind_double(statement, 2, now.addingTimeInterval(leaseSeconds).timeIntervalSince1970)
                bindText(runID, at: 3, to: statement)
                bindText(workerID, at: 4, to: statement)
                try stepDone(statement)
            }
            return sqlite3_changes(db) == 1
        }
    }

    @discardableResult
    func complete(runID: String, workerID: String,
                  resultMessageID: UUID?, costUSD: Double,
                  now: Date = Date()) throws -> AgentJobFinishOutcome {
        try finish(runID: runID, workerID: workerID, state: .completed,
                   error: nil, resultMessageID: resultMessageID,
                   costUSD: costUSD, now: now, retryDelay: nil)
    }

    @discardableResult
    func fail(runID: String, workerID: String, error: String,
              retryable: Bool, now: Date = Date(), retryDelay: TimeInterval = 5) throws
        -> AgentJobFinishOutcome {
        try finish(runID: runID, workerID: workerID, state: .failed,
                   error: error, resultMessageID: nil, costUSD: 0,
                   now: now, retryDelay: retryable ? retryDelay : nil)
    }

    func stopActiveRun(jobID: String, now: Date = Date()) throws
        -> AgentJobControlTransition {
        try lock.withLock {
            try transaction {
                guard let job = try jobUnlocked(id: jobID) else {
                    throw AgentJobStoreError.invalidState("automation no longer exists")
                }
                let runIDs = try activeRunIDsUnlocked(jobID: jobID)
                guard !runIDs.isEmpty else {
                    return AgentJobControlTransition(
                        job: job, cancelledRunIDs: [], didTransition: false)
                }
                try cancelActiveRunsUnlocked(jobID: jobID, now: now, reason: "stopped by user")
                let interval = job.trigger == .interval ? job.intervalSeconds : nil
                let target: AgentJobState = interval == nil ? .completed : .queued
                let next = interval.map { now.addingTimeInterval(max(1, $0)) }
                try withStatement(
                    """
                    UPDATE agent_jobs SET state=?,next_run_at=?,pending_trigger_at=NULL,
                      is_enabled=1,execution_generation=execution_generation+1,updated_at=?
                    WHERE id=? AND is_enabled=1
                    """) { statement in
                    bindText(target.rawValue, at: 1, to: statement)
                    bindOptionalDouble(next?.timeIntervalSince1970, at: 2, to: statement)
                    sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                    bindText(jobID, at: 4, to: statement)
                    try stepDone(statement)
                }
                guard let updated = try jobUnlocked(id: jobID) else {
                    throw AgentJobStoreError.invalidState("automation no longer exists")
                }
                return AgentJobControlTransition(
                    job: updated, cancelledRunIDs: runIDs, didTransition: true)
            }
        }
    }

    func disable(jobID: String, now: Date = Date()) throws
        -> AgentJobControlTransition {
        try lock.withLock {
            try transaction {
                guard let job = try jobUnlocked(id: jobID) else {
                    throw AgentJobStoreError.invalidState("automation no longer exists")
                }
                let runIDs = try activeRunIDsUnlocked(jobID: jobID)
                let changed = job.isEnabled || !runIDs.isEmpty
                if !runIDs.isEmpty {
                    try cancelActiveRunsUnlocked(
                        jobID: jobID, now: now, reason: "disabled by user")
                }
                let target: AgentJobState = job.state == .blocked || job.state == .failed
                    ? job.state : .disabled
                try withStatement(
                    """
                    UPDATE agent_jobs SET state=?,is_enabled=0,next_run_at=NULL,
                      pending_trigger_at=NULL,execution_generation=execution_generation+?,
                      updated_at=? WHERE id=?
                    """) { statement in
                    bindText(target.rawValue, at: 1, to: statement)
                    sqlite3_bind_int(statement, 2, changed ? 1 : 0)
                    sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                    bindText(jobID, at: 4, to: statement)
                    try stepDone(statement)
                }
                guard let updated = try jobUnlocked(id: jobID) else {
                    throw AgentJobStoreError.invalidState("automation no longer exists")
                }
                return AgentJobControlTransition(
                    job: updated, cancelledRunIDs: runIDs, didTransition: changed)
            }
        }
    }

    func enable(jobID: String, now: Date = Date()) throws
        -> AgentJobControlTransition {
        try lock.withLock {
            try transaction {
                guard let job = try jobUnlocked(id: jobID) else {
                    throw AgentJobStoreError.invalidState("automation no longer exists")
                }
                guard !job.isEnabled else {
                    return AgentJobControlTransition(
                        job: job, cancelledRunIDs: [], didTransition: false)
                }
                let interval = job.trigger == .interval ? job.intervalSeconds : nil
                let target: AgentJobState = interval == nil ? .completed : .queued
                let next = interval.map { now.addingTimeInterval(max(1, $0)) }
                try withStatement(
                    """
                    UPDATE agent_jobs SET state=?,is_enabled=1,next_run_at=?,
                      pending_trigger_at=NULL,execution_generation=execution_generation+1,
                      updated_at=? WHERE id=?
                    """) { statement in
                    bindText(target.rawValue, at: 1, to: statement)
                    bindOptionalDouble(next?.timeIntervalSince1970, at: 2, to: statement)
                    sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                    bindText(jobID, at: 4, to: statement)
                    try stepDone(statement)
                }
                guard let updated = try jobUnlocked(id: jobID) else {
                    throw AgentJobStoreError.invalidState("automation no longer exists")
                }
                return AgentJobControlTransition(
                    job: updated, cancelledRunIDs: [], didTransition: true)
            }
        }
    }

    func runNow(jobID: String, at: Date = Date()) throws -> AgentRunNowOutcome {
        try lock.withLock {
            try transaction {
                guard let job = try jobUnlocked(id: jobID) else {
                    throw AgentJobStoreError.invalidState("automation no longer exists")
                }
                guard job.isEnabled else { return .rejectedDisabled(job) }
                guard job.state != .running else { return .rejectedRunning(job) }
                try withStatement(
                    """
                    UPDATE agent_jobs SET state='queued',next_run_at=?,pending_trigger_at=NULL,
                      execution_generation=execution_generation+1,updated_at=? WHERE id=?
                    """) { statement in
                    sqlite3_bind_double(statement, 1, at.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 2, at.timeIntervalSince1970)
                    bindText(jobID, at: 3, to: statement)
                    try stepDone(statement)
                }
                guard let updated = try jobUnlocked(id: jobID) else {
                    throw AgentJobStoreError.invalidState("automation no longer exists")
                }
                return .queued(updated)
            }
        }
    }

    @available(*, deprecated, message: "Use enable/disable through AgentSupervisor")
    func setEnabled(jobID: String, enabled: Bool, now: Date = Date()) throws {
        if enabled { _ = try enable(jobID: jobID, now: now) }
        else { _ = try disable(jobID: jobID, now: now) }
    }

    /// Prepare an Assistant folder for Trash without losing rollback. Every
    /// owned job state is captured and non-running jobs are disabled in one
    /// transaction; a running row aborts the whole operation unchanged.
    func disableJobsForAssistant(
        _ assistantSlug: String, now: Date = Date()
    ) throws -> [AgentJobStateSnapshot] {
        try lock.withLock {
            try transaction {
                let jobs = try withStatement(
                    """
                    SELECT id,state,is_enabled,execution_generation,next_run_at,
                      pending_trigger_at,updated_at
                    FROM agent_jobs WHERE assistant_slug=? ORDER BY id
                    """) { statement in
                    bindText(assistantSlug, at: 1, to: statement)
                    var result: [AgentJobStateSnapshot] = []
                    while sqlite3_step(statement) == SQLITE_ROW {
                        result.append(AgentJobStateSnapshot(
                            id: text(statement, 0),
                            state: AgentJobState(rawValue: text(statement, 1)) ?? .failed,
                            isEnabled: sqlite3_column_int(statement, 2) == 1,
                            generation: Int(sqlite3_column_int(statement, 3)),
                            nextRunAt: optionalDate(statement, 4),
                            pendingTriggerAt: optionalDate(statement, 5),
                            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))))
                    }
                    return result
                }
                guard !jobs.contains(where: { $0.state == .running }) else {
                    throw AgentJobStoreError.invalidState(
                        "an automation for this Assistant is running")
                }
                try withStatement(
                    "UPDATE agent_jobs SET state='disabled',is_enabled=0,next_run_at=NULL,pending_trigger_at=NULL,updated_at=? WHERE assistant_slug=?") { statement in
                    sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                    bindText(assistantSlug, at: 2, to: statement)
                    try stepDone(statement)
                }
                return jobs
            }
        }
    }

    func restoreJobStates(_ snapshots: [AgentJobStateSnapshot]) throws {
        guard !snapshots.isEmpty else { return }
        try lock.withLock {
            try transaction {
                for snapshot in snapshots {
                    try withStatement(
                        """
                        UPDATE agent_jobs SET state=?,is_enabled=?,execution_generation=?,
                          next_run_at=?,pending_trigger_at=?,updated_at=? WHERE id=?
                        """) { statement in
                        bindText(snapshot.state.rawValue, at: 1, to: statement)
                        sqlite3_bind_int(statement, 2, snapshot.isEnabled ? 1 : 0)
                        sqlite3_bind_int(statement, 3, Int32(snapshot.generation))
                        bindOptionalDouble(snapshot.nextRunAt?.timeIntervalSince1970, at: 4, to: statement)
                        bindOptionalDouble(snapshot.pendingTriggerAt?.timeIntervalSince1970, at: 5, to: statement)
                        sqlite3_bind_double(statement, 6, snapshot.updatedAt.timeIntervalSince1970)
                        bindText(snapshot.id, at: 7, to: statement)
                        try stepDone(statement)
                    }
                }
            }
        }
    }

    /// Expired workers never silently remain running. At most one retry is
    /// scheduled because the original run row is transitioned atomically.
    @discardableResult
    func recoverExpired(now: Date = Date(), retryDelay: TimeInterval = 5) throws -> Int {
        try lock.withLock {
            try transaction {
                let expired = try runs(
                    sql: "SELECT * FROM agent_runs WHERE state='running' AND lease_expires_at<?",
                    bind: { sqlite3_bind_double($0, 1, now.timeIntervalSince1970) })
                for run in expired {
                    try withStatement(
                        "UPDATE agent_runs SET state='interrupted', finished_at=?, error=? WHERE id=? AND state='running'") { statement in
                        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                        bindText("worker lease expired", at: 2, to: statement)
                        bindText(run.id, at: 3, to: statement)
                        try stepDone(statement)
                    }
                    guard let job = try jobUnlocked(id: run.jobID),
                          job.isEnabled, job.generation == run.generation else { continue }
                    let attempts = try scalarInt(
                        """
                        SELECT COUNT(*) FROM agent_runs
                        WHERE job_id=? AND execution_generation=?
                        """, text: job.id, integer: job.generation)
                    if attempts < job.maxAttempts {
                        try schedule(job.id, at: now.addingTimeInterval(retryDelay), newGeneration: false)
                    } else {
                        try setJobState(job.id, state: .failed, at: now)
                    }
                }
                return expired.count
            }
        }
    }

    func activeRuns() throws -> [AgentRun] {
        try lock.withLock {
            try runs(sql: "SELECT * FROM agent_runs WHERE state='running' ORDER BY started_at", bind: { _ in })
        }
    }

    func run(id: String) throws -> AgentRun? {
        try lock.withLock {
            try runs(sql: "SELECT * FROM agent_runs WHERE id=?", bind: {
                self.bindText(id, at: 1, to: $0)
            }).first
        }
    }

    private func finish(runID: String, workerID: String,
                        state: AgentRunState, error: String?, resultMessageID: UUID?,
                        costUSD: Double, now: Date, retryDelay: TimeInterval?) throws
        -> AgentJobFinishOutcome {
        try lock.withLock {
            try transaction {
                guard let run = try runs(
                    sql: "SELECT * FROM agent_runs WHERE id=? AND worker_id=? AND state='running'",
                    bind: { statement in
                        self.bindText(runID, at: 1, to: statement)
                        self.bindText(workerID, at: 2, to: statement)
                    }).first else {
                    return .superseded
                }
                guard let job = try jobUnlocked(id: run.jobID),
                      job.isEnabled, job.generation == run.generation else {
                    try withStatement(
                        """
                        UPDATE agent_runs SET state='cancelled',finished_at=?,error='superseded'
                        WHERE id=? AND worker_id=? AND state='running'
                        """) { statement in
                        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                        bindText(runID, at: 2, to: statement)
                        bindText(workerID, at: 3, to: statement)
                        try stepDone(statement)
                    }
                    return .superseded
                }
                try withStatement(
                    """
                    UPDATE agent_runs SET state=?, finished_at=?, cost_usd=?, error=?, result_message_id=?
                    WHERE id=? AND worker_id=? AND state='running'
                    """) { statement in
                    bindText(state.rawValue, at: 1, to: statement)
                    sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 3, max(0, costUSD))
                    bindOptionalText(error.map { AgentSecretPolicy.redacted($0) }, at: 4, to: statement)
                    bindOptionalText(resultMessageID?.uuidString, at: 5, to: statement)
                    bindText(runID, at: 6, to: statement)
                    bindText(workerID, at: 7, to: statement)
                    try stepDone(statement)
                }
                let pending = try scalarDouble(
                    "SELECT COALESCE(pending_trigger_at,0) FROM agent_jobs WHERE id=?",
                    text: job.id)
                if pending > 0 {
                    try withStatement(
                        "UPDATE agent_jobs SET pending_trigger_at=NULL WHERE id=?") { statement in
                        bindText(job.id, at: 1, to: statement)
                        try stepDone(statement)
                    }
                    try schedule(job.id, at: now, newGeneration: true)
                } else if state == .completed, job.trigger == .interval, let interval = job.intervalSeconds {
                    try schedule(
                        job.id, at: now.addingTimeInterval(interval), newGeneration: true)
                } else if let retryDelay {
                    let attempts = try scalarInt(
                        """
                        SELECT COUNT(*) FROM agent_runs
                        WHERE job_id=? AND execution_generation=?
                        """, text: job.id, integer: job.generation)
                    if attempts < job.maxAttempts {
                        try schedule(
                            job.id, at: now.addingTimeInterval(retryDelay),
                            newGeneration: false)
                    } else {
                        try setJobState(job.id, state: .failed, at: now)
                    }
                } else {
                    try setJobState(job.id, state: state == .completed ? .completed : .failed, at: now)
                }
                return .applied
            }
        }
    }

    private func dueJobs(now: Date) throws -> [AgentJob] {
        try withStatement(
            """
            SELECT * FROM agent_jobs
            WHERE is_enabled=1 AND state='queued'
              AND next_run_at IS NOT NULL AND next_run_at<=?
            ORDER BY next_run_at ASC, updated_at ASC, created_at ASC
            """) { statement in
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            var result: [AgentJob] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(decodeJob(statement)) }
            return result
        }
    }

    private func schedule(_ jobID: String, at date: Date,
                          newGeneration: Bool) throws {
        try withStatement(
            """
            UPDATE agent_jobs SET state='queued',next_run_at=?,
              execution_generation=execution_generation+?,updated_at=?
            WHERE id=? AND is_enabled=1
            """) { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, newGeneration ? 1 : 0)
            sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
            bindText(jobID, at: 4, to: statement)
            try stepDone(statement)
        }
    }

    private func setJobState(_ id: String, state: AgentJobState, at date: Date) throws {
        try withStatement("UPDATE agent_jobs SET state=?, updated_at=? WHERE id=?") { statement in
            bindText(state.rawValue, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            bindText(id, at: 3, to: statement)
            try stepDone(statement)
        }
    }

    private func activeRunIDsUnlocked(jobID: String) throws -> [String] {
        try withStatement(
            "SELECT id FROM agent_runs WHERE job_id=? AND state='running' ORDER BY started_at,id"
        ) { statement in
            bindText(jobID, at: 1, to: statement)
            var ids: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { ids.append(text(statement, 0)) }
            return ids
        }
    }

    private func cancelActiveRunsUnlocked(
        jobID: String, now: Date, reason: String
    ) throws {
        try withStatement(
            """
            UPDATE agent_runs SET state='cancelled',finished_at=?,error=?
            WHERE job_id=? AND state='running'
            """) { statement in
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            bindText(reason, at: 2, to: statement)
            bindText(jobID, at: 3, to: statement)
            try stepDone(statement)
        }
    }

    private func insert(_ run: AgentRun) throws {
        try withStatement(
            """
            INSERT INTO agent_runs (
              id,job_id,turn_id,runtime,state,worker_id,lease_expires_at,
              heartbeat_at,attempt,started_at,finished_at,cost_usd,error,result_message_id,
              execution_generation
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """) { statement in
            bindText(run.id, at: 1, to: statement)
            bindText(run.jobID, at: 2, to: statement)
            bindText(run.turnID.uuidString, at: 3, to: statement)
            bindText(run.runtime.rawValue, at: 4, to: statement)
            bindText(run.state.rawValue, at: 5, to: statement)
            bindText(run.workerID, at: 6, to: statement)
            sqlite3_bind_double(statement, 7, run.leaseExpiresAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 8, run.heartbeatAt.timeIntervalSince1970)
            sqlite3_bind_int(statement, 9, Int32(run.attempt))
            sqlite3_bind_double(statement, 10, run.startedAt.timeIntervalSince1970)
            bindOptionalDouble(run.finishedAt?.timeIntervalSince1970, at: 11, to: statement)
            sqlite3_bind_double(statement, 12, run.costUSD)
            bindOptionalText(run.error, at: 13, to: statement)
            bindOptionalText(run.resultMessageID?.uuidString, at: 14, to: statement)
            sqlite3_bind_int(statement, 15, Int32(run.generation))
            try stepDone(statement)
        }
    }

    private func jobUnlocked(id: String) throws -> AgentJob? {
        try withStatement("SELECT * FROM agent_jobs WHERE id=?") { statement in
            bindText(id, at: 1, to: statement)
            return sqlite3_step(statement) == SQLITE_ROW ? decodeJob(statement) : nil
        }
    }

    private func runs(sql: String, bind: (OpaquePointer) -> Void) throws -> [AgentRun] {
        try withStatement(sql) { statement in
            bind(statement)
            var result: [AgentRun] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(decodeRun(statement)) }
            return result
        }
    }

    private func decodeJob(_ statement: OpaquePointer) -> AgentJob {
        AgentJob(
            id: text(statement, 0), name: optionalText(statement, 18),
            assistantSlug: text(statement, 1),
            conversationID: text(statement, 2),
            runtime: AgentRuntimeKind(rawValue: text(statement, 3)) ?? .codex,
            trigger: AgentJobTriggerKind(rawValue: text(statement, 4)) ?? .manual,
            modelID: optionalText(statement, 17),
            prompt: text(statement, 5),
            trustProfile: AgentTrustProfile(rawValue: text(statement, 6)) ?? .unattended,
            state: AgentJobState(rawValue: text(statement, 7)) ?? .failed,
            nextRunAt: optionalDate(statement, 8),
            isEnabled: sqlite3_column_int(statement, 19) == 1,
            generation: Int(sqlite3_column_int(statement, 20)),
            intervalSeconds: optionalDouble(statement, 9),
            concurrencyKey: text(statement, 10),
            dailyBudgetUSD: sqlite3_column_double(statement, 11),
            maxDurationSeconds: sqlite3_column_double(statement, 12),
            maxAttempts: Int(sqlite3_column_int(statement, 13)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 15)))
    }

    private func decodeRun(_ statement: OpaquePointer) -> AgentRun {
        AgentRun(
            id: text(statement, 0), jobID: text(statement, 1),
            turnID: UUID(uuidString: text(statement, 2)) ?? UUID(),
            runtime: AgentRuntimeKind(rawValue: text(statement, 3)) ?? .codex,
            generation: Int(sqlite3_column_int(statement, 14)),
            state: AgentRunState(rawValue: text(statement, 4)) ?? .failed,
            workerID: text(statement, 5),
            leaseExpiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            heartbeatAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            attempt: Int(sqlite3_column_int(statement, 8)),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            finishedAt: optionalDate(statement, 10),
            costUSD: sqlite3_column_double(statement, 11),
            error: optionalText(statement, 12),
            resultMessageID: optionalText(statement, 13).flatMap(UUID.init(uuidString:)))
    }

    private func migrate() throws {
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("""
        CREATE TABLE IF NOT EXISTS agent_jobs (
          id TEXT PRIMARY KEY,
          assistant_slug TEXT NOT NULL,
          conversation_id TEXT NOT NULL,
          runtime TEXT NOT NULL,
          trigger_kind TEXT NOT NULL,
          prompt TEXT NOT NULL,
          trust_profile TEXT NOT NULL,
          state TEXT NOT NULL,
          next_run_at REAL,
          interval_seconds REAL,
          concurrency_key TEXT NOT NULL,
          daily_budget_usd REAL NOT NULL,
          max_duration_seconds REAL NOT NULL,
          max_attempts INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          pending_trigger_at REAL,
          model_id TEXT,
          name TEXT,
          is_enabled INTEGER NOT NULL DEFAULT 1,
          execution_generation INTEGER NOT NULL DEFAULT 1
        )
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS agent_runs (
          id TEXT PRIMARY KEY,
          job_id TEXT NOT NULL REFERENCES agent_jobs(id),
          turn_id TEXT NOT NULL,
          runtime TEXT NOT NULL,
          state TEXT NOT NULL,
          worker_id TEXT NOT NULL,
          lease_expires_at REAL NOT NULL,
          heartbeat_at REAL NOT NULL,
          attempt INTEGER NOT NULL,
          started_at REAL NOT NULL,
          finished_at REAL,
          cost_usd REAL NOT NULL DEFAULT 0,
          error TEXT,
          result_message_id TEXT,
          execution_generation INTEGER NOT NULL DEFAULT 1
        )
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS processed_events (
          source TEXT NOT NULL,
          event_id TEXT NOT NULL,
          processed_at REAL NOT NULL,
          PRIMARY KEY(source,event_id)
        )
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_jobs_due ON agent_jobs(state,next_run_at,updated_at)")
        try exec("CREATE INDEX IF NOT EXISTS idx_jobs_conversation ON agent_jobs(conversation_id,state)")
        try exec("CREATE INDEX IF NOT EXISTS idx_jobs_assistant ON agent_jobs(assistant_slug,state)")
        try exec("CREATE INDEX IF NOT EXISTS idx_runs_active ON agent_runs(state,runtime,lease_expires_at)")
        try addColumnIfMissing(
            table: "agent_jobs", column: "pending_trigger_at",
            definition: "pending_trigger_at REAL")
        try addColumnIfMissing(
            table: "agent_jobs", column: "model_id", definition: "model_id TEXT")
        try addColumnIfMissing(
            table: "agent_jobs", column: "name", definition: "name TEXT")
        let schemaVersion = try scalarInt("PRAGMA user_version")
        if schemaVersion < 1 {
            try addColumnIfMissing(
                table: "agent_jobs", column: "is_enabled",
                definition: "is_enabled INTEGER NOT NULL DEFAULT 1")
            try addColumnIfMissing(
                table: "agent_jobs", column: "execution_generation",
                definition: "execution_generation INTEGER NOT NULL DEFAULT 1")
            try addColumnIfMissing(
                table: "agent_runs", column: "execution_generation",
                definition: "execution_generation INTEGER NOT NULL DEFAULT 0")
            try transaction {
                try exec("""
                UPDATE agent_jobs SET is_enabled=CASE
                  WHEN state IN ('disabled','cancelled') THEN 0 ELSE 1 END,
                  execution_generation=1
                """)
                try exec("""
                UPDATE agent_runs SET execution_generation=1
                WHERE started_at>COALESCE(
                  (SELECT MAX(completed.finished_at) FROM agent_runs AS completed
                   WHERE completed.job_id=agent_runs.job_id
                     AND completed.state='completed'),0)
                """)
                try exec("PRAGMA user_version=1")
            }
        }
        try exec("""
        UPDATE agent_jobs
        SET name=CASE
          WHEN trim(prompt)='' THEN 'Untitled automation'
          WHEN instr(replace(prompt,char(13),''),char(10))>0 THEN
            substr(trim(replace(prompt,char(13),'')),1,
              instr(trim(replace(prompt,char(13),'')),char(10))-1)
          ELSE trim(prompt)
        END
        WHERE name IS NULL OR trim(name)=''
        """)
    }

    private func addColumnIfMissing(
        table: String, column: String, definition: String
    ) throws {
        let exists = try withStatement("PRAGMA table_info(\(table))") { statement in
            var found = false
            while sqlite3_step(statement) == SQLITE_ROW {
                if text(statement, 1) == column { found = true }
            }
            return found
        }
        if !exists { try exec("ALTER TABLE \(table) ADD COLUMN \(definition)") }
    }

    private func transaction<T>(_ work: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try work()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? lastError()
            sqlite3_free(error)
            throw AgentJobStoreError.database(detail)
        }
    }

    private func withStatement<T>(_ sql: String, _ work: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw AgentJobStoreError.database(lastError()) }
        defer { sqlite3_finalize(statement) }
        return try work(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AgentJobStoreError.database(lastError())
        }
    }

    private func scalarInt(_ sql: String, text value: String? = nil,
                           texts: [String] = []) throws -> Int {
        try withStatement(sql) { statement in
            if let value { bindText(value, at: 1, to: statement) }
            for (offset, item) in texts.enumerated() { bindText(item, at: Int32(offset + 1), to: statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func scalarInt(_ sql: String, text value: String,
                           integer: Int) throws -> Int {
        try withStatement(sql) { statement in
            bindText(value, at: 1, to: statement)
            sqlite3_bind_int(statement, 2, Int32(integer))
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func scalarDouble(_ sql: String, text value: String,
                              number: Double) throws -> Double {
        try withStatement(sql) { statement in
            bindText(value, at: 1, to: statement)
            sqlite3_bind_double(statement, 2, number)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return sqlite3_column_double(statement, 0)
        }
    }

    private func scalarDouble(_ sql: String, text value: String) throws -> Double {
        try withStatement(sql) { statement in
            bindText(value, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return sqlite3_column_double(statement, 0)
        }
    }

    private func bind(_ job: AgentJob, to statement: OpaquePointer) {
        bindText(job.id, at: 1, to: statement)
        bindText(job.assistantSlug, at: 2, to: statement)
        bindText(job.conversationID, at: 3, to: statement)
        bindText(job.runtime.rawValue, at: 4, to: statement)
        bindText(job.trigger.rawValue, at: 5, to: statement)
        bindText(job.prompt, at: 6, to: statement)
        bindText(job.trustProfile.rawValue, at: 7, to: statement)
        bindText(job.state.rawValue, at: 8, to: statement)
        bindOptionalDouble(job.nextRunAt?.timeIntervalSince1970, at: 9, to: statement)
        bindOptionalDouble(job.intervalSeconds, at: 10, to: statement)
        bindText(job.concurrencyKey, at: 11, to: statement)
        sqlite3_bind_double(statement, 12, job.dailyBudgetUSD)
        sqlite3_bind_double(statement, 13, job.maxDurationSeconds)
        sqlite3_bind_int(statement, 14, Int32(job.maxAttempts))
        sqlite3_bind_double(statement, 15, job.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 16, job.updatedAt.timeIntervalSince1970)
        bindOptionalText(job.modelID, at: 17, to: statement)
        bindText(job.name, at: 18, to: statement)
        sqlite3_bind_int(statement, 19, job.isEnabled ? 1 : 0)
        sqlite3_bind_int(statement, 20, Int32(job.generation))
    }

    private func bindText(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT_VF)
    }

    private func bindOptionalText(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        if let value { bindText(value, at: index, to: statement) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bindOptionalDouble(_ value: Double?, at index: Int32, to statement: OpaquePointer) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    private func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, index)
    }

    private func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        optionalDouble(statement, index).map(Date.init(timeIntervalSince1970:))
    }

    private func lastError() -> String { String(cString: sqlite3_errmsg(db)) }
}

private let SQLITE_TRANSIENT_VF = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
