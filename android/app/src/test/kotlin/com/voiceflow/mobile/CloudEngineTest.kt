package com.voiceflow.mobile

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MemoryCloudPersistence : CloudPersistence {
    val values = mutableMapOf<String, String>()
    val owners = mutableMapOf<String, String>()
    @Synchronized override fun <T> transaction(body: (CloudTransaction) -> T): T {
        val next = values.toMutableMap(); val claims = owners.toMutableMap()
        val result = body(object : CloudTransaction {
            override fun read(partition: String) = next[partition]?.let { CloudAccountState.parse(JSONObject(it)) } ?: CloudAccountState()
            override fun write(partition: String, state: CloudAccountState) { next[partition] = state.json().toString() }
            override fun sourceOwner(key: String) = claims[key]
            override fun claim(key: String, partition: String) { claims.putIfAbsent(key, partition) }
        })
        values.clear(); values.putAll(next); owners.clear(); owners.putAll(claims); return result
    }
}
class CloudEngineTest {
    private val a = "https://api.atika.ai|owner-a"
    private val b = "https://api.atika.ai|owner-b"
    private fun edit(id: String, text: String) = CloudEdit(CloudCollection.DICTATIONS, id, CloudPayload.Dictation(text, "pasted"))
    private fun receipt(op: CloudOperation, seq: String = "1") = CloudReceipt(op.operationId, "applied", seq,
        CloudRecord(op.collection, op.recordId, (CloudWire.version(op.baseVersion) + 1).toString(), op.payload, if (op.op == "delete") "2026-09-12T12:00:00Z" else null, seq), null)
    private inline fun rejects(body: () -> Unit) { try { body(); fail("Expected rejection") } catch (_: CloudFailure) { } }

