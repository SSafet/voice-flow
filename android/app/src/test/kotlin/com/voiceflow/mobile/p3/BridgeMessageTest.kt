package com.voiceflow.mobile.p3

import com.voiceflow.mobile.generated.BridgeErrorCode
import com.voiceflow.mobile.generated.BridgeMethodName
import com.voiceflow.mobile.generated.ComposerInsertSource
import com.voiceflow.mobile.shell.BridgeCodec
import com.voiceflow.mobile.shell.BridgeRefusal
import com.voiceflow.mobile.shell.RequestParse
import com.voiceflow.mobile.shell.ShellBridge
import com.voiceflow.mobile.shell.ShellContract
import com.voiceflow.mobile.shell.ShellText
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bridge's message handling, driven with the shell-bridge contract's own
 * fixtures.
 *
 * Every rule here is one of 02 §3.6's: the envelopes, the version, the fixed
 * error codes, the capability gate, the method table, and the rule that an
 * attachment crosses as a same-origin reference and never as bytes. The
 * fixture files are the published examples from the Atika commit pinned in
 * `thread-protocol.lock`; they are inputs to this test, not expected copies of
 * anything this package returns.
 */
class BridgeMessageTest {

    private val fakeHost = FakeShellHost()
    private val bridge = ShellBridge(fakeHost)
    private val host get() = fakeHost

    private fun responseFor(line: String): JSONObject {
        val out = bridge.handleRequest(line)
        assertNotNull("the bridge answers a request; it returned null for $line", out)
        return JSONObject(out!!)
    }

    private fun okResponse(line: String): JSONObject {
        val out = responseFor(line)
        assertTrue("expected ok for $line, got $out", out.getBoolean("ok"))
        assertTrue("an ok response carries result", out.has("result"))
        assertFalse("an ok response carries no error", out.has("error"))
        return out.getJSONObject("result")
    }

    private fun errorResponse(line: String): JSONObject {
        val out = responseFor(line)
        assertFalse("expected a refusal for $line, got $out", out.getBoolean("ok"))
        assertFalse("a refusal carries no result", out.has("result"))
        assertTrue("a refusal carries error", out.has("error"))
        return out.getJSONObject("error")
    }

    private fun strings(array: JSONArray): List<String> = (0 until array.length()).map { array.getString(it) }

    // ── the contract fixtures parse ─────────────────────────────────────────

    @Test
    fun `the request examples of the contract parse into the model the shell uses`() {
        val examples = P3Paths.examples("BridgeRequest")
        assertTrue("the contract publishes at least one request example", examples.length() >= 1)
        for (index in 0 until examples.length()) {
            val line = examples.getJSONObject(index).toString()
            val parsed = BridgeCodec.parseRequest(line)
            assertTrue("the example request $index parses: $line", parsed is RequestParse.Accepted)
            val request = (parsed as RequestParse.Accepted).request
            assertEquals("the id survives", examples.getJSONObject(index).getString("id"), request.id)
            assertEquals(
                "the method is one the contract names",
                examples.getJSONObject(index).getString("method"),
                ShellContract.methodSpelling(request.method),
            )
        }
    }

    @Test
    fun `the prompt's known request shape parses with its thread id`() {
        val line = P3Paths.exampleLine("BridgeRequest", 1)
        val request = (BridgeCodec.parseRequest(line) as RequestParse.Accepted).request
        assertEquals(BridgeMethodName.DictateStart, request.method)
        assertEquals("6B1F0E0C-52C1-4C55-9B5B-0D4A1B3F9A2C", request.params.getString("threadId"))
    }

    // ── the version, and refusals by name ───────────────────────────────────

    @Test
    fun `a request from another bridge version is refused by name and the id is preserved`() {
        val error = errorResponse(P3Paths.requestLine("r1", "shell.describe", v = 2))
        assertEquals("not_supported", error.getString("code"))
        assertTrue("the refusal names the bridge version", error.getString("message").contains("1"))
        assertTrue("and the version the request asked for", error.getString("message").contains("2"))
        assertTrue("and says what the disagreement is", error.getString("message").contains("version"))
        assertEquals("the answer keeps the request's id", "r1", responseFor(P3Paths.requestLine("r1", "shell.describe", v = 2)).getString("id"))
    }

    @Test
    fun `an unknown method is refused by name`() {
        val error = errorResponse(P3Paths.requestLine("r2", "shell.teleport"))
        assertEquals("not_supported", error.getString("code"))
        assertTrue("the refusal names the method", error.getString("message").contains("shell.teleport"))
    }

