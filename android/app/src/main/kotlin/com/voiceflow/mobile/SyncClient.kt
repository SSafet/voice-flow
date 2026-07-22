package com.voiceflow.mobile

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/// Talks to the Mac's sync server (swift/Sync.swift, port 8793, bearer
/// token) over Tailscale. Pushes unsynced dictations + chat, pulls the
/// Mac's recent dictation history plus settings parity (custom_vocabulary,
/// agent_model). The Mac stays the source of truth; the phone only ever
/// re-sends what the Mac hasn't acknowledged.
class SyncClient(context: Context, private val store: Store, private val keys: Keys) {
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
    fun sync(): String? {
        if (!configured()) { lastError = null; return null }
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

        // Try every known address, Tailscale first — whichever answers wins.
        var payload: JSONObject? = null
        for (host in hosts()) {
            payload = try {
                Net.postJson("http://$host:$port/sync", body, mapOf("Authorization" to "Bearer $token"), 20_000)
            } catch (e: Net.HttpError) {
                if (e.code == 401) {   // token revoked on the Mac → re-pair
                    prefs.edit().putBoolean("paired", false).apply()
                    lastError = "unpaired"
                    return null
                }
                lastError = e.message?.take(120); continue
            } catch (e: Exception) {
                lastError = e.message?.take(120); continue
            }
            break
        }
        if (payload == null) return null   // Mac unreachable — offline is a delay, not a failure
        lastError = null

        // Everything we sent is now on the Mac.
        if (outDictations.isNotEmpty() || outChat.isNotEmpty()) {
            dictations.forEach { it.synced = true }
            chat.forEach { it.synced = true }
        }

        // Merge the Mac's history into ours (dedupe on time+text; Mac
        // entries carry no date, so unseen ones append below local history).
        val seen = dictations.map { it.time + "" + it.text }.toHashSet()
        var pulled = 0
        payload.optJSONArray("dictations")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val key = o.optString("time") + "" + o.optString("text")
                if (key in seen || o.optString("text").isBlank()) continue
                seen.add(key)
                dictations.add(DictationEntry(
                    java.util.UUID.randomUUID().toString(),
                    o.optString("time"), o.optString("timestamp").take(10),
                    o.optString("text"),
                    o.optString("destination", "pasted"),
                    true,
                ))
                pulled++
            }
        }
        store.saveDictations(dictations)
        store.saveChat(chat)

        // Adopt the Mac's API keys for any slot still empty on the phone.
        payload.optJSONObject("keys")?.let { served ->
            if (keys.load(Keys.OPENAI).isNullOrBlank() && served.optString("openai").isNotBlank())
                keys.save(Keys.OPENAI, served.optString("openai"))
            if (keys.load(Keys.AGENT).isNullOrBlank() && served.optString("agent").isNotBlank())
                keys.save(Keys.AGENT, served.optString("agent"))
        }

        payload.optJSONArray("vocabulary")?.let {
            prefs.edit().putString("vocabulary", it.toString()).apply()
        }
        payload.optString("agent_model").takeIf { it.isNotBlank() }?.let {
            prefs.edit().putString("agent_model", it).apply()
        }
        if (payload.has("cleanup_enabled")) {
            prefs.edit().putBoolean("cleanup_enabled", payload.optBoolean("cleanup_enabled", true)).apply()
        }

        return "synced ↑${outDictations.size + outChat.size} ↓$pulled"
    }
}
