package com.voiceflow.mobile.p4

import com.voiceflow.mobile.CloudCollection
import com.voiceflow.mobile.CloudFailure
import com.voiceflow.mobile.CloudPayload
import com.voiceflow.mobile.DictationEntry
import com.voiceflow.mobile.RecordEngine
import com.voiceflow.mobile.RecordStore
import com.voiceflow.mobile.Transcriber
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The record store is reduced: it carries `dictations` and `preferences` and
 * nothing else, the projection layer is gone, and the new
 * `dictation_cleanup_model` preference is seeded with the model the phone
 * hardcodes today and is read from the local mirror (08 §3.9).
 */
class RecordStoreTest {

    private class FakeEngine : RecordEngine {
        val notes = linkedMapOf<String, DictationEntry>()
        val prefs = mutableMapOf<String, String>()
        override fun put(entry: DictationEntry) { notes[entry.id] = entry }
        override fun all(): List<DictationEntry> = notes.values.toList()
        override fun preference(key: String): String? = prefs[key]
        override fun setPreference(key: String, value: String) { prefs[key] = value }
    }

    private fun entry(id: String, text: String, kind: String = "pasted") =
        DictationEntry(id, "12:00:00", "2026-09-19", text, kind, synced = false)

    // ── the reduction ──

    @Test
    fun `the store carries dictations and preferences and nothing else`() {
        assertEquals(
            setOf(CloudCollection.DICTATIONS, CloudCollection.PREFERENCES),
            RecordStore.COLLECTIONS,
        )
        assertFalse("threads left the phone's record store", CloudCollection.THREADS in RecordStore.COLLECTIONS)
        assertFalse("messages left the phone's record store", CloudCollection.MESSAGES in RecordStore.COLLECTIONS)
        val store = P4Paths.source("RecordStore.kt")
        assertFalse(
            "the reduced store must not read or write a thread or a message",
            store.contains("CloudCollection.THREADS") || store.contains("CloudCollection.MESSAGES"),
        )
        assertFalse(
            "agent_model belonged to the assistant being deleted; the reduced store does not touch it",
            store.contains("agent_model"),
        )
    }

    // ── the note is durable and is what the store returns ──

    @Test
    fun `a saved note is written to the engine before saveNote returns`() {
        val engine = FakeEngine()
        val store = RecordStore(engine)
        store.saveNote(entry("n1", "First note"))
        assertEquals(listOf("n1"), store.dictations().map { it.id })
    }

    // ── dictation_cleanup_model ──

    @Test
    fun `the cleanup model is seeded with the model the phone hardcodes today`() {
        val store = RecordStore(FakeEngine())
        assertEquals(Transcriber.CLEANUP_MODEL, store.cleanupModel())
    }

    @Test
    fun `the cleanup model preference is spelled dictation_cleanup_model and a stored value wins`() {
        assertEquals("dictation_cleanup_model", RecordStore.DICTATION_CLEANUP_MODEL)
        val engine = FakeEngine()
        engine.prefs[RecordStore.DICTATION_CLEANUP_MODEL] = "openrouter/other-model"
        assertEquals("openrouter/other-model", RecordStore(engine).cleanupModel())
    }

    @Test
    fun `cleanup is on by default and the stored switch decides`() {
        val engine = FakeEngine()
        assertTrue(RecordStore(engine).cleanupEnabled())
        engine.prefs["cleanup_enabled"] = "false"
        assertFalse(RecordStore(engine).cleanupEnabled())
    }

    @Test
    fun `the vocabulary is read from the local mirror with no network`() {
        val engine = FakeEngine()
        engine.prefs["vocabulary"] = JSONArray(listOf("Atika", "VoiceFlow")).toString()
        assertEquals(listOf("Atika", "VoiceFlow"), RecordStore(engine).vocabulary())
        assertEquals(emptyList<String>(), RecordStore(FakeEngine()).vocabulary())
    }

    // ── what the phone writes on the wire ──

    @Test
    fun `a phone dictation is written with captureKind dictate and the mode's destination`() {
        val edit = RecordStore.edit(entry("d1", "Some words", "kept"))
        assertEquals(CloudCollection.DICTATIONS, edit.collection)
        assertEquals("d1", edit.recordId)
        val payload = edit.payload as CloudPayload.Dictation
        assertEquals("Some words", payload.text)
        assertEquals("kept", payload.destination)
        assertEquals("dictate", payload.captureKind)
    }

    @Test
    fun `the edit the phone sends is valid on the wire and keeps the timestamps it sends today`() {
        val edit = RecordStore.edit(DictationEntry("d2", "12:34:56", "2026-09-19", "Some words", "pasted", synced = false))
        val payload = edit.payload as CloudPayload.Dictation
        assertEquals("2026-09-19T12:34:56", payload.legacyTimestamp)
        assertNotNull("the change carries the time the note was made", payload.modifiedAt)
        // The gateway's own validator, run on the JSON this edit would send.
        payload.validate(CloudCollection.DICTATIONS, "d2")
    }

    @Test
    fun `the closed preference set accepts dictation_cleanup_model and still refuses an unknown key`() {
        val accepted = CloudPayload.parse(
            CloudCollection.PREFERENCES, "dictation_cleanup_model",
            JSONObject().put("value", "openai/gpt-4o-mini"),
        ) as CloudPayload.Model
        assertEquals("openai/gpt-4o-mini", accepted.value)

        val refused = try {
            CloudPayload.parse(CloudCollection.PREFERENCES, "agent_temperature", JSONObject().put("value", "0.2"))
            null
        } catch (error: CloudFailure.InvalidRecord) {
            error
        }
        assertTrue("an unknown preference key is still refused", refused != null)
    }

    @Test
    fun `the journal decoder reads the new preference too, so a queued edit replays`() {
        val decoded = CloudPayload.local(
            CloudCollection.PREFERENCES, "dictation_cleanup_model",
            JSONObject().put("value", "openrouter/other-model"),
        ) as CloudPayload.Model
        assertEquals("openrouter/other-model", decoded.value)
    }

    @Test
    fun `the dictation record shape stays closed`() {
        val extraField = try {
            CloudPayload.parse(
                CloudCollection.DICTATIONS, "d3",
                JSONObject().put("text", "hello").put("destination", "kept").put("originDevice", "phone"),
            )
            null
        } catch (error: CloudFailure.InvalidRecord) {
            error
        }
        assertTrue("this design adds no field to the dictation record", extraField != null)

        val thirdDestination = try {
            CloudPayload.parse(
                CloudCollection.DICTATIONS, "d4",
                JSONObject().put("text", "hello").put("destination", "composer"),
            )
            null
        } catch (error: CloudFailure.InvalidRecord) {
            error
        }
        assertTrue("the wire has two destinations, pasted and kept", thirdDestination != null)
    }
}
