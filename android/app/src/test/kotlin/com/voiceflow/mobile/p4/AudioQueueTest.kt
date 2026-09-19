package com.voiceflow.mobile.p4

import com.voiceflow.mobile.AudioQueue
import com.voiceflow.mobile.DictationMode
import com.voiceflow.mobile.QueueItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The audio queue is a list on disk written atomically, plus the audio files:
 * it survives the app being killed and the phone rebooting, it keeps insertion
 * order, and nothing is deleted until the text exists (08 §3.7 "Queue").
 *
 * Every test writes and reads a real directory; no test asserts a value the
 * queue also writes into itself, and none passes by timing.
 */
class AudioQueueTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun queue(root: File = tmp.root) = AudioQueue(root)

    private fun recorded(root: File, id: String, mode: DictationMode, bytes: Int = 64): QueueItem {
        val dir = File(root, "queue").apply { mkdirs() }
        val file = File(dir, "$id.m4a")
        file.writeBytes(ByteArray(bytes) { 1 })
        return QueueItem(id, file.absolutePath, mode.wire, 1_700_000_000_000L + id.hashCode())
    }

    // ── durability and order ──

    @Test
    fun `the queue survives a restart in insertion order`() {
        val first = queue()
        val a = recorded(tmp.root, "a", DictationMode.INSERT)
        val b = recorded(tmp.root, "b", DictationMode.KEEP)
        val c = recorded(tmp.root, "c", DictationMode.COMPOSER)
        first.enqueue(a)
        first.enqueue(b)
        first.enqueue(c)

        // A fresh instance over the same directory is the restart.
        val afterRestart = queue()
        assertEquals(listOf("a", "b", "c"), afterRestart.items().map { it.id })
        assertEquals(3, afterRestart.count())
        assertEquals("b", afterRestart.item("b")?.id)
        assertEquals(DictationMode.KEEP.wire, afterRestart.item("b")?.mode)
    }

    @Test
    fun `an empty directory is an empty queue, not an error`() {
        assertEquals(emptyList<QueueItem>(), queue().items())
        assertNull(queue().item("nothing"))
        assertEquals(0, queue().count())
    }

    // ── nothing is deleted until the text exists ──

    @Test
    fun `complete removes the row and the audio only when it is called`() {
        val q = queue()
        val item = recorded(tmp.root, "done", DictationMode.INSERT)
        q.enqueue(item)
        assertTrue(File(item.file).isFile)

        q.complete("done")

        assertFalse("the audio is deleted only on complete", File(item.file).exists())
        assertNull(q.item("done"))
        assertEquals(0, q.count())
    }

    @Test
    fun `a take whose audio is gone can be discarded`() {
        val q = queue()
        val item = recorded(tmp.root, "gone", DictationMode.INSERT)
        q.enqueue(item)
        File(item.file).delete()

        q.discard("gone")

        assertNull(q.item("gone"))
        assertEquals(0, q.count())
    }

    @Test
    fun `a take whose audio is present is refused by name and kept`() {
        val q = queue()
        val item = recorded(tmp.root, "keep-me", DictationMode.INSERT)
        q.enqueue(item)

        val thrown = try {
            q.discard("keep-me")
            null
        } catch (error: AudioQueue.Refused) {
            error
        }

        assertNotNull("discarding a present recording must be refused", thrown)
        assertEquals("keep-me", q.item("keep-me")?.id)
        assertTrue("the audio is still there", File(item.file).isFile)
    }

    // ── a damaged list is refused, never silently emptied ──

    @Test
    fun `a corrupt queue file is refused by name instead of dropping recordings`() {
        val q = queue()
        q.enqueue(recorded(tmp.root, "survivor", DictationMode.INSERT))
        File(tmp.root, "queue.json").writeText("{ this is not the queue }")

        val thrown = try {
            queue().items()
            null
        } catch (error: AudioQueue.Corrupt) {
            error
        }

        assertNotNull("a corrupt queue must be refused, not read as empty", thrown)
    }

    // ── the mode is the delivery intent, and maps to the wire destination ──

    @Test
    fun `the three delivery modes map to the two wire destinations`() {
        assertEquals("pasted", DictationMode.INSERT.destination)
        assertEquals("kept", DictationMode.KEEP.destination)
        assertEquals("pasted", DictationMode.COMPOSER.destination)
        assertEquals(DictationMode.INSERT, DictationMode.parse("insert"))
        assertEquals(DictationMode.KEEP, DictationMode.parse("keep"))
        assertEquals(DictationMode.COMPOSER, DictationMode.parse("composer"))
    }
}