    @Test
    fun `a line that is not a request is not answered and never thrown`() {
        for (line in listOf("not json", "{}", "[]", "null", "", """{"v":1,"id":"x","kind":"response","ok":true}""")) {
            val out = bridge.handleRequest(line)
            assertNull("no usable id means no answer; the shell logs it: <$line>", out)
        }
    }

    @Test
    fun `params that are not an object are refused`() {
        val error = errorResponse(P3Paths.requestLineRaw("r3", "shell.describe", JSONArray().put("x")))
        assertEquals("internal", error.getString("code"))
        assertEquals("r3", responseFor(P3Paths.requestLineRaw("r3", "shell.describe", JSONArray().put("x"))).getString("id"))
    }

    @Test
    fun `a request with no params object is treated as empty`() {
        val line = JSONObject()
            .put("v", 1).put("id", "r4").put("kind", "request").put("method", "shell.describe").toString()
        val result = okResponse(line)
        assertEquals("android", result.getString("shell"))
        assertEquals(1, result.getInt("v"))
    }

    // ── the descriptor, against the contract's own android example ──────────

    @Test
    fun `shell describe answers the descriptor the contract's android example lists`() {
        val result = okResponse(P3Paths.requestLine("r5", "shell.describe"))
        val android = P3Paths.example("ShellDescriptor", 1)
        assertEquals(1, result.getInt("v"))
        assertEquals("android", result.getString("shell"))
        assertEquals("phone", result.getJSONObject("platform").getString("formFactor"))
        assertEquals(
            "the capability list is exactly the contract's android list",
            strings(android.getJSONArray("capabilities")),
            strings(result.getJSONArray("capabilities")),
        )
        val endpoints = result.getJSONArray("endpoints")
        assertEquals("Android reports one endpoint", 1, endpoints.length())
        assertEquals("cloud", endpoints.getJSONObject(0).getString("id"))
        assertEquals("atika", endpoints.getJSONObject(0).getString("kind"))
        assertEquals("https://atika.ai", endpoints.getJSONObject(0).getString("baseUrl"))
        assertEquals("shell-token", endpoints.getJSONObject(0).getString("authMode"))
    }

    // ── the live capability gate ────────────────────────────────────────────

    @Test
    fun `a capability the shell does not have is refused and never reaches the host`() {
        val absent = mapOf(
            "capture.screen" to "capture.screen",
            "annotate.start" to "annotate",
            "files.pickFolder" to "files.pickFolder",
            "files.reveal" to "files.reveal",
        )
        for ((method, capability) in absent) {
            val before = host.calls.size
            val error = errorResponse(P3Paths.requestLine("cap", method, JSONObject().put("threadId", "t1")))
            assertEquals("$method is not offered", "not_supported", error.getString("code"))
            assertTrue(
                "the refusal names the capability $capability",
                error.getString("message").contains(capability),
            )
            assertEquals("the host was not reached for $method", before, host.calls.size)
        }
    }

    @Test
    fun `the android capability list is the design's list and nothing else`() {
        val android = P3Paths.example("ShellDescriptor", 1)
        assertEquals(
            strings(android.getJSONArray("capabilities")),
            ShellContract.ANDROID_CAPABILITIES.map { ShellContract.capabilitySpelling(it) },
        )
        for (absent in listOf("capture.screen", "annotate", "files.pickFolder", "files.reveal")) {
            assertFalse("$absent is never advertised", ShellContract.ANDROID_CAPABILITIES.any {
                ShellContract.capabilitySpelling(it) == absent
            })
        }
    }

    // ── errors: fixed codes, never a throw ──────────────────────────────────

    @Test
    fun `permission_denied carries the row that would fix it`() {
        host.dictateStartFailure = BridgeRefusal(
            BridgeErrorCode.PermissionDenied,
            "Microphone is not allowed.",
            permissionId = "microphone",
        )
        val error = errorResponse(P3Paths.requestLine("r6", "dictate.start", JSONObject().put("threadId", "t1")))
        assertEquals("permission_denied", error.getString("code"))
        assertEquals("microphone", error.getString("permissionId"))
        assertFalse(error.getString("message").isBlank())
    }

    @Test
    fun `an unexpected failure is internal and never thrown out of the bridge`() {
        host.notifyFailure = IllegalStateException("notification service is gone")
        val params = JSONObject()
            .put("threadId", "t1").put("title", "Fix cart").put("body", "Needs your approval · pantria")
            .put("tag", "thread:t1")
        val error = errorResponse(P3Paths.requestLine("r7", "notify", params))
        assertEquals("internal", error.getString("code"))
        assertTrue("the detail carries the cause", error.optString("detail").contains("notification service is gone"))
    }

