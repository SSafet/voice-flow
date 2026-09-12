package com.voiceflow.mobile

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class CloudHTTPTest {
    private val origin = "https://api.atika.ai"
    private val saved = CloudCredentials(origin, "owner-a", "owner@example.test", "01AAAAAAAAAAAAAAAAAAAAAAAA", "refresh-0")
    private class Vault(var credentials: CloudCredentials?) : CloudVault {
        var failSave = false
        @Synchronized override fun load(partition: String) = credentials?.takeIf { it.partition == partition }
        @Synchronized override fun save(credentials: CloudCredentials) { if (failSave) throw CloudFailure.Storage(); this.credentials = credentials }
        @Synchronized override fun remove(partition: String) { if (credentials?.partition == partition) credentials = null }
    }
    private fun rotated(index: Int, user: String = saved.userId) = JSONObject().put("user", JSONObject().put("id", user).put("email", saved.email))
        .put("deviceId", saved.deviceId).put("refreshToken", "refresh-$index").put("accessToken", "access-$index").put("accessExpiresIn", 900)

    @Test fun simultaneousRequestsRefreshOnceAndPersistBeforeUse() {
        val vault = Vault(saved); val refreshes = AtomicInteger(); val executor = Executors.newFixedThreadPool(6)
        val client = CloudHTTP(origin, vault, saved.partition, network = { _, url, _, token ->
            if (url.endsWith("/refresh")) rotated(refreshes.incrementAndGet())
            else { assertEquals("refresh-1", vault.credentials!!.refreshToken); assertEquals("access-1", token); JSONObject().put("protocolVersion", 1) }
        })
        try { val start = CountDownLatch(1); val futures = (0 until 6).map { executor.submit { start.await(); client.capabilities() } }; start.countDown(); futures.forEach { it.get(3, TimeUnit.SECONDS) }; assertEquals(1, refreshes.get()) }
        finally { executor.shutdownNow() }
    }

    @Test fun lostRefreshResponseRetriesRetainedTokenAndMismatchedIdentityNeverReplacesVault() {
        val vault = Vault(saved); var calls = 0
        val client = CloudHTTP(origin, vault, saved.partition, network = { _, url, body, _ ->
            if (url.endsWith("/refresh")) { calls++; assertEquals("refresh-0", body!!.getString("refreshToken")); if (calls == 1) throw java.io.IOException("lost response"); rotated(1) }
            else JSONObject().put("protocolVersion", 1)
        })
        try { client.capabilities(); fail("Expected offline") } catch (_: java.io.IOException) { }
        assertEquals(saved, vault.credentials); client.capabilities(); assertEquals("refresh-1", vault.credentials!!.refreshToken)
        val impostor = CloudHTTP(origin, vault, saved.partition, network = { _, _, _, _ -> rotated(2, "owner-b") })
        try { impostor.capabilities(); fail("Expected identity validation") } catch (_: CloudFailure.InvalidResponse) { }
        assertEquals("refresh-1", vault.credentials!!.refreshToken)
    }

    @Test fun failedDurableSaveCannotUseUncommittedAccessToken() {
        val vault = Vault(saved).apply { failSave = true }; var authorized = 0
        val client = CloudHTTP(origin, vault, saved.partition, network = { _, url, _, _ ->
            if (url.endsWith("/refresh")) rotated(1) else { authorized++; JSONObject().put("protocolVersion", 1) }
        })
        try { client.capabilities(); fail("Expected storage failure") } catch (_: CloudFailure.Storage) { }
        assertEquals(0, authorized); assertEquals(saved, vault.credentials)
    }

    @Test fun logoutDuringRefreshRevokesSuccessorAndCannotResurrectCredentials() {
        val vault = Vault(saved); val refreshing = CountDownLatch(1); val release = CountDownLatch(1); val executor = Executors.newFixedThreadPool(2)
        var revoked: String? = null
        val client = CloudHTTP(origin, vault, saved.partition, network = { _, url, body, _ ->
            when {
                url.endsWith("/refresh") -> { refreshing.countDown(); check(release.await(3, TimeUnit.SECONDS)); rotated(1) }
                url.endsWith("/logout") -> { revoked = body!!.getString("refreshToken"); JSONObject() }
                else -> error("Logged-out request reached sync endpoint")
            }
        })
        try {
            val request = executor.submit { try { client.capabilities(); fail("Expected sign-out") } catch (_: CloudFailure.SignIn) { } }
            check(refreshing.await(3, TimeUnit.SECONDS)); val logout = executor.submit { client.logout() }
            // Wait until logout is blocked on the in-flight rotation before releasing it.
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            while (Thread.getAllStackTraces().keys.none { it.state == Thread.State.BLOCKED && it.name.startsWith("pool-") } && System.nanoTime() < deadline) Thread.yield()
            release.countDown(); request.get(3, TimeUnit.SECONDS); logout.get(3, TimeUnit.SECONDS)
            assertEquals("refresh-1", revoked); assertNull(vault.credentials)
            try { client.capabilities(); fail("Expected sign-out") } catch (_: CloudFailure.SignIn) { }
        } finally { release.countDown(); executor.shutdownNow() }
    }

    @Test fun a401RefreshesOnceWithoutChangingMutationIdentity() {
        val vault = Vault(saved); var refreshes = 0; val bodies = mutableListOf<String>()
        val operation = CloudOperation(CloudCollection.DICTATIONS, "item-a", "0", "put", CloudPayload.Dictation("Offline edit", "pasted"))
        val client = CloudHTTP(origin, vault, saved.partition, network = { _, url, body, _ ->
            if (url.endsWith("/refresh")) rotated(++refreshes)
            else { bodies.add(body.toString()); if (bodies.size == 1) throw CloudFailure.SignIn(); JSONObject().put("results", org.json.JSONArray()) }
        })
        assertTrue(client.mutate(listOf(operation)).isEmpty()); assertEquals(2, refreshes); assertEquals(bodies[0], bodies[1])
    }
}
