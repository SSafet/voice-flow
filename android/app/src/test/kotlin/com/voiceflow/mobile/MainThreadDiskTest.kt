package com.voiceflow.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * The guard kills a debug build that touches disk on the main thread, and P1
 * removes none of the surfaces that still do. Those surfaces run their disk
 * work inside [MainThreadGuard.allowingDisk], which lifts disk detection for
 * the length of one call and then puts the policy back.
 *
 * Putting it back is the whole of the correctness here: a policy lifted and
 * left lifted would leave the main thread unguarded for the rest of the
 * process, and nothing would say so. Android's `StrictMode` is unreachable
 * from a unit test, so the lift and the restore are parameters of
 * [MainThreadGuard.restoring] and this file proves them with plain values.
 */
class MainThreadDiskTest {

    private val log = mutableListOf<String>()

    private fun lift(): String {
        log.add("lift")
        return "policy"
    }

    private fun restore(token: String) {
        log.add("restore:$token")
    }

    @Test
    fun `the block runs between the lift and the restore`() {
        val value = MainThreadGuard.restoring(::lift, ::restore) {
            log.add("block")
            7
        }
        assertEquals(7, value)
        assertEquals(listOf("lift", "block", "restore:policy"), log)
    }

    @Test
    fun `the policy is restored when the block throws, and the failure still travels`() {
        val error = assertThrows(IllegalStateException::class.java) {
            MainThreadGuard.restoring(::lift, ::restore) {
                log.add("block")
                throw IllegalStateException("the read failed")
            }
        }
        assertEquals("the read failed", error.message)
        assertEquals(
            "a lifted policy that is never put back leaves the thread unguarded",
            listOf("lift", "block", "restore:policy"),
            log,
        )
    }

    @Test
    fun `the policy is restored when the block returns out of the caller`() {
        assertEquals("early", earlyReturn())
        assertEquals(
            "an early return out of a wrapped body must still put the policy back",
            listOf("lift", "block", "restore:policy"),
            log,
        )
    }

    /** What every wrapped body with a guard clause in it looks like. */
    private fun earlyReturn(): String {
        val value = MainThreadGuard.restoring(::lift, ::restore) {
            log.add("block")
            if (log.isNotEmpty()) return "early"
            "never"
        }
        return "late:$value"
    }
}
