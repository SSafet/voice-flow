package com.voiceflow.mobile.p3

import com.voiceflow.mobile.shell.BundleValidation
import com.voiceflow.mobile.shell.InterfaceBundle
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The interface bundle inside the app: where it is copied from, the build id
 * the build records for it, and the rule that a bundle whose recorded id does
 * not match its own `index.html` is refused by name rather than run.
 *
 * The build id is the same value W2 computes for the gateway's version
 * document — the first twelve hexadecimal characters of the SHA-256 of
 * `index.html` — so the app and the server agree about which bundle each has.
 */
class BundleEmbedTest {

    private fun bundleDir(indexHtml: String, manifest: JSONObject?): File {
        val dir = Files.createTempDirectory("p3-bundle").toFile()
        File(dir, "index.html").writeText(indexHtml)
        manifest?.let { File(dir, InterfaceBundle.MANIFEST_FILE).writeText(it.toString()) }
        return dir
    }

    private fun manifestFor(indexHtml: String, buildId: String = InterfaceBundle.buildId(indexHtml.toByteArray()), protocol: Int = 2): JSONObject =
        JSONObject()
            .put(InterfaceBundle.BUILD_ID_FIELD, buildId)
            .put(InterfaceBundle.PROTOCOL_VERSION_FIELD, protocol)

    // ── the build id ────────────────────────────────────────────────────────

    @Test
    fun `the build id is the first twelve hex characters of the page's sha256`() {
        assertEquals("2cf24dba5fb0", InterfaceBundle.buildId("hello".toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun `the build id is lower case hex and twelve characters long`() {
        val id = InterfaceBundle.buildId("<html>one</html>".toByteArray(Charsets.UTF_8))
        assertEquals(12, id.length)
        assertTrue("only lower-case hex: $id", Regex("^[0-9a-f]{12}$").matches(id))
        assertTrue(
            "a different page has a different id",
            InterfaceBundle.buildId("<html>two</html>".toByteArray(Charsets.UTF_8)) != id,
        )
    }

    // ── the recorded id is checked ──────────────────────────────────────────

    @Test
    fun `a bundle whose id and protocol match is valid`() {
        val page = "<html>the interface</html>"
        assertEquals(BundleValidation.Valid, InterfaceBundle.validate(bundleDir(page, manifestFor(page))))
    }

    @Test
    fun `a bundle whose recorded id is wrong is refused by name`() {
        val page = "<html>the interface</html>"
        val validation = InterfaceBundle.validate(bundleDir(page, manifestFor(page, buildId = "000000000000")))
        assertEquals(BundleValidation.Invalid("interfaceBuildId"), validation)
    }

    @Test
    fun `a bundle with no build json is refused by name`() {
        assertEquals(BundleValidation.Invalid("build.json"), InterfaceBundle.validate(bundleDir("<html/>", null)))
    }

    @Test
    fun `a bundle with no index html is refused by name`() {
        val dir = Files.createTempDirectory("p3-bundle-empty").toFile()
        File(dir, InterfaceBundle.MANIFEST_FILE).writeText(manifestFor("<html/>").toString())
        assertEquals(BundleValidation.Invalid("index.html"), InterfaceBundle.validate(dir))
    }

    @Test
    fun `a bundle built for another protocol is refused by name`() {
        val page = "<html>the interface</html>"
        val validation = InterfaceBundle.validate(bundleDir(page, manifestFor(page, protocol = 1)))
        assertEquals(BundleValidation.Invalid("threadProtocolVersion"), validation)
    }

    @Test
    fun `a bundle with a blank id is refused by name`() {
        val page = "<html>the interface</html>"
        val validation = InterfaceBundle.validate(bundleDir(page, manifestFor(page, buildId = "")))
        assertEquals(BundleValidation.Invalid("interfaceBuildId"), validation)
    }

    // ── where the files live inside the app ─────────────────────────────────

    @Test
    fun `the bundle lives in one asset folder and the fallback serves its page`() {
        assertEquals("interface", InterfaceBundle.ASSET_DIR)
        assertEquals("interface/index.html", InterfaceBundle.assetPath("/"))
        assertEquals("interface/assets/index-abc.js", InterfaceBundle.assetPath("/assets/index-abc.js"))
        assertEquals("interface/__bridge-check", InterfaceBundle.assetPath("/__bridge-check"))
    }

    // ── the build step that embeds it ───────────────────────────────────────

    @Test
    fun `the gradle build copies the bundle and refuses one that is missing or stale`() {
        val gradle = P3Paths.text("android/app/build.gradle.kts")
        assertTrue("the copy step is a Gradle task", gradle.contains("syncInterfaceAssets"))
        assertTrue("the lock check is a Gradle task", gradle.contains("checkInterfaceBundle"))
        assertTrue("the build checks the bundle before it compiles", gradle.contains("preBuild"))
        assertTrue("the P3 not-due filter is wired", gradle.contains("p3.notDue"))
    }

    @Test
    fun `the copy script is pinned to the contract lock and has a check mode`() {
        val script = P3Paths.path("scripts/sync-interface-bundle.sh")
        assertTrue("scripts/sync-interface-bundle.sh exists", script.isFile)
        assertTrue("the script is executable", script.canExecute())
        val text = script.readText()
        assertTrue("it has a check mode", text.contains("--check"))
        assertTrue("it has an update mode", text.contains("--update"))
        assertTrue("it reads the one lock", text.contains("thread-protocol.lock"))
    }

    @Test
    fun `the lock the copy is pinned to names the Atika commit`() {
        val lock = P3Paths.text("thread-protocol.lock")
        val commit = lock.lineSequence().firstOrNull { it.startsWith("atika_commit=") }
        assertTrue("thread-protocol.lock names atika_commit", commit != null)
        assertTrue(
            "the pinned commit is a real hash",
            Regex("^atika_commit=[0-9a-f]{40}$").matches(commit!!.trim()),
        )
    }
}
