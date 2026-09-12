package com.voiceflow.mobile

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONArray
import java.util.concurrent.Executors

/** One explicit transport choice. Cloud account/queue recovery stays reachable
 * even when the Mac is offline or this phone has never been paired. */
class CloudSettingsActivity : Activity() {
    private val executor = Executors.newSingleThreadExecutor()
    private lateinit var root: LinearLayout
    private lateinit var status: TextView
    private lateinit var cloud: CloudSync
    private var challenge: CloudChallenge? = null
    private var loginClient: CloudHTTP? = null
    private var busy = false
    private val primary = Color.parseColor("#F2F2F4")
    private val muted = Color.parseColor("#8E8E96")
    private val accent = Color.parseColor("#E8A33D")
    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); cloud = CloudSync(applicationContext); render()
    }
    override fun onDestroy() { executor.shutdown(); super.onDestroy() }
    private fun label(text: String, size: Float = 14f, strong: Boolean = false): TextView = TextView(this).apply {
        this.text = text; textSize = size; setTextColor(if (strong) primary else muted)
        if (strong) setTypeface(null, Typeface.BOLD)
        setPadding(0, dp(8), 0, dp(8)); setTextIsSelectable(true)
    }
    private fun action(title: String, body: () -> Unit): Button = Button(this).apply {
        text = title; isAllCaps = false; setTextColor(accent); setOnClickListener { if (!busy) body() }
        root.addView(this, LinearLayout.LayoutParams(-1, -2))
    }
    private fun field(hint: String, value: String = "", kind: Int = InputType.TYPE_CLASS_TEXT): EditText = EditText(this).apply {
        this.hint = hint; setText(value); inputType = kind; setTextColor(primary); setHintTextColor(muted); textSize = 15f
        root.addView(this, LinearLayout.LayoutParams(-1, -2))
    }
    private fun section(title: String) { root.addView(label(title, 19f, true)) }
    private fun work(message: String, body: () -> String?) {
        if (busy) return
        busy = true; status.text = message
        executor.execute {
            val result = runCatching(body)
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                busy = false
                if (result.isSuccess) { render(); result.getOrNull()?.let { status.text = it } }
                else status.text = (result.exceptionOrNull() as? CloudFailure)?.message ?: "Could not finish. Your data remains saved on this phone."
            }
        }
    }
    private fun render() {
        root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(22), dp(14), dp(22), dp(30)); setBackgroundColor(Color.parseColor("#0F0F12")) }
        setContentView(ScrollView(this).apply { addView(root) })
        action("‹ Back") { finish() }
        root.addView(label("Settings & sync", 26f, true))
        status = label(runCatching { cloud.status() }.getOrDefault("Local data is retained. Review sync settings."), 15f, true); root.addView(status)
        root.addView(label("Sync dictation text, completed conversations, vocabulary, your model choice, and cleanup preference. Recordings and attachments stay on their source device."))
        val group = RadioGroup(this)
        val choices = listOf(SyncTransport.OFF to "Local only", SyncTransport.CLOUD to "Atika cloud", SyncTransport.LOCAL to "Paired Mac · LAN / Tailscale")
        choices.forEachIndexed { index, (_, title) -> group.addView(RadioButton(this).apply { id = index + 100; text = title; setTextColor(primary) }) }
        group.check(choices.indexOfFirst { it.first == cloud.preferences.transport } + 100)
        root.addView(group)
        group.setOnCheckedChangeListener { _, selected ->
            val mode = choices.getOrNull(selected - 100)?.first ?: return@setOnCheckedChangeListener
            work("Changing sync transport…") {
                synchronized(SyncClient.syncLock) {
                    cloud.preferences.transport = mode
                    if (mode == SyncTransport.CLOUD && cloud.credentials() != null) cloud.importLegacy(refresh = true)
                }
                SyncJob.schedule(this); if (mode == SyncTransport.CLOUD) SyncJob.request(this)
                if (mode == SyncTransport.LOCAL && !cloud.preferences.prefs.getBoolean("paired", false)) "Return to Voice Flow to pair this phone with your Mac." else null
            }
        }
        if (cloud.preferences.transport == SyncTransport.CLOUD) buildCloud()
        else if (cloud.preferences.transport == SyncTransport.LOCAL) {
            root.addView(label("Your existing pairing stays saved. Only the selected transport delivers changes."))
            action("Sync with paired Mac") { work("Connecting to Mac…") { SyncClient(this, Store(this), Keys(this)).sync("settings") } }
        }
        buildLocalSettings()
    }

    private fun buildCloud() {
        section("Atika account")
        val credentials = runCatching { cloud.credentials() }.getOrNull()
        val selectionPartition = credentials?.takeIf { cloud.configured() }?.partition
        root.addView(label("Choose what this phone uploads. Unselected data and queued edits remain local. Cloud history stays available to read."))
        listOf("Dictation text" to setOf(CloudCollection.DICTATIONS), "Completed conversations" to setOf(CloudCollection.THREADS, CloudCollection.MESSAGES), "Vocabulary, model & cleanup" to setOf(CloudCollection.PREFERENCES)).forEach { (title, collections) ->
            root.addView(android.widget.CheckBox(this).apply {
                text = title; setTextColor(primary); isChecked = cloud.preferences.included(selectionPartition).containsAll(collections)
                setOnCheckedChangeListener { _, checked -> work("Saving upload selection…") {
                    synchronized(SyncClient.syncLock) {
                        val selected = cloud.preferences.included(selectionPartition).toMutableSet()
                        if (checked) selected.addAll(collections) else selected.removeAll(collections)
                        cloud.preferences.setIncluded(selected, selectionPartition)
                    }
                    if (selectionPartition != null) SyncJob.request(this@CloudSettingsActivity)
                    "Upload selection saved."
                } }
            })
        }
        if (credentials != null && cloud.configured()) {
            root.addView(label(credentials.email, 16f, true))
            root.addView(label("${credentials.origin}\nThis Android device: ${credentials.deviceId}"))
            action("Sync now") { work("Syncing…") { val result = cloud.sync("settings"); if (cloud.hasDelivery()) SyncJob.request(this); result } }
            action("Sign out · keep local data") { work("Signing out…") {
                synchronized(SyncClient.syncLock) { cloud.client().logout() }
                cloud.preferences.prefs.edit().putBoolean(cloud.preferences.statusKey("auth_required"), true).commit()
                "Signed out. This account’s local data and queued changes are retained."
            } }
        } else {
            val pending = challenge
            if (pending == null) {
                val origin = field("Atika address", cloud.preferences.origin, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI)
                val email = field("Email", cloud.preferences.prefs.getString("cloud_email", "") ?: "", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS)
                action("Send sign-in code") {
                    val address = origin.text.toString(); val mail = email.text.toString().trim()
                    work("Requesting your sign-in code…") {
                        val api = CloudHTTP(address, cloud.vault); val next = api.start(mail)
                        loginClient = api; challenge = next; "Enter the code sent to ${next.email}."
                    }
                }
            } else {
                root.addView(label("Enter the code sent to ${pending.email}."))
                val code = field("Sign-in code", kind = InputType.TYPE_CLASS_NUMBER)
                action("Sign in and sync") {
                    val value = code.text.toString().trim()
                    work("Signing in…") {
                        val next = (loginClient ?: throw CloudFailure.SignIn()).complete(pending, value, "${Build.MANUFACTURER} ${Build.MODEL}")
                        synchronized(SyncClient.syncLock) { cloud.preferences.use(next); cloud.importLegacy() }
                        challenge = null; loginClient = null; SyncJob.schedule(this); SyncJob.request(this)
                        "Signed in. Local edits are saved and queued for cloud sync."
                    }
                }
                action("Use another email or request a new code") { challenge = null; loginClient = null; render() }
            }
        }
        val state = runCatching { cloud.state() }.getOrNull() ?: return
        root.addView(label("${state.records.size} retained records · ${state.pendingCount} queued edits · ${state.conflicts.size} conflicts"))
        if (state.reviewCopies.any { !it.corrected }) section("Saved on this phone · needs review")
        state.reviewCopies.filter { !it.corrected }.forEach { review ->
            action("Review ${review.collection.wire} · ${review.recordId.take(18)}") {
                val value = org.json.JSONObject(review.portableJSON)
                val content = label("This copy exceeds the portable record limits or has unsupported fields. It stays saved here while other records sync. A valid edit replaces it for delivery; this original is retained.\n\n" + value.optString("text", review.portableJSON), 14f, true)
                val dialog = AlertDialog.Builder(this).setTitle("Local review copy").setView(ScrollView(this).apply { setPadding(dp(20), 0, dp(20), 0); addView(content) }).setPositiveButton("Close", null)
                if (value.has("text")) dialog.setNegativeButton("Edit text") { _, _ ->
                    val editor = EditText(this).apply { setText(value.getString("text")); inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE }
                    AlertDialog.Builder(this).setTitle("Correct retained text").setView(editor).setNegativeButton("Cancel", null).setPositiveButton("Save") { _, _ ->
                        val corrected = editor.text.toString()
                        work("Saving corrected copy…") {
                            value.put("text", corrected)
                            cloud.capture(listOf(CloudEdit(review.collection, review.recordId, CloudPayload.local(review.collection, review.recordId, value))))
                            SyncJob.request(this); "Saved. The original copy is retained."
                        }
                    }.show()
                }
                dialog.show()
            }
        }
        if (state.requiresBaselineReview) {
            root.addView(label("The cloud history was restored or replaced. Reloading starts its cursor again while retaining your local values, queued edits and conflict copies."))
            action("Review and reload cloud baseline") {
                AlertDialog.Builder(this).setTitle("Reload cloud baseline?").setMessage("Your local changes remain saved. Conflicting cloud revisions will need review.")
                    .setNegativeButton("Cancel", null).setPositiveButton("Reload") { _, _ -> work("Reloading cloud history…") {
                        cloud.engine.resetBaseline(cloud.preferences.partition!!); SyncJob.request(this); null
                    } }.show()
            }
        }
        if (state.conflicts.isNotEmpty()) section("Conflicts")
        state.conflicts.forEach { conflict ->
            action("Review ${conflict.collection.wire} · ${conflict.recordId.take(18)}") { inspectConflict(conflict) }
        }
        val deleted = state.records.values.filter { it.payload == null && it.remote?.deletedAt != null && it.lastLivePayload != null }
        if (deleted.isNotEmpty()) section("Deleted records")
        deleted.forEach { row ->
            action("Restore ${row.collection.wire} · ${row.recordId.take(18)}") {
                AlertDialog.Builder(this).setTitle("Restore this cloud record?").setMessage(preview(row.lastLivePayload))
                    .setNegativeButton("Cancel", null).setPositiveButton("Restore") { _, _ -> work("Saving restore…") {
                        cloud.capture(listOf(CloudEdit(row.collection, row.recordId, row.lastLivePayload, restore = true))); SyncJob.request(this); "Restore queued."
                    } }.show()
            }
        }
        val threads = state.records.values.filter { it.collection == CloudCollection.THREADS && it.payload is CloudPayload.Thread }
        if (threads.isNotEmpty()) section("Cloud threads")
        root.addView(label("Cloud conversations are available to read here. They do not silently replace the phone assistant’s current conversation."))
        threads.sortedBy { (it.payload as CloudPayload.Thread).title }.forEach { row ->
            action((row.payload as CloudPayload.Thread).title) { showThread(row.recordId) }
        }
    }
    private fun inspectConflict(conflict: CloudConflict) {
        work("Loading the latest cloud copy…") {
            val remote = cloud.client().record(conflict.collection, conflict.recordId)
            val local = cloud.state()?.records?.get(CloudEngine.key(conflict.collection, conflict.recordId))?.payload
            runOnUiThread {
                val text = "THIS DEVICE\n${preview(local)}\n\nCLOUD\n${preview(remote.payload)}\n\nRETAINED PROPOSAL\n${preview(conflict.proposed.payload)}"
                AlertDialog.Builder(this).setTitle("Choose the version to keep").setMessage(text)
                    .setNeutralButton("Use this device") { _, _ -> resolve(conflict, remote, CloudResolution.THIS_DEVICE) }
                    .setNegativeButton("Use cloud") { _, _ -> resolve(conflict, remote, CloudResolution.CLOUD) }
                    .setPositiveButton("Use proposal") { _, _ -> resolve(conflict, remote, CloudResolution.PROPOSAL) }.show()
            }
            null
        }
    }
    private fun resolve(conflict: CloudConflict, remote: CloudRecord, choice: CloudResolution) = work("Saving conflict resolution…") {
        cloud.engine.resolve(conflict, remote, choice, cloud.preferences.partition!!); SyncJob.request(this); "Resolution queued. Concurrent changes remain protected."
    }
    private fun preview(payload: CloudPayload?): String = when (payload) {
        null -> "Deleted"
        is CloudPayload.Dictation -> payload.text
        is CloudPayload.Message -> payload.text
        is CloudPayload.Thread -> payload.title
        else -> payload.json().toString()
    }.take(10_000)
    private fun showThread(id: String) {
        val state = cloud.state() ?: return
        val messages = state.records.values.filter { (it.payload as? CloudPayload.Message)?.threadId == id }
            .sortedBy { (it.payload as CloudPayload.Message).createdAt }
        val text = messages.joinToString("\n\n") { row -> val value = row.payload as CloudPayload.Message
            "${value.role.uppercase()} · ${row.recordId}\n${value.parentMessageId?.let { "Replies to $it\n" } ?: ""}${value.text}"
        }.ifBlank { "No completed messages have synced yet." }
        val content = label(text, 14f, true)
        AlertDialog.Builder(this).setTitle((state.records["threads:$id"]?.payload as? CloudPayload.Thread)?.title ?: "Cloud thread")
            .setView(ScrollView(this).apply { setPadding(dp(20), 0, dp(20), 0); addView(content) }).setPositiveButton("Close", null).show()
    }

    private fun buildLocalSettings() {
        section("Assistant & dictation")
        val prefs = cloud.preferences.prefs
        val model = field("OpenRouter model ID", prefs.getString("agent_model", Assistant.DEFAULT_MODEL) ?: Assistant.DEFAULT_MODEL)
        val vocabulary = field("Vocabulary · one term per line", runCatching { val values = JSONArray(prefs.getString("vocabulary", "[]")); List(values.length()) { values.getString(it) }.joinToString("\n") }.getOrDefault(""), InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE)
        val cleanup = android.widget.Switch(this).apply { text = "Clean up dictation"; isChecked = prefs.getBoolean("cleanup_enabled", true); setTextColor(primary) }; root.addView(cleanup)
        action("Save preferences") {
            val modelValue = model.text.toString().trim(); val words = vocabulary.text.toString().lines().map { it.trim() }.filter { it.isNotEmpty() }; val enabled = cleanup.isChecked
            work("Saving preferences…") {
                val edits = listOf(CloudEdit(CloudCollection.PREFERENCES, "agent_model", CloudPayload.Model(modelValue)), CloudEdit(CloudCollection.PREFERENCES, "vocabulary", CloudPayload.Vocabulary(words)), CloudEdit(CloudCollection.PREFERENCES, "cleanup_enabled", CloudPayload.Cleanup(enabled)))
                edits.forEach { it.payload!!.validate(it.collection, it.recordId) }; cloud.capture(edits)
                if (!prefs.edit().putString("agent_model", modelValue).putString("vocabulary", JSONArray(words).toString()).putBoolean("cleanup_enabled", enabled).commit()) throw CloudFailure.Storage()
                SyncJob.request(this); "Preferences saved."
            }
        }
        section("Provider keys on this phone")
        root.addView(label("Dictation uses an OpenAI key; the phone assistant uses an OpenRouter key. They stay in Android secure storage and are excluded from cloud sync."))
        val openAI = field("OpenAI key · leave blank to keep saved key", kind = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        val router = field("OpenRouter key · leave blank to keep saved key", kind = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        action("Save keys on this phone") {
            val first = openAI.text.toString().trim(); val second = router.text.toString().trim()
            work("Saving provider keys…") {
                val keys = Keys(this); if (first.isNotBlank()) keys.saveDurable(Keys.OPENAI, first); if (second.isNotBlank()) keys.saveDurable(Keys.AGENT, second)
                "Provider keys saved on this phone."
            }
        }
    }
}
