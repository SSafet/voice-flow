package com.voiceflow.mobile

import org.json.JSONArray
import org.json.JSONObject

data class CloudLocalRecord(val collection: CloudCollection, val recordId: String,
                            var payload: CloudPayload? = null, var remote: CloudRecord? = null,
                            val pending: MutableList<CloudOperation> = mutableListOf(),
                            val conflicts: MutableList<CloudConflict> = mutableListOf(),
                            val retainedProposals: MutableList<CloudOperation> = mutableListOf(), var blocked: Boolean = false,
                            var lastLivePayload: CloudPayload? = null) {
    fun json(): JSONObject = JSONObject().put("collection", collection.wire).put("recordId", recordId)
        .put("payload", payload?.json() ?: JSONObject.NULL).put("remote", remote?.json() ?: JSONObject.NULL)
        .put("pending", JSONArray(pending.map { it.json() })).put("conflicts", JSONArray(conflicts.map { it.json() }))
        .put("retainedProposals", JSONArray(retainedProposals.map { it.json() })).put("blocked", blocked).put("lastLivePayload", lastLivePayload?.json() ?: JSONObject.NULL)
    companion object { fun parse(o: JSONObject): CloudLocalRecord {
        val collection = CloudCollection.parse(o.getString("collection")); val id = CloudWire.id(o.getString("recordId"))
        fun <T> list(name: String, parse: (JSONObject) -> T): MutableList<T> { val values = o.optJSONArray(name) ?: JSONArray(); return MutableList(values.length()) { parse(values.getJSONObject(it)) } }
        return CloudLocalRecord(collection, id, o.optJSONObject("payload")?.let { CloudPayload.parse(collection, id, it) },
            o.optJSONObject("remote")?.let(CloudRecord::parse), list("pending", CloudOperation::parse), list("conflicts", CloudConflict::parse),
            list("retainedProposals", CloudOperation::parse), o.optBoolean("blocked"), o.optJSONObject("lastLivePayload")?.let { CloudPayload.parse(collection, id, it) })
    } }
}
data class CloudReviewCopy(val collection: CloudCollection, val recordId: String, val portableJSON: String,
                           val reviewId: String = java.util.UUID.randomUUID().toString(), var corrected: Boolean = false) {
    fun json() = JSONObject().put("collection", collection.wire).put("recordId", recordId).put("portableJSON", portableJSON).put("reviewId", reviewId).put("corrected", corrected)
    companion object { fun parse(o: JSONObject) = CloudReviewCopy(CloudCollection.parse(o.getString("collection")), o.getString("recordId"), o.getString("portableJSON"), o.getString("reviewId"), o.optBoolean("corrected")) }
}
data class CloudAccountState(val records: MutableMap<String, CloudLocalRecord> = linkedMapOf(), var cursor: String? = null,
                             var epoch: String? = null, var appliedSequence: String = "0", var imported: Boolean = false,
                             var requiresBaselineReview: Boolean = false, var lastSuccess: String? = null,
                             val reviewCopies: MutableList<CloudReviewCopy> = mutableListOf()) {
    fun detached() = copy(records = records.mapValues { (_, row) -> row.copy(pending = row.pending.toMutableList(), conflicts = row.conflicts.toMutableList(), retainedProposals = row.retainedProposals.toMutableList()) }.toMutableMap(),
        reviewCopies = reviewCopies.map { it.copy() }.toMutableList())
    val pendingCount get() = records.values.sumOf { it.pending.size }
    val conflicts get() = records.values.flatMap { it.conflicts }
    fun json(): JSONObject = JSONObject().put("records", JSONObject().apply { records.forEach { (key, value) -> put(key, value.json()) } })
        .put("cursor", cursor ?: JSONObject.NULL).put("epoch", epoch ?: JSONObject.NULL).put("appliedSequence", appliedSequence)
        .put("imported", imported).put("requiresBaselineReview", requiresBaselineReview).put("lastSuccess", lastSuccess ?: JSONObject.NULL)
        .put("reviewCopies", JSONArray(reviewCopies.map { it.json() }))
    companion object { fun parse(o: JSONObject): CloudAccountState {
        val rows = o.getJSONObject("records")
        return CloudAccountState(rows.keys().asSequence().associateWith { CloudLocalRecord.parse(rows.getJSONObject(it)) }.toMutableMap(),
            CloudWire.optional(o, "cursor"), CloudWire.optional(o, "epoch"), o.getString("appliedSequence"), o.getBoolean("imported"),
            o.getBoolean("requiresBaselineReview"), CloudWire.optional(o, "lastSuccess"),
            (o.optJSONArray("reviewCopies") ?: JSONArray()).let { values -> MutableList(values.length()) { CloudReviewCopy.parse(values.getJSONObject(it)) } })
    } }
}

