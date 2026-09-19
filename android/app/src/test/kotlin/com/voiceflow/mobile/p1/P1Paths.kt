package com.voiceflow.mobile.p1

import org.w3c.dom.Document
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The paths and the small XML reading every P1 test shares.
 *
 * Nothing here names an application class, so this file compiles from the very
 * first task on, whichever P1 test files are switched on.
 */
internal object P1Paths {

    const val ANDROID_NS = "http://schemas.android.com/apk/res/android"

    const val SOURCE_DIR = "android/app/src/main/kotlin/com/voiceflow/mobile"

    /**
     * The VoiceFlow worktree root: the nearest folder at or above the test
     * working directory that holds `thread-protocol.lock`.
     */
    val repoRoot: File by lazy {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        var found: File? = null
        var hops = 0
        while (found == null && hops < 6) {
            val here = dir ?: break
            if (File(here, "thread-protocol.lock").isFile) found = here else dir = here.parentFile
            hops += 1
        }
        found ?: throw AssertionError(
            "no thread-protocol.lock at or above " + System.getProperty("user.dir") +
                "; the P1 unit tests must run from the android module of a VoiceFlow worktree",
        )
    }

    /** A file that must exist, named from the worktree root. */
    fun file(relative: String): File {
        val f = File(repoRoot, relative)
        if (!f.isFile) throw AssertionError("missing file: $relative (worktree ${repoRoot.absolutePath})")
        return f
    }

    /** A path that may or may not exist, named from the worktree root. */
    fun path(relative: String): File = File(repoRoot, relative)

    /**
     * The manifest the Android build merged, handed to the unit test task by
     * `app/build.gradle.kts` as `-Dvoiceflow.mergedManifest`. This is what AGP
     * actually produced, not what the source manifest says.
     */
    val mergedManifest: File by lazy {
        val named = System.getProperty("voiceflow.mergedManifest")
            ?: throw AssertionError(
                "the system property voiceflow.mergedManifest is not set: app/build.gradle.kts must hand " +
                    "the merged manifest of each variant to its unit test task",
            )
        val f = File(named)
        if (!f.isFile) throw AssertionError("voiceflow.mergedManifest names a file that does not exist: $named")
        f
    }

    fun xml(file: File): Document {
        val factory = DocumentBuilderFactory.newInstance()
        factory.isNamespaceAware = true
        return factory.newDocumentBuilder().parse(file)
    }

    fun elements(document: Document, tag: String): List<Element> {
        val nodes = document.getElementsByTagName(tag)
        return (0 until nodes.length).mapNotNull { nodes.item(it) as? Element }
    }

    /** An `android:`-namespaced attribute, or null when it is absent or empty. */
    fun androidAttribute(element: Element, name: String): String? {
        val value = element.getAttributeNS(ANDROID_NS, name)
        return if (value.isNullOrEmpty()) null else value
    }

    /**
     * The text of the argument list of every call of [token] in [source]: from
     * the `(` that follows the token to the `)` that closes it, counting nested
     * parentheses. Each entry is paired with the 1-based line the call starts on.
     */
    fun callArguments(source: String, token: String): List<Pair<Int, String>> {
        val found = mutableListOf<Pair<Int, String>>()
        var from = source.indexOf(token)
        while (from >= 0) {
            val open = from + token.length - 1
            if (source.getOrNull(open) == '(') {
                var depth = 0
                var index = open
                while (index < source.length) {
                    when (source[index]) {
                        '(' -> depth += 1
                        ')' -> {
                            depth -= 1
                            if (depth == 0) break
                        }
                    }
                    index += 1
                }
                val line = source.substring(0, from).count { it == '\n' } + 1
                found += line to source.substring(open + 1, minOf(index, source.length))
            }
            from = source.indexOf(token, from + 1)
        }
        return found
    }
}