    @Test
    fun `a required parameter that is missing is refused naming the field`() {
        val missingTitle = JSONObject()
            .put("threadId", "t1").put("body", "Needs your approval · pantria").put("tag", "thread:t1")
        val error = errorResponse(P3Paths.requestLine("r8", "notify", missingTitle))
        assertEquals("internal", error.getString("code"))
        assertTrue("the message names title", error.getString("message").contains("title"))

        val missingMultiple = JSONObject().put("accept", JSONArray().put("image/*"))
        val pickError = errorResponse(P3Paths.requestLine("r9", "files.pick", missingMultiple))
        assertEquals("internal", pickError.getString("code"))
        assertTrue("the message names multiple", pickError.getString("message").contains("multiple"))
    }

    @Test
    fun `a response is exactly one of result or error and is always version 1`() {
        val ok = responseFor(P3Paths.requestLine("r10", "shell.describe"))
        assertEquals(1, ok.getInt("v"))
        assertEquals("r10", ok.getString("id"))
        assertEquals("response", ok.getString("kind"))
        assertTrue("exactly one of result or error on an ok answer", ok.has("result") != ok.has("error"))

        val bad = responseFor(P3Paths.requestLine("r11", "shell.teleport"))
        assertEquals(1, bad.getInt("v"))
        assertEquals("r11", bad.getString("id"))
        assertEquals("response", bad.getString("kind"))
        assertTrue("exactly one of result or error on a refusal", bad.has("result") != bad.has("error"))
    }

    @Test
    fun `shell ready is idempotent and answers an empty result`() {
        val line = P3Paths.requestLine("r12", "shell.ready", JSONObject().put("buildId", "7cbe540d"))
        val first = bridge.handleRequest(line)
        val second = bridge.handleRequest(line)
        assertEquals("the same request answers the same line", first, second)
        assertEquals("ready carries the build id", "7cbe540d", host.readyBuildId)
        val result = JSONObject(first!!).getJSONObject("result")
        assertEquals("a method with no result answers an empty object", 0, result.length())
    }

    // ── attachments: references, same origin, never bytes ───────────────────

    @Test
    fun `files pick returns same-origin references and never bytes`() {
        host.stagedAttachments = listOf(stagedFile())
        val params = JSONObject().put("multiple", true).put("accept", JSONArray())
        val result = okResponse(P3Paths.requestLine("r13", "files.pick", params))
        val attachment = result.getJSONArray("attachments").getJSONObject(0)
        assertEquals("att-0001", attachment.getString("id"))
        assertEquals("file", attachment.getString("kind"))
        assertEquals("application/pdf", attachment.getString("mime"))
        assertEquals(48213L, attachment.getLong("bytes"))
        assertEquals("invoice.pdf", attachment.getString("name"))
        assertEquals(
            "the interface fetches the bytes from the one origin the web view may load",
            "${ShellContract.INTERFACE_ORIGIN}${ShellContract.SHELL_FILES_PREFIX}att-0001",
            attachment.getString("url"),
        )
        assertFalse("the reference carries no data field", attachment.has("data"))
        val raw = bridge.handleRequest(P3Paths.requestLine("r14", "files.pick", params))!!
        assertFalse("no base64 crosses the bridge", raw.contains("base64"))
    }

    @Test
    fun `the staged file address is same-origin and nothing else is`() {
        val url = ShellContract.stagedFileUrl("att-0001")
        assertEquals("https://appassets.androidplatform.net/shell-files/att-0001", url)
        assertTrue(ShellContract.isStagedFileUrl(url))
        assertTrue(
            "the contract's own android example is recognised",
            ShellContract.isStagedFileUrl(P3Paths.example("FilesPickResult").getJSONArray("attachments").getJSONObject(0).getString("url")),
        )
        assertFalse("a Mac loopback address is not this shell's", ShellContract.isStagedFileUrl("http://localhost:8792/shell-files/att-0001"))
        assertFalse("another origin is not this shell's", ShellContract.isStagedFileUrl("https://evil.example/shell-files/att-0001"))
    }

    // ── cleaning, on the way out ────────────────────────────────────────────

    @Test
    fun `cleaning replaces the two forbidden sequences and leaves real text alone`() {
        assertEquals("a\uFFFDb", ShellText.clean("a\u0000b"))
        assertEquals("\uFFFD", ShellText.clean("\uD800"))
        assertEquals("\uFFFD", ShellText.clean("\uDC00"))
        assertEquals("emoji \uD83D\uDE00 stays", ShellText.clean("emoji \uD83D\uDE00 stays"))
        assertEquals("", ShellText.clean(""))
    }

    @Test
    fun `a dictation's text is cleaned before it reaches the interface`() {
        host.dictateStopResult = com.voiceflow.mobile.generated.DictateStopResult(text = "fix\u0000 the cart")
        val params = JSONObject().put("captureId", "dict-0001")
        val result = okResponse(P3Paths.requestLine("r15", "dictate.stop", params))
        assertEquals("fix\uFFFD the cart", result.getString("text"))
    }

