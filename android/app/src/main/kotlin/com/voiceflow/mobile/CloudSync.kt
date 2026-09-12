package com.voiceflow.mobile

import android.content.Context
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

enum class SyncTransport(val value: String) { OFF("off"), LOCAL("local"), CLOUD("cloud") }
class CloudPreferences(private val context: Context) {
    val prefs = context.getSharedPreferences("app", Context.MODE_PRIVATE)
    var transport: SyncTransport
        get() = SyncTransport.entries.firstOrNull { it.value == prefs.getString("sync_transport", null) }
            ?: if (prefs.getBoolean("paired", false)) SyncTransport.LOCAL else SyncTransport.OFF
        set(value) { if (!prefs.edit().putString("sync_transport", value.value).commit()) throw CloudFailure.Storage() }
    val chosen get() = prefs.contains("sync_transport") || prefs.getBoolean("paired", false)
    val partition get() = prefs.getString("cloud_partition", null)
    fun statusKey(name: String, partition: String? = this.partition) = "cloud_state_${partition ?: "draft"}_$name"
    val origin get() = prefs.getString("cloud_origin", "https://api.atika.ai") ?: "https://api.atika.ai"
    private fun selectionKey(partition: String?) = "cloud_selection_" + (partition ?: "draft")
    fun included(partition: String? = this.partition): Set<CloudCollection> {
        val raw = prefs.getString(selectionKey(partition), null) ?: prefs.getString(selectionKey(null), "[\"dictations\",\"threads\",\"messages\",\"preferences\"]")!!
        val values = JSONArray(raw)
        return (0 until values.length()).map { CloudCollection.parse(values.getString(it)) }.toSet()
    }
    fun setIncluded(values: Set<CloudCollection>, partition: String? = this.partition) {
        if (!prefs.edit().putString(selectionKey(partition), JSONArray(values.map { it.wire }).toString()).commit()) throw CloudFailure.Storage()
    }
    fun use(credentials: CloudCredentials) {
        if (!prefs.contains(selectionKey(credentials.partition))) setIncluded(included(null), credentials.partition)
        if (!prefs.edit().putString("cloud_partition", credentials.partition).putString("cloud_origin", credentials.origin)
                .putString("cloud_email", credentials.email).putString("cloud_device_id", credentials.deviceId)
                .putBoolean(statusKey("auth_required", credentials.partition), false).putString("sync_transport", "cloud").commit()) throw CloudFailure.Storage()
    }
}

/** Ordered recovery intents close the SQLite/legacy-file projection gap.
 * Only portable edits enter this directory; account identity is frozen. */
class CloudCaptureJournal(private val context: Context, private val engine: CloudEngine) {
    private val root get() = File(context.filesDir, "cloud-edit-intents").apply { mkdirs() }
    fun save(edits: List<CloudEdit>, partition: String) = synchronized(Store.lock) {
        replay()
        val counter = AtomicFile(File(root, "sequence"))
        val old = runCatching { String(counter.readFully()).toLong() }.getOrDefault(0)
        val existing = root.listFiles().orEmpty().mapNotNull { it.name.removeSuffix(".json").toLongOrNull() }.maxOrNull() ?: 0
        val sequence = maxOf(old, existing) + 1
        write(counter, sequence.toString())
        val file = AtomicFile(File(root, sequence.toString().padStart(20, '0') + ".json"))
        write(file, JSONObject().put("partition", partition).put("edits", JSONArray(edits.map { edit ->
            JSONObject().put("collection", edit.collection.wire).put("recordId", edit.recordId).put("payload", edit.payload?.json() ?: JSONObject.NULL).put("restore", edit.restore)
        })).toString())
        replay()
    }
    fun replay() = synchronized(Store.lock) {
        root.listFiles().orEmpty().filter { it.name.matches(Regex("[0-9]{20}\\.json")) }.sortedBy { it.name }.forEach { file ->
            val intent = JSONObject(String(AtomicFile(file).readFully(), Charsets.UTF_8))
            val edits = intent.getJSONArray("edits")
            engine.capture(List(edits.length()) { val edit = edits.getJSONObject(it); val collection = CloudCollection.parse(edit.getString("collection")); val id = edit.getString("recordId")
                CloudEdit(collection, id, edit.optJSONObject("payload")?.let { payload -> CloudPayload.local(collection, id, payload) }, edit.optBoolean("restore")) }, intent.getString("partition"))
            AtomicFile(file).delete()
        }
    }
    private fun write(file: AtomicFile, value: String) {
        val out = file.startWrite()
        try { out.write(value.toByteArray(Charsets.UTF_8)); file.finishWrite(out) }
        catch (error: Throwable) { file.failWrite(out); throw error }
    }
}

