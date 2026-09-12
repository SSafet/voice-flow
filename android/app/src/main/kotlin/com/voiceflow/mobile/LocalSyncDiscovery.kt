package com.voiceflow.mobile

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object LocalSyncDiscovery {
    /** Multicast-filtered Wi-Fi fallback. One port, at most 254 neighbors, no credentials. */
    fun findPairedHost(context: Context, port: String, token: String): String? {
        val cm = context.getSystemService(android.net.ConnectivityManager::class.java)
        val network = cm.activeNetwork ?: return null
        if (cm.getNetworkCapabilities(network)?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) != true) return null
        val address = cm.getLinkProperties(network)?.linkAddresses?.firstOrNull {
            it.address is java.net.Inet4Address
        } ?: return null
        val bytes = address.address.address
        val own = bytes.fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 255) }
        val bits = address.prefixLength.coerceAtLeast(24)
        if (bits > 30) return null
        val mask = (0xffffffffL shl (32 - bits)) and 0xffffffffL
        val base = own and mask
        val count = 1L shl (32 - bits)
        val executor = java.util.concurrent.Executors.newFixedThreadPool(16)
        val completions = java.util.concurrent.ExecutorCompletionService<String?>(executor)
        var submitted = 0
        try {
            for (ip in base + 1 until base + count - 1) {
                if (ip == own) continue
                val host = (3 downTo 0).joinToString(".") { ((ip shr (it * 8)) and 255).toString() }
                completions.submit(java.util.concurrent.Callable {
                    if (SyncIdentity.verify(host, port, token, 500)) host else null
                })
                submitted++
            }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            repeat(submitted) {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) return null
                val future = completions.poll(remaining, TimeUnit.NANOSECONDS) ?: return null
                future.get()?.let { return it }
            }
        } finally { executor.shutdownNow() }
        return null
    }

    /** Bounded discovery on a worker thread; never opens a pairing window. */
    fun hosts(context: Context): List<String> {
        val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val hosts = CopyOnWriteArraySet<String>()
        val found = CountDownLatch(1)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) { found.countDown() }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                manager.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {}
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        // The Mac listener is IPv4. Do not cache IPv6-only results.
                        @Suppress("DEPRECATION")
                        val addresses = if (android.os.Build.VERSION.SDK_INT >= 34)
                            info.hostAddresses else listOfNotNull(info.host)
                        addresses.filterIsInstance<java.net.Inet4Address>().forEach {
                            it.hostAddress?.let(hosts::add)
                        }
                        // Keep collecting for the bounded window: another Mac
                        // may advertise the same service before the paired Mac.
                    }
                })
            }
        }
        try {
            manager.discoverServices("_voiceflow-sync._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)
            found.await(2, TimeUnit.SECONDS)
        } finally {
            runCatching { manager.stopServiceDiscovery(listener) }
        }
        return hosts.toList()
    }
}
