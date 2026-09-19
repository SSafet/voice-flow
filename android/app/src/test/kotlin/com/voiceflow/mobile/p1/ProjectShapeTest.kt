package com.voiceflow.mobile.p1

import com.voiceflow.mobile.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * Work package P1, the shape of the Android project: the SDK levels, exactly
 * three dependencies, a pinned Gradle, and the fact that P1 removes nothing.
 *
 * Every assertion here reads either what the Android build actually produced
 * (the merged manifest, `BuildConfig`, the unit test classpath) or the one file
 * that owns a pinned value. None of them reads a value this test also writes.
 */
class ProjectShapeTest {

    private fun loads(className: String): Boolean =
        try {
            Class.forName(className, false, javaClass.classLoader)
            true
        } catch (_: Throwable) {
            false
        }

    private fun pinnedLines(): List<String> =
        P1Paths.file("android/app/dependencies.txt")
            .readLines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }

    // ── The SDK levels (Global Constraints: minSdk 29, compileSdk and targetSdk 36) ──

    @Test
    fun `the merged manifest declares minSdk 29 and targetSdk 36`() {
        val usesSdk = P1Paths.elements(P1Paths.xml(P1Paths.mergedManifest), "uses-sdk")
        assertEquals("the merged manifest declares exactly one uses-sdk element", 1, usesSdk.size)
        assertEquals("minSdkVersion", "29", P1Paths.androidAttribute(usesSdk[0], "minSdkVersion"))
        assertEquals("targetSdkVersion", "36", P1Paths.androidAttribute(usesSdk[0], "targetSdkVersion"))
    }

    @Test
    fun `the build script and the merged manifest name the same SDK levels`() {
        assertEquals("BuildConfig.MIN_SDK", 29, BuildConfig.MIN_SDK)
        assertEquals("BuildConfig.TARGET_SDK", 36, BuildConfig.TARGET_SDK)
        assertEquals("BuildConfig.COMPILE_SDK", 36, BuildConfig.COMPILE_SDK)
        val usesSdk = P1Paths.elements(P1Paths.xml(P1Paths.mergedManifest), "uses-sdk").single()
        assertEquals(
            "minSdk is declared once and used everywhere",
            P1Paths.androidAttribute(usesSdk, "minSdkVersion"),
            BuildConfig.MIN_SDK.toString(),
        )
        assertEquals(
            "targetSdk is declared once and used everywhere",
            P1Paths.androidAttribute(usesSdk, "targetSdkVersion"),
            BuildConfig.TARGET_SDK.toString(),
        )
    }

    // ── Exactly three dependencies ──

    @Test
    fun `dependencies are pinned in one file and nowhere else`() {
        val lines = pinnedLines()
        val implementation = lines
            .filter { it.startsWith("implementation ") }
            .map { it.removePrefix("implementation ").trim() }
        val testImplementation = lines
            .filter { it.startsWith("testImplementation ") }
            .map { it.removePrefix("testImplementation ").trim() }
        assertEquals(
            "every line of dependencies.txt begins with implementation or testImplementation: $lines",
            lines.size,
            implementation.size + testImplementation.size,
        )
        assertEquals(
            listOf(
                "androidx.webkit:webkit:1.17.0",
                "androidx.work:work-runtime:2.11.2",
                "com.google.firebase:firebase-messaging",
                "platform com.google.firebase:firebase-bom:34.19.0",
            ),
            implementation.sorted(),
        )
        assertEquals(
            listOf("junit:junit:4.13.2", "org.json:json:20240303"),
            testImplementation.sorted(),
        )
    }

    @Test
    fun `no fourth library is pinned`() {
        val refused = listOf(
            "kotlinx-serialization", "okhttp", "retrofit", "moshi", "klaxon",
            "robolectric", "mockito", "assertj", "truth", "ktor", "volley",
            "glide", "coil", "dagger", "hilt", "koin", "timber", "rxjava",
        )
        for (line in pinnedLines()) {
            for (name in refused) {
                if (line.contains(name)) fail("dependencies.txt pins a fourth library ($name): $line")
            }
        }
    }

    @Test
    fun `the three dependencies resolved onto the classpath`() {
        assertTrue("androidx.webkit WebViewAssetLoader", loads("androidx.webkit.WebViewAssetLoader"))
        assertTrue("androidx.webkit WebViewFeature", loads("androidx.webkit.WebViewFeature"))
        assertTrue("androidx.work WorkManager", loads("androidx.work.WorkManager"))
        assertTrue("Firebase Cloud Messaging", loads("com.google.firebase.messaging.FirebaseMessaging"))
    }

    @Test
    fun `no serialisation or HTTP library came with them`() {
        for (className in listOf(
            "okhttp3.OkHttpClient",
            "retrofit2.Retrofit",
            "com.squareup.moshi.Moshi",
            "kotlinx.serialization.json.Json",
            "com.beust.klaxon.Klaxon",
            "org.robolectric.Robolectric",
        )) {
            assertFalse("$className must not be on the classpath", loads(className))
        }
    }

    // ── One pinned Gradle, so the build is the same build everywhere ──

    @Test
    fun `the Gradle wrapper pins one version`() {
        val properties = P1Paths.file("android/gradle/wrapper/gradle-wrapper.properties").readText()
        assertTrue(
            "gradle-wrapper.properties must pin gradle-9.3.1-bin.zip:\n$properties",
            properties.contains("gradle-9.3.1-bin.zip"),
        )
        assertTrue("android/gradle/wrapper/gradle-wrapper.jar", P1Paths.path("android/gradle/wrapper/gradle-wrapper.jar").isFile)
        assertTrue("android/gradlew must be executable", P1Paths.file("android/gradlew").canExecute())
    }

    // ── P1 removes nothing ──

    @Test
    fun `no source file a later package deletes has been removed`() {
        for (name in listOf(
            "Assistant.kt", "MainActivity.kt", "CloudSettingsActivity.kt", "Pairing.kt",
            "SyncClient.kt", "SyncMerge.kt", "SyncIdentity.kt", "SyncJob.kt",
            "LocalSyncDiscovery.kt", "Store.kt", "Net.kt", "Keys.kt",
        )) {
            assertTrue(
                "$name is deleted by P4 or P6, never by P1",
                File(P1Paths.repoRoot, "${P1Paths.SOURCE_DIR}/$name").isFile,
            )
        }
    }

    @Test
    fun `the old app surface is still declared in the merged manifest`() {
        val document = P1Paths.xml(P1Paths.mergedManifest)
        val application = P1Paths.elements(document, "application").single()
        assertEquals(
            "android:usesCleartextTraffic is deleted by P6, not by P1",
            "true",
            P1Paths.androidAttribute(application, "usesCleartextTraffic"),
        )
        val declared = listOf("activity", "activity-alias", "service", "receiver")
            .flatMap { P1Paths.elements(document, it) }
            .mapNotNull { P1Paths.androidAttribute(it, "name") }
            .toSet()
        for (component in listOf(
            "com.voiceflow.mobile.MainActivity",
            "com.voiceflow.mobile.CloudSettingsActivity",
            "com.voiceflow.mobile.SyncJob",
            "com.voiceflow.mobile.BubbleService",
            "com.voiceflow.mobile.InsertionService",
            "com.voiceflow.mobile.RecordTileService",
            "com.voiceflow.mobile.DictateTrampoline",
            "com.voiceflow.mobile.BubbleBootReceiver",
        )) {
            assertTrue("$component is missing from the merged manifest: $declared", declared.contains(component))
        }
    }

    // ── A lint error is fixed where it happens, never hidden ──

    @Test
    fun `there is no lint baseline`() {
        assertFalse(
            "android/app/lint-baseline.xml must not exist: a lint error is fixed at its site, not recorded",
            P1Paths.path("android/app/lint-baseline.xml").exists(),
        )
    }

    // ── The generated contract copy is where the sync script writes it ──

    @Test
    fun `the generated contract copy is compiled by this module`() {
        assertTrue(
            "the Kotlin copy must sit where scripts/sync-thread-protocol.sh writes it",
            P1Paths.path("${P1Paths.SOURCE_DIR}/generated/PlatformContracts.kt").isFile,
        )
    }
}
