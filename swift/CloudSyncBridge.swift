import Cocoa
import CryptoKit

struct CloudAccountSelection: Codable {
    var origin: String = "https://api.atika.ai"
    var userID: String?
    var email: String = ""
    var deviceID: String?
    var transport: String = "local"
    var signedIn: Bool = false
    var exports: CloudExportSelection?
    var included: CloudExportSelection { exports ?? CloudExportSelection() }
    var partition: String? { userID.map { CloudSyncStore.partition(origin: origin, userID: $0) } }
}
private struct CloudRecoveryIntent: Codable { var partition: String; var edits: [CloudLocalEdit]; var initialImport: Bool? }

/// The only adapter from native persistence into cloud records. It stages
/// portable intent on disk before SQLite, then the caller writes its existing
/// JSON projection. A crash at any point is repaired by replaying that intent.
final class CloudSyncBridge {
    static let shared = CloudSyncBridge()
    private let lock = NSRecursiveLock()
    let store: CloudSyncStore?
    private(set) var selection: CloudAccountSelection
    private(set) var failure: String?
    private var projecting = false
    var onChange: (() -> Void)?
    private let root: URL
    private let selectionURL: URL
    private let recoveryURL: URL
    private var sequenceURL: URL { root.appendingPathComponent("cloud-sync-intent-sequence") }
    var reviewDirectory: URL { root.appendingPathComponent("cloud-sync-review", isDirectory: true) }
    private var intentSequence: UInt64 = 0
    private var lastPreferences: [String: CloudPayload] = [:]
    private var bootstrapping = false

    init(root: URL = VoiceFlowPaths.shared.configRoot) {
        self.root = root
        selectionURL = root.appendingPathComponent("cloud-sync-account.json")
        recoveryURL = root.appendingPathComponent("cloud-sync-intents", isDirectory: true)
        intentSequence = ((try? FileManager.default.contentsOfDirectory(at: recoveryURL, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { UInt64($0.deletingPathExtension().lastPathComponent) }.max() ?? 0
        if let saved = try? String(contentsOf: root.appendingPathComponent("cloud-sync-intent-sequence"), encoding: .utf8),
           let value = UInt64(saved.trimmingCharacters(in: .whitespacesAndNewlines)) { intentSequence = max(intentSequence, value) }
        if let bytes = try? Data(contentsOf: selectionURL), let saved = try? JSONDecoder().decode(CloudAccountSelection.self, from: bytes) {
            selection = saved
        } else { selection = CloudAccountSelection() }
        do { store = try CloudSyncStore(url: root.appendingPathComponent("cloud-sync.sqlite")) }
        catch { store = nil; failure = error.localizedDescription }
    }

    func currentSelection() -> CloudAccountSelection { lock.withLock { selection } }
    func saveSelection(_ value: CloudAccountSelection) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: selectionURL, options: .atomic)
            selection = value
            if let partition = value.partition { try store?.setExports(value.included, partition: partition) }
        }
        onChange?()
    }
    func installHooks() {
        lastPreferences = Dictionary(uniqueKeysWithValues: preferenceEdits().map { ($0.recordId, $0.payload!) })
        DictationsView.onPersist = { [weak self] in self?.captureDictations($0) }
        AssistantHistoryStore.shared.onPersist = { [weak self] in self?.captureConversations($0) }
        AssistantHistoryStore.shared.onDelete = { [weak self] id in
            self?.capture([CloudLocalEdit(collection: .threads, recordId: id, payload: nil)])
        }
        UserSettings.onPortableSave = { [weak self] in self?.capturePreferences() }
    }

