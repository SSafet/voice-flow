import com.android.build.api.artifact.SingleArtifact
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val minSdkLevel = 29
val sdkLevel = 36

android {
    namespace = "com.voiceflow.mobile"
    compileSdk = sdkLevel

    defaultConfig {
        applicationId = "com.voiceflow.mobile"
        minSdk = minSdkLevel
        targetSdk = sdkLevel
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("int", "MIN_SDK", "$minSdkLevel")
        buildConfigField("int", "TARGET_SDK", "$sdkLevel")
        buildConfigField("int", "COMPILE_SDK", "$sdkLevel")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
        // Separate app/data/Keystore for automatic-sync device checks.
        create("syncQa") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".syncqa"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

// The dependencies the app has are named once, in dependencies.txt; checkDependencyPins
// compares that file with what this build actually declares and fails when they differ.
dependencies {
    implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
    implementation("androidx.webkit:webkit:1.17.0")
    implementation("androidx.work:work-runtime:2.11.2")
    implementation("com.google.firebase:firebase-messaging")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

tasks.register("checkDependencyPins") {
    group = "verification"
    val pinnedFile = file("dependencies.txt")
    val implementationDeps = configurations.getByName("implementation").dependencies
    val testDeps = configurations.getByName("testImplementation").dependencies
    doLast {
        fun render(dependencies: Iterable<org.gradle.api.artifacts.Dependency>): Set<String> =
            dependencies.map { dependency ->
                val version = dependency.version
                if (version.isNullOrEmpty()) {
                    "${dependency.group}:${dependency.name}"
                } else {
                    "${dependency.group}:${dependency.name}:$version"
                }
            }.toSet()
        fun pinned(prefix: String): Set<String> = pinnedFile.readLines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") && it.startsWith("$prefix ") }
            .map { it.removePrefix("$prefix ").trim().removePrefix("platform ").trim() }
            .toSet()
        val declaredImplementation = render(implementationDeps)
        val declaredTest = render(testDeps)
        val pinnedImplementation = pinned("implementation")
        val pinnedTest = pinned("testImplementation")
        if (declaredImplementation != pinnedImplementation || declaredTest != pinnedTest) {
            throw GradleException(
                "the declared dependencies are not the pinned ones.\n" +
                    "declared implementation: $declaredImplementation\n" +
                    "pinned implementation:   $pinnedImplementation\n" +
                    "declared testImplementation: $declaredTest\n" +
                    "pinned testImplementation:   $pinnedTest",
            )
        }
    }
}

val checkThreadProtocolLock = tasks.register<Exec>("checkThreadProtocolLock") {
    group = "verification"
    workingDir = rootProject.projectDir.parentFile
    environment("VF_PROJECT_DIR", rootProject.projectDir.parentFile.absolutePath)
    commandLine("bash", "scripts/sync-thread-protocol.sh", "--check")
}
tasks.named("preBuild") { dependsOn(checkThreadProtocolLock) }

val p1NotDue: List<String> = (project.findProperty("p1.notDue") as String?).orEmpty()
    .split(",").map { it.trim() }.filter { it.isNotEmpty() }

tasks.withType<KotlinCompile>().configureEach {
    if (name.endsWith("UnitTestKotlin")) exclude(p1NotDue.map { "**/p1/$it.kt" })
}

androidComponents {
    onVariants { variant ->
        val merged = variant.artifacts.get(SingleArtifact.MERGED_MANIFEST)
        val taskName = "test" + variant.name.replaceFirstChar { it.uppercase() } + "UnitTest"
        tasks.withType<Test>().matching { it.name == taskName }.configureEach {
            inputs.file(merged)
            jvmArgumentProviders.add(
                CommandLineArgumentProvider {
                    listOf("-Dvoiceflow.mergedManifest=" + merged.get().asFile.absolutePath)
                },
            )
        }
    }
}
