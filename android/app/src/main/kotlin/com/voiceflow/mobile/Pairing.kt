package com.voiceflow.mobile

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet

/// Zero-typing setup. The Mac advertises _voiceflow-sync._tcp on the LAN
/// and opens a short pairing window from its menu bar ("Pair Phone");
/// POST /pair during that window returns everything the phone needs —
/// token, host list (Tailscale first), port. The user never sees any of it.
class Pairing(private val context: Context, private val keys: Keys) {
    private val prefs = context.getSharedPreferences("app", Context.MODE_PRIVATE)
    private val discovered = CopyOnWriteArraySet<String>()
    private var nsd: NsdManager? = null
    private var listener: NsdManager.DiscoveryListener? = null

    val paired: Boolean get() = prefs.getBoolean("paired", false)

    fun unpair() {
        prefs.edit().putBoolean("paired", false).apply()
    }

    fun startDiscovery() {
        if (listener != null) return
        val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        nsd = manager
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                manager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {}
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        info.host?.hostAddress?.let { discovered.add(it) }
                    }
                })
            }
        }
        listener = l
        try {
            manager.discoverServices("_voiceflow-sync._tcp.", NsdManager.PROTOCOL_DNS_SD, l)
        } catch (_: Exception) { listener = null }
    }

    fun stopDiscovery() {
        try { listener?.let { nsd?.stopServiceDiscovery(it) } } catch (_: Exception) {}
        listener = null
    }

    /// Hosts worth knocking on: anything Bonjour found, previously paired
    /// hosts, and the emulator's host-loopback alias.
    private fun candidates(): List<String> {
        val known = savedHosts()
        return (discovered.toList() + known + listOf("10.0.2.2")).distinct()
    }

    fun savedHosts(): List<String> {
        val arr = try { JSONArray(prefs.getString("sync_hosts", "[]")) } catch (_: Exception) { JSONArray() }
        return List(arr.length()) { arr.getString(it) }.filter { it.isNotBlank() }
    }

    /// One pairing attempt across all candidates. Returns a status string:
    /// "paired:<mac name>" on success, "window-closed" if a Mac answered but
    /// pairing isn't open, null if no Mac was reachable at all.
    /// Blocking — background executor only.
    fun tryPair(): String? {
        var sawMac = false
        for (host in candidates()) {
            val port = prefs.getString("sync_port", "8793")!!.ifBlank { "8793" }
            val payload = try {
                Net.postJson(
                    "http://$host:$port/pair",
                    JSONObject().put("device", "${Build.MANUFACTURER} ${Build.MODEL}".trim()),
                    emptyMap(), timeoutMs = 4_000,
                )
            } catch (e: Net.HttpError) {
                if (e.code == 403) sawMac = true
                continue
            } catch (_: Exception) {
                continue
            }
            val token = payload.optString("token")
            if (token.isBlank()) continue
            keys.save(Keys.SYNC_TOKEN, token)
            val hosts = mutableListOf<String>()
            payload.optJSONArray("hosts")?.let { arr ->
                for (i in 0 until arr.length()) hosts.add(arr.getString(i))
            }
            if (host !in hosts) hosts.add(host)   // the address that actually worked
            prefs.edit()
                .putString("sync_hosts", JSONArray(hosts).toString())
                .putString("sync_port", payload.optInt("port", 8793).toString())
                .putString("mac_name", payload.optString("mac_name", "Mac"))
                .putBoolean("paired", true)
                .apply()
            return "paired:${payload.optString("mac_name", "Mac")}"
        }
        return if (sawMac) "window-closed" else null
    }
}
