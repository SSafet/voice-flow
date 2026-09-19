package com.voiceflow.mobile.p3

import com.voiceflow.mobile.generated.BridgeCapability
import com.voiceflow.mobile.generated.BridgeErrorCode
import com.voiceflow.mobile.generated.ComposerInsertSource
import com.voiceflow.mobile.generated.EndpointAuthMode
import com.voiceflow.mobile.generated.EndpointID
import com.voiceflow.mobile.generated.EndpointKind
import com.voiceflow.mobile.generated.EndpointState
import com.voiceflow.mobile.generated.FormFactor
import com.voiceflow.mobile.generated.PermissionState
import com.voiceflow.mobile.generated.ShellAccount
import com.voiceflow.mobile.generated.ShellName
import com.voiceflow.mobile.shell.AndroidPanes
import com.voiceflow.mobile.shell.BridgeRefusal
import com.voiceflow.mobile.shell.ExternalOpen
import com.voiceflow.mobile.shell.ShareIntake
import com.voiceflow.mobile.shell.ShareRoute
import com.voiceflow.mobile.shell.ShellBridge
import com.voiceflow.mobile.shell.ShellContract
import com.voiceflow.mobile.shell.ShellDescriptorFactory
import com.voiceflow.mobile.shell.ShellDescriptorInput
import com.voiceflow.mobile.shell.ShellPermissions
import com.voiceflow.mobile.shell.TokenFreshness
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The decisions behind the native methods, as pure functions, plus the
 * dispatch of the methods a phone answers without touching the operating
 * system.
 *
 * The Android half that speaks to the microphone, the pickers and the
 * notification manager is not unit-tested; it is Android's own API and 08 §8
 * observes it on the phone. What is tested here are the rules those methods
 * must obey: which capabilities are advertised, what a permission refusal
 * looks like, when a token is minted again, which links may leave the app,
 * where a share lands, and the two attachment rules of 08 §3.11.
 */
class NativeCapabilitiesTest {

    private val fakeHost = FakeShellHost()
    private val bridge = ShellBridge(fakeHost)

    private fun resultOf(line: String): JSONObject {
        val out = bridge.handleRequest(line) ?: throw AssertionError("no answer for $line")
        val response = JSONObject(out)
        assertTrue("expected ok for $line: $response", response.getBoolean("ok"))
        return response.getJSONObject("result")
    }

    private fun errorOf(line: String): JSONObject {
        val out = bridge.handleRequest(line) ?: throw AssertionError("no answer for $line")
        val response = JSONObject(out)
        assertFalse("expected a refusal for $line: $response", response.getBoolean("ok"))
        return response.getJSONObject("error")
    }

    // ── the descriptor the shell answers ────────────────────────────────────

    @Test
    fun `the android descriptor is the phone record and the seven capabilities`() {
        val descriptor = ShellDescriptorFactory.describe(
            ShellDescriptorInput(
                shellVersion = "2.0.0",
                interfaceBuildId = "7cbe540d",
                osVersion = "16",
                endpointState = EndpointState.Ready,
                account = ShellAccount(userID = "usr_01J8ZK3F9A", displayName = "Safet", email = "owner@example.com"),
            ),
        )
        assertEquals(ShellName.Android, descriptor.shell)
        assertEquals(1L, descriptor.v)
        assertEquals("2.0.0", descriptor.shellVersion)
        assertEquals("7cbe540d", descriptor.interfaceBuildID)
        assertEquals(FormFactor.Phone, descriptor.platform.formFactor)
        assertEquals("Android", descriptor.platform.os)
        assertEquals("16", descriptor.platform.osVersion)
        assertEquals(ShellContract.ANDROID_CAPABILITIES, descriptor.capabilities)
        assertEquals(1, descriptor.endpoints.size)
        assertEquals(EndpointID.Cloud, descriptor.endpoints[0].id)
        assertEquals(EndpointKind.Atika, descriptor.endpoints[0].kind)
        assertEquals(EndpointAuthMode.ShellToken, descriptor.endpoints[0].authMode)
        assertEquals("https://atika.ai", descriptor.endpoints[0].baseURL)
        assertEquals("Atika", descriptor.endpoints[0].label)
        assertNull("a cloud endpoint carries no local secret", descriptor.endpoints[0].secret)
        assertNotNull(descriptor.account)
    }

