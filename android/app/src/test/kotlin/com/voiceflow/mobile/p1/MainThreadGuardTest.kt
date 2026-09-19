package com.voiceflow.mobile.p1

import com.voiceflow.mobile.MainThreadGuard
import com.voiceflow.mobile.ViolationSink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Nothing touches disk or the network on the main thread: in a debug build a
 * violation kills the app, in a release build it is logged and reported once
 * per site, so a regression is loud rather than a stutter.
 *
 * The policies are decided by a plain function, so the decision is testable
 * without Android; installing them is the one line the application class runs.
 */
class MainThreadGuardTest {

    private fun frame(className: String, method: String, line: Int) =
        StackTraceElement(className, method, "Source.kt", line)

    // ── The thread policy ──

    @Test
    fun `a debug build dies on disk and network work on the main thread`() {
        val policy = MainThreadGuard.threadPolicyFor(debuggable = true)
        assertTrue("disk reads are detected", policy.detectDiskReads)
        assertTrue("disk writes are detected", policy.detectDiskWrites)
        assertTrue("network calls are detected", policy.detectNetwork)
        assertEquals(MainThreadGuard.Reaction.DEATH, policy.reaction)
    }

    @Test
    fun `a release build detects the same work and never dies of it`() {
        val policy = MainThreadGuard.threadPolicyFor(debuggable = false)
        assertTrue("disk reads are detected", policy.detectDiskReads)
        assertTrue("disk writes are detected", policy.detectDiskWrites)
        assertTrue("network calls are detected", policy.detectNetwork)
        assertEquals(MainThreadGuard.Reaction.LOG_AND_REPORT, policy.reaction)
    }

    // ── The virtual machine policy ──

    @Test
    fun `leaks are watched in both build types and only a debug build dies of them`() {
        for (debuggable in listOf(true, false)) {
            val policy = MainThreadGuard.vmPolicyFor(debuggable)
            assertTrue("closable objects, debuggable=$debuggable", policy.detectLeakedClosableObjects)
            assertTrue("SQLite objects, debuggable=$debuggable", policy.detectLeakedSqlLiteObjects)
            assertTrue("activity leaks, debuggable=$debuggable", policy.detectActivityLeaks)
        }
        assertEquals(MainThreadGuard.Reaction.DEATH, MainThreadGuard.vmPolicyFor(true).reaction)
        assertEquals(MainThreadGuard.Reaction.LOG_AND_REPORT, MainThreadGuard.vmPolicyFor(false).reaction)
    }

    // ── Reporting a violation ──

    @Test
    fun `the first violation at a site is reported with its kind and its site`() {
        val sink = ViolationSink()
        val line = sink.accept(
            "DiskReadViolation",
            listOf(
                frame("android.os.StrictMode", "onDiskRead", 1),
                frame("com.voiceflow.mobile.Store", "load", 42),
                frame("com.voiceflow.mobile.MainActivity", "onCreate", 7),
            ),
        )
        assertNotNull("the first violation at a site is reported", line)
        assertTrue("the line names the violation: $line", line!!.contains("DiskReadViolation"))
        assertTrue("the line names the site: $line", line.contains("com.voiceflow.mobile.Store.load:42"))
        assertEquals(1, sink.reported.size)
    }

    @Test
    fun `the same violation at the same site is reported once`() {
        val sink = ViolationSink()
        val stack = listOf(frame("com.voiceflow.mobile.Store", "load", 42))
        assertNotNull("the first one is reported", sink.accept("DiskReadViolation", stack))
        assertNull("a tight loop does not report again", sink.accept("DiskReadViolation", stack))
        assertNull("nor a third time", sink.accept("DiskReadViolation", stack))
        assertEquals(1, sink.reported.size)
    }

    @Test
    fun `another line and another kind are new reports`() {
        val sink = ViolationSink()
        assertNotNull(sink.accept("DiskReadViolation", listOf(frame("com.voiceflow.mobile.Store", "load", 42))))
        assertNotNull(sink.accept("DiskReadViolation", listOf(frame("com.voiceflow.mobile.Store", "load", 43))))
        assertNotNull(sink.accept("DiskReadViolation", listOf(frame("com.voiceflow.mobile.Store", "save", 42))))
        assertNotNull(sink.accept("NetworkViolation", listOf(frame("com.voiceflow.mobile.Store", "load", 42))))
        assertEquals(4, sink.reported.size)
    }

    @Test
    fun `a violation with no frame of this app is reported against an unknown site`() {
        val sink = ViolationSink()
        val line = sink.accept(
            "NetworkViolation",
            listOf(frame("android.os.StrictMode", "onNetwork", 1), frame("java.net.Socket", "connect", 9)),
        )
        assertNotNull("it is still reported", line)
        assertTrue("the site is named unknown: $line", line!!.contains("unknown"))
        assertNull(
            "the unknown site is reported once too",
            sink.accept("NetworkViolation", listOf(frame("android.os.StrictMode", "onNetwork", 2))),
        )
    }

    @Test
    fun `an empty stack is refused by name and does not throw`() {
        val sink = ViolationSink()
        val line = sink.accept("DiskWriteViolation", emptyList())
        assertNotNull(line)
        assertTrue("the site is named unknown: $line", line!!.contains("unknown"))
    }

    @Test
    fun `the guard's own frames are never the site`() {
        val sink = ViolationSink()
        val line = sink.accept(
            "DiskReadViolation",
            listOf(
                frame("com.voiceflow.mobile.MainThreadGuard", "report", 3),
                frame("com.voiceflow.mobile.ViolationSink", "accept", 4),
                frame("com.voiceflow.mobile.Recorder", "start", 88),
            ),
        )
        assertNotNull(line)
        assertTrue("the site skips the guard itself: $line", line!!.contains("com.voiceflow.mobile.Recorder.start:88"))
    }

    // ── The guard is actually installed ──

    @Test
    fun `the application class names the guard and the manifest names the application class`() {
        val application = P1Paths.elements(P1Paths.xml(P1Paths.mergedManifest), "application").single()
        assertEquals(
            "the merged manifest must name the application class that installs the guard",
            "com.voiceflow.mobile.VoiceFlowApp",
            P1Paths.androidAttribute(application, "name"),
        )
        val source = P1Paths.file("${P1Paths.SOURCE_DIR}/VoiceFlowApp.kt").readText()
        assertTrue(
            "VoiceFlowApp must install the guard in onCreate",
            source.contains("MainThreadGuard.install("),
        )
    }
}
