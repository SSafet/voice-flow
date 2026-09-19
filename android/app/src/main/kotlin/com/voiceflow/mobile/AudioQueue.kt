package com.voiceflow.mobile

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/// The delivery intent of a dictation. The wire value is what the queue file
/// stores; the destination is the two-value wire the Mac and Atika accept.
enum class DictationMode(val wire: String) {
    INSERT("insert"),
    KEEP("keep"),
    COMPOSER("composer"),
    ;

    val destination: String get() = if (this == KEEP) "kept" else "pasted"

    companion object {
        /// Reads the three wire values, plus the spellings the shipped build
        /// wrote into `queue.json`, so the first launch after the upgrade does
        /// not lose a queued recording. `continue:<id>` and anything else are
        /// null, never an exception.
        fun parse(value: String): DictationMode? = when (value) {
            "insert", "pasted", "bubble" -> INSERT
            "keep", "quick" -> KEEP
            "composer", "assistant" -> COMPOSER
            else -> null
        }
    }
}

/// A recording waiting for transcription. `mode` is left exactly as it was
/// written; nothing here parses it, so a row the shipped build wrote survives.
data class QueueItem(
    val id: String,
    val file: String,
    val mode: String,
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

/// A durable ordered list on disk (`queue.json`) plus the audio files in
/// `queue/`. Nothing is deleted until the text exists: `complete` is the only
/// thing that removes a recording's audio and its row.
class AudioQueue(private val root: File) {

    class Corrupt(message: String) : Exception(message)
    class Refused(message: String) : Exception(message)

    private val queueFile = File(root, "queue.json")
    val audioDir: File = File(root, "queue").apply { mkdirs() }

    /// Insertion order, modes exactly as written.
    fun items(): List<QueueItem> {
        if (!queueFile.exists()) return emptyList()
        return try {
            val array = JSONArray(queueFile.readText())
            List(array.length()) { QueueItem.fromJson(array.getJSONObject(it)) }
        } catch (error: Exception) {
            throw Corrupt("queue.json exists but cannot be read: ${error.message}")
        }
    }

    fun item(id: String): QueueItem? = items().firstOrNull { it.id == id }

    fun count(): Int = items().size

    /// Atomic: a temp file, fsynced, renamed over `queue.json`. An id already
    /// queued is replaced in place so it keeps its first position.
    fun enqueue(item: QueueItem) {
        root.mkdirs()
        val list = items().toMutableList()
        val index = list.indexOfFirst { it.id == item.id }
        if (index >= 0) list[index] = item else list.add(item)
        write(list)
    }

    /// Called only after the text is durable: delete the audio and the row.
    fun complete(id: String) {
        val list = items()
        val found = list.firstOrNull { it.id == id } ?: return
        File(found.file).delete()
        write(list.filterNot { it.id == id })
    }

    /// Audio gone -> the row may be dropped; audio present -> refused by name.
    fun discard(id: String) {
        val list = items()
        val found = list.firstOrNull { it.id == id } ?: return
        if (File(found.file).exists()) throw Refused("recording $id still has its audio")
        write(list.filterNot { it.id == id })
    }

    private fun write(list: List<QueueItem>) {
        root.mkdirs()
        val array = JSONArray()
        list.forEach { array.put(it.toJson()) }
        val temp = File(root, "queue.json.tmp")
        FileOutputStream(temp).use { out ->
            out.write(array.toString().toByteArray(Charsets.UTF_8))
            out.flush()
            out.fd.sync()
        }
        try {
            Files.move(
                temp.toPath(), queueFile.toPath(),
                StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(temp.toPath(), queueFile.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }
}
