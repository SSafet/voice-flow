package com.voiceflow.mobile.device

/**
 * Work package P2, the test support the device tests share.
 *
 * Nothing in this file names an application class of the package, so it
 * compiles from the first task on, whichever test files are switched on.
 *
 * `EcdsaBytes` is a deliberately independent implementation of the P-256
 * signature encodings: the tests and the fake gateway use it to check what
 * `DeviceKeys` produced, never `DeviceKeys`' own conversion, so a bug in the
 * production conversion cannot cancel out against the same bug in the check.
 */
internal object EcdsaBytes {

    /** The raw 64-byte `r||s` form of P-256, as base64 of DER would carry it. */
    fun rawToDer(raw: ByteArray): ByteArray {
        require(raw.size == 64) { "a P-256 signature is 64 bytes, not ${raw.size}" }
        val r = integer(raw.copyOfRange(0, 32))
        val s = integer(raw.copyOfRange(32, 64))
        val body = r + s
        require(body.size < 128) { "a P-256 DER signature fits one length byte" }
        return byteArrayOf(0x30, body.size.toByte()) + body
    }

    private fun integer(unsigned: ByteArray): ByteArray {
        var start = 0
        while (start < unsigned.size - 1 && unsigned[start] == 0.toByte()) start++
        var value = unsigned.copyOfRange(start, unsigned.size)
        if (value[0].toInt() and 0x80 != 0) value = byteArrayOf(0) + value
        return byteArrayOf(0x02, value.size.toByte()) + value
    }

    /** The inverse, for reading a DER signature a JDK `Signature` produced. */
    fun derToRaw(der: ByteArray): ByteArray {
        var index = 0
        require(der[index++] == 0x30.toByte()) { "not a DER sequence" }
        var length = der[index++].toInt() and 0xFF
        if (length and 0x80 != 0) {
            val count = length and 0x7F
            length = 0
            repeat(count) { length = (length shl 8) or (der[index++].toInt() and 0xFF) }
        }
        val out = ByteArray(64)
        readInteger(der, index, out, 0)
        index = nextInteger(der, index)
        readInteger(der, index, out, 32)
        return out
    }

    private fun nextInteger(der: ByteArray, index: Int): Int {
        var i = index
        require(der[i++] == 0x02.toByte()) { "not a DER integer" }
        val length = der[i++].toInt() and 0xFF
        return i + length
    }

    private fun readInteger(der: ByteArray, index: Int, out: ByteArray, target: Int) {
        var i = index
        require(der[i++] == 0x02.toByte()) { "not a DER integer" }
        val length = der[i++].toInt() and 0xFF
        var start = i
        val end = i + length
        while (start < end - 1 && der[start] == 0.toByte()) start++
        val value = der.copyOfRange(start, end)
        require(value.size <= 32) { "a P-256 integer is at most 32 bytes" }
        System.arraycopy(value, 0, out, target + (32 - value.size), value.size)
    }
}

/** A clock the tests move by hand, so no test ever waits. */
internal class FixedClock(var millis: Long) {
    fun now(): Long = millis
    fun advance(deltaMillis: Long) {
        millis += deltaMillis
    }
}

/**
 * The worktree paths a structural test needs. `thread-protocol.lock` at the
 * repository root is the anchor, exactly as P1's tests find it, so the tests
 * run from the `android` module of a worktree and nowhere else.
 */
internal object DevicePaths {

    val repoRoot: java.io.File by lazy {
        var dir: java.io.File? = java.io.File(System.getProperty("user.dir") ?: ".").absoluteFile
        var found: java.io.File? = null
        var hops = 0
        while (found == null && hops < 6) {
            val here = dir ?: break
            if (java.io.File(here, "thread-protocol.lock").isFile) found = here else dir = here.parentFile
            hops += 1
        }
        found ?: throw AssertionError(
            "no thread-protocol.lock at or above " + System.getProperty("user.dir") +
                "; the P2 unit tests must run from the android module of a VoiceFlow worktree",
        )
    }

    /** Every Kotlin source of the app, for the structural deletion checks. */
    fun mainSources(): List<java.io.File> {
        val root = java.io.File(repoRoot, "android/app/src/main/kotlin/com/voiceflow/mobile")
        if (!root.isDirectory) throw AssertionError("no source directory at $root")
        return root.walkTopDown().filter { it.isFile && it.name.endsWith(".kt") }.toList()
    }
}

