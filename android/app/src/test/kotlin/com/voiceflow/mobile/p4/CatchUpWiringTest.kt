package com.voiceflow.mobile.p4

import com.voiceflow.mobile.CatchUp
import com.voiceflow.mobile.CatchUpReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Catch-up is one WorkManager job with a network constraint, run when the
 * network returns, after a local change, and periodically (08 §3.9). The
 * hand-driven `SyncJob` scheduling is deleted, so there is exactly one owner
 * of background catch-up.
 */
class CatchUpWiringTest {

    @Test
    fun `every reason needs the network and shares one catch-up job`() {
        for (reason in CatchUpReason.entries) {
            val plan = CatchUp.plan(reason)
            assertTrue("$reason must wait for the network", plan.requiresNetwork)
            assertEquals("one catch-up, replaced not duplicated", CatchUp.UNIQUE_NAME, plan.uniqueName)
        }
    }

    @Test
    fun `a local change and a returning network are expedited one-off work`() {
        for (reason in listOf(CatchUpReason.LOCAL_CHANGE, CatchUpReason.NETWORK_RETURNED)) {
            val plan = CatchUp.plan(reason)
            assertTrue("$reason is expedited", plan.expedited)
            assertNull("$reason is not periodic", plan.periodicMinutes)
        }
    }

    @Test
    fun `the periodic run is not expedited and repeats every fifteen minutes`() {
        val plan = CatchUp.plan(CatchUpReason.PERIODIC)
        assertFalse(plan.expedited)
        assertEquals(15, CatchUp.PERIOD_MINUTES)
        assertEquals(15, plan.periodicMinutes)
    }

    // ── the old hand-driven scheduling is gone, and the new one is wired ──

    @Test
    fun `SyncJob is deleted and no main source drives a JobScheduler`() {
        assertFalse("SyncJob.kt is deleted", P4Paths.path("${P4Paths.SOURCE_DIR}/SyncJob.kt").exists())
        val offenders = P4Paths.mainSources()
            .filterValues { it.contains("JobScheduler") || it.contains("JobService") }
            .keys
        assertTrue("no main source may schedule a system JobInfo: $offenders", offenders.isEmpty())
        assertNull(
            "the SyncJob service is gone from the manifest the build merged",
            P4Paths.manifestComponent("service", ".SyncJob"),
        )
    }

    @Test
    fun `catch-up is scheduled through the one owner`() {
        val callers = P4Paths.mainSources()
            .filterValues { it.contains("CatchUp.schedule(") || it.contains("CatchUpWorker") }
            .keys
        assertTrue("something must actually schedule catch-up: $callers", callers.isNotEmpty())
    }

    @Test
    fun `a note saved on the phone asks for a catch-up of its own`() {
        // 08 §3.9 step 2: the phone stores the dictation, and catch-up pushes it
        // to Atika at the next opportunity — which only happens if saving asks.
        val askers = P4Paths.mainSources()
            .filterValues { it.contains("CatchUpReason.LOCAL_CHANGE") }
            .keys
        assertTrue("a local change must schedule catch-up: $askers", askers.isNotEmpty())
    }

    @Test
    fun `the catch-up job states its network constraint and its unique work to WorkManager`() {
        val source = P4Paths.source("CatchUpWorker.kt")
        assertTrue("the constraint is WorkManager's own", source.contains("NetworkType.CONNECTED"))
        assertTrue("one-off catch-up replaces the one already queued", source.contains("ExistingWorkPolicy"))
        assertTrue("the periodic run is a PeriodicWorkRequest", source.contains("PeriodicWorkRequest"))
        assertTrue("expedited work is asked for by name", source.contains("setExpedited"))
    }
}
