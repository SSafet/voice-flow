package com.voiceflow.mobile.p1

import com.voiceflow.mobile.DotAnnouncement
import com.voiceflow.mobile.DotState
import com.voiceflow.mobile.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * Every user-visible string of the native surfaces that survive lives in
 * `res/values/strings.xml` with a Bulgarian twin, and the floating dot says
 * what it is doing.
 *
 * The surfaces P6 deletes — the tabs, the pairing page, the assistant — are
 * deliberately out of scope: their strings would be extracted and then thrown
 * away. The files named in [SURVIVING_SOURCES] are the ones that remain.
 */
class StringsTest {

    private companion object {
        val SURVIVING_SOURCES = listOf("Bubble.kt", "RecordTileService.kt", "Insertion.kt")

        /** Calls whose arguments reach a person's eyes or a screen reader. */
        val USER_FACING_CALLS = listOf(
            "Toast.makeText(",
            "toast(",
            "setContentTitle(",
            "setContentText(",
            "setTicker(",
            "NotificationChannel(",
            "Notification.Action.Builder(",
            "announceForAccessibility(",
        )

        val CYRILLIC = Regex("[\\u0400-\\u04FF]")
    }

    private fun stringsOf(relative: String): List<Pair<String, String>> {
        val document = P1Paths.xml(P1Paths.file(relative))
        return P1Paths.elements(document, "string").map { element ->
            val name = element.getAttribute("name")
            if (name.isNullOrEmpty()) fail("$relative has a <string> with no name")
            name to (element.textContent ?: "")
        }
    }

    private fun translatableFlags(relative: String): Map<String, Boolean> {
        val document = P1Paths.xml(P1Paths.file(relative))
        return P1Paths.elements(document, "string").associate { element ->
            element.getAttribute("name") to (element.getAttribute("translatable") != "false")
        }
    }

    private fun resourceNamesById(): Map<Int, String> =
        R.string::class.java.declaredFields
            .filter { it.type == Int::class.javaPrimitiveType }
            .associate { field ->
                field.isAccessible = true
                (field.getInt(null)) to field.name
            }

    // ── The two string files agree ──

    @Test
    fun `English strings are named once and never blank`() {
        val strings = stringsOf("android/app/src/main/res/values/strings.xml")
        val duplicates = strings.map { it.first }.groupBy { it }.filterValues { it.size > 1 }.keys
        assertEquals("a string is named once: $duplicates", emptySet<String>(), duplicates)
        for ((name, value) in strings) {
            assertTrue("the string $name is blank", value.trim().isNotEmpty())
        }
    }

    @Test
    fun `every translatable string has a Bulgarian twin and nothing else does`() {
        val english = translatableFlags("android/app/src/main/res/values/strings.xml")
        val bulgarian = stringsOf("android/app/src/main/res/values-bg/strings.xml").map { it.first }.toSet()
        val translatable = english.filterValues { it }.keys
        val fixed = english.filterValues { !it }.keys
        assertEquals(
            "these translatable strings have no Bulgarian twin",
            emptySet<String>(),
            translatable - bulgarian,
        )
        assertEquals(
            "these Bulgarian strings name nothing in values/strings.xml",
            emptySet<String>(),
            bulgarian - english.keys,
        )
        assertEquals(
            "a string marked translatable=\"false\" must not be translated",
            emptySet<String>(),
            fixed intersect bulgarian,
        )
        assertTrue("there is at least one translatable string", translatable.isNotEmpty())
    }

    @Test
    fun `the Bulgarian file is in Bulgarian`() {
        val bulgarian = stringsOf("android/app/src/main/res/values-bg/strings.xml")
        val duplicates = bulgarian.map { it.first }.groupBy { it }.filterValues { it.size > 1 }.keys
        assertEquals("a string is named once: $duplicates", emptySet<String>(), duplicates)
        for ((name, value) in bulgarian) {
            assertTrue("the Bulgarian string $name is blank", value.trim().isNotEmpty())
            assertTrue(
                "the Bulgarian string $name holds no Cyrillic, so it was never translated: $value",
                CYRILLIC.containsMatchIn(value),
            )
        }
    }

    // ── Nothing user-visible is left in code or in the manifest ──

