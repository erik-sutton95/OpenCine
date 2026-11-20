// Live streaming for every app's Android shell (Swift twin: OpenCineStreaming, through the JNI
// facade StreamingNative exported by OpenCineStreamingAndroid). The shared run controller owns
// connect, reconnect, the send queue, bitrate and status; this module owns the socket, the
// MediaCodec encoders, the microphone, Keystore storage and the clocks. StreamingNative's class
// name is part of the native symbol names (consumer-rules.pro keeps it).
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

val repositoryRoot: File = projectDir.resolve("../..")

android {
    namespace = "com.opencapture.opencine.streaming"
    compileSdk = libs.versions.androidCompileSdk.get().toInt()
    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
    // FakeStreamingNative for this module's JVM tests and for composition tests elsewhere.
    testFixtures { enable = true }
    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    // KeystoreSeal, the device-only envelope every stored secret uses.
    api(project(":platform"))
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.kotlin.test.junit)
    // org.json from android.jar is a stub on the JVM.
    testImplementation(libs.json)
    testFixturesApi(libs.kotlinx.coroutines.core)
}

tasks.withType<Test>().configureEach {
    systemProperty("opencine.repositoryRoot", repositoryRoot.canonicalPath)
}