    @Test
    fun `the android descriptor advertises nothing it cannot do`() {
        val descriptor = ShellDescriptorFactory.describe(
            ShellDescriptorInput("2.0.0", "7cbe540d", "16", EndpointState.SignedOut, endpointStateReason = "revoked"),
        )
        for (absent in listOf(
            BridgeCapability.CaptureScreen,
            BridgeCapability.Annotate,
            BridgeCapability.FilesPickFolder,
            BridgeCapability.FilesReveal,
        )) {
            assertFalse("$absent is never advertised on a phone", descriptor.capabilities.contains(absent))
        }
        assertEquals("revoked", descriptor.endpoints[0].stateReason)
        assertNull("signed out means no account", descriptor.account)
    }

    // ── permissions ─────────────────────────────────────────────────────────

    @Test
    fun `the permission rows are the phone's own and carry their state`() {
        assertEquals(
            listOf("microphone", "notifications", "overlay", "battery_exemption", "accessibility", "assist_gesture", "location"),
            AndroidPanes.ALL,
        )
        val rows = ShellPermissions.rows(mapOf("microphone" to PermissionState.Ok, "notifications" to PermissionState.Needed))
        assertEquals("one row per pane, in order", AndroidPanes.ALL, rows.map { it.id })
        for (row in rows) {
            assertFalse("row ${row.id} has a title", row.title.isBlank())
            assertFalse("row ${row.id} has a sentence", row.detail.isBlank())
            assertFalse("row ${row.id} has an action", row.actionLabel.isBlank())
        }
        assertEquals(PermissionState.Ok, rowState(rows, "microphone"))
        assertEquals(PermissionState.Needed, rowState(rows, "notifications"))
        assertEquals("an unreported pane is needed, never unavailable", PermissionState.Needed, rowState(rows, "overlay"))
    }

    @Test
    fun `a refused permission answers permission_denied with the row that fixes it`() {
        val needed = ShellPermissions.rows(mapOf("microphone" to PermissionState.Needed))
        val refusal = ShellPermissions.refusalFor(BridgeCapability.Dictate, needed)
        assertNotNull("dictating without the microphone is refused", refusal)
        assertEquals(BridgeErrorCode.PermissionDenied, refusal!!.code)
        assertEquals("microphone", refusal.permissionId)

        val ok = ShellPermissions.rows(mapOf("microphone" to PermissionState.Ok))
        assertNull("an allowed microphone is not refused", ShellPermissions.refusalFor(BridgeCapability.Dictate, ok))
    }

    @Test
    fun `only the capabilities that need a permission have one`() {
        assertEquals("microphone", ShellPermissions.requiredRowFor(BridgeCapability.Dictate))
        assertEquals("notifications", ShellPermissions.requiredRowFor(BridgeCapability.Notify))
        assertNull(ShellPermissions.requiredRowFor(BridgeCapability.ExternalOpen))
        assertNull(ShellPermissions.requiredRowFor(BridgeCapability.Speak))
        assertNull(ShellPermissions.requiredRowFor(BridgeCapability.FilesPick))
        assertNull(ShellPermissions.requiredRowFor(BridgeCapability.FilesSave))
    }

    @Test
    fun `every pane id opens a real settings screen`() {
        for (id in AndroidPanes.ALL) {
            assertTrue("$id has a known pane", AndroidPanes.isKnown(id))
            assertNotNull("$id names a system action", AndroidPanes.intentAction(id))
        }
        assertFalse(AndroidPanes.isKnown("teleport"))
        assertNull(AndroidPanes.intentAction("teleport"))
    }

    // ── the token rule and the outside link rule ────────────────────────────

