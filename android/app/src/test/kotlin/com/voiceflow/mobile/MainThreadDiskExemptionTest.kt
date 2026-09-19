package com.voiceflow.mobile

import com.voiceflow.mobile.p1.P1Paths
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Where the main thread is still allowed to touch disk, and nowhere else.
 *
 * P1 turns StrictMode on and removes nothing, so the surfaces P4 and P6
 * replace still read and write on the main thread; a debug build would die on
 * the first of them. Each of those bodies runs inside
 * `MainThreadGuard.allowingDisk`, and this file is what notices when one of
 * them stops doing so — without it, dropping an exemption would look green
 * here and kill the app on the phone.
 *
 * The lists shrink as P4 and P6 delete the surfaces; they never grow without a
 * reason written next to them.
 */
class MainThreadDiskExemptionTest {

    private val exemption = "MainThreadGuard.allowingDisk"

    /** file → (the function that must run under the exemption → how many times). */
    private val exempted = mapOf(
        "MainActivity.kt" to mapOf(
            "onCreate" to 1,            // the store, the keys, the sync client, WorkManager
            "onResume" to 1,            // is the bubble switched on
            "applyPairedState" to 1,    // the cloud preferences
            "buildRecordPage" to 2,     // the offline banner's retry, the bubble switch
            "toggleRecording" to 1,     // the queue folder and the .m4a
            "stopRecording" to 2,       // closing the .m4a, then queueing it
            "refreshBubbleRow" to 1,
            "setBubbleEnabled" to 1,
            "advanceBubbleSetup" to 4,  // two one-time nudges, read then written
            "bubbleRowTapped" to 1,
            "refreshHistory" to 1,      // dictations.json and the cloud database
            "refreshChat" to 1,         // chat.json
            "sendChat" to 2,            // the agent key, then the message
            "attachImage" to 1,         // decoding the shared image
            "quietSync" to 1,           // the banner, rebuilt from what the sync wrote
            "watchConnectivity" to 1,
        ),
        "Bubble.kt" to mapOf(
            "onCreate" to 2,            // the store and WorkManager, and the network callback
            "onStartCommand" to 1,
            "onDestroy" to 1,           // deleting a half-written recording
            "addBubble" to 2,           // where the dot was left, plus the drag listener declared inside it
            "onTouch" to 1,             // where the dot was dragged to
            "startRecording" to 1,
            "stopRecording" to 2,
            "onReceive" to 1,           // the boot receiver
        ),
        "CloudSettingsActivity.kt" to mapOf(
            "onCreate" to 1,
            "render" to 1,              // the whole screen is drawn from disk
        ),
    )

    @Test
    fun `every surface that still touches disk on the main thread says so`() {
        for ((name, functions) in exempted) {
            val source = P1Paths.file("${P1Paths.SOURCE_DIR}/$name").readLines()
            for ((function, expected) in functions) {
                val body = bodyOf(source, function, "$name.$function")
                val found = body.count { it.contains(exemption) }
                assertEquals(
                    "$name.$function must run its disk work inside $exemption — a debug build " +
                        "dies on the first unexempted read. Body:\n" + body.joinToString("\n"),
                    expected,
                    found,
                )
            }
        }
    }

    @Test
    fun `the exemption has one name and one home`() {
        val sources = P1Paths.path(P1Paths.SOURCE_DIR).walkTopDown()
            .filter { it.isFile && it.name.endsWith(".kt") }
        val offenders = sources.filter { it.name != "MainThreadGuard.kt" }
            .filter { file -> file.readText().contains("StrictMode.") }
            .map { it.name }
            .toList()
        assertTrue(
            "only MainThreadGuard decides the thread policy; these name StrictMode themselves: $offenders",
            offenders.isEmpty(),
        )
    }

    /**
     * The lines of [function]'s body: from the line that declares it to the
     * next function declared at the same nesting or shallower, so a function
     * declared inside it stays part of it.
     */
    private fun bodyOf(source: List<String>, function: String, named: String): List<String> {
        val declaration = Regex("""^(\s*)(?:\S.*\s)?fun\s+`?${Regex.escape(function)}`?\s*[(<]""")
        val anyFunction = Regex("""^(\s*)(?:\S.*\s)?fun\s""")
        val start = source.indexOfFirst { declaration.containsMatchIn(it) }
        if (start < 0) throw AssertionError("no function named $named; the exemption list is stale")
        val indent = declaration.find(source[start])!!.groupValues[1].length
        var end = source.size
        for (index in start + 1 until source.size) {
            val next = anyFunction.find(source[index]) ?: continue
            if (next.groupValues[1].length <= indent) {
                end = index
                break
            }
        }
        return source.subList(start, end)
    }
}
