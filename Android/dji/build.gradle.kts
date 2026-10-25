// DJI Android integration (Kotlin side of OpenCineDJI), moved from the OpenPocketCine app: the
// camera session (PocketCameraSession), BLE link, Wi-Fi joining and datalink driver, DUML command
// and status models, gimbal programs, connection and live-view policies, and the OpenCineCore
// CameraSession adapter. Wire bytes come through the JNI facade DjiNative (Swift side:
// OpenCineDJIAndroid), whose class name is part of the native symbols (consumer-rules.pro keeps
// it). The app supplies preferences, diagnostics, build identity and face detection through
// PocketSessionHost and keeps all UI.
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.dji"
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
    api(project(":core"))
    api(project(":media"))
    api(project(":camera-vocabulary"))
    api(project(":platform"))
    api(project(":decoder"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.json)
    testImplementation(testFixtures(project(":core")))
}

// Same unchanged model/zoom vectors as the Swift integration tests.
tasks.withType<Test>().configureEach {
    systemProperty("opencine.fixtures", rootProject.projectDir.resolve("../Fixtures").absolutePath)
}
