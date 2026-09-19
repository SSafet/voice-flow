package com.voiceflow.mobile

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import java.io.File

/// The one Android caller of the dictation pipeline: it builds the real
/// engine, transcriber, insertion sink and field probe, and drains. Both the
/// panel and the floating dot call this.
class DictationService(
    private val context: Context,
    private val delivered: DeliverySink? = null,
) {
    fun drain(freshId: String? = null): DrainReport = synchronized(lock) {
        val pipeline = DictationPipeline(
            queue = AudioQueue(context.filesDir),
            notes = RecordStore(CloudRecordEngine(context)),
            transcription = TranscriptionAdapter(context),
            sink = sink(),
            field = FieldProbe { if (InsertionService.instance != null) FieldState.EDITABLE else FieldState.NONE },
        )
        pipeline.drain(freshId)
    }

    private fun sink(): DeliverySink = delivered ?: DeliverySink { text, delivery ->
        when (delivery) {
            Delivery.INSERTED -> if (InsertionService.instance?.insert(text) != true) copy(text)
            Delivery.CLIPBOARD -> copy(text)
            Delivery.COMPOSER -> Unit
        }
    }

    private fun copy(text: String) {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("dictation", text))
    }

    /// The real Transcriber, adapted to the pipeline's keyless contract. A
    /// missing key is named `NO_KEY`; an unauthorized server answer is too;
    /// a network failure is `OFFLINE`; anything else is
    /// `TRANSCRIPTION_FAILED` and keeps the take.
    private class TranscriptionAdapter(private val context: Context) : Transcription {
        override fun transcribe(file: File, vocabulary: List<String>): String {
            val key = Keys(context).load(Keys.OPENAI)
            if (key.isNullOrBlank()) throw TranscriptionUnavailable(Refusal.NO_KEY, "no OpenAI key")
            return try {
                Transcriber.transcribe(file, key, vocabulary)
            } catch (error: Net.HttpError) {
                if (error.code == 401) throw TranscriptionUnavailable(Refusal.NO_KEY, error.message ?: "no key")
                throw TranscriptionUnavailable(Refusal.TRANSCRIPTION_FAILED, error.message ?: "transcription failed")
            } catch (error: Exception) {
                throw TranscriptionUnavailable(Refusal.OFFLINE, error.message ?: "offline")
            }
        }

        override fun cleanup(raw: String, vocabulary: List<String>, model: String): String {
            val key = Keys(context).load(Keys.AGENT)
            if (key.isNullOrBlank()) return raw
            return Transcriber.clean(raw, key, vocabulary, model)
        }
    }

    companion object {
        /// Drains serialize in the process, so the panel and the dot never
        /// transcribe the same row at once.
        private val lock = Any()
    }
}
