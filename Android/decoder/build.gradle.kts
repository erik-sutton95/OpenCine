// Live-view MediaCodec decoder (HEVC and AVC to a Surface), moved unchanged from the Pocket and
// Insta apps. The policy it runs (random-access hold, input ownership, error lifetime, present
// timing) is in `:media`; this module adds only the Android codec runtime.
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.decoder"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig { minSdk = 29 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
}

dependencies {
    api(project(":media"))
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(libs.kotlin.test.junit)
}
