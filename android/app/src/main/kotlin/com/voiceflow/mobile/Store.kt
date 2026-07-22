package com.voiceflow.mobile

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/// One dictation record. `kind` mirrors the Mac's CaptureDestination raw
/// values: "pasted" for a normal dictation, "kept" for an idea capture —
/// "kept" is what the Mac's tickets intake reads as brain-dump material.
data class DictationEntry(
    val id: String,
    val time: String,      // HH:mm:ss, same shape the Mac writes
    val date: String,      // yyyy-MM-dd, phone-local bookkeeping
    val text: String,
    val kind: String,      // "pasted" | "kept"
    var synced: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("time", time).put("date", date)
        .put("timestamp", if (date.isBlank() || time.isBlank()) "" else "${date}T${time}")
        .put("text", text).put("kind", kind).put("synced", synced)

    companion object {
        fun fromJson(o: JSONObject) = DictationEntry(
            o.optString("id", UUID.randomUUID().toString()),
            o.optString("time"), o.optString("date"),
            o.optString("text"), o.optString("kind", "pasted"),
            o.optBoolean("synced", false),
        )

        fun now(text: String, kind: String): DictationEntry {
            val d = Date()
            return DictationEntry(
                UUID.randomUUID().toString(),
                SimpleDateFormat("HH:mm:ss", Locale.US).format(d),
                SimpleDateFormat("yyyy-MM-dd", Locale.US).format(d),
                text, kind, false,
            )
        }
    }
}

data class ChatMessage(
    val id: String,
    val role: String,      // "user" | "assistant"
    val text: String,
    val ts: Long,
    var synced: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("role", role).put("text", text)
        .put("ts", ts).put("synced", synced)

    companion object {
        fun fromJson(o: JSONObject) = ChatMessage(
            o.optString("id", UUID.randomUUID().toString()),
            o.optString("role"), o.optString("text"),
            o.optLong("ts"), o.optBoolean("synced", false),
        )

        fun now(role: String, text: String) =
            ChatMessage(UUID.randomUUID().toString(), role, text, System.currentTimeMillis(), false)
    }
}

/// A recording waiting for transcription (store-and-forward: survives the
/// app dying and the network being gone — audio sits on disk until it works).
data class QueueItem(
    val id: String,
    val file: String,      // absolute path of the .m4a
    val mode: String,      // "pasted" | "kept" | "assistant"
    val createdAt: Long,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("file", file).put("mode", mode).put("createdAt", createdAt)

    companion object {
        fun fromJson(o: JSONObject) = QueueItem(
            o.optString("id"), o.optString("file"),
            o.optString("mode", "pasted"), o.optLong("createdAt"),
        )
    }
}

/// JSON-file persistence in filesDir, newest-first like the Mac stores.
/// All access from the single background executor in MainActivity, so no
/// locking beyond @Synchronized safety belts.
class Store(private val context: Context) {
    private val dictationsFile get() = File(context.filesDir, "dictations.json")
    private val chatFile get() = File(context.filesDir, "chat.json")
    private val queueFile get() = File(context.filesDir, "queue.json")
    val audioDir: File get() = File(context.filesDir, "queue").apply { mkdirs() }

    private fun readArray(f: File): JSONArray =
        if (f.exists()) try { JSONArray(f.readText()) } catch (_: Exception) { JSONArray() }
        else JSONArray()

    private fun writeArray(f: File, arr: JSONArray) {
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeText(arr.toString())
        tmp.renameTo(f)
    }

    // ── dictations ──
    @Synchronized
    fun dictations(): MutableList<DictationEntry> {
        val arr = readArray(dictationsFile)
        return MutableList(arr.length()) { DictationEntry.fromJson(arr.getJSONObject(it)) }
    }

    @Synchronized
    fun saveDictations(list: List<DictationEntry>) {
        val arr = JSONArray()
        list.take(500).forEach { arr.put(it.toJson()) }
        writeArray(dictationsFile, arr)
    }

    @Synchronized
    fun addDictation(entry: DictationEntry) {
        val list = dictations()
        list.add(0, entry)
        saveDictations(list)
    }

    /// Continue-append (ticket #36): the new transcript joins the existing
    /// entry with a paragraph break; time/date refresh to now and the entry
    /// moves to the top, marked unsynced so the next sync UPDATES the Mac's
    /// copy (matched by id). Returns false when the entry is gone.
    @Synchronized
    fun appendToDictation(id: String, text: String): Boolean {
        val list = dictations()
        val idx = list.indexOfFirst { it.id == id }
        if (idx < 0) return false
        val d = Date()
        val entry = list.removeAt(idx)
        list.add(0, entry.copy(
            text = entry.text + "\n\n" + text,
            time = SimpleDateFormat("HH:mm:ss", Locale.US).format(d),
            date = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(d),
            synced = false,
        ))
        saveDictations(list)
        return true
    }

    // ── assistant chat ──
    @Synchronized
    fun chat(): MutableList<ChatMessage> {
        val arr = readArray(chatFile)
        return MutableList(arr.length()) { ChatMessage.fromJson(arr.getJSONObject(it)) }
    }

    @Synchronized
    fun saveChat(list: List<ChatMessage>) {
        val arr = JSONArray()
        list.takeLast(400).forEach { arr.put(it.toJson()) }
        writeArray(chatFile, arr)
    }

    @Synchronized
    fun addChat(msg: ChatMessage) {
        val list = chat()
        list.add(msg)
        saveChat(list)
    }

    // ── pending-audio queue ──
    @Synchronized
    fun queue(): MutableList<QueueItem> {
        val arr = readArray(queueFile)
        return MutableList(arr.length()) { QueueItem.fromJson(arr.getJSONObject(it)) }
    }

    @Synchronized
    fun saveQueue(list: List<QueueItem>) {
        val arr = JSONArray()
        list.forEach { arr.put(it.toJson()) }
        writeArray(queueFile, arr)
    }

    @Synchronized
    fun enqueue(item: QueueItem) {
        val list = queue()
        list.add(item)
        saveQueue(list)
    }

    @Synchronized
    fun dequeue(id: String) {
        val list = queue()
        list.firstOrNull { it.id == id }?.let { File(it.file).delete() }
        saveQueue(list.filterNot { it.id == id })
    }
}
