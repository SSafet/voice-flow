package com.voiceflow.mobile

/// The floating dictation dot's four states (ticket VF-51). IDLE is the
/// always-on service with nothing on screen; RECORDING, TRANSCRIBING and KEPT
/// are the states in which the dot is visible and says what it is doing.
enum class DotState { IDLE, RECORDING, TRANSCRIBING, KEPT }

object DotAnnouncement {
    /** The string the floating dot announces in this state, or null when it announces nothing. */
    fun contentDescriptionFor(state: DotState): Int? = when (state) {
        DotState.IDLE -> null
        DotState.RECORDING -> R.string.dot_recording
        DotState.TRANSCRIBING -> R.string.dot_transcribing
        DotState.KEPT -> R.string.dot_kept
    }
}
