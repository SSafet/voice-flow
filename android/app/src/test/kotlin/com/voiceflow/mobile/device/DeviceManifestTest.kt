package com.voiceflow.mobile.device

import com.voiceflow.mobile.generated.DeviceTool
import com.voiceflow.mobile.generated.ToolClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * Work package P2, the phone's manifest (05 §3.2 "The record", 08 §3.3): a
 * phone declares no channel features and only the `observe` switch, its tool
 * catalogue travels with the manifest, and `catalogHash` changes exactly when
 * the tools change. The hash is the device's own; the gateway stores it and
 * asks for the catalogue again only when it moves.
 */
class DeviceManifestTest {

    private val gateway = FakeDeviceTransport()
    private val keys = DeviceKeys(FakeSigningKeyStore())
    private val state = InMemoryDeviceStateStore()
    private val clock = FixedClock(Instant.parse("2026-09-19T10:00:00.000Z").toEpochMilli())

    private fun tool(
        name: String,
        description: String = "reads something from the phone",
        schema: String = """{"type":"object"}""",
        toolClass: ToolClass = ToolClass.Observe,
    ): DeviceTool = DeviceTool(
        name = name,
        description = description,
        inputSchemaJSON = schema,
        deviceToolClass = toolClass,
    )

    private fun signedIn(): DeviceIdentity {
        val identity = DeviceIdentity(gateway.origin(), gateway, keys, state, clock::now)
        identity.completeSignIn(identity.startSignIn("owner@test.local"), "1234 5678", "Pixel 8")
        return identity
    }

    @Test
    fun `the phone's manifest declares no channel features and only the observe switch`() {
        val manifest = DeviceManifestBuilder.phone(
            appVersion = "0.1.0",
            allowedClients = listOf("01CCCCCCCCCCCCCCCCCCCCCCCC"),
            tools = emptyList(),
            observe = true,
        )
        assertEquals("a phone holds no socket, so it speaks no frame family", emptyList<String>(), manifest.features)
        assertEquals(true, manifest.switches.observe)
        assertNull(manifest.switches.threads)
        assertNull(manifest.switches.files)
        assertNull(manifest.switches.terminal)
        assertNull(manifest.switches.present)
        assertNull(manifest.switches.control)
        assertEquals(listOf("01CCCCCCCCCCCCCCCCCCCCCCCC"), manifest.allowedClients)
        assertTrue(manifest.tools.isEmpty())
        assertTrue("the catalog hash is always populated", manifest.catalogHash.isNotEmpty())
    }

    @Test
    fun `the catalog hash is a lower-case SHA-256 in hex`() {
        val hash = DeviceManifestBuilder.catalogHash(listOf(tool("get_location")))
        assertTrue("$hash is not a SHA-256 hex digest", Regex("^[0-9a-f]{64}$").matches(hash))
    }

    @Test
    fun `the catalog hash ignores the order of the tools`() {
        val location = tool("get_location")
        val photo = tool("take_photo", description = "takes one photo", toolClass = ToolClass.Observe)
        assertEquals(
            DeviceManifestBuilder.catalogHash(listOf(location, photo)),
            DeviceManifestBuilder.catalogHash(listOf(photo, location)),
        )
    }

    @Test
    fun `the catalog hash changes when a tool's name, description, schema or class changes`() {
        val base = DeviceManifestBuilder.catalogHash(listOf(tool("get_location")))
        assertNotEquals(base, DeviceManifestBuilder.catalogHash(listOf(tool("take_photo"))))
        assertNotEquals(base, DeviceManifestBuilder.catalogHash(listOf(tool("get_location", description = "another sentence"))))
        assertNotEquals(base, DeviceManifestBuilder.catalogHash(listOf(tool("get_location", schema = """{"type":"array"}"""))))
        assertNotEquals(base, DeviceManifestBuilder.catalogHash(listOf(tool("get_location", toolClass = ToolClass.Present))))
    }

    @Test
    fun `the tools keep the class and the input schema the phone declared`() {
        val tools = listOf(
            tool("get_location", toolClass = ToolClass.Observe),
            tool("take_photo", toolClass = ToolClass.Observe),
            tool("recent_shares", schema = """{"type":"object","properties":{}}""", toolClass = ToolClass.Observe),
        )
        val manifest = DeviceManifestBuilder.phone("0.1.0", emptyList(), tools, observe = true)
        assertEquals(tools.map { it.name }, manifest.tools.map { it.name })
        assertEquals(tools.map { it.deviceToolClass }, manifest.tools.map { it.deviceToolClass })
        assertEquals(tools.map { it.inputSchemaJSON }, manifest.tools.map { it.inputSchemaJSON })
        assertEquals(DeviceManifestBuilder.catalogHash(tools), manifest.catalogHash)
    }

    @Test
    fun `the published manifest carries the hash the gateway records`() {
        val identity = signedIn()
        val tools = listOf(tool("get_location"), tool("recent_shares"))
        val manifest = DeviceManifestBuilder.phone("0.1.0", emptyList(), tools, observe = true)
        identity.publishManifest(manifest)
        val body = gateway.manifestBodies.last()
        assertEquals(manifest.catalogHash, body.getString("catalogHash"))
        assertEquals(2, body.getJSONArray("tools").length())

        val first = body.getJSONArray("tools").getJSONObject(0)
        assertEquals("get_location", first.getString("name"))
        assertEquals(
            "the wire spelling is the contract's, not the generated Kotlin property name",
            """{"type":"object"}""",
            first.getString("inputSchemaJson"),
        )
        assertEquals("observe", first.getString("class"))
        assertTrue("the generated Kotlin spelling must not reach the wire", !first.has("inputSchemaJSON"))
        assertTrue(!first.has("deviceToolClass"))

        assertEquals(
            "a phone's manifest carries only the switches it has",
            listOf("observe"),
            body.getJSONObject("switches").keys().asSequence().sorted().toList(),
        )
    }
}