/** Implementations commit all reads/writes/ownership claims atomically. State
 * returned by a transaction must not alias an already committed instance. */
interface CloudTransaction {
    fun read(partition: String): CloudAccountState
    fun write(partition: String, state: CloudAccountState)
    fun sourceOwner(key: String): String?
    fun claim(key: String, partition: String)
}
interface CloudPersistence { fun <T> transaction(body: (CloudTransaction) -> T): T }
enum class CloudResolution { THIS_DEVICE, CLOUD, PROPOSAL }

class CloudEngine(private val persistence: CloudPersistence) {
    companion object {
        fun partition(origin: String, userId: String) = "$origin|${CloudWire.id(userId)}"
        fun key(collection: CloudCollection, id: String) = "${collection.wire}:$id"
    }
    fun state(partition: String) = persistence.transaction { it.read(partition) }
    fun sourceOwner(collection: CloudCollection, id: String) = persistence.transaction { it.sourceOwner(key(collection, id)) }

    fun capture(edits: List<CloudEdit>, partition: String, markImported: Boolean = false) {
        val valid = edits.map { runCatching { CloudWire.id(it.recordId); it.payload?.validate(it.collection, it.recordId) }.isSuccess }
        persistence.transaction { tx ->
            val states = mutableMapOf<String, CloudAccountState>()
            edits.forEachIndexed { index, edit ->
                val key = key(edit.collection, edit.recordId)
                // Stable source ownership prevents a later sign-in from
                // republishing an earlier account's local records.
                val owner = if (edit.collection == CloudCollection.PREFERENCES) partition else tx.sourceOwner(key) ?: partition
                val state = states.getOrPut(owner) { tx.read(owner) }
                if (!valid[index]) {
                    val portable = edit.payload?.json()?.toString() ?: "null"
                    if (state.reviewCopies.none { !it.corrected && it.collection == edit.collection && it.recordId == edit.recordId && it.portableJSON == portable }) {
                        state.reviewCopies.filter { !it.corrected && it.collection == edit.collection && it.recordId == edit.recordId }.forEach { it.corrected = true }
                        state.reviewCopies.add(CloudReviewCopy(edit.collection, edit.recordId, portable))
                    }
                    tx.claim(key, owner)
                    return@forEachIndexed
                }
                state.reviewCopies.filter { !it.corrected && it.collection == edit.collection && it.recordId == edit.recordId }.forEach { it.corrected = true }
                val row = state.records[key] ?: CloudLocalRecord(edit.collection, edit.recordId)
                if (row.payload != edit.payload || (key !in state.records && edit.payload != null)) {
                    val base = row.pending.lastOrNull()?.let { CloudWire.version(it.baseVersion) + 1 }
                        ?: if (markImported) 0 else row.remote?.let { CloudWire.version(it.version) } ?: 0
                    row.pending.add(CloudOperation(edit.collection, edit.recordId, base.toString(),
                        if (edit.payload == null) "delete" else if (edit.restore) "restore" else "put", edit.payload))
                    row.payload = edit.payload
                    if (edit.payload != null) row.lastLivePayload = edit.payload
                    state.records[key] = row
                }
                tx.claim(key, owner)
            }
            if (markImported) states.getOrPut(partition) { tx.read(partition) }.imported = true
            states.forEach { (owner, state) -> tx.write(owner, state) }
        }
    }

