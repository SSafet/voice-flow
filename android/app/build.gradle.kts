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
    // The build needs JDK 21. Without a toolchain, a wrong JDK fails deep inside
    // AGP's jlink transform without ever naming a Java version; with it, Gradle
    // says which Java it wants. The bytecode stays Java 17 — that is what
    // compileOptions above and jvmTarget below decide, not this.
    jvmToolchain(21)
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

// What this build declares, by the configuration it declares it in, rendered at
// configuration time: every configuration a dependency can be declared on, not
// only `implementation` and `testImplementation`, so a fourth library cannot
// enter through `debugImplementation`, `api`, `compileOnly`, `runtimeOnly` or an
// androidTest bucket. Rendering it here rather than holding the live
// DependencySet into the task action is also what keeps the task cacheable.
// The two buckets the Android and Kotlin plugins fill for their own toolchain:
// the JDK image AGP compiles against, and the Kotlin build-tools implementation.
// Neither is a dependency of the app. They are named here rather than matched by
// shape, so a bucket nobody expected gaining a dependency fails this task instead
// of passing it.
val toolchainConfigurations = setOf("androidJdkImage", "kotlinBuildToolsApiClasspath")

val declaredDependencies: Map<String, Set<String>> = configurations
    .filter { it.isCanBeDeclared && it.name !in toolchainConfigurations }
    .associate { configuration ->
        configuration.name to configuration.dependencies.map { dependency ->
            val version = dependency.version
            if (version.isNullOrEmpty()) {
                "${dependency.group}:${dependency.name}"
            } else {
                "${dependency.group}:${dependency.name}:$version"
            }
        }.toSet()
    }
    .filterValues { it.isNotEmpty() }

tasks.register("checkDependencyPins") {
    group = "verification"
    description = "Fails when the build declares a dependency dependencies.txt does not pin, or the other way round."
    val pinnedFile = file("dependencies.txt")
    val declared = declaredDependencies
    inputs.file(pinnedFile)
    inputs.property("declared", declared.toString())
    doLast {
        val pinned = pinnedFile.readLines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .map { line ->
                val configuration = line.substringBefore(' ')
                configuration to line.substringAfter(' ').trim().removePrefix("platform ").trim()
            }
            .groupBy({ it.first }, { it.second })
            .mapValues { (_, coordinates) -> coordinates.toSet() }
        if (declared != pinned) {
            val differing = (declared.keys + pinned.keys).filter { declared[it] != pinned[it] }.sorted()
            throw GradleException(
                "the declared dependencies are not the ones dependencies.txt pins.\n" +
                    differing.joinToString("\n") { configuration ->
                        "  $configuration\n" +
                            "    declared: ${declared[configuration].orEmpty().sorted()}\n" +
                            "    pinned:   ${pinned[configuration].orEmpty().sorted()}"
                    },
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
