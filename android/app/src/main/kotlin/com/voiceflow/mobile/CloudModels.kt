package com.voiceflow.mobile

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.time.Instant
import java.time.OffsetDateTime
import java.util.UUID

/** Portable metadata only. These types cannot encode API keys, LAN pairing,
 * recordings, file paths, runtime bindings, permissions, or attachments. */
enum class CloudCollection(val wire: String) {
    DICTATIONS("dictations"), THREADS("threads"), MESSAGES("messages"), PREFERENCES("preferences");
    companion object { fun parse(value: String) = entries.firstOrNull { it.wire == value } ?: throw CloudFailure.UpdateRequired() }
}

sealed class CloudFailure(message: String) : Exception(message) {
    class InvalidRecord : CloudFailure("This record needs review. Your local copy is retained.")
    class InvalidResponse : CloudFailure("The cloud response could not be verified. Changes remain queued.")
    class Storage : CloudFailure("Cloud sync could not save locally. Existing data is retained.")
    class SignIn : CloudFailure("Sign in again. Your changes are saved here.")
    class UpdateRequired : CloudFailure("Update required. Your changes are saved here.")
    class Origin : CloudFailure("Use an HTTPS Atika address with no path or credentials.")
    class Baseline : CloudFailure("Cloud history changed. Review its baseline; your local changes are retained.")
    class Server(val status: Int, val code: String) : CloudFailure(if (status == 501) "Cloud sync is not enabled for this account yet. Changes are saved here." else "Cloud sync is unavailable ($status). Changes are saved here.")
}

object CloudWire {
    fun id(value: String): String { if (!Regex("^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$").matches(value)) throw CloudFailure.InvalidRecord(); return value }
    fun version(value: String): Long {
        val parsed = value.toLongOrNull()
        if (!Regex("^(0|[1-9][0-9]{0,18})$").matches(value) || parsed == null || parsed < 0 || parsed == Long.MAX_VALUE) throw CloudFailure.InvalidResponse()
        return parsed
    }
    fun origin(input: String, allowLoopback: Boolean = false): String {
        val uri = try { URI(input.trim()) } catch (_: Exception) { throw CloudFailure.Origin() }
        val host = uri.host?.lowercase() ?: throw CloudFailure.Origin()
        if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null || uri.path !in listOf("", "/") ||
            (uri.scheme != "https" && !(allowLoopback && uri.scheme == "http" && host in listOf("localhost", "127.0.0.1", "[::1]", "10.0.2.2")))) throw CloudFailure.Origin()
        return "${uri.scheme}://$host${if (uri.port >= 0 && !((uri.scheme == "https" && uri.port == 443) || (uri.scheme == "http" && uri.port == 80))) ":${uri.port}" else ""}"
    }
    fun timestamp() = Instant.now().toString()
    fun date(value: String): String { if (value.length > 40 || !Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$").matches(value)) throw CloudFailure.InvalidRecord(); try { OffsetDateTime.parse(value) } catch (_: Exception) { throw CloudFailure.InvalidRecord() }; return value }
    fun text(value: String, max: Int): String { if (value.isBlank() || value.length > max || value.contains('\u0000')) throw CloudFailure.InvalidRecord(); return value }
    fun fields(json: JSONObject, allowed: Set<String>) { if (json.keys().asSequence().any { it !in allowed }) throw CloudFailure.InvalidRecord() }
    fun optional(json: JSONObject, name: String): String? = if (!json.has(name) || json.isNull(name)) null else json.getString(name)
    fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + canonical(value.get(it)) }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        else -> value.toString()
    }
}
private fun JSONObject.optional(name: String, value: String?): JSONObject = apply { if (value != null) put(name, value) }

sealed class CloudPayload {
    abstract fun json(): JSONObject
    data class Dictation(val text: String, val destination: String, val createdAt: String? = null, val modifiedAt: String? = null,
                         val legacyTimestamp: String? = null, val captureKind: String? = null) : CloudPayload() {
        override fun json() = JSONObject().put("text", text).put("destination", destination).optional("createdAt", createdAt)
            .optional("modifiedAt", modifiedAt).optional("legacyTimestamp", legacyTimestamp).optional("captureKind", captureKind)
    }
    data class Thread(val title: String, val createdAt: String? = null, val completedAt: String? = null, val assistantName: String? = null) : CloudPayload() {
        override fun json() = JSONObject().put("title", title).optional("createdAt", createdAt).optional("completedAt", completedAt).optional("assistantName", assistantName)
    }
    data class Message(val text: String, val threadId: String, val role: String, val createdAt: String? = null,
                       val parentMessageId: String? = null, val turnId: String? = null) : CloudPayload() {
        override fun json() = JSONObject().put("text", text).put("threadId", threadId).put("role", role).optional("createdAt", createdAt)
            .optional("parentMessageId", parentMessageId).optional("turnId", turnId)
    }
    data class Model(val value: String) : CloudPayload() { override fun json() = JSONObject().put("value", value) }
    data class Vocabulary(val value: List<String>) : CloudPayload() { override fun json() = JSONObject().put("value", JSONArray(value)) }
    data class Cleanup(val value: Boolean) : CloudPayload() { override fun json() = JSONObject().put("value", value) }

