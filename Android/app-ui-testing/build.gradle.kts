// The shared conformance kit (Swift twin: OpenCineAppUITesting): scenarios every app runs against its
// own production composition from its androidTest source set
// (`androidTestImplementation("com.opencapture.opencine:app-ui-testing")`). The scenarios drive the
// installed app through the platform accessibility tree and injected touches, as an operator and
// TalkBack reach it; they never mount a composable. Apps subclass each scenario in one line.
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.appuitesting"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig { minSdk = 29 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin {
        explicitApi()
        compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
    }
}

dependencies {
    // ReviewLaunch, MonitorCapabilities and the settings and media values the scenarios stage.
    api(project(":monitor-ui"))
    api(libs.androidx.test.core)
    api(libs.androidx.test.runner)
    api(libs.androidx.test.ext.junit)
    api(libs.kotlin.test.junit)
    // Every app's test APK gets the run listener that keeps Android's full screen tutorial off.
    api(project(":system-hints-testing"))
    // Screenshots go through the test storage service, so connected runs collect them.
    testImplementation(libs.kotlin.test.junit)
}
