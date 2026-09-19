package com.voiceflow.mobile.p3

import com.voiceflow.mobile.shell.AssetResolution
import com.voiceflow.mobile.shell.MixedContent
import com.voiceflow.mobile.shell.Navigation
import com.voiceflow.mobile.shell.ShellContract
import com.voiceflow.mobile.shell.WebViewPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The web view's configuration and its two rules, as pure data.
 *
 * The Android half that applies them is not unit-tested — it is Android's own
 * API. What is tested here is every decision 08 §3.2 and 02 §3.2 actually make:
 * that the page is a secure origin at the one address Android reserves, that
 * navigation anywhere else leaves the web view, that no file or mixed content
 * is allowed, that the fallback never lets a request reach the network, and
 * that debugging is on only in a debug build.
 */
class WebViewPolicyTest {

    private val bundle = setOf("/index.html", "/assets/index-abc.js", "/assets/index-abc.css")
    private fun bundled(path: String): Boolean = path in bundle

    // ── the configuration ───────────────────────────────────────────────────

    @Test
    fun `a release build allows no file access and no mixed content`() {
        val settings = WebViewPolicy.settingsFor(debuggable = false)
        assertEquals(ShellContract.INTERFACE_ORIGIN, settings.origin)
        assertTrue("the interface needs JavaScript", settings.javaScriptEnabled)
        assertTrue("the interface needs storage", settings.domStorageEnabled)
        assertFalse("file access is off", settings.allowFileAccess)
        assertFalse("content access is off", settings.allowContentAccess)
        assertFalse("file URLs may not read other files", settings.allowFileAccessFromFileUrls)
        assertFalse("file URLs get no universal access", settings.allowUniversalAccessFromFileUrls)
        assertEquals(MixedContent.NEVER_ALLOW, settings.mixedContentMode)
        assertTrue("safe browsing is on", settings.safeBrowsingEnabled)
        assertFalse("a release build is not debuggable", settings.webContentsDebuggingEnabled)
    }

    @Test
    fun `a debug build differs in exactly one setting`() {
        val release = WebViewPolicy.settingsFor(debuggable = false)
        val debug = WebViewPolicy.settingsFor(debuggable = true)
        assertTrue("a debug build is debuggable", debug.webContentsDebuggingEnabled)
        assertEquals(
            "nothing else changes with the build type",
            release.copy(webContentsDebuggingEnabled = true),
            debug,
        )
    }

    // ── locked navigation ───────────────────────────────────────────────────

    @Test
    fun `the one address the page may load is the asset origin`() {
        for (url in listOf(
            "https://appassets.androidplatform.net/",
            "https://appassets.androidplatform.net/t/01JQZ8X0000000000000000000",
            "https://appassets.androidplatform.net/__bridge-check",
            "https://appassets.androidplatform.net/shell-files/att-0001",
        )) {
            assertEquals("$url stays in the web view", Navigation.LOAD_IN_WEB_VIEW, WebViewPolicy.navigationFor(url))
        }
    }

    @Test
    fun `anything outside the asset origin leaves the web view`() {
        for (url in listOf(
            "https://atika.ai/",
            "https://evil.example/",
            "https://appassets.androidplatform.net.evil.example/",
            "http://appassets.androidplatform.net/",
            "https://appassets.androidplatform.net:8443/",
        )) {
            assertEquals("$url opens in the browser", Navigation.OPEN_EXTERNALLY, WebViewPolicy.navigationFor(url))
        }
    }

    @Test
    fun `a scheme that is not http or https is refused, not opened`() {
        for (url in listOf(
            "javascript:alert(1)",
            "data:text/html,<h1>x</h1>",
            "file:///etc/passwd",
            "intent://scan/#Intent;scheme=zxing;end",
            "content://com.example/x",
            "about:blank",
        )) {
            assertEquals("$url is refused", Navigation.REFUSE, WebViewPolicy.navigationFor(url))
        }
    }

    // ── the fallback handler and the staged files ───────────────────────────

    @Test
    fun `a staged attachment is served from its id`() {
        val resolved = WebViewPolicy.resolveAssetPath("/shell-files/att-0001", ::bundled)
        assertEquals(AssetResolution.StagedFile("att-0001"), resolved)
    }