    fun validate(collection: CloudCollection, id: String): CloudPayload = parse(collection, id, json())
    companion object {
        /** Decodes our own typed edit journal before wire validation. Invalid
         * or oversized portable edits must reach the retained review store. */
        fun local(collection: CloudCollection, id: String, value: JSONObject): CloudPayload = when (collection) {
            CloudCollection.DICTATIONS -> Dictation(value.getString("text"), value.getString("destination"), CloudWire.optional(value, "createdAt"), CloudWire.optional(value, "modifiedAt"), CloudWire.optional(value, "legacyTimestamp"), CloudWire.optional(value, "captureKind"))
            CloudCollection.THREADS -> Thread(value.getString("title"), CloudWire.optional(value, "createdAt"), CloudWire.optional(value, "completedAt"), CloudWire.optional(value, "assistantName"))
            CloudCollection.MESSAGES -> Message(value.getString("text"), value.getString("threadId"), value.getString("role"), CloudWire.optional(value, "createdAt"), CloudWire.optional(value, "parentMessageId"), CloudWire.optional(value, "turnId"))
            CloudCollection.PREFERENCES -> when (id) {
                "agent_model" -> Model(value.getString("value"))
                "cleanup_enabled" -> Cleanup(value.getBoolean("value"))
                "vocabulary" -> value.getJSONArray("value").let { words -> Vocabulary(List(words.length()) { words.getString(it) }) }
                else -> throw CloudFailure.InvalidRecord()
            }
        }
        fun parse(collection: CloudCollection, id: String, value: JSONObject): CloudPayload {
            CloudWire.id(id)
            if (value.toString().toByteArray(Charsets.UTF_8).size > 65_536) throw CloudFailure.InvalidRecord()
            fun optional(name: String) = CloudWire.optional(value, name)
            fun date(name: String) = optional(name)?.let(CloudWire::date)
            return when (collection) {
                CloudCollection.DICTATIONS -> {
                    CloudWire.fields(value, setOf("text", "destination", "createdAt", "modifiedAt", "legacyTimestamp", "captureKind"))
                    val destination = value.getString("destination")
                    if (destination !in listOf("pasted", "kept")) throw CloudFailure.InvalidRecord()
                    val kind = optional("captureKind")
                    if (kind != null && kind !in listOf("dictate", "dictateSnapshot", "continuousCapture", "typed")) throw CloudFailure.InvalidRecord()
                    Dictation(CloudWire.text(value.getString("text"), 60_000), destination, date("createdAt"), date("modifiedAt"), optional("legacyTimestamp")?.let { CloudWire.text(it, 64) }, kind)
                }
                CloudCollection.THREADS -> {
                    CloudWire.fields(value, setOf("title", "createdAt", "completedAt", "assistantName"))
                    Thread(CloudWire.text(value.getString("title"), 500), date("createdAt"), date("completedAt"), optional("assistantName")?.let { CloudWire.text(it, 200) })
                }
                CloudCollection.MESSAGES -> {
                    CloudWire.fields(value, setOf("text", "threadId", "role", "createdAt", "parentMessageId", "turnId"))
                    val role = value.getString("role")
                    if (role !in listOf("user", "assistant", "note")) throw CloudFailure.InvalidRecord()
                    Message(CloudWire.text(value.getString("text"), 60_000), CloudWire.id(value.getString("threadId")), role, date("createdAt"), optional("parentMessageId")?.let(CloudWire::id), optional("turnId")?.let(CloudWire::id))
                }
                CloudCollection.PREFERENCES -> {
                    CloudWire.fields(value, setOf("value"))
                    when (id) {
                        "agent_model" -> Model(CloudWire.text(value.getString("value"), 200).also { if (!Regex("^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$").matches(it)) throw CloudFailure.InvalidRecord() })
                        "cleanup_enabled" -> Cleanup((value.get("value") as? Boolean) ?: throw CloudFailure.InvalidRecord())
                        "vocabulary" -> {
                            val words = value.getJSONArray("value")
                            if (words.length() > 512) throw CloudFailure.InvalidRecord()
                            Vocabulary(List(words.length()) { CloudWire.text(words.getString(it), 200) })
                        }
                        else -> throw CloudFailure.InvalidRecord()
                    }
                }
            }
        }
    }
}