class CloudSync(private val context: Context) {
    val preferences = CloudPreferences(context)
    val engine = CloudEngine(CloudDatabase.get(context))
    val vault: CloudVault = CloudKeystoreVault(Keys(context))
    private val journal = CloudCaptureJournal(context, engine)
    var lastError: String? = null; private set
    companion object { private val deliveryLock = SyncClient.syncLock }
    fun credentials(): CloudCredentials? = preferences.partition?.let { vault.load(it) }
    fun configured() = credentials() != null && !preferences.prefs.getBoolean(preferences.statusKey("auth_required"), false)
    fun client(): CloudHTTP {
        val credentials = credentials() ?: throw CloudFailure.SignIn()
        return CloudHTTP(credentials.origin, vault, credentials.partition, allowLoopback = context.packageName.endsWith(".syncqa"))
    }
    fun state(): CloudAccountState? = preferences.partition?.let(engine::state)
    fun hasDelivery(): Boolean = preferences.partition?.let { runCatching { val state = engine.state(it); !state.imported || state.cursor == null || engine.nextOperations(it, included = preferences.included(it)).isNotEmpty() }.getOrDefault(false) } == true || preferences.prefs.getBoolean(preferences.statusKey("more"), false)

    fun capture(edits: List<CloudEdit>) {
        val partition = preferences.partition ?: return
        if (!engine.state(partition).imported) importLegacy()
        journal.save(edits, partition)
    }
    fun dictation(entry: DictationEntry): CloudEdit {
        val stamp = runCatching { LocalDateTime.parse("${entry.date}T${entry.time}").atZone(ZoneId.systemDefault()).toInstant().toString() }.getOrNull()
        return CloudEdit(CloudCollection.DICTATIONS, entry.id, CloudPayload.Dictation(entry.text, entry.kind, modifiedAt = stamp,
            legacyTimestamp = "${entry.date}T${entry.time}".takeIf { entry.date.isNotBlank() && entry.time.isNotBlank() }, captureKind = "dictate"))
    }
    fun chat(message: ChatMessage, previous: String?): List<CloudEdit> {
        val thread = threadId()
        val state = state()
        val title = state?.records?.get(CloudEngine.key(CloudCollection.THREADS, thread))?.payload
            ?: CloudPayload.Thread("Phone assistant", assistantName = "Voice Flow Android")
        val partition = preferences.partition
        val safePrevious = previous?.takeIf { id ->
            val owner = engine.sourceOwner(CloudCollection.MESSAGES, id)
            owner == null || (owner == partition && (state?.records?.get("messages:$id")?.payload as? CloudPayload.Message)?.threadId == thread)
        }
        return listOf(CloudEdit(CloudCollection.THREADS, thread, title),
            CloudEdit(CloudCollection.MESSAGES, message.id, CloudPayload.Message(message.text, thread, message.role,
                Instant.ofEpochMilli(message.ts).toString(), parentMessageId = safePrevious)))
    }
    fun threadId(): String {
        val prefs = preferences.prefs
        val suffix = java.security.MessageDigest.getInstance("SHA-256").digest((preferences.partition ?: "local").toByteArray()).joinToString("") { "%02x".format(it) }
        val key = "cloud_phone_thread_$suffix"
        var id = prefs.getString(key, null)
        if (id == null) { id = "phone-" + java.util.UUID.randomUUID(); if (!prefs.edit().putString(key, id).commit()) throw CloudFailure.Storage() }
        return id
    }

    /** Merge first. Read every retained legacy entry, with stable imported IDs,
     * before any old UI cap can trim its compatibility file. */
    fun importLegacy(refresh: Boolean = false) = synchronized(Store.lock) {
        val partition = preferences.partition ?: return@synchronized
        journal.replay()
        if (engine.state(partition).imported && !refresh) return@synchronized
        val store = Store(context)
        val dictations = store.legacyDictationsForCloud()
        val messages = store.legacyChatForCloud()
        val edits = mutableListOf<CloudEdit>()
        dictations.filter { engine.sourceOwner(CloudCollection.DICTATIONS, it.id).let { owner -> owner == null || owner == partition } }.forEach { edits.add(dictation(it)) }
        var previous: String? = null
        messages.forEach { message ->
            if (engine.sourceOwner(CloudCollection.MESSAGES, message.id).let { it == null || it == partition }) {
                edits.addAll(chat(message, previous)); previous = message.id
            }
        }
        if (preferences.prefs.getString("cloud_preferences_owner", null).let { it == null || it == partition }) {
            val words = JSONArray(preferences.prefs.getString("vocabulary", "[]"))
            edits.add(CloudEdit(CloudCollection.PREFERENCES, "vocabulary", CloudPayload.Vocabulary(List(words.length()) { words.getString(it) })))
            edits.add(CloudEdit(CloudCollection.PREFERENCES, "agent_model", CloudPayload.Model(preferences.prefs.getString("agent_model", Assistant.DEFAULT_MODEL) ?: Assistant.DEFAULT_MODEL)))
            edits.add(CloudEdit(CloudCollection.PREFERENCES, "cleanup_enabled", CloudPayload.Cleanup(preferences.prefs.getBoolean("cleanup_enabled", true))))
        }
        // The whole imported dataset and its marker commit together. An exact
        // restart replay does not create new operation identities.
        engine.capture(edits, partition, markImported = true)
        if (!preferences.prefs.edit().putString("cloud_preferences_owner", partition).commit()) throw CloudFailure.Storage()
    }

