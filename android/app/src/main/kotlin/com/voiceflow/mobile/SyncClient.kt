package com.voiceflow.mobile

import android.content.Context
import org.json.JSONArray

/// The phone's sync entry point. The platform (Atika) owns every record, so
/// this is a thin delegator to `CloudSync`; the old hand-rolled LAN path to
/// the Mac is deleted and nothing here builds a second one.
class SyncClient(private val context: Context) {
    private val prefs = context.getSharedPreferences("app", Context.MODE_PRIVATE)

    var lastError: String? = null
        private set

    fun configured(): Boolean =
        CloudPreferences(context).transport != SyncTransport.OFF && CloudSync(context).configured()

    fun hasPendingDelivery(): Boolean = CloudSync(context).hasDelivery()
    fun retryable(): Boolean = configured() && (lastError != null || hasPendingDelivery())

    fun macName(): String = "Atika"

    fun vocabulary(): List<String> {
        val arr = try { JSONArray(prefs.getString("vocabulary", "[]")) } catch (_: Exception) { JSONArray() }
        return List(arr.length()) { arr.getString(it) }.filter { it.isNotBlank() }
    }

    fun agentModel(): String =
        prefs.getString("agent_model", null)?.takeIf { it.isNotBlank() } ?: Assistant.DEFAULT_MODEL

    /// One sync round trip. Returns a human status line. Blocking — background
    /// executor only.
    fun sync(trigger: String = "activity"): String? = synchronized(syncLock) {
        if (CloudPreferences(context).transport == SyncTransport.OFF) {
            lastError = null
            return@synchronized "Local only"
        }
        val cloud = CloudSync(context)
        val status = cloud.sync(trigger)
        lastError = cloud.lastError
        status
    }

    companion object { val syncLock = Any() }
}
