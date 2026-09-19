package com.voiceflow.mobile.p4

import org.w3c.dom.Document
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The paths and the small readers every P4 test shares.
 *
 * Nothing here names a P4 application class, so this file compiles from the
 * very first task on, whichever P4 test files are switched on. The worktree
 * root is found the way P1's own helper finds it: the nearest folder at or
 * above the test working directory that holds `thread-protocol.lock`.
 */
internal object P4Paths {

    const val ANDROID_NS = "http://schemas.android.com/apk/res/android"

    const val SOURCE_DIR = "android/app/src/main/kotlin/com/voiceflow/mobile"

    const val ACCESSIBILITY_XML = "android/app/src/main/res/xml/accessibility_service.xml"

    /** The VoiceFlow worktree root. */
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
                "; the P4 unit tests must run from the android module of a VoiceFlow worktree",
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

    /** The text of a main-source file that must exist. */
    fun source(relative: String): String = file("$SOURCE_DIR/$relative").readText()

    /** Every main-source file of the app, keyed by file name. */
    fun mainSources(): Map<String, String> {
        val dir = path(SOURCE_DIR)
        if (!dir.isDirectory) throw AssertionError("missing source directory: $SOURCE_DIR (worktree ${repoRoot.absolutePath})")
        return dir.listFiles().orEmpty()
            .filter { it.isFile && it.name.endsWith(".kt") }
            .associate { it.name to it.readText() }
    }

    /**
     * A player whose move (a lexical call) is recorded in order: each P4 test
     * that checks an ordering calls [note] and compares the whole list, so a
     * wrong order fails by naming the sequence, never by timing.
     */
    class Steps {
        private val seen = mutableListOf<String>()
        fun note(step: String) { seen.add(step) }
        fun all(): List<String> = seen.toList()
        override fun toString(): String = seen.toString()
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
}
