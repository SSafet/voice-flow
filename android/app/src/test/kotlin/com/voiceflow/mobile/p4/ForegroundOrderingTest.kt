package com.voiceflow.mobile.p4

import com.voiceflow.mobile.BeginResult
import com.voiceflow.mobile.DotState
import com.voiceflow.mobile.ForegroundHost
import com.voiceflow.mobile.NoticeSink
import com.voiceflow.mobile.OverlayHost
import com.voiceflow.mobile.RecorderPort
import com.voiceflow.mobile.RecordingRefusal
import com.voiceflow.mobile.RecordingSession
import com.voiceflow.mobile.RecordingState
import com.voiceflow.mobile.TrampolineHandshake
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The foreground-service ordering fix and the trampoline fix (08 §3.7): a dot
 * becomes visible first, then the microphone type is claimed, then the recorder
 * starts; on the way out the service is demoted before the dot is removed. A
 * refused type or a refused recorder says so, by name, with a red dot that does
 * not start pulsing — never a silent failure into nothing.
 */
class ForegroundOrderingTest {

    private class Fixture {
        val steps = P4Paths.Steps()
        var overlay = object : OverlayHost {
            override fun showDot(mode: DotState) { steps.note("showDot:$mode") }
            override fun setPulsing(on: Boolean) { steps.note("pulsing:$on") }
            override fun removeDot() { steps.note("removeDot") }
        }
        var foreground = object : ForegroundHost {
            override fun promoteMicrophone(): Boolean { steps.note("promoteMicrophone"); return promote }
            override fun demoteMicrophone() { steps.note("demoteMicrophone") }
        }
        var recorder = object : RecorderPort {
            override fun start(): Boolean { steps.note("recorderStart"); return start }
            override fun stop(): File? { steps.note("recorderStop"); return finished }
        }
        var notices = object : NoticeSink {
            override fun show(code: String) { steps.note("notice:$code") }
        }
        var promote = true
        var start = true
        var finished: File? = File("/tmp/take.m4a")
        val session = RecordingSession(overlay, foreground, recorder, notices)
    }

    // ── the order ──

    @Test
    fun `the dot is visible, then the microphone is claimed, then the recorder starts`() {
        val f = Fixture()

        val result = f.session.begin(DotState.RECORDING)

        assertEquals(
            listOf("showDot:RECORDING", "promoteMicrophone", "recorderStart"),
            f.steps.all(),
        )
        assertSame(BeginResult.Started, result)
        assertEquals(RecordingState.RECORDING, f.session.state)
    }

    @Test
    fun `a kept take shows the kept dot`() {
        val f = Fixture()
        f.session.begin(DotState.KEPT)
        assertEquals("showDot:KEPT", f.steps.all().first())
    }

    @Test
    fun `the service is demoted before the dot is removed`() {
        val f = Fixture()
        f.session.begin(DotState.RECORDING)
        val file = f.session.end()
        val ending = f.steps.all().dropWhile { it != "demoteMicrophone" }
        assertTrue("both happen: ${f.steps.all()}", ending.contains("removeDot"))
        assertTrue(
            "demote must come before removing the dot: ${f.steps.all()}",
            ending.indexOf("demoteMicrophone") < ending.indexOf("removeDot"),
        )
        assertEquals("/tmp/take.m4a", file?.path)
        assertEquals(RecordingState.IDLE, f.session.state)
    }

    // ── failure is said, never silent ──

    @Test
    fun `a refused microphone type is a red dot that does not pulse and a named refusal`() {
        val f = Fixture()
        f.promote = false

        val result = f.session.begin(DotState.RECORDING)

        assertEquals(
            listOf("showDot:RECORDING", "promoteMicrophone", "pulsing:false", "notice:mic_refused", "demoteMicrophone"),
            f.steps.all(),
        )
        assertSame(RecordingRefusal.MIC_REFUSED, (result as BeginResult.Refused).refusal)
        assertEquals(RecordingState.IDLE, f.session.state)
        assertFalse("the recorder is never started", f.steps.all().contains("recorderStart"))
    }

    @Test
    fun `a refused recorder is a red dot that does not pulse and a named refusal`() {
        val f = Fixture()
        f.start = false

        val result = f.session.begin(DotState.RECORDING)

        assertEquals(
            listOf("showDot:RECORDING", "promoteMicrophone", "recorderStart", "pulsing:false", "notice:recorder_failed", "demoteMicrophone"),
            f.steps.all(),
        )
        assertSame(RecordingRefusal.RECORDER_FAILED, (result as BeginResult.Refused).refusal)
        assertEquals(RecordingState.IDLE, f.session.state)
    }

    // ── the trampoline stays alive until the service confirms ──

    @Test
    fun `the trampoline does not finish before recording has begun`() {
        val handshake = TrampolineHandshake()
        handshake.requested()
        assertFalse("still waiting for the service", handshake.done)
        handshake.confirmed()
        assertTrue("finishes once the dot is up and recording began", handshake.done)
    }

    @Test
    fun `a refused start also releases the trampoline`() {
        val handshake = TrampolineHandshake()
        handshake.requested()
        assertFalse(handshake.done)
        handshake.refused(RecordingRefusal.MIC_REFUSED)
        assertTrue(handshake.done)
    }

    // ── the insertion service only acts when handed a finished transcript ──

    @Test
    fun `the insertion service consumes no events and reads nothing of its own`() {
        val source = P4Paths.source("Insertion.kt")
        assertTrue(
            "onAccessibilityEvent must stay empty",
            source.contains("override fun onAccessibilityEvent(event: AccessibilityEvent?) {}"),
        )
        assertTrue(
            "onInterrupt must stay empty",
            source.contains("override fun onInterrupt() {}"),
        )
        for (forbidden in listOf("ClipboardManager", "MediaRecorder", "Recorder")) {
            assertFalse("InsertionService must not touch $forbidden", source.contains(forbidden))
        }

        val document = P4Paths.xml(P4Paths.file(P4Paths.ACCESSIBILITY_XML))
        val service = P4Paths.elements(document, "accessibility-service").single()
        assertEquals("the service is told to ask for nothing more than focus", "typeViewFocused", P4Paths.androidAttribute(service, "accessibilityEventTypes"))
    }
}