    @Test fun largeImportAndImmutableQueueSurviveRestartAndConcurrentEdit() {
        val persistence = MemoryCloudPersistence(); val engine = CloudEngine(persistence)
        val records = (0 until 1200).map { edit("id-$it", "Original $it") }
        engine.capture(records, a, markImported = true)
        val sent = engine.nextOperations(a); val original = sent.map { it.json().toString() }
        val changed = sent.first(); engine.capture(listOf(edit(changed.recordId, "Edited while uploading")), a)
        assertEquals(original, sent.map { it.json().toString() })
        engine.acknowledge(sent.mapIndexed { i, op -> receipt(op, (i + 1).toString()) }, sent, a)
        val restarted = CloudEngine(persistence)
        assertEquals(1200, restarted.state(a).records.size)
        val row = restarted.state(a).records["dictations:${changed.recordId}"]!!
        assertEquals("Edited while uploading", (row.payload as CloudPayload.Dictation).text)
        assertEquals(1, row.pending.size); assertEquals("1", row.pending.first().baseVersion)
        assertNotEquals(changed.operationId, row.pending.first().operationId)
        restarted.acknowledge(sent.mapIndexed { i, op -> receipt(op, (i + 1).toString()) }, sent, a)
        assertEquals(1, restarted.state(a).records["dictations:${changed.recordId}"]!!.pending.size)
    }
    @Test fun malformedAcknowledgmentCannotClearAnyQueuedOperation() {
        val engine = CloudEngine(MemoryCloudPersistence()); engine.capture(listOf(edit("one", "One"), edit("two", "Two")), a)
        val sent = engine.nextOperations(a); val good = receipt(sent[0]); val bad = receipt(sent[1], "2").let { it.copy(record = it.record!!.copy(payload = CloudPayload.Dictation("Other payload", "pasted"))) }
        rejects { engine.acknowledge(listOf(good, bad), sent, a) }
        assertEquals(2, engine.state(a).pendingCount)
        rejects { engine.acknowledge(listOf(good, good), sent, a) }
        assertEquals(2, engine.state(a).pendingCount)
    }
    @Test fun accountSwitchPreservesOriginalSourceOwnershipAndFiltersExports() {
        val engine = CloudEngine(MemoryCloudPersistence())
        engine.capture(listOf(edit("old-account-record", "Owner A")), a)
        engine.capture(listOf(edit("old-account-record", "A edited after sign-out"), edit("new-record", "Owner B")), b)
        assertEquals(setOf("dictations:new-record"), engine.state(b).records.keys)
        assertEquals(2, engine.state(a).pendingCount)
        engine.capture(listOf(CloudEdit(CloudCollection.PREFERENCES, "agent_model", CloudPayload.Model("new/model"))), b)
        assertTrue(engine.nextOperations(b, included = setOf(CloudCollection.MESSAGES)).isEmpty())
        assertEquals(2, engine.state(b).pendingCount)
        assertEquals("preferences", engine.nextOperations(b, included = setOf(CloudCollection.PREFERENCES)).single().collection.wire)
    }
    @Test fun conflictBlocksOnlyItsRecordAndResolutionRetainsOtherProposals() {
        val engine = CloudEngine(MemoryCloudPersistence()); engine.capture(listOf(edit("one", "First"), edit("two", "Independent")), a)
        val sent = engine.nextOperations(a); val op = sent.first { it.recordId == "one" }
        engine.capture(listOf(edit("one", "Latest local")), a)
        val conflict = CloudConflict("conflict-1", op.collection, op.recordId, "0", "1", op, "version_changed", "2026-09-12T12:00:00Z")
        engine.acknowledge(listOf(CloudReceipt(op.operationId, "conflict", "2", null, conflict)), listOf(op), a)
        assertEquals("two", engine.nextOperations(a).single().recordId)
        val remote = CloudRecord(op.collection, op.recordId, "1", CloudPayload.Dictation("Other device", "pasted"), null, "1")
        engine.resolve(conflict, remote, CloudResolution.THIS_DEVICE, a)
        val row = engine.state(a).records["dictations:one"]!!
        assertEquals(1, row.retainedProposals.size); assertEquals("Latest local", (row.pending.single().payload as CloudPayload.Dictation).text)
        assertEquals("conflict-1", row.pending.single().resolvesConflictId)
        assertEquals(2, engine.nextOperations(a).size)
    }
    @Test fun initialImportCollisionUsesZeroBaseRatherThanOverwritingPulledCloud() {
        val engine = CloudEngine(MemoryCloudPersistence())
        val remote = CloudRecord(CloudCollection.DICTATIONS, "collision", "8", CloudPayload.Dictation("Cloud copy", "pasted"), null, "1")
        engine.apply(CloudPage(listOf(CloudChange("1", "record", remote, null, null)), "cursor", false, "1", "epoch"), a)
        engine.capture(listOf(edit("collision", "Local legacy")), a, markImported = true)
        assertEquals("0", engine.nextOperations(a).single().baseVersion)
    }
    @Test fun cursorTransactionRejectsGapsAndEpochChangesAndRetainsDeletedText() {
        val persistence = MemoryCloudPersistence(); val engine = CloudEngine(persistence)
        val live = CloudRecord(CloudCollection.DICTATIONS, "record", "1", CloudPayload.Dictation("Keep for restore", "pasted"), null, "1")
        val deleted = live.copy(version = "2", payload = null, deletedAt = "2026-09-12T12:00:00Z", seq = "2")
        val page = CloudPage(listOf(CloudChange("1", "record", live, null, null), CloudChange("2", "record", deleted, null, null)), "cursor-2", false, "2", "epoch")
        engine.apply(page, a); engine.apply(page, a)
        val row = engine.state(a).records["dictations:record"]!!
        assertNull(row.payload); assertEquals(live.payload, row.lastLivePayload)
        rejects { engine.apply(page.copy(epoch = "other"), a) }
        rejects { engine.apply(CloudPage(listOf(CloudChange("4", "record", live.copy(seq = "4", version = "3"), null, null)), "bad", false, "4", "epoch"), a) }
        assertEquals("cursor-2", CloudEngine(persistence).state(a).cursor)
        engine.capture(listOf(CloudEdit(row.collection, row.recordId, row.lastLivePayload, restore = true)), a)
        assertEquals("restore", engine.nextOperations(a).single().op)
    }
    @Test fun oversizedLocalCopiesAreRetainedWithoutBlockingValidDelivery() {
        val persistence = MemoryCloudPersistence(); val engine = CloudEngine(persistence)
        val oversized = edit("large", "x".repeat(70_000))
        engine.capture(listOf(oversized, edit("valid", "Valid new capture")), a, markImported = true)
        assertEquals(listOf("valid"), engine.nextOperations(a).map { it.recordId })
        val reopened = CloudEngine(persistence).state(a)
        assertEquals(70_000, JSONObject(reopened.reviewCopies.single().portableJSON).getString("text").length)
        assertFalse(reopened.reviewCopies.single().corrected)
        engine.capture(listOf(oversized), a); assertEquals(1, engine.state(a).reviewCopies.size)
        engine.capture(listOf(edit("large", "Corrected record")), a)
        assertTrue(engine.state(a).reviewCopies.single().corrected)
        assertEquals(2, engine.nextOperations(a).size)
    }

    @Test fun cloudPayloadRejectsSecretContainingLegacyShapesAndInsecureOrigins() {
        rejects { CloudPayload.parse(CloudCollection.DICTATIONS, "record", JSONObject().put("text", "Safe text").put("destination", "pasted").put("keys", JSONObject().put("openai_api_key", "CANARY"))) }
        rejects { CloudPayload.parse(CloudCollection.PREFERENCES, "sync_token", JSONObject().put("value", "CANARY")) }
        rejects { CloudWire.origin("http://api.atika.ai") }
        rejects { CloudWire.origin("https://user:password@api.atika.ai") }
        assertEquals("https://api.atika.ai", CloudWire.origin("https://api.atika.ai/"))
    }
}
