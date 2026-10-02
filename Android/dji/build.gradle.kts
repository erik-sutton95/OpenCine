// DJI Android integration (Kotlin side of OpenCineDJI), moved from the OpenPocketCine app: BLE
// link and initialization, Wi-Fi datalink driver, DUML command and status models, gimbal
// programs, connection and live-view policies, and the OpenCineCore CameraSession adapter.
// Wire bytes come from the app's Swift Android library through the JNI facade DjiNative, whose
// class name is part of the native symbol names (consumer-rules.pro keeps it). The app keeps its
// session orchestration, diagnostics, preferences and UI.
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
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(project(":decoder"))
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.json)
}

// camfov-vectors.tsv is shared with the Swift CamFovVectorTests (Fixtures/ at the repository root).
tasks.withType<Test>().configureEach {
    val fixtures = rootDir.resolve("../Fixtures")
    inputs.dir(fixtures)
    systemProperty("opencine.fixtures", fixtures.absolutePath)
}