    @Test
    fun `a staged path is malformed or traversal and is refused`() {
        for (path in listOf("/shell-files/", "/shell-files/a/b", "/shell-files/../index.html")) {
            val resolved = WebViewPolicy.resolveAssetPath(path, ::bundled)
            assertTrue("$path is refused, not served: $resolved", resolved is AssetResolution.Refused)
        }
        assertEquals("traversal is named", "traversal", (WebViewPolicy.resolveAssetPath("/shell-files/../index.html", ::bundled) as AssetResolution.Refused).reason)
        assertEquals("a missing id is named", "staged_id", (WebViewPolicy.resolveAssetPath("/shell-files/", ::bundled) as AssetResolution.Refused).reason)
    }

    @Test
    fun `a bundle file is a bundle file`() {
        assertEquals(
            AssetResolution.BundleFile("/assets/index-abc.js"),
            WebViewPolicy.resolveAssetPath("/assets/index-abc.js", ::bundled),
        )
        assertEquals(
            AssetResolution.BundleFile("/index.html"),
            WebViewPolicy.resolveAssetPath("/index.html", ::bundled),
        )
    }

    @Test
    fun `a path with no file falls to index html and never to the network`() {
        for (path in listOf("/", "/t/01JQZ8X0000000000000000000", "/__bridge-check", "/no/such/file")) {
            assertEquals("$path falls back", AssetResolution.IndexFallback, WebViewPolicy.resolveAssetPath(path, ::bundled))
        }
        assertEquals(
            "an unknown file under assets also falls back",
            AssetResolution.IndexFallback,
            WebViewPolicy.resolveAssetPath("/assets/gone.js", ::bundled),
        )
    }

    @Test
    fun `traversal is refused before any lookup`() {
        var lookedUp = false
        val resolved = WebViewPolicy.resolveAssetPath("/../etc/passwd") { lookedUp = true; true }
        assertTrue(resolved is AssetResolution.Refused)
        assertEquals("traversal", (resolved as AssetResolution.Refused).reason)
        assertFalse("nothing is looked up for a traversal path", lookedUp)
    }

    // ── the feature check, the transport names, the injection ───────────────

    @Test
    fun `the two webkit features the bridge needs are checked by name`() {
        assertEquals(
            listOf("DOCUMENT_START_SCRIPT", "WEB_MESSAGE_LISTENER"),
            WebViewPolicy.REQUIRED_FEATURES,
        )
        assertEquals(
            listOf("WEB_MESSAGE_LISTENER"),
            WebViewPolicy.missingFeatures { it == "DOCUMENT_START_SCRIPT" },
        )
        assertEquals(
            "both features present means nothing is missing",
            emptyList<String>(),
            WebViewPolicy.missingFeatures { true },
        )
    }

    @Test
    fun `the unsupported-feature screen names Android System WebView`() {
        assertTrue(WebViewPolicy.UNSUPPORTED_FEATURE_MESSAGE.contains("Android System WebView"))
        assertFalse(WebViewPolicy.UNSUPPORTED_FEATURE_MESSAGE.isBlank())
    }

    @Test
    fun `the injected object carries the two contract names and the version`() {
        val script = ShellContract.bootstrapScript(shellVersion = "2.0.0", interfaceBuildId = "7cbe540d")
        assertTrue("the injected object is named", script.contains(ShellContract.GLOBAL_OBJECT))
        assertTrue("the reply function is named", script.contains(ShellContract.RECEIVE_FUNCTION))
        assertTrue("the object states the contract version", script.contains(ShellContract.BRIDGE_VERSION.toString()))
        assertTrue("the object states the shell name", script.contains("android"))
        assertTrue("the object states the bundle inside this app", script.contains("7cbe540d"))
        assertFalse("the old Android mechanism is not used", script.contains("addJavascriptInterface"))
    }

    @Test
    fun `the shell files prefix and the asset origin are the fix points`() {
        assertEquals("https://appassets.androidplatform.net", ShellContract.INTERFACE_ORIGIN)
        assertEquals("/shell-files/", ShellContract.SHELL_FILES_PREFIX)
        assertEquals("/shell-files/att-1", ShellContract.stagedRequestPath("att-1"))
        assertTrue(
            ShellContract.stagedFileUrl("att-1").startsWith(
                ShellContract.INTERFACE_ORIGIN + ShellContract.SHELL_FILES_PREFIX,
            ),
        )
    }
}
