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
    let assistantSlug: String
    let conversationID: String
    let runtime: AgentRuntimeKind
    let modelID: String?
    let trigger: AgentJobTriggerKind
    let prompt: String
    let trustProfile: AgentTrustProfile
    let state: AgentJobState
    let nextRunAt: Date?
    let intervalSeconds: TimeInterval?
    let concurrencyKey: String
    let dailyBudgetUSD: Double
    let maxDurationSeconds: TimeInterval
    let maxAttempts: Int
    let createdAt: Date
    let updatedAt: Date

    init(id: String = UUID().uuidString,
         assistantSlug: String, conversationID: String,
         runtime: AgentRuntimeKind, trigger: AgentJobTriggerKind,
         modelID: String? = nil,
         prompt: String, trustProfile: AgentTrustProfile = .unattended,
         state: AgentJobState = .queued, nextRunAt: Date? = Date(),
         intervalSeconds: TimeInterval? = nil,
         concurrencyKey: String? = nil,
         dailyBudgetUSD: Double = 1.0,
         maxDurationSeconds: TimeInterval = 900,
         maxAttempts: Int = 3,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.assistantSlug = assistantSlug
        self.conversationID = conversationID
        self.runtime = runtime
        let trimmedModel = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.modelID = trimmedModel.isEmpty ? nil : trimmedModel
        self.trigger = trigger
        self.prompt = prompt
        self.trustProfile = trustProfile
        self.state = state
        self.nextRunAt = nextRunAt
        self.intervalSeconds = intervalSeconds
        self.concurrencyKey = concurrencyKey ?? conversationID
        self.dailyBudgetUSD = dailyBudgetUSD
        self.maxDurationSeconds = maxDurationSeconds
        self.maxAttempts = maxAttempts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AgentRun: Equatable {
    let id: String
    let jobID: String
    let turnID: UUID
    let runtime: AgentRuntimeKind
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
              max_attempts, created_at, updated_at, model_id
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
              model_id=excluded.model_id
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
                      updated_at=?
                    WHERE id=? AND state NOT IN ('cancelled','disabled')
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
                      updated_at=?
                    WHERE trigger_kind=? AND state NOT IN ('cancelled','disabled')
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
                        WHERE job_id=? AND started_at>COALESCE(
                          (SELECT MAX(finished_at) FROM agent_runs
                           WHERE job_id=? AND state='completed'), 0)
                        """, texts: [job.id, job.id])
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
                        runtime: job.runtime, state: .running, workerID: workerID,
                        leaseExpiresAt: now.addingTimeInterval(leaseSeconds),
                        heartbeatAt: now, attempt: attempts + 1,
                        startedAt: now, finishedAt: nil, costUSD: 0,
                        error: nil, resultMessageID: nil)
                    try insert(run)
                    try setJobState(job.id, state: .running, at: now)
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

    func complete(runID: String, workerID: String,
                  resultMessageID: UUID?, costUSD: Double,
                  now: Date = Date()) throws {
        try finish(runID: runID, workerID: workerID, state: .completed,
                   error: nil, resultMessageID: resultMessageID,
                   costUSD: costUSD, now: now, retryDelay: nil)
    }

    func fail(runID: String, workerID: String, error: String,
              retryable: Bool, now: Date = Date(), retryDelay: TimeInterval = 5) throws {
        try finish(runID: runID, workerID: workerID, state: .failed,
                   error: error, resultMessageID: nil, costUSD: 0,
                   now: now, retryDelay: retryable ? retryDelay : nil)
    }

    func cancel(jobID: String, now: Date = Date()) throws {
        try lock.withLock {
            try transaction {
                try setJobState(jobID, state: .cancelled, at: now)
                try withStatement(
                    "UPDATE agent_runs SET state='cancelled', finished_at=? WHERE job_id=? AND state='running'") { statement in
                    sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
                    bindText(jobID, at: 2, to: statement)
                    try stepDone(statement)
                }
            }
        }
    }

    func runNow(jobID: String, at: Date = Date()) throws {
        _ = try enqueueEvent(
            source: "manual", eventID: UUID().uuidString,
            jobID: jobID, at: at)
    }

    func setEnabled(jobID: String, enabled: Bool, now: Date = Date()) throws {
        try lock.withLock {
            try withStatement(
                "UPDATE agent_jobs SET state=?, next_run_at=?, updated_at=? WHERE id=?") { statement in
                bindText(enabled ? AgentJobState.queued.rawValue : AgentJobState.disabled.rawValue,
                         at: 1, to: statement)
                if enabled { sqlite3_bind_double(statement, 2, now.timeIntervalSince1970) }
                else { sqlite3_bind_null(statement, 2) }
                sqlite3_bind_double(statement, 3, now.timeIntervalSince1970)
                bindText(jobID, at: 4, to: statement)
                try stepDone(statement)
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
                    guard let job = try jobUnlocked(id: run.jobID) else { continue }
                    let attempts = try scalarInt(
                        """
                        SELECT COUNT(*) FROM agent_runs
                        WHERE job_id=? AND started_at>COALESCE(
                          (SELECT MAX(finished_at) FROM agent_runs
                           WHERE job_id=? AND state='completed'), 0)
                        """, texts: [job.id, job.id])
                    if attempts < job.maxAttempts {
                        try schedule(job.id, at: now.addingTimeInterval(retryDelay))
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
                        costUSD: Double, now: Date, retryDelay: TimeInterval?) throws {
        try lock.withLock {
            try transaction {
                guard let run = try runs(
                    sql: "SELECT * FROM agent_runs WHERE id=? AND worker_id=? AND state='running'",
                    bind: { statement in
                        self.bindText(runID, at: 1, to: statement)
                        self.bindText(workerID, at: 2, to: statement)
                    }).first else {
                    throw AgentJobStoreError.invalidState("run lease is no longer owned by this worker")
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
                guard let job = try jobUnlocked(id: run.jobID) else { return }
                let pending = try scalarDouble(
                    "SELECT COALESCE(pending_trigger_at,0) FROM agent_jobs WHERE id=?",
                    text: job.id)
                if pending > 0 {
                    try withStatement(
                        "UPDATE agent_jobs SET pending_trigger_at=NULL WHERE id=?") { statement in
                        bindText(job.id, at: 1, to: statement)
                        try stepDone(statement)
                    }
                    try schedule(job.id, at: now)
                } else if state == .completed, job.trigger == .interval, let interval = job.intervalSeconds {
                    try schedule(job.id, at: now.addingTimeInterval(interval))
                } else if let retryDelay {
                    let attempts = try scalarInt(
                        """
                        SELECT COUNT(*) FROM agent_runs
                        WHERE job_id=? AND started_at>COALESCE(
                          (SELECT MAX(finished_at) FROM agent_runs
                           WHERE job_id=? AND state='completed'), 0)
                        """, texts: [job.id, job.id])
                    if attempts < job.maxAttempts {
                        try schedule(job.id, at: now.addingTimeInterval(retryDelay))
                    } else {
                        try setJobState(job.id, state: .failed, at: now)
                    }
                } else {
                    try setJobState(job.id, state: state == .completed ? .completed : .failed, at: now)
                }
            }
        }
    }

    private func dueJobs(now: Date) throws -> [AgentJob] {
        try withStatement(
            """
            SELECT * FROM agent_jobs
            WHERE state='queued' AND next_run_at IS NOT NULL AND next_run_at<=?
            ORDER BY next_run_at ASC, updated_at ASC, created_at ASC
            """) { statement in
            sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
            var result: [AgentJob] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(decodeJob(statement)) }
            return result
        }
    }

    private func schedule(_ jobID: String, at date: Date) throws {
        try withStatement(
            "UPDATE agent_jobs SET state='queued', next_run_at=?, updated_at=? WHERE id=?") { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
            bindText(jobID, at: 3, to: statement)
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

    private func insert(_ run: AgentRun) throws {
        try withStatement(
            """
            INSERT INTO agent_runs (
              id,job_id,turn_id,runtime,state,worker_id,lease_expires_at,
              heartbeat_at,attempt,started_at,finished_at,cost_usd,error,result_message_id
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
            id: text(statement, 0), assistantSlug: text(statement, 1),
            conversationID: text(statement, 2),
            runtime: AgentRuntimeKind(rawValue: text(statement, 3)) ?? .codex,
            trigger: AgentJobTriggerKind(rawValue: text(statement, 4)) ?? .manual,
            modelID: optionalText(statement, 17),
            prompt: text(statement, 5),
            trustProfile: AgentTrustProfile(rawValue: text(statement, 6)) ?? .unattended,
            state: AgentJobState(rawValue: text(statement, 7)) ?? .failed,
            nextRunAt: optionalDate(statement, 8),
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
          model_id TEXT
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
          result_message_id TEXT
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
        try? exec("ALTER TABLE agent_jobs ADD COLUMN pending_trigger_at REAL")
        try? exec("ALTER TABLE agent_jobs ADD COLUMN model_id TEXT")
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
