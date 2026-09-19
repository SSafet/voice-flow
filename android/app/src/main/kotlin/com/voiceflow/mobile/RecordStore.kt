package com.voiceflow.mobile

import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.time.LocalDateTime
import java.time.ZoneId
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

/// The seam between the reduced store and the cloud sync: the store's rules
/// are pinned without a Context, SharedPreferences or SQLite.
interface RecordEngine {
    /// Returns only once the entry is durable.
    fun put(entry: DictationEntry)
    fun all(): List<DictationEntry>
    fun preference(key: String): String?
    fun setPreference(key: String, value: String)
}

/// The reduced record store: `dictations` and `preferences`, nothing else.
/// The assistant's threads and messages and the local-network sync are not
/// its concern; the stored files stay on disk untouched for the migration.
class RecordStore(private val engine: RecordEngine) {

    fun saveNote(entry: DictationEntry) = engine.put(entry)

    fun dictations(): List<DictationEntry> = engine.all()

    /// The model the phone hardcodes today when the preference is unset.
    fun cleanupModel(): String =
        engine.preference(DICTATION_CLEANUP_MODEL)?.takeIf { it.isNotBlank() } ?: Transcriber.CLEANUP_MODEL

    fun cleanupEnabled(): Boolean =
        engine.preference(CLEANUP_ENABLED)?.let { it.lowercase() != "false" } ?: true

    fun vocabulary(): List<String> {
        val raw = engine.preference(VOCABULARY) ?: return emptyList()
        val words = JSONArray(raw)
        return List(words.length()) { words.getString(it) }
    }

    companion object {
        const val DICTATION_CLEANUP_MODEL = "dictation_cleanup_model"
        const val CLEANUP_ENABLED = "cleanup_enabled"
        const val VOCABULARY = "vocabulary"

        val COLLECTIONS: Set<CloudCollection> =
            setOf(CloudCollection.DICTATIONS, CloudCollection.PREFERENCES)

        /// The wire edit a phone dictation writes: unchanged from the day it
        /// was CloudSync's, `captureKind` "dictate" and the mode's destination.
        fun edit(entry: DictationEntry): CloudEdit {
            val stamp = runCatching {
                LocalDateTime.parse("${entry.date}T${entry.time}")
                    .atZone(ZoneId.systemDefault()).toInstant().toString()
            }.getOrNull()
            return CloudEdit(
                CloudCollection.DICTATIONS, entry.id,
                CloudPayload.Dictation(
                    entry.text, entry.kind,
                    modifiedAt = stamp,
                    legacyTimestamp = "${entry.date}T${entry.time}"
                        .takeIf { entry.date.isNotBlank() && entry.time.isNotBlank() },
                    captureKind = "dictate",
                ),
            )
        }
    }
}
