package com.voiceflow.mobile

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/// Talks to the Mac's sync server (swift/Sync.swift, port 8793, bearer
/// token) over the local network. Pushes unsynced dictations + chat, pulls the
/// Mac's recent dictation history plus settings parity (custom_vocabulary,
/// agent_model). The Mac stays the source of truth; the phone only ever
/// re-sends what the Mac hasn't acknowledged.
class SyncClient(private val context: Context, private val store: Store, private val keys: Keys) {
    private val prefs = context.getSharedPreferences("app", Context.MODE_PRIVATE)

    var lastError: String? = null
        private set

    fun configured(): Boolean =
        prefs.getBoolean("paired", false) && !keys.load(Keys.SYNC_TOKEN).isNullOrBlank()

    fun macName(): String = prefs.getString("mac_name", "Mac") ?: "Mac"

    private fun hosts(): List<String> {
        val arr = try { org.json.JSONArray(prefs.getString("sync_hosts", "[]")) } catch (_: Exception) { org.json.JSONArray() }
        return List(arr.length()) { arr.getString(it) }.filter { it.isNotBlank() }
    }

    fun vocabulary(): List<String> {
        val arr = try { JSONArray(prefs.getString("vocabulary", "[]")) } catch (_: Exception) { JSONArray() }
        return List(arr.length()) { arr.getString(it) }.filter { it.isNotBlank() }
    }

    fun agentModel(): String =
        prefs.getString("agent_model", null)?.takeIf { it.isNotBlank() } ?: Assistant.DEFAULT_MODEL

    /// One sync round trip. Returns a human status line; null on "nothing to do
    /// and not configured". Blocking — background executor only.
    fun sync(trigger: String = "activity"): String? = synchronized(syncLock) {
        val started = System.currentTimeMillis()
        prefs.edit().putLong("sync_last_attempt", started).putString("sync_last_trigger", trigger).apply()
        android.util.Log.i("VoiceFlowSync", "start trigger=$trigger pending=${store.pendingSyncCount()}")
        try { syncOnce() }
        catch (e: Exception) { lastError = "Sync could not finish; changes remain on this phone"; throw e }
        finally {
            val pending = store.pendingSyncCount()
            prefs.edit().putString("sync_last_error", lastError).putInt("sync_pending", pending).apply()
            android.util.Log.i("VoiceFlowSync", "finish trigger=$trigger success=${lastError == null} pending=$pending elapsedMs=${System.currentTimeMillis() - started}")
        }
    }

    private fun syncOnce(): String? {
        if (!configured()) { lastError = "Pair this phone with VoiceFlow on the Mac"; return null }
        val port = prefs.getString("sync_port", "8793")!!.trim().ifBlank { "8793" }
        val token = keys.load(Keys.SYNC_TOKEN) ?: return null

        val dictations = store.dictations()
        val chat = store.chat()
        val outDictations = dictations.filter { !it.synced }.asReversed()  // oldest first
        val outChat = chat.filter { !it.synced }

        val body = JSONObject()
            .put("device", "android")
            .put("dictations", JSONArray().also { arr -> outDictations.forEach { arr.put(it.toJson()) } })
            .put("chat", JSONArray().also { arr -> outChat.forEach { arr.put(it.toJson()) } })

        // Rediscovery repairs DHCP changes. A fresh HMAC challenge proves the
        // candidate knows our pairing secret before it receives that secret or history.
        val discovered = runCatching { LocalSyncDiscovery.hosts(context) }.getOrDefault(emptyList())
        val candidates = (discovered + hosts()).distinct().take(8).toMutableList()
        lastError = "Mac unavailable — check Wi-Fi, VoiceFlow, and the Mac firewall"

        var payload: JSONObject? = null
        var candidateIndex = 0
        while (true) {
            if (candidateIndex == candidates.size) {
                val now = System.currentTimeMillis()
                if (now - prefs.getLong("sync_last_scan", 0) < 5 * 60_000) break
                prefs.edit().putLong("sync_last_scan", now).apply()
                val recovered = runCatching { LocalSyncDiscovery.findPairedHost(context, port, token) }.getOrNull() ?: break
                if (recovered in candidates) break
                candidates.add(recovered)
            }
            val host = candidates[candidateIndex++]
            payload = try {
                if (!SyncIdentity.verify(host, port, token)) continue
                Net.postJson("http://$host:$port/sync", body, mapOf("Authorization" to "Bearer $token"), 20_000, 2_000)
                    .also {
                        check(it.optBoolean("ok") && it.optJSONArray("dictations") != null) { "Invalid sync response" }
                        prefs.edit().putString("sync_hosts", JSONArray(listOf(host) + hosts().filter { it != host }).toString()).apply()
                    }
            } catch (e: Net.HttpError) {
                // A stale address may now belong to another device; it must
                // never revoke this phone's pairing or acknowledge its uploads.
                continue
            } catch (e: Exception) {
                continue
            }
            break
        }
        val response = payload ?: return null   // Mac unreachable — offline is a delay, not a failure
        lastError = null

        return synchronized(Store.lock) {
            // Reload after the network request so a concurrent capture/append survives.
            val dictations = store.dictations()
            val chat = store.chat()
            val pulled = SyncMerge.apply(dictations, chat, outDictations, outChat, response)
            store.saveDictations(dictations)
            store.saveChat(chat)

            // Adopt the Mac's API keys for any slot still empty on the phone.
            response.optJSONObject("keys")?.let { served ->
                if (keys.load(Keys.OPENAI).isNullOrBlank() && served.optString("openai").isNotBlank())
                    keys.save(Keys.OPENAI, served.optString("openai"))
                if (keys.load(Keys.AGENT).isNullOrBlank() && served.optString("agent").isNotBlank())
                    keys.save(Keys.AGENT, served.optString("agent"))
            }

            response.optJSONArray("vocabulary")?.let {
                prefs.edit().putString("vocabulary", it.toString()).apply()
            }
            response.optString("agent_model").takeIf { it.isNotBlank() }?.let {
                prefs.edit().putString("agent_model", it).apply()
            }
            if (response.has("cleanup_enabled")) {
                prefs.edit().putBoolean("cleanup_enabled", response.optBoolean("cleanup_enabled", true)).apply()
            }

            prefs.edit().putLong("sync_last_success", System.currentTimeMillis()).apply()
            "synced ↑${outDictations.size + outChat.size} ↓$pulled"
        }
    }

    companion object { private val syncLock = Any() }
}