    fun nextOperations(partition: String, limit: Int = 50, included: Set<CloudCollection> = CloudCollection.entries.toSet()): List<CloudOperation> {
        val state = state(partition)
        if (state.requiresBaselineReview) throw CloudFailure.Baseline()
        val result = mutableListOf<CloudOperation>(); var bytes = 0
        for (key in state.records.keys.sorted()) {
            val row = state.records.getValue(key)
            if (row.collection !in included) continue
            val operation = row.pending.firstOrNull() ?: continue
            if (row.blocked) continue
            val size = operation.json().toString().toByteArray(Charsets.UTF_8).size
            if (result.isNotEmpty() && (bytes + size > 900_000 || result.size >= limit.coerceIn(1, 100))) break
            result.add(operation); bytes += size
        }
        return result
    }

    fun acknowledge(receipts: List<CloudReceipt>, sent: List<CloudOperation>, partition: String) {
        if (sent.map { it.operationId }.toSet().size != sent.size || receipts.size != sent.size || receipts.map { it.operationId }.toSet().size != sent.size) throw CloudFailure.InvalidResponse()
        val byId = sent.associateBy { it.operationId }
        persistence.transaction { tx ->
            val state = tx.read(partition)
            receipts.forEach { receipt ->
                val operation = byId[receipt.operationId] ?: throw CloudFailure.InvalidResponse()
                val row = state.records[key(operation.collection, operation.recordId)] ?: throw CloudFailure.InvalidResponse()
                CloudWire.version(receipt.seq)
                if (receipt.status == "applied") {
                    val remote = receipt.record ?: throw CloudFailure.InvalidResponse()
                    remote.validate()
                    if (remote.collection != operation.collection || remote.recordId != operation.recordId || remote.seq != receipt.seq ||
                        CloudWire.version(remote.version) != CloudWire.version(operation.baseVersion) + 1 ||
                        remote.payload != operation.payload || ((remote.deletedAt != null) != (operation.op == "delete"))) throw CloudFailure.InvalidResponse()
                    val pending = row.pending.firstOrNull { it.operationId == operation.operationId }
                    if (pending != null && pending != operation) throw CloudFailure.InvalidResponse()
                    if (pending != null) {
                        row.pending.removeAll { it.operationId == operation.operationId }
                        operation.resolvesConflictId?.let { resolved -> row.conflicts.removeAll { it.conflictId == resolved } }
                        row.blocked = row.conflicts.isNotEmpty()
                        accept(remote, row)
                    }
                } else if (receipt.status == "conflict") {
                    val conflict = receipt.conflict ?: throw CloudFailure.InvalidResponse()
                    if (conflict.proposed != operation) throw CloudFailure.InvalidResponse()
                    val pending = row.pending.firstOrNull { it.operationId == operation.operationId }
                    if (pending != null && pending != operation) throw CloudFailure.InvalidResponse()
                    if (pending != null) { row.pending.removeAll { it.operationId == operation.operationId }; add(conflict, row) }
                } else throw CloudFailure.InvalidResponse()
            }
            tx.write(partition, state)
        }
    }

