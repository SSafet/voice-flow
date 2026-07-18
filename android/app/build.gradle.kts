plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.voiceflow.mobile"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.voiceflow.mobile"
        minSdk = 29
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

// No external dependencies on purpose: HttpURLConnection + org.json ship with
// the platform, which keeps the sideloaded APK small and the build offline-safe.
dependencies {}
