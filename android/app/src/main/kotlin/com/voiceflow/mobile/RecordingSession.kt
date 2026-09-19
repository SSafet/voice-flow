package com.voiceflow.mobile

import java.io.File

/// Why a take never started. A refusal is named and shown, never silent:
/// speaking into a recorder that is not running is the one failure the person
/// cannot see.
enum class RecordingRefusal(val code: String) {
    MIC_REFUSED("mic_refused"),
    RECORDER_FAILED("recorder_failed"),
}

enum class RecordingState { IDLE, RECORDING }

sealed class BeginResult {
    object Started : BeginResult()
    data class Refused(val refusal: RecordingRefusal) : BeginResult()
}

/// The floating dot, as the session needs it: show the mode's dot, stop or
/// start its pulse, take it away.
interface OverlayHost {
    fun showDot(mode: DotState)
    fun setPulsing(on: Boolean)
    fun removeDot()
}

/// The foreground service, as the session needs it: claim the microphone type
/// for the span of the take, then give it back.
interface ForegroundHost {
    fun promoteMicrophone(): Boolean
    fun demoteMicrophone()
}

/// The recorder, reduced to the two moves the ordering cares about.
interface RecorderPort {
    fun start(): Boolean
    fun stop(): File?
}

/// Where a named notice goes; the code is a [RecordingRefusal] code.
interface NoticeSink {
    fun show(code: String)
}

/// The corrected foreground ordering (08 §3.7), as a pure state machine:
/// show the dot first (an overlay window is visible), then claim the
/// microphone type, then start the recorder. On the way out, demote the
/// service before removing the dot. A refusal is said by name, with a dot that
/// does not pulse, and the service is demoted so nothing is left claimed.
class RecordingSession(
    private val overlay: OverlayHost,
    private val foreground: ForegroundHost,
    private val recorder: RecorderPort,
    private val notices: NoticeSink,
) {
    var state: RecordingState = RecordingState.IDLE
        private set

    /// 1. the dot, 2. the microphone type, 3. the recorder. A failure at 2 or
    /// 3 refuses by name, stops the pulse, demotes the service and stays IDLE.
    fun begin(mode: DotState): BeginResult {
        overlay.showDot(mode)
        if (!foreground.promoteMicrophone()) {
            overlay.setPulsing(false)
            notices.show(RecordingRefusal.MIC_REFUSED.code)
            foreground.demoteMicrophone()
            state = RecordingState.IDLE
            return BeginResult.Refused(RecordingRefusal.MIC_REFUSED)
        }
        if (!recorder.start()) {
            overlay.setPulsing(false)
            notices.show(RecordingRefusal.RECORDER_FAILED.code)
            foreground.demoteMicrophone()
            state = RecordingState.IDLE
            return BeginResult.Refused(RecordingRefusal.RECORDER_FAILED)
        }
        state = RecordingState.RECORDING
        return BeginResult.Started
    }

    /// Demote first, then take the dot away, then hand back the finished file.
    fun end(): File? {
        val file = recorder.stop()
        foreground.demoteMicrophone()
        overlay.removeDot()
        state = RecordingState.IDLE
        return file
    }
}

/// The trampoline's latch (08 §3.7): the no-window activity asks for a
/// recording; it may only finish once the service confirms the dot is up and
/// recording began. A refusal releases it too — the trampoline never wedges.
class TrampolineHandshake {
    var done: Boolean = false
        private set

    fun requested() {
        done = false
    }

    fun confirmed() {
        done = true
    }

    fun refused(refusal: RecordingRefusal) {
        done = true
    }
}