    func captureDictations(_ entries: [HistoryEntry]) {
        let edits = entries.compactMap { entry -> CloudLocalEdit? in
            guard let id = entry.id, !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  [.pasted, .kept].contains(entry.effectiveDestination) else { return nil }
            var payload = CloudPayload(text: entry.text, destination: entry.effectiveDestination.rawValue)
            if let timestamp = entry.timestamp, CloudWire.date(timestamp) != nil { payload.createdAt = timestamp }
            else if let timestamp = entry.timestamp { payload.legacyTimestamp = timestamp }
            else if !entry.time.isEmpty { payload.legacyTimestamp = entry.time }
            switch entry.capability {
            case .dictate: payload.captureKind = "dictate"
            case .snapshot: payload.captureKind = "dictateSnapshot"
            case .continuous: payload.captureKind = "continuousCapture"
            case nil: break
            }
            return CloudLocalEdit(collection: .dictations, recordId: id, payload: payload)
        }
        capture(edits)
    }
    func captureConversations(_ conversations: [AssistantConversation]) {
        guard let partition = currentSelection().partition else { return }
        let existing = try? store?.state(partition)
        var edits: [CloudLocalEdit] = []
        for conversation in conversations where conversation.turnState != .running && !conversation.messages.isEmpty {
            edits.append(CloudLocalEdit(collection: .threads, recordId: conversation.id,
                payload: CloudPayload(createdAt: CloudWire.timestamp(conversation.createdAt), title: conversation.title,
                    completedAt: conversation.completedAt.map(CloudWire.timestamp), assistantName: conversation.assistantNameSnapshot)))
            var previous: String?
            for message in conversation.messages where !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let id = message.id.uuidString
                let known = existing?.records[CloudSyncStore.key(.messages, id)]?.payload
                let parent = known == nil ? previous : known?.parentMessageId
                edits.append(CloudLocalEdit(collection: .messages, recordId: id,
                    payload: CloudPayload(text: message.text, createdAt: CloudWire.timestamp(message.at),
                        threadId: conversation.id, role: message.role.rawValue, parentMessageId: parent)))
                previous = id
            }
        }
        capture(edits)
    }
    private func preferenceEdits() -> [CloudLocalEdit] {
        let settings = UserSettings.shared
        return [
            CloudLocalEdit(collection: .preferences, recordId: "vocabulary", payload: CloudPayload(value: .words(settings.customVocabulary))),
            CloudLocalEdit(collection: .preferences, recordId: "agent_model", payload: CloudPayload(value: .text(settings.agentModel))),
            CloudLocalEdit(collection: .preferences, recordId: "cleanup_enabled", payload: CloudPayload(value: .enabled(settings.llmCleanupEnabled))),
        ]
    }
    func capturePreferences(force: Bool = false) {
        let edits = preferenceEdits()
        let changed = lock.withLock { () -> [CloudLocalEdit] in
            let changed = edits.filter { force || lastPreferences[$0.recordId] != $0.payload }
            lastPreferences = Dictionary(uniqueKeysWithValues: edits.map { ($0.recordId, $0.payload!) })
            return changed
        }
        capture(changed)
    }
    private func capture(_ edits: [CloudLocalEdit]) {
        let changed = lock.withLock { () -> Bool in
            guard !projecting, let partition = selection.partition, !edits.isEmpty else { return false }
            do {
                // The journal is intentional durability, not an unbounded copy
                // of source files: only new portable differences are staged.
                let state = try? store?.state(partition)
                let changed = edits.filter { selection.included.includes($0.collection) && state?.records[CloudSyncStore.key($0.collection, $0.recordId)]?.payload != $0.payload }
                guard !changed.isEmpty else { return false }
                try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
                intentSequence += 1
                try String(intentSequence).write(to: sequenceURL, atomically: true, encoding: .utf8)
                let journal = recoveryURL.appendingPathComponent(String(format: "%020llu.json", intentSequence))
                try JSONEncoder().encode(CloudRecoveryIntent(partition: partition, edits: changed, initialImport: bootstrapping)).write(to: journal, options: .atomic)
                // Replay older interrupted saves first. Committing this edit
                // ahead of an older intent could later roll the local value
                // backward when that older journal is recovered.
                try replayIntents()
                failure = nil
            } catch { failure = error.localizedDescription }
            return true
        }
        // A return inside withLock only exits that closure. Notifying for an
        // empty/suppressed capture makes a downloaded projection start another
        // sync, which projects again forever without any local edit.
        if changed { onChange?() }
    }
    func replayIntents() throws {
        try lock.withLock {
            guard let store else { throw CloudSyncError.storage("unavailable") }
            guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
            for url in try FileManager.default.contentsOfDirectory(at: recoveryURL, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
                let intent = try JSONDecoder().decode(CloudRecoveryIntent.self, from: Data(contentsOf: url))
                var valid: [CloudLocalEdit] = []
                var review: [CloudLocalEdit] = []
                for edit in intent.edits {
                    do {
                        guard CloudWire.validID(edit.recordId) else { throw CloudSyncError.invalidRecord }
                        try edit.payload?.validate(for: edit.collection, id: edit.recordId)
                        valid.append(edit)
                    } catch CloudSyncError.invalidRecord { review.append(edit) }
                }
                try store.capture(valid, partition: intent.partition, initialImport: intent.initialImport == true)
                try resolveReviewCopies(valid, partition: intent.partition)
                if !review.isEmpty {
                    try FileManager.default.createDirectory(at: reviewDirectory, withIntermediateDirectories: true)
                    try JSONEncoder().encode(CloudRecoveryIntent(partition: intent.partition, edits: review, initialImport: intent.initialImport))
                        .write(to: reviewDirectory.appendingPathComponent(url.lastPathComponent), options: .atomic)
                }
                try FileManager.default.removeItem(at: url)
            }
            failure = nil
        }
    }
    func reviewCount() -> Int {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: reviewDirectory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.reduce(0) { total, url in
                total + ((try? JSONDecoder().decode(CloudRecoveryIntent.self, from: Data(contentsOf: url)))?.edits.count ?? 1)
            }
        }
    }
    private func resolveReviewCopies(_ edits: [CloudLocalEdit], partition: String) throws {
        let keys = Set(edits.map { CloudSyncStore.key($0.collection, $0.recordId) })
        guard !keys.isEmpty, FileManager.default.fileExists(atPath: reviewDirectory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: reviewDirectory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            var intent = try JSONDecoder().decode(CloudRecoveryIntent.self, from: Data(contentsOf: url))
            guard intent.partition == partition else { continue }
            let remaining = intent.edits.filter { !keys.contains(CloudSyncStore.key($0.collection, $0.recordId)) }
            guard remaining.count != intent.edits.count else { continue }
            let archive = reviewDirectory.appendingPathComponent("resolved", isDirectory: true)
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: archive.appendingPathComponent("\(UUID().uuidString).json"))
            if !remaining.isEmpty {
                intent.edits = remaining
                try JSONEncoder().encode(intent).write(to: url, options: .atomic)
            }
        }
    }
    func bootstrapIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let store, let partition = currentSelection().partition else { throw CloudSyncError.signInRequired }
        try replayIntents()
        if try store.state(partition).imported { return }
        // Decode original stores before making any import claim. Malformed
        // data is a visible failure, never an empty replacement.
        let names = ["dictations.json", "assistant-sessions.json", "settings.json"]
        let backup = root.appendingPathComponent("cloud-sync-backups/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        var dictations: [HistoryEntry] = []
        var conversations: [AssistantConversation] = []
        for name in names {
            let source = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let bytes = try Data(contentsOf: source)
            if name == "dictations.json" { dictations = try JSONDecoder().decode([HistoryEntry].self, from: bytes) }
            else if name == "assistant-sessions.json" {
                struct Envelope: Decodable { var version: Int; var sessions: [AssistantConversation] }
                let decoded = try JSONDecoder().decode(Envelope.self, from: bytes)
                guard decoded.version == 1 else { throw CloudSyncError.updateRequired }
                conversations = decoded.sessions
            } else {
                guard try JSONSerialization.jsonObject(with: bytes) is [String: Any] else { throw CloudSyncError.storage("settings decode") }
            }
            try bytes.write(to: backup.appendingPathComponent(name), options: .atomic)
            manifest[name] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        // IDs generated by the original store migration are already durable.
        // A backup with ID-less records is recovered using its explicit map.
        let identityURL = root.appendingPathComponent("cloud-sync-import-ids.json")
        var identities: [String: String] = [:]
        if FileManager.default.fileExists(atPath: identityURL.path) {
            identities = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: identityURL))
        }
        var assignedIdentities = false
        for index in dictations.indices where dictations[index].id?.isEmpty ?? true {
            let key = "\(manifest["dictations.json"] ?? "missing"):\(index)"
            let id = identities[key] ?? UUID().uuidString
            dictations[index].id = id; identities[key] = id
            assignedIdentities = true
        }
        try JSONEncoder().encode(identities).write(to: identityURL, options: .atomic)
        try JSONSerialization.data(withJSONObject: ["hashes": manifest, "dictations": dictations.count,
            "conversations": conversations.count, "generatedIDs": identities], options: [.prettyPrinted, .sortedKeys])
            .write(to: backup.appendingPathComponent("manifest.json"), options: .atomic)
        // A restored pre-ID file can reach import before the normal Inbox
        // migration. Persist these same identities before cloud capture, or
        // a later Inbox read would invent new IDs for the original entries.
        // The byte-for-byte source and mapping are already backed up above.
        if assignedIdentities {
            try JSONEncoder().encode(dictations).write(to: root.appendingPathComponent("dictations.json"), options: .atomic)
        }
        bootstrapping = true
        defer { bootstrapping = false }
        captureDictations(dictations)
        captureConversations(conversations)
        // A later account starts from its own cloud preferences. Merely
        // signing in must not copy the previous account's current settings.
        capturePreferences(force: try !store.hasImportedAccount())
        try replayIntents()
        if let failure { throw CloudSyncError.storage(failure) }
        try store.capture([], partition: partition, markImported: true)
    }

    /// Runs on the main thread. Cloud arrival never calls the LAN wake-word
    /// handler and therefore never starts a job, runtime, or tool action.
    func projectDictations() throws {
        try lock.withLock {
            guard selection.included.dictations, let partition = selection.partition, let store else { return }
            let state = try store.state(partition)
            var local = DictationsView.recentEntries(limit: Int.max)
            for row in state.records.values where row.collection == .dictations {
                guard try store.sourceBelongsTo(partition, collection: row.collection, id: row.recordId) else { continue }
                let index = local.firstIndex { $0.id == row.recordId }
                if let payload = row.payload, let text = payload.text {
                    let timestamp = payload.modifiedAt ?? payload.createdAt ?? payload.legacyTimestamp
                    if let index {
                        if local[index].text != text { local[index].seen = false }
                        local[index].text = text
                        local[index].destination = CaptureDestination(rawValue: payload.destination ?? "kept")
                        local[index].timestamp = timestamp
                    } else {
                        local.append(HistoryEntry(text: text, time: timestamp.map { String($0.suffix(8)) } ?? "",
                            timestamp: timestamp, id: row.recordId,
                            destination: CaptureDestination(rawValue: payload.destination ?? "kept"), seen: false))
                    }
                } else if row.remote?.deletedAt != nil, row.pending.isEmpty, row.conflicts.isEmpty, let index {
                    local.remove(at: index)
                }
            }
            local.sort { ($0.timestamp ?? $0.time) > ($1.timestamp ?? $1.time) }
            projecting = true
            defer { projecting = false }
            DictationsView.projectPortableEntries(local)
        }
    }

    func projectPreferences() throws {
        try lock.withLock {
            guard selection.included.preferences, let partition = selection.partition, let store else { return }
            let state = try store.state(partition)
            let settings = UserSettings.shared
            for row in state.records.values where row.collection == .preferences && row.pending.isEmpty && !row.blocked {
                switch (row.recordId, row.payload?.value) {
                case ("vocabulary", .words(let words)): settings.customVocabulary = words
                case ("agent_model", .text(let model)): settings.agentModel = model
                case ("cleanup_enabled", .enabled(let enabled)): settings.llmCleanupEnabled = enabled
                default: break
                }
            }
            projecting = true
            defer { projecting = false }
            settings.save()
            lastPreferences = Dictionary(uniqueKeysWithValues: preferenceEdits().map { ($0.recordId, $0.payload!) })
        }
    }
}
