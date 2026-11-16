// Android system adapters. Portable policy stays in :core/:media; this module imports
// no integration, UI or app and owns no app storage namespace.
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.platform"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig { minSdk = 29 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
}

dependencies {
    // Core values only: the station host path seam and the network it joins.
    api(project(":core"))
    // The camera access-point join and the credential IO helper suspend.
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    // org.json from android.jar is a stub on the JVM; the real artifact backs the store tests.
    testImplementation(libs.json)
}