    fun sync(trigger: String): String = synchronized(deliveryLock) {
        val partition = preferences.partition ?: return@synchronized "Sign in to Atika. Local data stays on this phone."
        preferences.prefs.edit().putLong("sync_last_attempt", System.currentTimeMillis()).putString("sync_last_trigger", trigger).apply()
        try {
            journal.replay()
            if (!configured()) throw CloudFailure.SignIn()
            val api = client(); api.capabilities()
            if (engine.state(partition).requiresBaselineReview) throw CloudFailure.Baseline()
            var more = false
            // Bounded catch-up: jobs continue the saved cursor without keeping
            // the capture executor occupied indefinitely.
            repeat(5) {
                if (it == 0 || more) {
                    val page = api.pull(engine.state(partition).cursor); engine.apply(page, partition); more = page.hasMore
                }
            }
            if (!more) {
                importLegacy()
                repeat(5) {
                    val operations = engine.nextOperations(partition, included = preferences.included(partition))
                    if (operations.isNotEmpty()) engine.acknowledge(api.mutate(operations), operations, partition)
                }
                val page = api.pull(engine.state(partition).cursor); engine.apply(page, partition); more = page.hasMore
            }
            if (preferences.partition == partition && preferences.transport == SyncTransport.CLOUD) projectPreferences(partition)
            preferences.prefs.edit().putBoolean(preferences.statusKey("more", partition), more).putLong(preferences.statusKey("last_success", partition), System.currentTimeMillis()).putString(preferences.statusKey("last_error", partition), null).apply()
            lastError = null
            status()
        } catch (error: Exception) {
            if (error is CloudFailure.Baseline) engine.requireBaselineReview(partition)
            if (error is CloudFailure.SignIn) preferences.prefs.edit().putBoolean(preferences.statusKey("auth_required", partition), true).apply()
            lastError = if (error is CloudFailure) error.message else "Offline · your changes are saved on this phone."
            preferences.prefs.edit().putString(preferences.statusKey("last_error", partition), lastError).apply()
            if (error is InterruptedException) Thread.currentThread().interrupt()
            lastError!!
        }
    }

    fun status(): String {
        if (preferences.transport == SyncTransport.OFF) return "Local only"
        val state = state() ?: return "Sign in to Atika"
        val included = preferences.included()
        val pending = state.records.values.filter { it.collection in included }.sumOf { it.pending.size }
        val kept = state.pendingCount - pending
        if (state.reviewCopies.any { !it.corrected }) return "Review ${state.reviewCopies.count { !it.corrected }} local records · valid changes continue syncing"
        if (state.requiresBaselineReview) return "Review cloud history · ${state.pendingCount} saved here"
        if (state.conflicts.isNotEmpty()) return "Resolve ${state.conflicts.size} conflicts · changes saved here"
        if (!configured()) return "Sign in again · ${state.pendingCount} saved here"
        preferences.prefs.getString(preferences.statusKey("last_error"), null)?.let { return "$it · ${state.pendingCount} pending" }
        if (pending > 0 || preferences.prefs.getBoolean(preferences.statusKey("more"), false)) return "Syncing · $pending pending" + if (kept > 0) " · $kept kept local" else ""
        val last = preferences.prefs.getLong(preferences.statusKey("last_success"), 0)
        return (if (last == 0L) "Ready to sync" else "Synced · " + java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date(last))) + if (kept > 0) " · $kept kept local" else ""
    }
    fun projectPreferences(partition: String) {
        val state = engine.state(partition); val edit = preferences.prefs.edit()
        (state.records["preferences:vocabulary"]?.payload as? CloudPayload.Vocabulary)?.let { edit.putString("vocabulary", JSONArray(it.value).toString()) }
        (state.records["preferences:agent_model"]?.payload as? CloudPayload.Model)?.let { edit.putString("agent_model", it.value) }
        (state.records["preferences:cleanup_enabled"]?.payload as? CloudPayload.Cleanup)?.let { edit.putBoolean("cleanup_enabled", it.value) }
        edit.putString("cloud_preferences_owner", partition).apply()
    }
}