data class CloudOperation(val collection: CloudCollection, val recordId: String, val baseVersion: String, val op: String,
                          val payload: CloudPayload? = null, val operationId: String = UUID.randomUUID().toString(), val resolvesConflictId: String? = null) {
    fun json(): JSONObject = JSONObject().put("operationId", operationId).put("collection", collection.wire).put("recordId", recordId)
        .put("baseVersion", baseVersion).put("schemaVersion", 1).put("op", op).apply { payload?.let { put("payload", it.json()) } }.optional("resolvesConflictId", resolvesConflictId)
    companion object { fun parse(o: JSONObject): CloudOperation {
        if (o.getInt("schemaVersion") != 1) throw CloudFailure.UpdateRequired()
        val collection = CloudCollection.parse(o.getString("collection")); val id = CloudWire.id(o.getString("recordId")); val op = o.getString("op")
        if (op !in listOf("put", "delete", "restore") || ((op == "delete") != (!o.has("payload") || o.isNull("payload")))) throw CloudFailure.InvalidResponse()
        val version = o.getString("baseVersion"); CloudWire.version(version)
        return CloudOperation(collection, id, version, op, o.optJSONObject("payload")?.let { CloudPayload.parse(collection, id, it) }, CloudWire.id(o.getString("operationId")), CloudWire.optional(o, "resolvesConflictId")?.let(CloudWire::id))
    } }
}
data class CloudRecord(val collection: CloudCollection, val recordId: String, val version: String, val payload: CloudPayload?, val deletedAt: String?, val seq: String) {
    fun json(): JSONObject = JSONObject().put("collection", collection.wire).put("recordId", recordId).put("version", version).put("schemaVersion", 1)
        .put("payload", payload?.json() ?: JSONObject.NULL).put("deletedAt", deletedAt ?: JSONObject.NULL).put("seq", seq)
    fun validate() { CloudWire.id(recordId); if (CloudWire.version(version) < 1 || CloudWire.version(seq) < 1 || ((deletedAt == null) != (payload != null))) throw CloudFailure.InvalidResponse(); payload?.validate(collection, recordId); deletedAt?.let(CloudWire::date) }
    companion object { fun parse(o: JSONObject): CloudRecord {
        if (o.getInt("schemaVersion") != 1) throw CloudFailure.UpdateRequired()
        val collection = CloudCollection.parse(o.getString("collection")); val id = o.getString("recordId")
        return CloudRecord(collection, id, o.getString("version"), o.optJSONObject("payload")?.let { CloudPayload.parse(collection, id, it) }, CloudWire.optional(o, "deletedAt"), o.getString("seq")).also { it.validate() }
    } }
}
data class CloudConflict(val conflictId: String, val collection: CloudCollection, val recordId: String, val baseVersion: String,
                         val currentVersion: String, val proposed: CloudOperation, val reason: String, val createdAt: String, val resolvedAt: String? = null) {
    fun json(): JSONObject = JSONObject().put("conflictId", conflictId).put("collection", collection.wire).put("recordId", recordId)
        .put("baseVersion", baseVersion).put("currentVersion", currentVersion).put("proposed", proposed.json()).put("reason", reason).put("createdAt", createdAt).optional("resolvedAt", resolvedAt)
    companion object { fun parse(o: JSONObject): CloudConflict {
        val proposed = CloudOperation.parse(o.getJSONObject("proposed")); val collection = CloudCollection.parse(o.getString("collection")); val id = CloudWire.id(o.getString("recordId"))
        val base = o.getString("baseVersion"); val current = o.getString("currentVersion"); CloudWire.version(base); CloudWire.version(current)
        if (collection != proposed.collection || id != proposed.recordId || proposed.baseVersion != base) throw CloudFailure.InvalidResponse()
        val reason = o.getString("reason"); if (reason !in listOf("version_changed", "deleted", "not_deleted", "resolution_changed")) throw CloudFailure.InvalidResponse()
        return CloudConflict(CloudWire.id(o.getString("conflictId")), collection, id, base, current, proposed, reason, CloudWire.date(o.getString("createdAt")), CloudWire.optional(o, "resolvedAt"))
    } }
}
data class CloudReceipt(val operationId: String, val status: String, val seq: String, val record: CloudRecord?, val conflict: CloudConflict?) {
    companion object { fun parse(o: JSONObject) = CloudReceipt(CloudWire.id(o.getString("operationId")), o.getString("status"), o.getString("seq"), o.optJSONObject("record")?.let(CloudRecord::parse), o.optJSONObject("conflict")?.let(CloudConflict::parse)) }
}
data class CloudChange(val seq: String, val kind: String, val record: CloudRecord?, val conflict: CloudConflict?, val resolvedConflictId: String?)
data class CloudPage(val changes: List<CloudChange>, val nextCursor: String, val hasMore: Boolean, val highWatermark: String, val epoch: String) {
    companion object { fun parse(o: JSONObject): CloudPage {
        val rows = o.getJSONArray("changes")
        return CloudPage(List(rows.length()) { val row = rows.getJSONObject(it); CloudChange(row.getString("seq"), row.getString("kind"), row.optJSONObject("record")?.let(CloudRecord::parse), row.optJSONObject("conflict")?.let(CloudConflict::parse), CloudWire.optional(row, "resolvedConflictId")) },
            o.getString("nextCursor"), o.getBoolean("hasMore"), o.getString("highWatermark"), o.getString("epoch"))
    } }
}
data class CloudEdit(val collection: CloudCollection, val recordId: String, val payload: CloudPayload?, val restore: Boolean = false)
