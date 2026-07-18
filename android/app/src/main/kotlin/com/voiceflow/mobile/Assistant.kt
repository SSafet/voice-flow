package com.voiceflow.mobile

import org.json.JSONArray
import org.json.JSONObject

/// The Voice Flow assistant on the phone: a plain OpenRouter chat client
/// using the same model the Mac's agent uses (agent_model, synced from the
/// Mac; defaults to the Mac's current setting). No tools, no screen —
/// prompts by voice or text, photos attachable as image_url parts.
object Assistant {
    const val DEFAULT_MODEL = "anthropic/claude-sonnet-5"

    fun reply(
        history: List<ChatMessage>,
        userText: String,
        imageBase64Jpeg: String?,
        apiKey: String,
        model: String,
    ): String {
        val messages = JSONArray()
        messages.put(JSONObject().put("role", "system").put("content",
            "You are the Voice Flow assistant on Safet's phone. Be concise and direct; " +
            "answers are read on a phone screen. You have no tools — just answer."))
        history.takeLast(20).forEach {
            messages.put(JSONObject().put("role", it.role).put("content", it.text))
        }
        val content: Any = if (imageBase64Jpeg != null) {
            JSONArray()
                .put(JSONObject().put("type", "text").put("text", userText))
                .put(JSONObject().put("type", "image_url").put("image_url",
                    JSONObject().put("url", "data:image/jpeg;base64,$imageBase64Jpeg")))
        } else userText
        messages.put(JSONObject().put("role", "user").put("content", content))

        val body = JSONObject().put("model", model).put("messages", messages)
        val payload = Net.postJson(
            "https://openrouter.ai/api/v1/chat/completions", body,
            mapOf("Authorization" to "Bearer ${apiKey.trim()}"), timeoutMs = 180_000,
        )
        payload.optJSONObject("error")?.let {
            throw Exception(it.optString("message", "assistant error"))
        }
        return payload.optJSONArray("choices")?.optJSONObject(0)
            ?.optJSONObject("message")?.optString("content")?.trim()
            ?.takeIf { it.isNotBlank() }
            ?: throw Exception("Empty assistant reply")
    }
}
