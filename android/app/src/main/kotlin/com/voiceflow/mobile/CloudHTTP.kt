package com.voiceflow.mobile

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest

data class CloudCredentials(val origin: String, val userId: String, val email: String, val deviceId: String, val refreshToken: String) {
    val partition get() = CloudEngine.partition(origin, userId)
    fun json(): JSONObject = JSONObject().put("origin", origin).put("userId", userId).put("email", email).put("deviceId", deviceId).put("refreshToken", refreshToken)
    companion object { fun parse(o: JSONObject) = CloudCredentials(o.getString("origin"), CloudWire.id(o.getString("userId")), o.getString("email"), CloudWire.id(o.getString("deviceId")), o.getString("refreshToken")) }
}
interface CloudVault { fun load(partition: String): CloudCredentials?; fun save(credentials: CloudCredentials); fun remove(partition: String) }
class CloudKeystoreVault(private val keys: Keys) : CloudVault {
    private fun name(partition: String) = "cloud_refresh_" + MessageDigest.getInstance("SHA-256").digest(partition.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    override fun load(partition: String): CloudCredentials? = keys.load(name(partition))?.let { CloudCredentials.parse(JSONObject(it)) }?.also { if (it.partition != partition) throw CloudFailure.SignIn() }
    override fun save(credentials: CloudCredentials) = keys.saveDurable(name(credentials.partition), credentials.json().toString())
    override fun remove(partition: String) = keys.saveDurable(name(partition), null)
}
data class CloudChallenge(val state: String, val email: String, val expiresAt: String)

/** Separate transport from LAN sync. No cookies, redirects or DTO reuse; access
 * tokens live in memory and refresh successors commit through the vault. */
class CloudHTTP(origin: String, private val vault: CloudVault, private val partition: String? = null,
                allowLoopback: Boolean = false,
                private val network: (String, String, JSONObject?, String?) -> JSONObject = ::request) {
    val origin = CloudWire.origin(origin, allowLoopback)
    private var access: Pair<String, Long>? = null
    @Volatile private var stopped = false
    companion object {
        private val refreshLocks = mutableMapOf<String, Any>()
        private fun refreshLock(partition: String) = synchronized(refreshLocks) { refreshLocks.getOrPut(partition) { Any() } }
        private fun request(method: String, url: String, body: JSONObject?, token: String?): JSONObject {
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.requestMethod = method; connection.instanceFollowRedirects = false
            connection.connectTimeout = 10_000; connection.readTimeout = 20_000; connection.useCaches = false
            connection.setRequestProperty("Accept", "application/json")
            if (token != null) connection.setRequestProperty("Authorization", "Bearer $token")
            try {
                if (body != null) {
                    val bytes = body.toString().toByteArray(Charsets.UTF_8)
                    if (bytes.size > 1024 * 1024) throw CloudFailure.InvalidRecord()
                    connection.doOutput = true; connection.setFixedLengthStreamingMode(bytes.size); connection.setRequestProperty("Content-Type", "application/json")
                    connection.outputStream.use { it.write(bytes) }
                }
                val status = connection.responseCode
                val input = if (status in 200..299) connection.inputStream else connection.errorStream
                val bytes = input?.use { stream ->
                    val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
                    while (true) { val count = stream.read(buffer); if (count < 0) break; if (out.size() + count > 2 * 1024 * 1024) throw CloudFailure.InvalidResponse(); out.write(buffer, 0, count) }
                    out.toByteArray()
                } ?: ByteArray(0)
                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                val json = try { JSONObject(String(bytes, Charsets.UTF_8)) } catch (_: Exception) { if (status == 204) JSONObject() else throw CloudFailure.InvalidResponse() }
                if (status !in 200..299) {
                    val code = json.optJSONObject("error")?.optString("code") ?: ""
                    if (status == 401) throw CloudFailure.SignIn()
                    if (code == "sync.cursor_expired") throw CloudFailure.Baseline()
                    throw CloudFailure.Server(status, code)
                }
                return json
            } finally { connection.disconnect() }
        }
    }
    fun start(email: String): CloudChallenge {
        val response = send("/auth/native/login/start", JSONObject().put("email", email)).getJSONObject("challenge")
        return CloudChallenge(response.getString("state"), response.getString("email"), response.getString("expiresAt"))
    }
    fun complete(challenge: CloudChallenge, code: String, label: String): CloudCredentials {
        val response = send("/auth/native/login/complete", JSONObject().put("state", challenge.state).put("email", challenge.email).put("code", code)
            .put("device", JSONObject().put("kind", "android").put("label", label.take(100))))
        return accept(response)
    }
    fun capabilities() { if (authorized("/sync").getInt("protocolVersion") != 1) throw CloudFailure.UpdateRequired() }
    fun pull(cursor: String?): CloudPage = CloudPage.parse(authorized("/sync/changes?limit=20" + (cursor?.let { "&cursor=" + URLEncoder.encode(it, "UTF-8") } ?: "")))
    fun mutate(operations: List<CloudOperation>): List<CloudReceipt> {
        val response = authorized("/sync/mutations", JSONObject().put("protocolVersion", 1).put("operations", JSONArray(operations.map { it.json() }))).getJSONArray("results")
        return List(response.length()) { CloudReceipt.parse(response.getJSONObject(it)) }
    }
    fun record(collection: CloudCollection, id: String) = CloudRecord.parse(authorized("/sync/records/${collection.wire}/${CloudWire.id(id)}").getJSONObject("record"))
    fun logout() {
        val partition = partition ?: return
        stopped = true
        synchronized(refreshLock(partition)) {
            val credentials = vault.load(partition)
            try { if (credentials != null) send("/auth/native/logout", JSONObject().put("refreshToken", credentials.refreshToken), access?.first) }
            catch (_: Exception) { /* Offline local sign-out is still available. */ }
            finally { vault.remove(partition); access = null }
        }
    }
    private fun accept(response: JSONObject, expected: CloudCredentials? = null): CloudCredentials {
        val user = response.getJSONObject("user")
        val credentials = CloudCredentials(origin, CloudWire.id(user.getString("id")), user.getString("email"), CloudWire.id(response.getString("deviceId")), response.getString("refreshToken"))
        val token = response.getString("accessToken"); val seconds = response.getInt("accessExpiresIn")
        if (credentials.deviceId.length != 26 || credentials.refreshToken.isBlank() || token.isBlank() || seconds < 1 ||
            (expected != null && (expected.userId != credentials.userId || expected.deviceId != credentials.deviceId)) ||
            (partition != null && credentials.partition != partition)) throw CloudFailure.InvalidResponse()
        vault.save(credentials)
        access = token to (System.currentTimeMillis() + seconds * 1000L)
        return credentials
    }
    private fun accessToken(force: Boolean = false): String {
        val partition = partition ?: throw CloudFailure.SignIn()
        return synchronized(refreshLock(partition)) {
            if (stopped) throw CloudFailure.SignIn()
            if (!force) access?.takeIf { it.second - System.currentTimeMillis() > 30_000 }?.let { return@synchronized it.first }
            val credentials = vault.load(partition) ?: throw CloudFailure.SignIn()
            if (credentials.origin != origin) throw CloudFailure.SignIn()
            val response = send("/auth/native/refresh", JSONObject().put("deviceId", credentials.deviceId).put("refreshToken", credentials.refreshToken))
            accept(response, credentials)
            if (stopped) throw CloudFailure.SignIn()
            access!!.first
        }
    }
    private fun authorized(path: String, body: JSONObject? = null): JSONObject {
        val token = accessToken()
        return try { send(path, body, token) } catch (_: CloudFailure.SignIn) { send(path, body, accessToken(force = true)) }
    }
    private fun send(path: String, body: JSONObject? = null, token: String? = null): JSONObject {
        if (Thread.currentThread().isInterrupted) throw InterruptedException()
        if (!path.startsWith("/") || path.contains("..")) throw CloudFailure.InvalidResponse()
        return network(if (body == null) "GET" else "POST", "$origin/api/v1$path", body, token)
    }
}
