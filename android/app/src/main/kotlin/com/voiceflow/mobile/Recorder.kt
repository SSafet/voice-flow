package com.voiceflow.mobile

import android.media.MediaRecorder
import java.io.File

/// Thin MediaRecorder wrapper: AAC mono 16 kHz into an .m4a — small enough
/// to queue offline, accepted directly by OpenAI transcription.
class Recorder {
    private var recorder: MediaRecorder? = null
    var currentFile: File? = null
        private set

    val isRecording: Boolean get() = recorder != null

    fun start(outputDir: File): File {
        stopQuietly()
        val file = File(outputDir, "rec-${System.currentTimeMillis()}.m4a")
        @Suppress("DEPRECATION")
        val r = MediaRecorder()
        r.setAudioSource(MediaRecorder.AudioSource.MIC)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        r.setAudioSamplingRate(16_000)
        r.setAudioEncodingBitRate(64_000)
        r.setAudioChannels(1)
        r.setOutputFile(file.absolutePath)
        r.prepare()
        r.start()
        recorder = r
        currentFile = file
        return file
    }

    /// Returns the finished file, or null if the take was too short/empty.
    fun stop(): File? {
        val r = recorder ?: return null
        recorder = null
        val file = currentFile
        currentFile = null
        return try {
            r.stop()
            r.release()
            if (file != null && file.length() > 1_000) file else { file?.delete(); null }
        } catch (_: Exception) {
            r.release()
            file?.delete()
            null
        }
    }

    fun stopQuietly() {
        try { recorder?.stop() } catch (_: Exception) {}
        try { recorder?.release() } catch (_: Exception) {}
        recorder = null
        currentFile?.delete()
        currentFile = null
    }
}