    @Test
    fun `notify cleans what a person will see and speak cleans what is spoken`() {
        val params = JSONObject()
            .put("threadId", "t1").put("title", "Ti\u0000tle").put("body", "done\u0000").put("tag", "tag:1")
        okResponse(P3Paths.requestLine("r16", "notify", params))
        assertEquals("Ti\uFFFDtle", host.lastNotifyTitle)

        val speak = JSONObject().put("text", "say\u0000 this").put("threadId", "t1")
        okResponse(P3Paths.requestLine("r17", "speak.start", speak))
        assertEquals("say\uFFFD this", host.lastSpeakText)
    }

    // ── events ──────────────────────────────────────────────────────────────

    @Test
    fun `composer insert is the event of the contract and cleans its text`() {
        val line = bridge.composerInsert("fix\u0000 the cart", ComposerInsertSource.Share)
        val event = JSONObject(line)
        assertEquals(1, event.getInt("v"))
        assertEquals("event", event.getString("kind"))
        assertEquals("composer.insert", event.getString("topic"))
        val data = event.getJSONObject("data")
        assertEquals("fix\uFFFD the cart", data.getString("text"))
        assertEquals("share", data.getString("source"))
        assertFalse("an absent thread id means the draft composer", data.has("threadId"))
    }

    @Test
    fun `composer attach carries references, and a named thread`() {
        val line = bridge.composerAttach(listOf(stagedFile(id = "att-0009")), threadId = "t1")
        val data = JSONObject(line).getJSONObject("data")
        assertEquals("composer.attach", JSONObject(line).getString("topic"))
        assertEquals("t1", data.getString("threadId"))
        assertEquals(
            "${ShellContract.INTERFACE_ORIGIN}${ShellContract.SHELL_FILES_PREFIX}att-0009",
            data.getJSONArray("attachments").getJSONObject(0).getString("url"),
        )
    }

    @Test
    fun `connectivity and lifecycle use the topics and the spellings the contract fixes`() {
        val connectivity = JSONObject(bridge.connectivity(online = false))
        assertEquals("connectivity", connectivity.getString("topic"))
        assertEquals(false, connectivity.getJSONObject("data").getBoolean("online"))

        val background = JSONObject(bridge.lifecycle(foreground = false))
        assertEquals("lifecycle", background.getString("topic"))
        assertEquals("background", background.getJSONObject("data").getString("state"))

        val foreground = JSONObject(bridge.lifecycle(foreground = true))
        assertEquals("foreground", foreground.getJSONObject("data").getString("state"))
    }

    @Test
    fun `the descriptor can be re-sent whole as a shell changed event`() {
        val line = bridge.shellChanged()
        val event = JSONObject(line)
        assertEquals("shell.changed", event.getString("topic"))
        assertEquals(
            "the event's data is the descriptor",
            strings(P3Paths.example("ShellDescriptor", 1).getJSONArray("capabilities")),
            strings(event.getJSONObject("data").getJSONArray("capabilities")),
        )
    }

    @Test
    fun `dictate partial is one final fragment and speak state reports playback`() {
        val partial = JSONObject(
            bridge.dictatePartial(captureId = "dict-0007", text = "fix the\u0000 cart", isFinal = true),
        )
        assertEquals("dictate.partial", partial.getString("topic"))
        val partialData = partial.getJSONObject("data")
        assertEquals("dict-0007", partialData.getString("captureId"))
        assertEquals("the phone transcribes in one call, so the one fragment is final and cleaned", "fix the\uFFFD cart", partialData.getString("text"))
        assertTrue(partialData.getBoolean("isFinal"))

        val speak = JSONObject(bridge.speakState(playbackId = "play-0007", state = "playing"))
        assertEquals("speak.state", speak.getString("topic"))
        assertEquals("play-0007", speak.getJSONObject("data").getString("playbackId"))
        assertEquals("playing", speak.getJSONObject("data").getString("state"))
    }

    @Test
    fun `every topic the shell sends is a topic of the contract`() {
        val sent = listOf(
            bridge.shellChanged(),
            bridge.composerInsert("x", ComposerInsertSource.Dictation),
            bridge.composerAttach(listOf(stagedFile())),
            bridge.connectivity(online = true),
            bridge.lifecycle(foreground = true),
        )
        val known = ShellContract.CONTRACT_EVENT_TOPICS
        for (line in sent) {
            val topic = JSONObject(line).getString("topic")
            assertTrue("$topic is a contract topic", topic in known)
        }
    }
}
