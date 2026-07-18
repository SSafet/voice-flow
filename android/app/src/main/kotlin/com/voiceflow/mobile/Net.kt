package com.voiceflow.mobile

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/// Shared HTTP plumbing for the three backends (OpenAI STT, OpenRouter
/// chat, Mac sync). Blocking; always called from the background executor.
object Net {
    class HttpError(val code: Int, message: String) : Exception(message)

    fun postJson(url: String, body: JSONObject, headers: Map<String, String>, timeoutMs: Int = 90_000): JSONObject {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.connectTimeout = 15_000
        conn.readTimeout = timeoutMs
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/json")
        headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
        conn.outputStream.use { it.write(body.toString().toByteArray()) }
        return readResponse(conn)
    }

    /// multipart/form-data upload, same layout as the Mac backend's
    /// _build_multipart_body in voice_flow/openai_transcriber.py.
    fun postMultipart(
        url: String,
        fields: Map<String, String>,
        file: File,
        fileField: String,
        mimeType: String,
        headers: Map<String, String>,
    ): JSONObject {
        val boundary = "voiceflow-${UUID.randomUUID().toString().replace("-", "")}"
        val out = ByteArrayOutputStream()
        fun line(s: String) = out.write((s + "\r\n").toByteArray())
        fields.forEach { (name, value) ->
            line("--$boundary")
            line("Content-Disposition: form-data; name=\"$name\"")
            line("")
            line(value)
        }
        line("--$boundary")
        line("Content-Disposition: form-data; name=\"$fileField\"; filename=\"${file.name}\"")
        line("Content-Type: $mimeType")
        line("")
        out.write(file.readBytes())
        line("")
        line("--$boundary--")

        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.connectTimeout = 15_000
        conn.readTimeout = 90_000
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
        headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
        conn.outputStream.use { it.write(out.toByteArray()) }
        return readResponse(conn)
    }

    private fun readResponse(conn: HttpURLConnection): JSONObject {
        val code = conn.responseCode
        val body = (if (code in 200..299) conn.inputStream else conn.errorStream)
            ?.bufferedReader()?.readText() ?: ""
        if (code !in 200..299) {
            val message = try {
                JSONObject(body).optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() } ?: body
            } catch (_: Exception) { body }
            throw HttpError(code, "HTTP $code: ${message.take(300)}")
        }
        return try { JSONObject(body) } catch (_: Exception) { JSONObject() }
    }
}
