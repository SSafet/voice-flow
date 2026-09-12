package com.voiceflow.mobile

import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SyncIdentityTest {
    private class Server(val handler: (String, Map<String, String>, String) -> String) : java.io.Closeable {
        val socket = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        val port get() = socket.localPort.toString()
        private val worker = kotlin.concurrent.thread(isDaemon = true) {
            try {
                while (!socket.isClosed) socket.accept().use { client ->
                    client.soTimeout = 3000
                    val reader = client.getInputStream().bufferedReader()
                    val request = reader.readLine()
                    val headers = mutableMapOf<String, String>()
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        headers[line.substringBefore(":").lowercase()] = line.substringAfter(":").trim()
                    }
                    val data = CharArray(headers["content-length"]?.toInt() ?: 0)
                    var read = 0
                    while (read < data.size) {
                        val n = reader.read(data, read, data.size - read)
                        if (n < 0) break
                        read += n
                    }
                    client.getOutputStream().write(handler(request, headers, String(data)).toByteArray())
                }
            } catch (_: SocketException) { /* fixture closed */ }
        }
        override fun close() { socket.close(); worker.join(3000) }
    }

    @Test fun provesPairedMacWithoutSendingCredentials() {
        val authorization = AtomicReference<String?>("unset")
        val token = "fixture-secret"
        Server { _, headers, request ->
            authorization.set(headers["authorization"])
            val nonce = JSONObject(request).getString("nonce")
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(token.toByteArray(), "HmacSHA256"))
            val proof = mac.doFinal("voiceflow-sync-probe:$nonce".toByteArray()).joinToString("") { "%02x".format(it) }
            val body = JSONObject().put("proof", proof).toString()
            "HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body"
        }.use { server ->
            assertTrue(SyncIdentity.verify("127.0.0.1", server.port, token))
            assertNull(authorization.get())
            assertFalse(SyncIdentity.verify("127.0.0.1", server.port, "different-pairing"))
        }
    }

    @Test fun discoveryDoesNotFollowRedirects() {
        val followed = AtomicBoolean(false)
        Server { request, _, _ ->
            if (!request.contains("/sync-probe")) followed.set(true)
            "HTTP/1.1 302 Found\r\nLocation: /elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }.use { server ->
            assertFalse(SyncIdentity.verify("127.0.0.1", server.port, "fixture"))
            assertFalse(followed.get())
        }
    }
}