    @Test
    fun `a token is minted again only inside the last thirty seconds`() {
        assertEquals(30_000L, TokenFreshness.RENEW_WITHIN_MILLIS)
        assertTrue("exactly at the boundary, mint again", TokenFreshness.needsMint(expiresAtMillis = 100_000, nowMillis = 70_000))
        assertFalse("one millisecond earlier, keep it", TokenFreshness.needsMint(expiresAtMillis = 100_000, nowMillis = 69_999))
        assertTrue("an expired token is minted again", TokenFreshness.needsMint(expiresAtMillis = 100_000, nowMillis = 200_000))
    }

    @Test
    fun `only an http or https address may leave the app`() {
        assertTrue(ExternalOpen.isOpenable("https://atika.ai/"))
        assertTrue(ExternalOpen.isOpenable("http://localhost:8792/"))
        for (url in listOf("javascript:alert(1)", "file:///etc/passwd", "content://x", "intent://x", "data:text/html,x", "")) {
            assertFalse("$url is not opened", ExternalOpen.isOpenable(url))
        }
    }

    // ── a share lands in the composer ───────────────────────────────────────

    @Test
    fun `a share is routed by what it carries`() {
        assertEquals(ShareRoute.COMPOSER_TEXT, ShareIntake.route("android.intent.action.SEND", "text/plain"))
        assertEquals(ShareRoute.COMPOSER_ATTACHMENT, ShareIntake.route("android.intent.action.SEND", "image/jpeg"))
        assertEquals(ShareRoute.IGNORE, ShareIntake.route("android.intent.action.MAIN", "text/plain"))
        assertEquals(ShareRoute.IGNORE, ShareIntake.route("android.intent.action.SEND", "application/pdf"))
    }

    @Test
    fun `a shared link opens in the composer as text`() {
        val line = ShareIntake.composerLine(
            bridge,
            action = "android.intent.action.SEND",
            mime = "text/plain",
            text = "https://example.com/article",
        )
        assertNotNull("a shared link is not dropped", line)
        val event = JSONObject(line!!)
        assertEquals("composer.insert", event.getString("topic"))
        val data = event.getJSONObject("data")
        assertEquals("https://example.com/article", data.getString("text"))
        assertEquals("share", data.getString("source"))
        assertFalse("with no thread named it lands in the draft composer", data.has("threadId"))
    }

    @Test
    fun `a shared note is cleaned and a share with no text is dropped`() {
        assertEquals("fix\uFFFD the cart", ShareIntake.sharedText("android.intent.action.SEND", "text/plain", "fix\u0000 the cart"))
        assertNull(ShareIntake.sharedText("android.intent.action.SEND", "text/plain", null))
        assertNull(
            "an image arrives as an attachment, not as text",
            ShareIntake.composerLine(bridge, "android.intent.action.SEND", "image/jpeg", "IMG_1.jpg"),
        )
    }

    // ── the methods that only need the host ─────────────────────────────────

    @Test
    fun `the phone answers permissions list and permissions open`() {
        fakeHost.permissionRows = listOf(permissionRow(), permissionRow(id = "notifications", state = PermissionState.Needed))
        val result = resultOf(P3Paths.requestLine("p1", "permissions.list"))
        assertEquals(2, result.getJSONArray("rows").length())
        assertEquals("microphone", result.getJSONArray("rows").getJSONObject(0).getString("id"))
        assertEquals("ok", result.getJSONArray("rows").getJSONObject(0).getString("state"))
        assertEquals("needed", result.getJSONArray("rows").getJSONObject(1).getString("state"))

        val opened = P3Paths.requestLine("p2", "permissions.open", JSONObject().put("id", "microphone"))
        assertTrue(JSONObject(bridge.handleRequest(opened)!!).getBoolean("ok"))
        assertEquals("microphone", fakeHost.lastPermissionOpen)
    }

