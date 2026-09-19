package com.voiceflow.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.atomic.AtomicInteger

/**
 * There is one process-wide [ViolationSink] behind [MainThreadGuard], so what it
 * hands out and what two threads do to it at once are its own business, not its
 * callers'. The guard's own behaviour is pinned by `p1/MainThreadGuardTest`;
 * this file pins the two properties that only a shared object needs.
 */
class ViolationSinkTest {

    private fun frame(className: String, method: String, line: Int) =
        StackTraceElement(className, method, "Source.kt", line)

    private val store = listOf(frame("com.voiceflow.mobile.Store", "load", 42))

    @Test
    fun `reported is a snapshot and does not grow behind the caller's back`() {
        val sink = ViolationSink()
        sink.accept("DiskReadViolation", store)
        val handedOut = sink.reported
        sink.accept("NetworkViolation", store)
        assertEquals("the set handed out must not change when the sink accepts more", 1, handedOut.size)
        assertEquals("the sink itself knows about both", 2, sink.reported.size)
    }

    @Test
    fun `a caller cannot empty the sink through reported`() {
        val sink = ViolationSink()
        assertNotNull(sink.accept("DiskReadViolation", store))
        @Suppress("UNCHECKED_CAST")
        runCatching { (sink.reported as MutableSet<String>).clear() }
        assertNull("the sink must still know it has reported this kind and site", sink.accept("DiskReadViolation", store))
        assertEquals(1, sink.reported.size)
    }

    @Test
    fun `two threads reporting the same violation at once report it once`() {
        val threads = 2
        repeat(200) {
            val sink = ViolationSink()
            val barrier = CyclicBarrier(threads)
            val reports = AtomicInteger()
            val thrown = mutableListOf<Throwable>()
            val workers = (1..threads).map {
                Thread {
                    try {
                        if (sink.accept("DiskReadViolation", BarrieredStack(store, barrier)) != null) {
                            reports.incrementAndGet()
                        }
                    } catch (error: Throwable) {
                        synchronized(thrown) { thrown.add(error) }
                    }
                }.apply { start() }
            }
            workers.forEach { it.join() }
            assertTrue("accept threw: $thrown", thrown.isEmpty())
            assertEquals("one kind at one site is one report, however many threads reach it", 1, reports.get())
            assertEquals(1, sink.reported.size)
        }
    }

    /** A stack whose iteration waits for every racing thread, so both are inside
     * `accept` at the same moment instead of a hair apart. */
    private class BarrieredStack(
        private val backing: List<StackTraceElement>,
        private val barrier: CyclicBarrier,
    ) : List<StackTraceElement> by backing {
        override fun iterator(): Iterator<StackTraceElement> {
            barrier.await()
            return backing.iterator()
        }
    }
}
