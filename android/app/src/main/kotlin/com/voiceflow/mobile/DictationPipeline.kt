package com.voiceflow.mobile

import java.io.File

/// Why a drain stopped short. `NOTHING_HEARD` is the only one that finishes
/// the row: silence is not a failure, there is simply no text to keep.
enum class Refusal(val code: String) {
    NO_KEY("no_key"),
    OFFLINE("offline"),
    NOTHING_HEARD("nothing_heard"),
    TRANSCRIPTION_FAILED("transcription_failed"),
}

/// Where the finished text is handed. COMPOSER is the interface's own input,
/// not another app's field.
enum class Delivery { INSERTED, CLIPBOARD, COMPOSER }

/// The focused field the fresh take would land in.
enum class FieldState { EDITABLE, NONE, PASSWORD }

data class CompletedDictation(
    val queueId: String,
    val note: DictationEntry,
    val delivery: Delivery,
    val fresh: Boolean,
)

data class DrainReport(
    val completed: List<CompletedDictation>,
    val refusal: Refusal?,
    val pending: Int,
)

/// A transcription that cannot proceed for a named reason. The take stays
/// queued; nothing is ever dropped for a failure.
class TranscriptionUnavailable(val refusal: Refusal, message: String) : Exception(message)

interface Transcription {
    fun transcribe(file: File, vocabulary: List<String>): String
    fun cleanup(raw: String, vocabulary: List<String>, model: String): String
}

fun interface DeliverySink { fun accept(text: String, delivery: Delivery) }

fun interface FieldProbe { fun field(): FieldState }

/// The one place the delivery is decided. Only the take the person just
/// finished may be typed; a recovered recording is never inserted; a missing
/// or password field always falls back to the clipboard.
object InsertionPolicy {
    fun decide(mode: DictationMode, fresh: Boolean, field: FieldState): Delivery = when {
        !fresh -> Delivery.CLIPBOARD
        mode == DictationMode.KEEP -> Delivery.CLIPBOARD
        mode == DictationMode.COMPOSER -> Delivery.COMPOSER
        mode == DictationMode.INSERT && field == FieldState.EDITABLE -> Delivery.INSERTED
        else -> Delivery.CLIPBOARD
    }
}

/// Drain -> transcribe -> clean up -> save note -> deliver. The note is
/// durable before the text is handed anywhere; the queue row and its audio
/// are removed only once the note exists. A row whose mode this pipeline does
/// not read is left queued, in place, for the screen that owns it.
class DictationPipeline(
    private val queue: AudioQueue,
    private val notes: RecordStore,
    private val transcription: Transcription,
    private val sink: DeliverySink,
    private val field: FieldProbe,
) {
    fun drain(freshId: String?): DrainReport {
        val completed = mutableListOf<CompletedDictation>()
        var refusal: Refusal? = null
        val vocabulary = notes.vocabulary()
        val model = notes.cleanupModel()
        val cleanup = notes.cleanupEnabled()
        for (item in queue.items()) {
            val mode = DictationMode.parse(item.mode) ?: continue
            val raw = try {
                transcription.transcribe(File(item.file), vocabulary)
            } catch (unavailable: TranscriptionUnavailable) {
                refusal = unavailable.refusal
                break
            }
            if (raw.isBlank()) {
                queue.complete(item.id)
                if (refusal == null) refusal = Refusal.NOTHING_HEARD
                continue
            }
            val text = if (cleanup) transcription.cleanup(raw, vocabulary, model) else raw
            val fresh = item.id == freshId
            val delivery = InsertionPolicy.decide(mode, fresh, field.field())
            val note = DictationEntry.now(text, mode.destination).copy(id = "dictation-${item.id}")
            notes.saveNote(note)
            sink.accept(text, delivery)
            queue.complete(item.id)
            completed.add(CompletedDictation(item.id, note, delivery, fresh))
        }
        return DrainReport(completed, refusal, queue.count())
    }
}
