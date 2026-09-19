package com.voiceflow.mobile

import android.content.Context
import android.util.AtomicFile
import org.json.JSONArray
import java.io.File

/// The production `RecordEngine`: a durable local mirror of the phone's
/// dictations plus a capture through the existing cloud sync, and the
/// preferences the dot reads offline. `put` returns only after the local
/// mirror has the note; a signed-in phone also queues the wire edit.
class CloudRecordEngine(private val context: Context) : RecordEngine {

    private val dictationsFile get() = File(context.filesDir, "dictations.json")

    override fun put(entry: DictationEntry) {
        synchronized(RecordStore.lock) {
            val list = all().toMutableList()
            list.removeAll { it.id == entry.id }
            list.add(0, entry)
            val array = JSONArray()
            list.take(500).forEach { array.put(it.toJson()) }
            write(array)
        }
        runCatching { CloudSync(context).capture(listOf(RecordStore.edit(entry))) }
    }

    /// The local mirror is the source; remote history only arrives through the
    /// sync engine and lands here when it does.
    override fun all(): List<DictationEntry> = synchronized(RecordStore.lock) {
        if (!dictationsFile.exists()) return emptyList()
        val array = try {
            JSONArray(dictationsFile.readText())
        } catch (_: Exception) {
            throw CloudFailure.Storage()
        }
        List(array.length()) { DictationEntry.fromJson(array.getJSONObject(it)) }
    }

    override fun preference(key: String): String? =
        CloudPreferences(context).prefs.getString(key, null)

    override fun setPreference(key: String, value: String) {
        if (!CloudPreferences(context).prefs.edit().putString(key, value).commit()) {
            throw CloudFailure.Storage()
        }
    }

    private fun write(array: JSONArray) {
        val atomic = AtomicFile(dictationsFile)
        val out = atomic.startWrite()
        try {
            out.write(array.toString().toByteArray(Charsets.UTF_8))
            atomic.finishWrite(out)
        } catch (error: Throwable) {
            atomic.failWrite(out)
            throw error
        }
    }
}
