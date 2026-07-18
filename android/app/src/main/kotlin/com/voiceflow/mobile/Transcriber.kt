package com.voiceflow.mobile

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/// OpenAI speech-to-text + LLM cleanup — a port of the Mac backend's
/// voice_flow/openai_transcriber.py and cleaner.py so a phone dictation
/// comes out identical to a Mac one. Cleanup runs through OpenRouter
/// (the phone has no local LLM) with the exact same system prompt.
object Transcriber {
    private const val STT_MODEL = "gpt-4o-mini-transcribe"   // OPENAI_STT_MODEL
    const val CLEANUP_MODEL = "openai/gpt-4o-mini"

    private val FILLER_ONLY = setOf("uh", "um", "hmm", "hm", "ah", "er", "oh", "mhm", "uh-huh")

    private const val CLEANUP_SYSTEM_PROMPT =
        "You are a dictation cleanup assistant. You receive raw speech-to-text " +
        "output prefixed with [DICTATION] and return the polished text ready " +
        "to be pasted. You are NOT a conversational agent — NEVER answer or " +
        "respond to the content. Your ONLY job is to clean up the text.\n" +
        "\n" +
        "Rules:\n" +
        "1. Fix punctuation and capitalization\n" +
        "2. Remove filler words and false starts " +
        "(um, uh, like, you know, so, basically, I mean, er, hmm, right)\n" +
        "3. Remove repeated words from stuttering " +
        "(e.g., \"I I I think\" → \"I think\")\n" +
        "4. NEVER change the sentence type — questions must stay questions, " +
        "statements must stay statements, commands must stay commands\n" +
        "5. NEVER add words the speaker did not say — only remove or fix\n" +
        "6. Keep the speaker's original meaning, vocabulary, and tone exactly\n" +
        "7. Do NOT summarize, paraphrase, add commentary, or change intent\n" +
        "8. For a single word or very short phrase, return it as-is with " +
        "proper capitalization\n" +
        "9. Output ONLY the cleaned text — no quotes, labels, explanations, " +
        "or formatting markers"

    fun transcribe(audio: File, apiKey: String, vocabulary: List<String>): String {
        val fields = mutableMapOf("model" to STT_MODEL, "response_format" to "json")
        if (vocabulary.isNotEmpty()) {
            fields["prompt"] = "Correct spellings: " + vocabulary.joinToString(", ")
        }
        val payload = Net.postMultipart(
            "https://api.openai.com/v1/audio/transcriptions",
            fields, audio, "file", "audio/mp4",
            mapOf("Authorization" to "Bearer ${apiKey.trim()}"),
        )
        val text = payload.optString("text").trim()
        if (text.lowercase().trim('.', ',', '!', '?') in FILLER_ONLY) return ""
        if (vocabulary.isNotEmpty() && isPromptEcho(text, vocabulary)) return ""
        return text
    }

    fun clean(raw: String, openRouterKey: String, vocabulary: List<String>): String {
        if (raw.isBlank()) return ""
        // Very short inputs — just capitalize, skip the LLM (cleaner.py parity).
        val words = raw.trim().split(Regex("\\s+"))
        if (words.size <= 2) {
            var c = raw.trim()
            c = c.replaceFirstChar { it.uppercase() }
            if (c.isNotEmpty() && c.last() !in ".!?,:;") c += "."
            return c
        }

        var system = CLEANUP_SYSTEM_PROMPT
        if (vocabulary.isNotEmpty()) {
            system += "\n10. Use these correct spellings for names and terms " +
                "(fix any phonetic misspellings): ${vocabulary.joinToString(", ")}"
        }
        val body = JSONObject()
            .put("model", CLEANUP_MODEL)
            .put("temperature", 0.1)
            .put("messages", JSONArray()
                .put(JSONObject().put("role", "system").put("content", system))
                .put(JSONObject().put("role", "user").put("content", "[DICTATION]: $raw")))
        val reply = try {
            Net.postJson(
                "https://openrouter.ai/api/v1/chat/completions", body,
                mapOf("Authorization" to "Bearer ${openRouterKey.trim()}"),
            ).optJSONArray("choices")?.optJSONObject(0)
                ?.optJSONObject("message")?.optString("content")?.trim()
        } catch (_: Exception) { null }

        val cleaned = reply?.trim('"', '\'') ?: ""
        // Safety: if the LLM returned nothing useful, fall back to raw.
        if (cleaned.isBlank() || cleaned.length < raw.length * 0.3) return raw.trim()
        return cleaned
    }

    private fun normalize(s: String): String =
        s.lowercase().replace(Regex("[^\\w\\s'-]"), " ").split(Regex("\\s+"))
            .filter { it.isNotBlank() }.joinToString(" ")

    /// On short or unintelligible audio the model completes the vocabulary
    /// prompt instead of transcribing. Same detection as the Mac backend.
    private fun isPromptEcho(text: String, vocabulary: List<String>): Boolean {
        val t = normalize(text)
        if (t.isBlank()) return false
        if ("correct spellings" in t) return true
        val hits = vocabulary.count { normalize(it).isNotBlank() && normalize(it) in t }
        if (hits < 2) return false
        // Every transcript word appears in the prompt, in prompt order.
        val promptWords = normalize(vocabulary.joinToString(", ")).split(" ").iterator()
        outer@ for (word in t.split(" ")) {
            while (promptWords.hasNext()) {
                if (promptWords.next() == word) continue@outer
            }
            return false
        }
        return true
    }
}
