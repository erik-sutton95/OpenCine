// Frame.io for every app's Android shell (Swift twin of the wire: OpenCineFrameIO, through the
// JNI facade FrameioNative exported by OpenCineFrameIOAndroid). One owner for the account state,
// token refresh, project listing, the multipart upload and status poll, upload history, the
// metadata sidecar and the camera-network hop lease, delivered through the shared delivery
// contracts of :appkit. Apps supply only their client id, redirect scheme, storage namespace and
// camera-network hop adapter. FrameioNative's class name is part of the native symbol names
// (consumer-rules.pro keeps it).
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.frameio"
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
}

dependencies {
    api(project(":appkit"))
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.json)
}