    @Test
    fun `the surviving native surfaces hand no literal to a person`() {
        for (fileName in SURVIVING_SOURCES) {
            val source = P1Paths.file("${P1Paths.SOURCE_DIR}/$fileName").readText()
            for (token in USER_FACING_CALLS) {
                for ((line, arguments) in P1Paths.callArguments(source, token)) {
                    // The empty literal carries no text, so it is not a string to extract.
                    assertFalse(
                        "$fileName:$line passes a literal to $token — it belongs in strings.xml: $arguments",
                        arguments.replace("\"\"", "").contains('"'),
                    )
                }
            }
            for ((index, line) in source.lines().withIndex()) {
                if (line.contains("contentDescription") && line.contains('=')) {
                    assertFalse(
                        "$fileName:${index + 1} sets a literal content description: $line",
                        line.substringAfter('=').contains('"'),
                    )
                }
            }
        }
    }

    @Test
    fun `every label and description in the manifest and in res xml is a string resource`() {
        val files = mutableListOf(P1Paths.file("android/app/src/main/AndroidManifest.xml"))
        P1Paths.path("android/app/src/main/res/xml").listFiles()
            ?.filter { it.extension == "xml" }
            ?.let { files += it }
        val attributes = listOf("label", "description", "title", "summary", "text")
        for (file in files) {
            val document = P1Paths.xml(file)
            val all = P1Paths.elements(document, "*")
            for (element in all) {
                for (attribute in attributes) {
                    val value = P1Paths.androidAttribute(element, attribute) ?: continue
                    assertTrue(
                        "${file.name}: android:$attribute=\"$value\" on <${element.tagName}> must be a @string/ reference",
                        value.startsWith("@string/"),
                    )
                }
            }
        }
    }

    @Test
    fun `every string the manifest and res xml name exists`() {
        val english = translatableFlags("android/app/src/main/res/values/strings.xml").keys
        val referenced = mutableSetOf<String>()
        val sources = mutableListOf<File>(P1Paths.file("android/app/src/main/AndroidManifest.xml"))
        P1Paths.path("android/app/src/main/res/xml").listFiles()
            ?.filter { it.extension == "xml" }
            ?.let { sources += it }
        for (file in sources) {
            Regex("@string/([A-Za-z0-9_]+)").findAll(file.readText()).forEach { referenced += it.groupValues[1] }
        }
        assertEquals("these @string/ references name nothing", emptySet<String>(), referenced - english)
    }

    // ── The floating dot announces its state ──

    @Test
    fun `the dot has exactly the states the design names`() {
        assertEquals(
            setOf("IDLE", "RECORDING", "TRANSCRIBING", "KEPT"),
            DotState.entries.map { it.name }.toSet(),
        )
    }

    @Test
    fun `each working state of the dot announces itself and an idle dot says nothing`() {
        assertNull("an idle dot is removed and announces nothing", DotAnnouncement.contentDescriptionFor(DotState.IDLE))
        val announced = listOf(DotState.RECORDING, DotState.TRANSCRIBING, DotState.KEPT)
            .associateWith { DotAnnouncement.contentDescriptionFor(it) }
        for ((state, resource) in announced) {
            assertNotNull("$state announces nothing", resource)
            assertTrue("$state announces resource 0", resource!! != 0)
        }
        assertEquals(
            "each state announces something of its own",
            announced.size,
            announced.values.toSet().size,
        )
    }

    @Test
    fun `the dot's announcements are named strings and are translated`() {
        val namesById = resourceNamesById()
        val english = translatableFlags("android/app/src/main/res/values/strings.xml").keys
        val bulgarian = stringsOf("android/app/src/main/res/values-bg/strings.xml").map { it.first }.toSet()
        val expected = mapOf(
            DotState.RECORDING to "dot_recording",
            DotState.TRANSCRIBING to "dot_transcribing",
            DotState.KEPT to "dot_kept",
        )
        for ((state, name) in expected) {
            val resource = DotAnnouncement.contentDescriptionFor(state)
            assertNotNull("$state announces nothing", resource)
            assertEquals("the resource $state announces", name, namesById[resource])
            assertTrue("$name is missing from values/strings.xml", english.contains(name))
            assertTrue("$name is missing from values-bg/strings.xml", bulgarian.contains(name))
        }
    }
}