    @Test
    fun `the phone answers the three authentication methods`() {
        val token = resultOf(P3Paths.requestLine("a1", "auth.token", JSONObject().put("endpointId", "cloud")))
        assertEquals("tok-0001", token.getString("accessToken"))
        assertEquals("2026-09-19T10:00:00Z", token.getString("expiresAt"))

        val signIn = resultOf(P3Paths.requestLine("a2", "auth.signIn", JSONObject().put("endpointId", "cloud")))
        assertEquals(true, signIn.getBoolean("started"))

        val signOut = resultOf(P3Paths.requestLine("a3", "auth.signOut", JSONObject().put("endpointId", "cloud")))
        assertEquals("sign out answers an empty result", 0, signOut.length())
        assertEquals(EndpointID.Cloud, fakeHost.lastSignOut)
    }

    @Test
    fun `a signed-out device answers not_signed_in rather than a token`() {
        fakeHost.accessTokenFailure = BridgeRefusal(BridgeErrorCode.NotSignedIn, "This phone is not signed in.")
        val error = errorOf(P3Paths.requestLine("a4", "auth.token", JSONObject().put("endpointId", "cloud")))
        assertEquals("not_signed_in", error.getString("code"))
    }

    @Test
    fun `external open passes the address to the host and refuses a bad one first`() {
        resultOf(P3Paths.requestLine("e1", "external.open", JSONObject().put("url", "https://atika.ai/")))
        assertEquals("https://atika.ai/", fakeHost.lastExternalOpen)

        val before = fakeHost.calls.size
        val error = errorOf(P3Paths.requestLine("e2", "external.open", JSONObject().put("url", "javascript:alert(1)")))
        assertEquals("internal", error.getString("code"))
        assertEquals("a bad address never reaches the host", before, fakeHost.calls.size)
    }

    @Test
    fun `files save hands over the link and never downloads anything itself`() {
        val result = resultOf(P3Paths.requestLine("s1", "files.save", JSONObject().put("url", "https://atika.ai/f/x").put("name", "report.pdf")))
        assertEquals(true, result.getBoolean("started"))
        assertTrue(fakeHost.calls.contains("files.save"))
    }

    @Test
    fun `the capability methods the phone has are all answered`() {
        fakeHost.stagedAttachments = emptyList()
        val pick = resultOf(P3Paths.requestLine("c1", "files.pick", JSONObject().put("multiple", false).put("accept", JSONArray())))
        assertEquals(0, pick.getJSONArray("attachments").length())

        val dictate = resultOf(P3Paths.requestLine("c2", "dictate.start", JSONObject().put("threadId", "t1")))
        assertEquals("dict-0001", dictate.getString("captureId"))

        val spoken = resultOf(P3Paths.requestLine("c3", "speak.start", JSONObject().put("text", "hello").put("threadId", "t1")))
        assertEquals("play-0001", spoken.getString("playbackId"))

        resultOf(P3Paths.requestLine("c4", "speak.stop", JSONObject().put("playbackId", "play-0001")))
        resultOf(P3Paths.requestLine("c5", "dictate.stop", JSONObject().put("captureId", "dict-0001")))
        assertTrue(fakeHost.calls.containsAll(listOf("files.pick", "dictate.start", "speak.start", "speak.stop", "dictate.stop")))
    }

    @Test
    fun `the android capability names are the contract's, not the design's older settings dot names`() {
        val spellings = ShellContract.ANDROID_CAPABILITIES.map { ShellContract.capabilitySpelling(it) }
        assertTrue("permissions is the fixed spelling", spellings.contains("permissions"))
        assertFalse("settings.permissions is not a capability name", spellings.contains("settings.permissions"))
        assertFalse("settings.open is not a capability name", spellings.contains("settings.open"))
        assertTrue(
            "the permissions methods are the fixed spellings",
            ShellContract.methodSpelling(com.voiceflow.mobile.generated.BridgeMethodName.PermissionsList).startsWith("permissions."),
        )
    }

    @Test
    fun `the share event names a thread when the shell has one`() {
        val event = JSONObject(bridge.composerInsert("hello", ComposerInsertSource.Share, threadId = "t9"))
        assertEquals("t9", event.getJSONObject("data").getString("threadId"))
    }
}
