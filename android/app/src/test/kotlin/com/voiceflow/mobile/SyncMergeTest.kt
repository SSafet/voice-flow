package com.voiceflow.mobile

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SyncMergeTest {
    private fun entry(id: String, text: String, synced: Boolean = false) =
        DictationEntry(id, "12:00:00", "2026-09-08", text, "pasted", synced)
    private fun response(vararg entries: DictationEntry) = JSONObject().put("dictations",
        JSONArray().also { arr -> entries.forEach { arr.put(it.toJson()) } })

    @Test fun appendDuringUploadStaysPending() {
        val sent = entry("1", "original")
        val local = mutableListOf(sent.copy(text = "original plus new words"))
        SyncMerge.apply(local, mutableListOf(), listOf(sent), emptyList(), response(sent))
        assertEquals("original plus new words", local.single().text)
        assertFalse(local.single().synced)
    }

    @Test fun captureDuringUploadSurvives() {
        val sent = entry("1", "first")
        val local = mutableListOf(entry("2", "captured while uploading"), sent.copy())
        SyncMerge.apply(local, mutableListOf(), listOf(sent), emptyList(), response(sent))
        assertEquals(2, local.size)
        assertFalse(local.first().synced)
        assertTrue(local.last().synced)
    }

    @Test fun staleResponseCannotUndoAcknowledgedUpload() {
        val sent = entry("1", "continued")
        val local = mutableListOf(sent.copy())
        SyncMerge.apply(local, mutableListOf(), listOf(sent), emptyList(), response(sent.copy(text = "old")))
        assertEquals("continued", local.single().text)
        assertTrue(local.single().synced)
    }

    @Test fun retriesDedupeAndPullMacUpdates() {
        val local = mutableListOf(entry("1", "old", true))
        val remote = response(entry("1", "updated"), entry("2", "new"))
        repeat(2) { SyncMerge.apply(local, mutableListOf(), emptyList(), emptyList(), remote) }
        assertEquals(2, local.size)
        assertEquals("updated", local.first { it.id == "1" }.text)
    }

    @Test fun chatCreatedDuringUploadIsNotAcknowledged() {
        val sent = ChatMessage("1", "user", "hello", 1, false)
        val local = mutableListOf(sent.copy(), sent.copy(id = "2", text = "new"))
        SyncMerge.apply(mutableListOf(), local, emptyList(), listOf(sent), response())
        assertTrue(local.first().synced)
        assertFalse(local.last().synced)
    }

    @Test fun newMacEntriesAppearAtTopBeforeRetentionLimit() {
        val local = MutableList(500) { entry("old-$it", "old", true).copy(date = "2026-09-01") }
        SyncMerge.apply(local, mutableListOf(), emptyList(), emptyList(), response(entry("new", "new")))
        assertEquals("new", local.take(500).first().id)
    }
}