    fun apply(page: CloudPage, partition: String) {
        persistence.transaction { tx ->
            val state = tx.read(partition)
            if (state.epoch != null && state.epoch != page.epoch) throw CloudFailure.Baseline()
            var sequence = CloudWire.version(state.appliedSequence)
            val upper = CloudWire.version(page.highWatermark)
            if (page.epoch.isBlank() || page.nextCursor.isBlank()) throw CloudFailure.InvalidResponse()
            page.changes.forEach { change ->
                val next = CloudWire.version(change.seq)
                if (next <= sequence) return@forEach
                if (next != sequence + 1 || next > upper) throw CloudFailure.InvalidResponse()
                if (change.kind == "record") {
                    val remote = change.record ?: throw CloudFailure.InvalidResponse(); remote.validate()
                    if (remote.seq != change.seq) throw CloudFailure.InvalidResponse()
                    val key = key(remote.collection, remote.recordId)
                    val row = state.records.getOrPut(key) { CloudLocalRecord(remote.collection, remote.recordId) }
                    change.resolvedConflictId?.let { resolved -> row.conflicts.removeAll { it.conflictId == resolved } }
                    row.blocked = row.conflicts.isNotEmpty()
                    accept(remote, row); tx.claim(key, partition)
                } else if (change.kind == "conflict") {
                    val conflict = change.conflict ?: throw CloudFailure.InvalidResponse()
                    val key = key(conflict.collection, conflict.recordId)
                    val row = state.records.getOrPut(key) { CloudLocalRecord(conflict.collection, conflict.recordId) }
                    add(conflict, row); tx.claim(key, partition)
                } else throw CloudFailure.UpdateRequired()
                sequence = next
            }
            if ((page.hasMore && sequence >= upper) || (!page.hasMore && sequence != upper)) throw CloudFailure.InvalidResponse()
            state.cursor = page.nextCursor; state.epoch = page.epoch; state.appliedSequence = sequence.toString(); state.lastSuccess = CloudWire.timestamp()
            tx.write(partition, state)
        }
    }

    fun requireBaselineReview(partition: String) = persistence.transaction { tx -> val state = tx.read(partition); state.requiresBaselineReview = true; tx.write(partition, state) }
    fun resetBaseline(partition: String) = persistence.transaction { tx ->
        val state = tx.read(partition); state.cursor = null; state.epoch = null; state.appliedSequence = "0"; state.requiresBaselineReview = false
        state.records.values.forEach { it.remote = null }; tx.write(partition, state)
    }
    fun resolve(conflict: CloudConflict, latest: CloudRecord, choice: CloudResolution, partition: String) {
        latest.validate()
        if (latest.collection != conflict.collection || latest.recordId != conflict.recordId) throw CloudFailure.InvalidResponse()
        persistence.transaction { tx ->
            val state = tx.read(partition)
            val row = state.records[key(conflict.collection, conflict.recordId)] ?: throw CloudFailure.InvalidResponse()
            if (row.conflicts.none { it.conflictId == conflict.conflictId }) throw CloudFailure.InvalidResponse()
            val chosen = when (choice) { CloudResolution.THIS_DEVICE -> row.payload; CloudResolution.CLOUD -> latest.payload; CloudResolution.PROPOSAL -> conflict.proposed.payload }
            row.retainedProposals.addAll(row.pending); row.pending.clear()
            row.pending.add(CloudOperation(conflict.collection, conflict.recordId, latest.version,
                if (chosen == null) "delete" else if (latest.deletedAt != null) "restore" else "put", chosen, resolvesConflictId = conflict.conflictId))
            row.payload = chosen; row.remote = latest; row.blocked = false
            if (chosen != null) row.lastLivePayload = chosen
            tx.write(partition, state)
        }
    }
    private fun accept(remote: CloudRecord, row: CloudLocalRecord) {
        if (row.remote != null && CloudWire.version(row.remote!!.version) > CloudWire.version(remote.version)) return
        row.remote = remote
        if (remote.payload != null) row.lastLivePayload = remote.payload
        if (row.pending.isEmpty() && !row.blocked) row.payload = remote.payload
    }
    private fun add(conflict: CloudConflict, row: CloudLocalRecord) {
        if (row.conflicts.none { it.conflictId == conflict.conflictId }) row.conflicts.add(conflict)
        row.blocked = true
    }
}
