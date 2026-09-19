package com.voiceflow.mobile.p4

import com.voiceflow.mobile.AudioQueue
import com.voiceflow.mobile.Delivery
import com.voiceflow.mobile.DeliverySink
import com.voiceflow.mobile.DictationEntry
import com.voiceflow.mobile.DictationMode
import com.voiceflow.mobile.DictationPipeline
import com.voiceflow.mobile.FieldProbe
import com.voiceflow.mobile.FieldState
import com.voiceflow.mobile.InsertionPolicy
import com.voiceflow.mobile.QueueItem
import com.voiceflow.mobile.RecordEngine
import com.voiceflow.mobile.RecordStore
import com.voiceflow.mobile.Refusal
import com.voiceflow.mobile.Transcription
import com.voiceflow.mobile.TranscriptionUnavailable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * One dictation pipeline, two callers (08 §3.7). These tests pin the ordering
 * and the destinations: a finished dictation becomes a durable note *before*
 * its text is handed anywhere; only the take the person just finished may be
 * typed into a field; a recording recovered from the queue never is; and the
 * queue drains in order.
 */
class DictationPipelineTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val steps = P4Paths.Steps()

    private class FakeEngine(private val steps: P4Paths.Steps) : RecordEngine {
        val notes = linkedMapOf<String, DictationEntry>()
        val prefs = mutableMapOf<String, String>()
        override fun put(entry: DictationEntry) {
            steps.note("note:${entry.id}")
            notes[entry.id] = entry
        }
        override fun all(): List<DictationEntry> = notes.values.toList()
        override fun preference(key: String): String? = prefs[key]
        override fun setPreference(key: String, value: String) { prefs[key] = value }
    }

    private class FakeTranscription : Transcription {
        val transcripts = mutableMapOf<String, String>()
        var unavailable: TranscriptionUnavailable? = null
        var cleanupCalls = 0
        var lastModel: String? = null
        override fun transcribe(file: File, vocabulary: List<String>): String {
            unavailable?.let { throw it }
            return transcripts[file.name] ?: ""
        }
        override fun cleanup(raw: String, vocabulary: List<String>, model: String): String {
            cleanupCalls += 1
            lastModel = model
            return "clean:$raw"
        }
    }

    private class FakeSink(private val steps: P4Paths.Steps) : DeliverySink {
        val deliveries = mutableListOf<Delivery>()
        override fun accept(text: String, delivery: Delivery) {
            deliveries.add(delivery)
            steps.note("deliver:$delivery")
        }
    }

    private fun item(root: File, id: String, mode: DictationMode, bytes: Int = 128): QueueItem {
        val dir = File(root, "queue").apply { mkdirs() }
        val file = File(dir, "$id.m4a").apply { writeBytes(ByteArray(bytes) { 7 }) }
        return QueueItem(id, file.absolutePath, mode.wire, 1_700_000_000_000L)
    }

    private class Fixture(root: File) {
        val steps = P4Paths.Steps()
        val engine = FakeEngine(steps)
        val notes = RecordStore(engine)
        val transcription = FakeTranscription()
        val sink = FakeSink(steps)
        var field = FieldState.EDITABLE
        val queue = AudioQueue(root)
        val pipeline = DictationPipeline(queue, notes, transcription, sink, FieldProbe { field })
    }

    private fun fixture(): Fixture = Fixture(tmp.root)

    // ── the note comes first, always ──

    @Test
    fun `the note is durable before the text is handed to the field`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.INSERT))
        f.transcription.transcripts["a.m4a"] = "Type these words"
        f.field = FieldState.EDITABLE

        val report = f.pipeline.drain(freshId = "a")

        val noteIndex = f.steps.all().indexOf("note:dictation-a")
        val deliverIndex = f.steps.all().indexOf("deliver:INSERTED")
        assertTrue("both events happened: ${f.steps.all()}", noteIndex >= 0 && deliverIndex >= 0)
        assertTrue("the note must be written before delivery: ${f.steps.all()}", noteIndex < deliverIndex)
        assertEquals(1, f.engine.notes.size)
        assertEquals(1, report.completed.size)
        assertEquals(0, f.queue.count())
    }

    // ── the three destinations ──

    @Test
    fun `an insert take goes into a focused editable field`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.INSERT))
        f.transcription.transcripts["a.m4a"] = "At the cursor"
        f.field = FieldState.EDITABLE

        val report = f.pipeline.drain(freshId = "a")

        assertEquals(Delivery.INSERTED, report.completed.single().delivery)
        assertEquals("pasted", report.completed.single().note.kind)
    }

    @Test
    fun `a keep take goes to the clipboard only`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.KEEP))
        f.transcription.transcripts["a.m4a"] = "Keep this idea"
        f.field = FieldState.EDITABLE

        val report = f.pipeline.drain(freshId = "a")

        assertEquals(Delivery.CLIPBOARD, report.completed.single().delivery)
        assertEquals("kept", report.completed.single().note.kind)
    }

    @Test
    fun `a composer take is returned to the interface and nowhere else`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.COMPOSER))
        f.transcription.transcripts["a.m4a"] = "Into the composer"
        f.field = FieldState.EDITABLE

        val report = f.pipeline.drain(freshId = "a")

        assertEquals(Delivery.COMPOSER, report.completed.single().delivery)
    }

    @Test
    fun `a password field is not typed into, it falls back to the clipboard`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.INSERT))
        f.transcription.transcripts["a.m4a"] = "Not a password"
        f.field = FieldState.PASSWORD

        val report = f.pipeline.drain(freshId = "a")

        assertEquals(Delivery.CLIPBOARD, report.completed.single().delivery)
    }

    @Test
    fun `the insertion policy is the one place the delivery is decided`() {
        assertEquals(Delivery.INSERTED, InsertionPolicy.decide(DictationMode.INSERT, fresh = true, field = FieldState.EDITABLE))
        assertEquals(Delivery.CLIPBOARD, InsertionPolicy.decide(DictationMode.INSERT, fresh = true, field = FieldState.NONE))
        assertEquals(Delivery.CLIPBOARD, InsertionPolicy.decide(DictationMode.INSERT, fresh = true, field = FieldState.PASSWORD))
        assertEquals(Delivery.CLIPBOARD, InsertionPolicy.decide(DictationMode.KEEP, fresh = true, field = FieldState.EDITABLE))
        assertEquals(Delivery.COMPOSER, InsertionPolicy.decide(DictationMode.COMPOSER, fresh = true, field = FieldState.EDITABLE))
        assertEquals(Delivery.CLIPBOARD, InsertionPolicy.decide(DictationMode.INSERT, fresh = false, field = FieldState.EDITABLE))
        assertEquals(Delivery.CLIPBOARD, InsertionPolicy.decide(DictationMode.KEEP, fresh = false, field = FieldState.EDITABLE))
        assertEquals(Delivery.CLIPBOARD, InsertionPolicy.decide(DictationMode.COMPOSER, fresh = false, field = FieldState.EDITABLE))
    }

    // ── a recovered take is never inserted, and the queue drains in order ──

    @Test
    fun `a recording recovered long after the fact is never inserted`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "old", DictationMode.INSERT))
        f.transcription.transcripts["old.m4a"] = "The field is gone"
        f.field = FieldState.EDITABLE

        val report = f.pipeline.drain(freshId = null)

        assertEquals(Delivery.CLIPBOARD, report.completed.single().delivery)
    }

    @Test
    fun `three offline dictations are transcribed in order and each lands on the clipboard`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.INSERT))
        f.queue.enqueue(item(tmp.root, "b", DictationMode.KEEP))
        f.queue.enqueue(item(tmp.root, "c", DictationMode.INSERT))
        f.transcription.transcripts["a.m4a"] = "first"
        f.transcription.transcripts["b.m4a"] = "second"
        f.transcription.transcripts["c.m4a"] = "third"

        val report = f.pipeline.drain(freshId = null)

        assertEquals(listOf("a", "b", "c"), report.completed.map { it.queueId })
        assertEquals(listOf(Delivery.CLIPBOARD, Delivery.CLIPBOARD, Delivery.CLIPBOARD), report.completed.map { it.delivery })
        assertEquals(listOf("dictation-a", "dictation-b", "dictation-c"), f.engine.notes.keys.toList())
    }

    // ── cleanup ──

    @Test
    fun `cleanup runs with the stored model when it is switched on`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.INSERT))
        f.transcription.transcripts["a.m4a"] = "um so this is a sentence"
        f.engine.prefs[RecordStore.DICTATION_CLEANUP_MODEL] = "openrouter/cleaner-x"

        val report = f.pipeline.drain(freshId = "a")

        assertEquals(1, f.transcription.cleanupCalls)
        assertEquals("openrouter/cleaner-x", f.transcription.lastModel)
        assertEquals("clean:um so this is a sentence", report.completed.single().note.text)
    }

    @Test
    fun `cleanup switched off leaves the raw transcript`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.INSERT))
        f.transcription.transcripts["a.m4a"] = "um so this is a sentence"
        f.engine.prefs["cleanup_enabled"] = "false"

        val report = f.pipeline.drain(freshId = "a")

        assertEquals(0, f.transcription.cleanupCalls)
        assertEquals("um so this is a sentence", report.completed.single().note.text)
    }

    // ── refusals and failures ──

    @Test
    fun `a blank transcript makes no note and is refused by name`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.INSERT))
        f.transcription.transcripts["a.m4a"] = ""

        val report = f.pipeline.drain(freshId = "a")

        assertSame(Refusal.NOTHING_HEARD, report.refusal)
        assertTrue(report.completed.isEmpty())
        assertTrue(f.engine.notes.isEmpty())
        assertEquals("the silent take does not stay queued", 0, f.queue.count())
    }

    @Test
    fun `an offline take stops the drain and is kept for later`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.INSERT))
        f.queue.enqueue(item(tmp.root, "b", DictationMode.INSERT))
        f.transcription.transcripts["a.m4a"] = "lands before the outage"
        f.transcription.transcripts["b.m4a"] = "waits"
        // Only the second file fails: the fake raises when it reaches b.
        val online = object : Transcription {
            override fun transcribe(file: File, vocabulary: List<String>): String =
                if (file.name == "b.m4a") throw TranscriptionUnavailable(Refusal.OFFLINE, "offline")
                else f.transcription.transcribe(file, vocabulary)
            override fun cleanup(raw: String, vocabulary: List<String>, model: String): String =
                f.transcription.cleanup(raw, vocabulary, model)
        }
        val pipeline = DictationPipeline(f.queue, f.notes, online, f.sink, FieldProbe { FieldState.EDITABLE })

        val report = pipeline.drain(freshId = null)

        assertSame(Refusal.OFFLINE, report.refusal)
        assertEquals(listOf("a"), report.completed.map { it.queueId })
        assertNotNull("the offline take is still queued", f.queue.item("b"))
        assertEquals(1, report.pending)
    }

    @Test
    fun `a missing API key is refused by name`() {
        val f = fixture()
        f.queue.enqueue(item(tmp.root, "a", DictationMode.INSERT))
        f.transcription.unavailable = TranscriptionUnavailable(Refusal.NO_KEY, "no key")

        val report = f.pipeline.drain(freshId = "a")

        assertSame(Refusal.NO_KEY, report.refusal)
        assertNotNull(f.queue.item("a"))
    }

    // ── idempotency ──

    @Test
    fun `draining the same recording twice writes one note, keyed by the queue id`() {
        val f = fixture()
        val recording = item(tmp.root, "a", DictationMode.INSERT)
        f.transcription.transcripts["a.m4a"] = "Only once"

        f.queue.enqueue(recording)
        f.pipeline.drain(freshId = "a")
        // A crash before the queue row was cleared: the same recording is drained again.
        f.queue.enqueue(recording)
        f.pipeline.drain(freshId = "a")

        assertEquals(1, f.engine.notes.size)
        assertEquals("dictation-a", f.engine.notes.keys.single())
    }

    // ── the projection layer is deleted, not kept beside the pipeline ──

    @Test
    fun `the old store and its projection layer are deleted`() {
        assertFalse("Store.kt is deleted when RecordStore and AudioQueue replace it", P4Paths.path("${P4Paths.SOURCE_DIR}/Store.kt").exists())
        val store = P4Paths.source("RecordStore.kt")
        assertFalse(
            "RecordStore is the sync engine and nothing else; the projection read is gone",
            store.contains("CloudSync(context)") || store.contains("fun dictations(): MutableList<DictationEntry>"),
        )
    }
}
