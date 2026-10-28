// Nikon Android integration (Kotlin side of OpenCineNikon), moved from the OpenZCine app: the
// Nikon session contract (CameraSession, LiveFrameSource) and its production session over the
// Swift PTP-IP / USB PTP layer, the live-view frame source, property and metadata wires, ISO and
// white-balance picker policy, and the OpenCineCore CameraSession adapter (NikonOpenCineSession).
// The session layer itself is Swift (OpenCineNikonAndroid), reached through the JNI facade
// NikonNative, whose class name is part of the native symbol names (consumer-rules.pro keeps it).
// The app keeps the Android USB host, discovery and pairing, diagnostics, preferences and UI.
plugins {
    alias(libs.plugins.android.library)
}

group = "com.opencapture.opencine"
version = "0.1.0-SNAPSHOT"

android {
    namespace = "com.opencapture.opencine.nikon"
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
    api(project(":nikon-wire"))
    api(project(":media"))
    api(project(":gyro"))
    // Session recovery state and copy have one owner (D-NI1).
    api(project(":camera-vocabulary"))
    // The shared camera access-point join (NikonCameraAp).
    api(project(":platform"))
    api(libs.kotlinx.coroutines.core)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.json)
    testImplementation(testFixtures(project(":core")))
    testImplementation(testFixtures(project(":gyro")))
}

// The saved-setup fixtures are shared with the Swift OpenCineNikonTests (Fixtures/ at the
// repository root).
tasks.withType<Test>().configureEach {
    val fixtures = rootDir.resolve("../Fixtures")
    inputs.dir(fixtures)
    systemProperty("opencine.fixtures", fixtures.absolutePath)
}
