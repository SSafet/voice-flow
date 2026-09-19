package com.voiceflow.mobile.p3

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The paths and the small reading every P3 test shares.
 *
 * Nothing here names a P3 class, so this file compiles from the very first
 * task on, whichever P3 test files are switched on. The contract fixtures are
 * read from `contract-fixtures/shell-bridge/`, which
 * `scripts/sync-thread-protocol.sh` copies from the Atika commit pinned in
 * `thread-protocol.lock`; they are the published examples of the one contract
 * the bridge implements and are never written by this lane.
 */
internal object P3Paths {

    const val SOURCE_DIR = "android/app/src/main/kotlin/com/voiceflow/mobile"
    const val SHELL_DIR = "$SOURCE_DIR/shell"
    const val TEST_DIR = "android/app/src/test/kotlin/com/voiceflow/mobile/p3"
    const val FIXTURE_DIR = "contract-fixtures/shell-bridge"

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
                "; the P3 unit tests must run from the android module of a VoiceFlow worktree",
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

    fun text(relative: String): String = file(relative).readText()

    /** One fixture file of the shell-bridge contract. */
    fun fixture(name: String): JSONObject = JSONObject(text("$FIXTURE_DIR/$name.json"))

    fun examples(name: String): JSONArray = fixture(name).getJSONArray("examples")

    fun example(name: String, index: Int = 0): JSONObject = examples(name).getJSONObject(index)

    /** The first example, as the one line a shell would see on its way in. */
    fun exampleLine(name: String, index: Int = 0): String = example(name, index).toString()

    /** One request envelope line, exactly the shape 02 §3.6 gives. */
    fun requestLine(id: String, method: String, params: JSONObject = JSONObject(), v: Int = 1): String =
        JSONObject()
            .put("v", v)
            .put("id", id)
            .put("kind", "request")
            .put("method", method)
            .put("params", params)
            .toString()

    /** A request line whose params are whatever the caller passes, even a non-object. */
    fun requestLineRaw(id: String, method: String, params: Any, v: Int = 1): String =
        JSONObject()
            .put("v", v)
            .put("id", id)
            .put("kind", "request")
            .put("method", method)
            .put("params", params)
            .toString()
}
